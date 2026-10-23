import AVFoundation
import Combine
import XCTest
@testable import TheAgoraLA

@MainActor
private final class StubSpeech: SpeechRecognizing {
    @Published var transcript = ""
    var transcriptPublisher: AnyPublisher<String, Never> { $transcript.eraseToAnyPublisher() }
    let changes = PassthroughSubject<Void, Never>()
    var updates: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    var isRecording = false
    var inputName = "Test microphone"
    var inputLevel = 0.0
    var hasDetectedVoice = false
    var lastVoiceActivityDate = Date.distantPast
    var authorizationNeedsSettings = false
    var canStart = true
    var starts = 0
    var finalTranscript: String?
    var delayFinalization = false
    var finalization: CheckedContinuation<String, Never>?
    func requestAuthorization() async -> Bool { !authorizationNeedsSettings }
    func startRecording() async -> Bool {
        starts += 1
        transcript = ""
        isRecording = canStart
        return canStart
    }
    func finishRecording() async -> String {
        isRecording = false
        if delayFinalization {
            return await withCheckedContinuation { finalization = $0 }
        }
        return finalTranscript ?? transcript
    }
    func stopRecording() { isRecording = false }
}

@MainActor
private final class StubNarrator: PromptNarrating {
    struct Reading {
        let text: String
        let persist: Bool
        let completion: (Result<Void, Error>) -> Void
    }
    var readings: [Reading] = []
    func speak(text: String, persist: Bool, preferNatural: Bool, voice: AVSpeechSynthesisVoice?,
               status: @escaping (String) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        readings.append(Reading(text: text, persist: persist, completion: completion))
    }
    func stop() {}
    func finish(_ index: Int? = nil, successfully: Bool = true) {
        let selected = index ?? readings.count - 1
        guard readings.indices.contains(selected) else { XCTFail("Expected a pending narration"); return }
        readings[selected].completion(successfully ? .success(()) : .failure(NaturalNarrationError.invalidAudio))
    }
}

@MainActor
private final class StubGrader: AnswerEvaluating {
    var answers: [String] = []
    var cancelled: [Bool] = []
    var delayed = false
    var continuation: CheckedContinuation<AIResult, Never>?
    var result = AIResult(score: 90, grade: .a, feedback: "You captured the main idea. Add the reason: evidence changed the speaker's view.", awardedPoints: 10)
    func evaluateAnswer(question: String, expectedAnswer: String, userAnswer: String,
                        transcript: String?, progressSeconds: Double?, analysisDepth: AnswerAnalysisDepth) async -> AIResult {
        answers.append(userAnswer)
        cancelled.append(Task.isCancelled)
        if delayed { return await withCheckedContinuation { continuation = $0 } }
        return result
    }
}

@MainActor
final class PlaybackFlowTests: XCTestCase {
    private struct Harness {
        let vm: PlayerViewModel
        let speech: StubSpeech
        let narrator: StubNarrator
        let grader: StubGrader
        let points: PointsStore
        let clock: TestClock
        let prompt: Prompt
    }
    private final class TestClock { var date = Date() }
    private var models: [PlayerViewModel] = []
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for vm in models {
            vm.continuePlayback()
            vm.audioManager.pause()
            UserDefaults.standard.removeObject(forKey: "TheAgoraLA.PromptHistory.\(vm.episode.id.uuidString)")
        }
        models.removeAll()
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func makeHarness(handsFree: Bool = true) async throws -> Harness {
        let speech = StubSpeech(), narrator = StubNarrator(), grader = StubGrader(), clock = TestClock()
        let vm = PlayerViewModel(speechManager: speech, aiService: grader, narrator: narrator, now: { clock.date })
        models.append(vm)
        vm.drivingModeEnabled = handsFree
        vm.selectedNarrationVoiceID = "test-local-voice" // Disables paid prefetch; narrator is injected.
        vm.feedbackDetailLevel = .full
        let prompt = Prompt(id: UUID(), timestampSeconds: 2, question: "Why did the speaker change their mind?",
                            expectedAnswer: "New evidence changed the speaker's view.", timingVerified: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agora-flow-\(UUID()).wav")
        temporaryFiles.append(url)
        // A real local AVPlayer item makes prompt scheduling and playback holds part of the test.
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        vm.updateEpisode(Episode(id: UUID(), title: "Regression episode", audioURL: url, prompts: [prompt]))
        vm.audioManager.load(url: url)
        await eventually { vm.audioManager.duration > 1 }
        let points = PointsStore()
        vm.bind(pointsStore: points)
        vm.audioManager.play()
        vm.checkForPrompt(at: 3)
        XCTAssertTrue(vm.showPrompt)
        XCTAssertTrue(vm.audioManager.playbackIsHeld)
        XCTAssertFalse(vm.audioManager.isPlaying)
        return Harness(vm: vm, speech: speech, narrator: narrator, grader: grader, points: points, clock: clock, prompt: prompt)
    }

    private func beginAnswer(_ h: Harness) async {
        XCTAssertEqual(h.vm.drivingPromptState, .announcingPrompt)
        h.narrator.finish()
        await eventually { h.speech.isRecording }
        XCTAssertEqual(h.vm.drivingPromptState, .listening)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
    }

    private func submitBySilence(_ h: Harness, answer: String = "The speaker considered new evidence") async {
        h.speech.transcript = answer
        await eventually { h.vm.answerText == answer }
        h.clock.date = h.clock.date.addingTimeInterval(4)
        await eventually { !h.grader.answers.isEmpty }
    }

    func testFullQuestionAnswerFeedbackResumeForEveryDetailLevel() async throws {
        for detail in FeedbackDetailLevel.allCases {
            let h = try await makeHarness()
            h.vm.feedbackDetailLevel = detail
            let pointsBefore = h.points.totalPoints
            await beginAnswer(h)
            h.speech.finalTranscript = "New evidence changed the speaker's view completely"
            await submitBySilence(h)
            await eventually { h.vm.drivingPromptState == .speakingFeedback }
            XCTAssertEqual(h.grader.answers, [h.speech.finalTranscript!])
            XCTAssertEqual(h.grader.cancelled, [false])
            XCTAssertTrue(h.vm.hasScoredActivePrompt)
            XCTAssertEqual(h.vm.feedbackText, h.grader.result.feedback)
            XCTAssertEqual(h.vm.response(for: h.prompt)?.answer, h.speech.finalTranscript)
            XCTAssertEqual(h.points.totalPoints - pointsBefore, 10)
            XCTAssertTrue(h.narrator.readings.last!.text.contains(h.grader.result.feedback))
            XCTAssertFalse(h.narrator.readings.last!.persist)
            h.vm.play() // Lock-screen Play must not skip feedback.
            XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
            h.narrator.finish()
            await eventually { !h.vm.showPrompt }
            XCTAssertFalse(h.vm.audioManager.playbackIsHeld)
            XCTAssertTrue(h.vm.audioManager.isPlaying)
            // A duplicate completion cannot reopen/advance anything or award twice.
            h.narrator.finish()
            XCTAssertEqual(h.points.totalPoints - pointsBefore, 10)
            h.vm.audioManager.pause()
        }
    }

    func testPlayCannotDismissFirstQuestionWhileAnnouncingOrListening() async throws {
        let h = try await makeHarness()
        h.vm.play()
        XCTAssertEqual(h.vm.drivingPromptState, .announcingPrompt)
        XCTAssertTrue(h.vm.showPrompt)
        await beginAnswer(h)
        h.vm.togglePlay()
        XCTAssertTrue(h.speech.isRecording)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        XCTAssertTrue(h.grader.answers.isEmpty)
    }

    func testMicrophoneFailureKeepsQuestionPausedForRetry() async throws {
        let h = try await makeHarness()
        h.speech.canStart = false
        h.narrator.finish()
        await eventually { h.speech.starts == 2 && h.vm.drivingPromptState == .idle }
        XCTAssertTrue(h.vm.showPrompt)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        XCTAssertEqual(h.narrator.readings.count, 1)
        h.speech.canStart = true
        h.vm.drivingMicTapped()
        await beginAnswer(h)
    }

    func testDeniedPermissionKeepsQuestionAndAllowsTypedSubmission() async throws {
        let h = try await makeHarness()
        h.speech.canStart = false
        h.speech.authorizationNeedsSettings = true
        h.narrator.finish()
        await eventually { h.vm.handsFreeNeedsSettings }
        XCTAssertFalse(h.vm.drivingModeEnabled)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        h.vm.answerText = "Evidence changed the speaker's view"
        await h.vm.submitAnswer(pointsStore: h.points)
        XCTAssertTrue(h.vm.hasScoredActivePrompt)
        XCTAssertTrue(h.vm.showPrompt)
    }

    func testTwoEmptyListeningAttemptsNeverResumePodcast() async throws {
        let h = try await makeHarness()
        await beginAnswer(h)
        h.clock.date = h.clock.date.addingTimeInterval(16)
        await eventually { h.vm.drivingPromptState == .retryingListening }
        h.narrator.finish()
        await eventually { h.speech.isRecording }
        h.clock.date = h.clock.date.addingTimeInterval(16)
        await eventually { h.vm.drivingPromptState == .idle }
        XCTAssertTrue(h.vm.showPrompt)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        XCTAssertTrue(h.grader.answers.isEmpty)
    }

    func testRecognitionEndsEarlyWithNoWordsKeepsQuestionPaused() async throws {
        let h = try await makeHarness()
        await beginAnswer(h)
        h.speech.isRecording = false
        await eventually { h.vm.drivingPromptState == .retryingListening }
        h.narrator.finish()
        await eventually { h.speech.isRecording }
        h.speech.isRecording = false
        await eventually { h.vm.drivingPromptState == .idle }
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
    }

    func testNarrationFailureDoesNotMasqueradeAsCompletion() async throws {
        let h = try await makeHarness()
        h.narrator.finish(successfully: false)
        XCTAssertEqual(h.vm.drivingPromptState, .idle)
        XCTAssertEqual(h.speech.starts, 0)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        h.vm.drivingMicTapped()
        await beginAnswer(h)
        await submitBySilence(h)
        await eventually { h.vm.drivingPromptState == .speakingFeedback }
        h.narrator.finish(successfully: false)
        XCTAssertEqual(h.vm.drivingPromptState, .idle)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        XCTAssertFalse(h.vm.feedbackText.isEmpty)
    }

    func testStopFeedbackAndLateCompletionStayPaused() async throws {
        let h = try await makeHarness()
        await beginAnswer(h)
        await submitBySilence(h)
        await eventually { h.vm.drivingPromptState == .speakingFeedback }
        h.vm.stopFeedbackNarration()
        h.narrator.finish()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(h.vm.showPrompt)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        h.vm.continuePlayback()
        XCTAssertTrue(h.vm.audioManager.isPlaying)
    }

    func testStaleGradingCannotScoreReopenedSamePrompt() async throws {
        let h = try await makeHarness()
        h.grader.delayed = true
        await beginAnswer(h)
        await submitBySilence(h)
        h.vm.continuePlayback()
        h.vm.presentPrompt(h.prompt)
        h.vm.answerText = "A different answer"
        h.grader.continuation?.resume(returning: h.grader.result)
        h.grader.continuation = nil
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(h.vm.feedbackText.isEmpty)
        XCTAssertFalse(h.vm.hasScoredActivePrompt)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
    }

    func testStaleFinalRecognitionCannotSubmitAfterReset() async throws {
        let h = try await makeHarness()
        await beginAnswer(h)
        h.speech.delayFinalization = true
        h.vm.drivingMicTapped()
        await eventually { h.speech.finalization != nil }
        XCTAssertTrue(h.vm.resetPromptProgress(for: h.vm.episode.id))
        h.vm.presentPrompt(h.prompt)
        h.speech.finalization?.resume(returning: "An obsolete answer")
        h.speech.finalization = nil
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(h.grader.answers.isEmpty)
        XCTAssertTrue(h.vm.answerText.isEmpty)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
    }

    func testStaleNarrationCannotStartMicrophoneForAnotherPrompt() async throws {
        let h = try await makeHarness()
        h.vm.presentPrompt(h.prompt)
        h.narrator.finish(0)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(h.speech.starts, 0)
        XCTAssertEqual(h.vm.drivingPromptState, .idle)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
    }

    func testNaturalLanguageAnswerContainingMoveOnIsGraded() async throws {
        let h = try await makeHarness()
        await beginAnswer(h)
        await submitBySilence(h, answer: "They chose to move on")
        XCTAssertEqual(h.grader.answers, ["They chose to move on"])
    }

    func testExplicitSpokenSkipResumesOnlyAfterAcknowledgement() async throws {
        let h = try await makeHarness()
        await beginAnswer(h)
        h.speech.transcript = "skip this question"
        await eventually { h.vm.answerText == "skip this question" }
        h.clock.date = h.clock.date.addingTimeInterval(4)
        await eventually { h.vm.drivingPromptState == .speakingFeedback }
        XCTAssertTrue(h.grader.answers.isEmpty)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        h.narrator.finish()
        await eventually { !h.vm.showPrompt }
    }

    func testWrittenFeedbackWaitsForContinueAtEveryDetailLevel() async throws {
        for detail in FeedbackDetailLevel.allCases {
            let h = try await makeHarness(handsFree: false)
            h.vm.feedbackDetailLevel = detail
            h.vm.answerText = "New evidence"
            await h.vm.submitAnswer(pointsStore: h.points)
            XCTAssertTrue(h.vm.showPrompt)
            XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
            XCTAssertFalse(h.vm.feedbackText.isEmpty)
            // Former timers fired at 1.6s/4.5s; waiting past both catches hidden automatic dismissals.
            try? await Task.sleep(nanoseconds: 4_700_000_000)
            XCTAssertTrue(h.vm.showPrompt)
            XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
            h.vm.continuePlayback()
            XCTAssertTrue(h.vm.audioManager.isPlaying)
            h.vm.audioManager.pause()
        }
    }

    func testInterruptedFeedbackReplaysBeforeResume() async throws {
        let h = try await makeHarness()
        await beginAnswer(h)
        await submitBySilence(h)
        await eventually { h.vm.drivingPromptState == .speakingFeedback }
        let oldReading = h.narrator.readings.count - 1
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await eventually { h.vm.drivingPromptState == .idle }
        h.narrator.finish(oldReading)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                                   AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        await eventually { h.narrator.readings.count > oldReading + 1 }
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        h.narrator.finish()
        await eventually { !h.vm.showPrompt }
    }
    func testFeedbackFinishingDuringInterruptionWaitsAndCanBeReplayed() async throws {
        let h = try await makeHarness()
        h.grader.delayed = true
        await beginAnswer(h)
        await submitBySilence(h)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try? await Task.sleep(nanoseconds: 50_000_000)
        h.grader.continuation?.resume(returning: h.grader.result)
        h.grader.continuation = nil
        await eventually { h.vm.hasScoredActivePrompt }
        XCTAssertEqual(h.narrator.readings.count, 1)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: UInt(0)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.narrator.readings.count, 1)
        h.vm.replayFeedbackNarration()
        XCTAssertEqual(h.narrator.readings.count, 2)
        XCTAssertTrue(h.narrator.readings.last!.text.contains(h.grader.result.feedback))
        h.narrator.finish()
        await eventually { !h.vm.showPrompt }
        XCTAssertEqual(h.grader.answers.count, 1)
    }

    func testResetDuringFeedbackCompletionDelayCannotResume() async throws {
        let h = try await makeHarness()
        await beginAnswer(h)
        await submitBySilence(h)
        await eventually { h.vm.drivingPromptState == .speakingFeedback }
        h.narrator.finish()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(h.vm.resetPromptProgress(for: h.vm.episode.id))
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(h.vm.audioManager.isPlaying)
        XCTAssertFalse(h.vm.showPrompt)
        XCTAssertTrue(h.vm.promptResponses.isEmpty)
        XCTAssertEqual(h.vm.audioManager.currentTime, 0)
    }

    func testEditedAnswerCancelsObsoleteFeedbackBeforeResume() async throws {
        let h = try await makeHarness()
        await beginAnswer(h)
        await submitBySilence(h)
        await eventually { h.vm.drivingPromptState == .speakingFeedback }
        h.vm.answerText = "I want to correct my answer"
        h.vm.activeAnswerDidChange()
        h.narrator.finish()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        XCTAssertFalse(h.vm.hasScoredActivePrompt)
        XCTAssertTrue(h.vm.feedbackText.isEmpty)
    }

    func testOfflineFeedbackIsReadAndRetryCannotDuplicatePoints() async throws {
        let h = try await makeHarness()
        h.grader.result = AIResult(score: 85, grade: .a, feedback: "Offline estimate. Add the new evidence that changed the speaker's view.", awardedPoints: 10, usedOfflineEstimate: true)
        await beginAnswer(h)
        await submitBySilence(h)
        await eventually { h.vm.drivingPromptState == .speakingFeedback }
        XCTAssertEqual(h.vm.response(for: h.prompt)?.usedOfflineEstimate, true)
        XCTAssertTrue(h.narrator.readings.last!.text.contains("Offline estimate"))
        h.vm.stopFeedbackNarration()
        let pointsAfterFirstAnswer = h.points.totalPoints
        h.grader.result = AIResult(score: 95, grade: .a, feedback: "Correct: new evidence changed the speaker's view.", awardedPoints: 10)
        await h.vm.submitAnswer(pointsStore: h.points)
        XCTAssertEqual(h.points.totalPoints, pointsAfterFirstAnswer)
        XCTAssertEqual(h.vm.response(for: h.prompt)?.usedOfflineEstimate, false)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
    }

    func testForegroundDoesNotRestartListeningDuringAnActiveInterruption() async throws {
        let h = try await makeHarness()
        await beginAnswer(h)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await eventually { h.vm.drivingPromptState == .idle }
        let readingsBeforeForeground = h.narrator.readings.count
        h.vm.appDidBecomeActive()
        XCTAssertEqual(h.narrator.readings.count, readingsBeforeForeground)
        XCTAssertFalse(h.speech.isRecording)
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        await eventually { h.narrator.readings.count == readingsBeforeForeground + 1 }
        h.narrator.finish()
        await eventually { h.speech.isRecording }
        XCTAssertTrue(h.vm.audioManager.playbackIsHeld)
    }

}
