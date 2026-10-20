import Foundation
import Combine
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

struct NarrationVoiceOption: Identifiable, Hashable {
    static let automaticID = "automatic"

    let id: String
    let name: String
    let detail: String
}

enum FeedbackDetailLevel: Int, CaseIterable {
    case quick = 0
    case balanced = 1
    case full = 2
}

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    enum DrivingPromptState: Equatable {
        case idle
        case announcingPrompt
        case listening
        case submitting
        case speakingFeedback
        case retryingListening
    }

    @Published var episode: Episode = MockEpisodeProvider.sample
    @Published var activePrompt: Prompt?
    @Published var showPrompt = false
    @Published var answerText = ""
    @Published var feedbackText = ""
    @Published var lastScore: Int = 0
    @Published var lastGrade: PromptGrade = .f
    @Published var lastAwardedPoints: Int = 0
    @Published var isEvaluating = false
    @Published private(set) var hasScoredActivePrompt = false
    @Published var interactiveModeEnabled = true
    @Published var promptResults: [PromptResult] = []
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var drivingModeEnabled = HandsFreePreference.isEnabled()
    @Published private(set) var drivingPromptState: DrivingPromptState = .idle
    @Published private(set) var drivingStatusText: String = ""
    @Published private(set) var handsFreeNeedsSettings = false
    @Published private(set) var narrationVoiceOptions: [NarrationVoiceOption]
    @Published var selectedNarrationVoiceID: String {
        didSet {
            UserDefaults.standard.set(selectedNarrationVoiceID, forKey: Self.narrationVoiceKey)
            prefetchUpcomingPromptNarration()
        }
    }
    @Published var feedbackDetailLevel: FeedbackDetailLevel {
        didSet {
            UserDefaults.standard.set(feedbackDetailLevel.rawValue, forKey: Self.feedbackDetailLevelKey)
        }
    }
    @Published var answerAnalysisDepth: AnswerAnalysisDepth {
        didSet {
            UserDefaults.standard.set(answerAnalysisDepth.rawValue, forKey: Self.answerAnalysisDepthKey)
        }
    }
    @Published private(set) var promptResponses: [UUID: PromptResponse] = [:]
    @Published private(set) var encounteredPromptIDs: [UUID] = []

    let audioManager = AudioPlayerManager()
    let speechManager = SpeechRecognitionManager()
    let aiService = AIService()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var naturalNarrationPlayer: AVAudioPlayer?
    private var naturalNarrationTask: Task<Void, Never>?
    private var narrationPrefetchTask: Task<Void, Never>?
    private var narrationPrefetchSignature: String?
    private var activeNaturalNarrationID: UUID?
    private var activeNaturalNarrationState: DrivingPromptState?
    private var cancellables = Set<AnyCancellable>()

    private var promptedIDs = Set<UUID>()
    private var earnedPointsByPrompt: [UUID: Int] = [:]
    private var promptSessionGeneration = UUID()
    private var promptTriggerTimes: [UUID: Double] = [:]
    private let nowPlaying = NowPlayingManager.shared
    private weak var pointsStore: PointsStore?
    private var silenceWatchTask: Task<Void, Never>?
    private var speechWatchdogTask: Task<Void, Never>?
    private var transcriptUpdateDate = Date()
    private var listeningStartDate = Date()
    private var emptyListeningRetryCount = 0
    private var activeSpeechUtterance: AVSpeechUtterance?
    private var activeSpeechState: DrivingPromptState?
    private var microphoneStartRetryCount = 0
    private var handsFreePausedForInterruption = false
    private var shouldResumeFeedbackAfterInterruption = false
    private var pendingPlaybackRestore: (episodeID: UUID, position: Double)?
    private var lastPersistedEpisodeID: UUID?
    private var lastPersistedPosition = 0.0
    private var lastPlaybackPositionWrite = Date.distantPast
    private var isChangingEpisode = false
    private var isApplyingPlaybackRestore = false
    private var autoContinueTask: Task<Void, Never>?
    private var evaluationID: UUID?
    private static let narrationVoiceKey = "TheAgoraLA.NarrationVoice"
    // ".v2" avoids reinterpreting an old saved rawValue under the 3-case scheme (old 1 meant full, new 1 means balanced).
    private static let feedbackDetailLevelKey = "TheAgoraLA.FeedbackDetailLevel.v2"
    private static let answerAnalysisDepthKey = "TheAgoraLA.AnswerAnalysisDepth"
    private static let playbackPositionKeyPrefix = "TheAgoraLA.PlaybackPosition."

    override init() {
        let voiceOptions = Self.makeNarrationVoiceOptions()
        narrationVoiceOptions = voiceOptions
        let savedVoiceID = UserDefaults.standard.string(forKey: Self.narrationVoiceKey)
        selectedNarrationVoiceID = voiceOptions.contains(where: { $0.id == savedVoiceID })
            ? (savedVoiceID ?? NarrationVoiceOption.automaticID)
            : NarrationVoiceOption.automaticID
        if let savedLevel = UserDefaults.standard.object(forKey: Self.feedbackDetailLevelKey) as? Int,
           let level = FeedbackDetailLevel(rawValue: savedLevel) {
            feedbackDetailLevel = level
        } else {
            feedbackDetailLevel = .full
        }
        if let savedDepth = UserDefaults.standard.object(forKey: Self.answerAnalysisDepthKey) as? Int,
           let depth = AnswerAnalysisDepth(rawValue: savedDepth) {
            answerAnalysisDepth = depth
        } else {
            answerAnalysisDepth = .deepest
        }
        super.init()
        speechSynthesizer.delegate = self
        loadPromptHistory(for: episode)
        if !episode.audioURL.isFileURL {
            audioManager.load(url: episode.audioURL)
        }
        audioManager.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.isPlaying = value
                if !value {
                    self.persistPlaybackPosition(force: true)
                }
            }
            .store(in: &cancellables)

        audioManager.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                guard let self else { return }
                self.currentTime = t
                self.persistPlaybackPosition()
            }
            .store(in: &cancellables)

        audioManager.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self] d in
                guard let self else { return }
                self.duration = d
                self.restorePlaybackPositionIfReady(duration: d)
            }
            .store(in: &cancellables)

        // Wire remote command handlers
        nowPlaying.playHandler = { [weak self] in self?.play() }
        nowPlaying.pauseHandler = { [weak self] in self?.audioManager.pause() }
        nowPlaying.skipForwardHandler = { [weak self] in self?.skip(by: 15) }
        nowPlaying.skipBackwardHandler = { [weak self] in self?.skip(by: -15) }
        nowPlaying.seekHandler = { [weak self] position in self?.seek(to: position) }

        audioManager.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                guard let self else { return }
                self.nowPlaying.update(elapsed: t, isPlaying: self.isPlaying, duration: self.audioManager.duration)
            }
            .store(in: &cancellables)

        audioManager.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                guard let self else { return }
                self.nowPlaying.update(elapsed: self.audioManager.currentTime, isPlaying: playing, duration: self.audioManager.duration)
            }
            .store(in: &cancellables)

        speechManager.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                guard self.drivingModeEnabled else { return }
                guard self.drivingPromptState == .listening else { return }
                self.answerText = text
                self.transcriptUpdateDate = Date()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
            .store(in: &cancellables)

        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.persistPlaybackPosition(force: true)
            }
            .store(in: &cancellables)
        #endif
    }

    func bind(pointsStore: PointsStore) {
        self.pointsStore = pointsStore
    }

    func setInteractiveMode(_ enabled: Bool) {
        interactiveModeEnabled = enabled
        if !enabled, drivingModeEnabled {
            setHandsFreeMode(false)
        }
    }

    func setHandsFreeMode(_ enabled: Bool) {
        HandsFreePreference.setEnabled(enabled)
        guard enabled != drivingModeEnabled else { return }
        drivingModeEnabled = enabled
        prefetchUpcomingPromptNarration()

        guard enabled else {
            handsFreeNeedsSettings = false
            cancelDrivingFlow()
            return
        }

        interactiveModeEnabled = true
        handsFreeNeedsSettings = false
        drivingStatusText = "Preparing microphone access..."
        Task {
            let authorized = await speechManager.requestAuthorization()
            guard drivingModeEnabled else { return }
            guard authorized else {
                drivingModeEnabled = false
                handsFreeNeedsSettings = speechManager.authorizationNeedsSettings
                drivingStatusText = "Allow Microphone and Speech Recognition in Settings to use hands-free mode."
                return
            }

            drivingStatusText = showPrompt ? "Starting hands-free prompt..." : "Ready for the next prompt."
            if let activePrompt, showPrompt {
                beginDrivingFlow(for: activePrompt)
            }
        }
    }

    func updateEpisode(_ updated: Episode) {
        if episode.id != updated.id || episode.audioURL != updated.audioURL {
            evaluationID = nil
            isEvaluating = false
        }
        let sourceChanged = episode.id != updated.id || episode.audioURL != updated.audioURL
        let playerNeedsReload = !updated.audioURL.isFileURL && audioManager.loadedURL != updated.audioURL
        if sourceChanged {
            persistPlaybackPosition(force: true)
            saveActiveDraft()
        }
        episode = updated
        promptTriggerTimes.removeAll()
        if sourceChanged {
            isChangingEpisode = true
            preparePlaybackRestore(for: updated)
            cancelDrivingFlow()
            audioManager.setPlaybackHeld(false)
            if updated.audioURL.isFileURL {
                audioManager.pause()
            } else {
                audioManager.load(url: updated.audioURL)
            }
            isChangingEpisode = false
            nowPlaying.configure(title: updated.title, duration: 0)
            PlayerDurationCache.shared.duration = 0
            loadPromptHistory(for: updated)
            showPrompt = false
            activePrompt = nil
            hasScoredActivePrompt = false
        } else {
            if playerNeedsReload {
                persistPlaybackPosition(force: true)
                isChangingEpisode = true
                preparePlaybackRestore(for: updated)
                audioManager.load(url: updated.audioURL)
                isChangingEpisode = false
                PlayerDurationCache.shared.duration = 0
            }
            let validPromptIDs = Set(updated.prompts.map(\.id))
            encounteredPromptIDs.removeAll { !validPromptIDs.contains($0) }
            promptedIDs.formIntersection(validPromptIDs)
            promptResponses = promptResponses.filter { validPromptIDs.contains($0.key) }
            persistPromptHistory()
            nowPlaying.configure(title: updated.title, duration: audioManager.duration)
            if let activePrompt, !updated.prompts.contains(where: { $0.id == activePrompt.id }) {
                cancelDrivingFlow()
                showPrompt = false
                self.activePrompt = nil
                hasScoredActivePrompt = false
                audioManager.setPlaybackHeld(false)
            }
        }
        prefetchUpcomingPromptNarration()
    }

    @discardableResult
    func resetPromptProgress(for episodeID: UUID) -> Bool {
        guard episode.id == episodeID, !episode.prompts.isEmpty else { return false }

        promptSessionGeneration = UUID()
        isEvaluating = false
        autoContinueTask?.cancel()
        autoContinueTask = nil
        audioManager.setPlaybackHeld(true)
        cancelDrivingFlow()
        // Also invalidate a microphone start that is still awaiting permission.
        speechManager.stopRecording()

        let resetHistory = PromptHistorySnapshot(
            responses: Array(promptResponses.values),
            encounteredPromptIDs: encounteredPromptIDs,
            earnedPointsByPrompt: earnedPointsByPrompt
        ).resettingProgress()
        earnedPointsByPrompt = resetHistory.pointAwardHistory
        promptResponses = [:]
        encounteredPromptIDs = []
        promptedIDs = []
        promptTriggerTimes = [:]
        promptResults = []
        activePrompt = nil
        showPrompt = false
        answerText = ""
        feedbackText = ""
        lastScore = 0
        lastGrade = .f
        lastAwardedPoints = 0
        hasScoredActivePrompt = false
        persistPromptHistory()

        pendingPlaybackRestore = nil
        isApplyingPlaybackRestore = true
        audioManager.seek(to: 0)
        currentTime = 0
        isPlaying = false
        isApplyingPlaybackRestore = false
        UserDefaults.standard.set(0, forKey: Self.playbackPositionKey(for: episodeID))
        lastPersistedEpisodeID = episodeID
        lastPersistedPosition = 0
        lastPlaybackPositionWrite = Date()
        nowPlaying.update(elapsed: 0, isPlaying: false, duration: audioManager.duration)
        audioManager.setPlaybackHeld(false)
        if drivingModeEnabled { drivingStatusText = "Ready to replay. Press Play to begin." }
        prefetchUpcomingPromptNarration()
        return true
    }

    func togglePlay() {
        if audioManager.isPlaying {
            audioManager.pause()
        } else {
            play()
        }
    }

    /// Play must always work. A question on screen is closed exactly as Continue closes it,
    /// and a playback hold left behind without a visible question is released.
    func play() {
        if showPrompt, activePrompt != nil {
            continuePlayback()
            return
        }
        audioManager.setPlaybackHeld(false)
        prefetchUpcomingPromptNarration()
        audioManager.play()
    }

    func skip(by seconds: Double) {
        let duration = max(audioManager.duration, 0)
        let current = max(audioManager.currentTime, 0)
        let target = min(max(current + seconds, 0), duration)
        seek(to: target)
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let playableDuration = max(audioManager.duration, 0)
        let target = playableDuration > 0
            ? min(max(seconds, 0), playableDuration)
            : max(seconds, 0)

        if interactiveModeEnabled, target > audioManager.currentTime + 1, playableDuration > 1 {
            let newlyPassed = episode.prompts
                .map { ($0, triggerTime(for: $0, duration: playableDuration)) }
                .filter { $0.1 <= target && !promptedIDs.contains($0.0.id) }
                .sorted { $0.1 < $1.1 }

            // A large seek should surface the most relevant reached prompt, not replay every missed one.
            for skipped in newlyPassed.dropLast() {
                markPromptEncountered(skipped.0)
            }
        }

        currentTime = target
        audioManager.seek(to: target)
        persistPlaybackPosition(force: true)
    }

    func checkForPrompt(at time: Double) {
        guard interactiveModeEnabled else { return }
        prefetchUpcomingPromptNarration()
        guard !showPrompt else { return }
        guard audioManager.isPlaying else { return }
        let duration = audioManager.duration
        guard time.isFinite, time > 0.5, duration.isFinite, duration > 1 else { return }

        let scheduledPrompts = episode.prompts
            .map { prompt in
                (prompt, triggerTime(for: prompt, duration: duration))
            }
            .sorted { $0.1 < $1.1 }

        if let nextPrompt = scheduledPrompts
            .first(where: { $0.1 <= time && !promptedIDs.contains($0.0.id) })?.0 {
            activatePrompt(nextPrompt, beginDriving: drivingModeEnabled)
        }
    }

    private func triggerTime(for prompt: Prompt, duration: Double) -> Double {
        if let cached = promptTriggerTimes[prompt.id] { return cached }

        let alignedEnd = prompt.timingVerified ? nil : alignedAnswerEnd(for: prompt, duration: duration)
        let answerEnd: Double
        if prompt.timestampSeconds.isFinite, prompt.timestampSeconds > 1 {
            answerEnd = max(min(prompt.timestampSeconds, duration), alignedEnd ?? 0)
        } else {
            answerEnd = alignedEnd ?? duration
        }

        // leadTimeSeconds is retained for saved-data compatibility but now acts as a safe delay.
        let delay = prompt.leadTimeSeconds.isFinite ? max(prompt.leadTimeSeconds, 0) : 0
        let trigger = min(max(answerEnd + delay, 1), duration)
        promptTriggerTimes[prompt.id] = trigger
        return trigger
    }

    private func alignedAnswerEnd(for prompt: Prompt, duration: Double) -> Double? {
        guard let transcript = episode.transcript, !transcript.isEmpty else { return nil }
        let transcriptWords = normalizedTimingWords(transcript)
        let targetTokens = Set(normalizedTimingWords(prompt.question + " " + prompt.expectedAnswer))
        guard transcriptWords.count >= 20, targetTokens.count >= 3 else { return nil }

        let windowSize = min(110, max(50, transcriptWords.count / 80))
        let step = max(8, windowSize / 5)
        var bestStart = 0
        var bestHits = 0
        var start = 0

        while start < transcriptWords.count {
            let end = min(start + windowSize, transcriptWords.count)
            let hits = Set(transcriptWords[start..<end]).intersection(targetTokens).count
            // On ties, prefer the later passage so a repeated idea is never asked too early.
            if hits > 0, hits >= bestHits {
                bestHits = hits
                bestStart = start
            }
            if end == transcriptWords.count { break }
            start += step
        }

        let minimumHits = min(4, max(2, targetTokens.count / 8))
        guard bestHits >= minimumHits else { return nil }
        let answerWindowEnd = min(bestStart + windowSize, transcriptWords.count)
        let progress = Double(answerWindowEnd) / Double(transcriptWords.count)
        let listeningBuffer = min(12, max(6, duration * 0.0025))
        return min(duration, (progress * duration) + listeningBuffer)
    }

    private func normalizedTimingWords(_ text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with", "is", "are",
            "was", "were", "it", "this", "that", "as", "by", "at", "from", "be", "has", "have", "had",
            "do", "does", "did", "not", "we", "you", "they", "he", "she", "what", "why", "how", "when",
            "where", "which", "who", "episode", "podcast", "speaker", "said", "says"
        ]
        return text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    func presentPrompt(_ prompt: Prompt) {
        saveActiveDraft()
        activatePrompt(prompt, beginDriving: false)
        if drivingModeEnabled {
            drivingStatusText = promptResponses[prompt.id]?.score == nil
                ? "Tap the microphone when you're ready to hear and answer this question."
                : "Your answer is saved. Tap the microphone only if you want to answer again."
        }
    }

    var queuedPrompts: [Prompt] {
        let promptsByID = Dictionary(uniqueKeysWithValues: episode.prompts.map { ($0.id, $0) })
        return encounteredPromptIDs.reversed().compactMap { id in
            guard activePrompt?.id != id || !showPrompt else { return nil }
            return promptsByID[id]
        }
    }

    func response(for prompt: Prompt) -> PromptResponse? {
        promptResponses[prompt.id]
    }

    var activePromptPosition: (number: Int, total: Int)? {
        guard let activePrompt else { return nil }
        let ordered = episode.prompts.sorted { $0.timestampSeconds < $1.timestampSeconds }
        guard let index = ordered.firstIndex(where: { $0.id == activePrompt.id }) else { return nil }
        return (index + 1, ordered.count)
    }

    var canSubmitActiveAnswer: Bool {
        guard let prompt = activePrompt else { return false }
        let answer = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, !isEvaluating else { return false }
        guard let saved = promptResponses[prompt.id], saved.score != nil else { return true }
        return saved.usedOfflineEstimate == true || saved.answer.trimmingCharacters(in: .whitespacesAndNewlines) != answer
    }

    func activeAnswerDidChange() {
        guard let prompt = activePrompt, let saved = promptResponses[prompt.id] else { return }
        guard saved.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            != answerText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        autoContinueTask?.cancel()
        autoContinueTask = nil
        feedbackText = ""
        hasScoredActivePrompt = false
    }

    func submitAnswer(pointsStore: PointsStore) async {
        guard let prompt = activePrompt else { return }
        guard !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isEvaluating else { return }
        guard canSubmitActiveAnswer else { return }

        let evaluatedSession = promptSessionGeneration
        isEvaluating = true
        let requestID = UUID()
        evaluationID = requestID
        let evaluatedEpisodeID = episode.id
        let evaluatedAnswer = answerText
        let backgroundTask = AnswerGradingBackgroundLease()
        if drivingModeEnabled {
            drivingPromptState = .submitting
            drivingStatusText = "Grading your answer..."
        }
        defer {
            backgroundTask.end()
            if evaluationID == requestID, promptSessionGeneration == evaluatedSession {
                isEvaluating = false
                evaluationID = nil
            }
        }

        let result = await aiService.evaluateAnswer(
            question: prompt.question,
            expectedAnswer: prompt.expectedAnswer,
            userAnswer: evaluatedAnswer,
            transcript: episode.transcript,
            progressSeconds: audioManager.currentTime,
            analysisDepth: answerAnalysisDepth
        )
        guard promptSessionGeneration == evaluatedSession else { return }
        guard evaluationID == requestID, episode.id == evaluatedEpisodeID,
              activePrompt?.id == prompt.id, showPrompt else { return }
        guard answerText == evaluatedAnswer else {
            if drivingModeEnabled {
                drivingPromptState = .idle
                drivingStatusText = "Your answer changed. Submit it again when you're ready."
            }
            return
        }

        let previousAward = earnedPointsByPrompt[prompt.id] ?? promptResponses[prompt.id]?.awardedPoints ?? 0
        let totalAward = max(previousAward, result.awardedPoints)
        let newlyEarnedPoints = max(totalAward - previousAward, 0)
        earnedPointsByPrompt[prompt.id] = totalAward
        let sessionAward = (promptResponses[prompt.id]?.awardedPoints ?? 0) + newlyEarnedPoints

        lastScore = result.score
        lastGrade = result.grade
        lastAwardedPoints = sessionAward
        feedbackText = result.feedback
        hasScoredActivePrompt = true
        promptResponses[prompt.id] = PromptResponse(
            promptID: prompt.id,
            answer: evaluatedAnswer,
            score: result.score,
            grade: result.grade,
            awardedPoints: sessionAward,
            feedback: result.feedback,
            lastUpdated: Date(),
            usedOfflineEstimate: result.usedOfflineEstimate
        )
        let promptResult = PromptResult(
            prompt: prompt,
            answer: evaluatedAnswer,
            score: result.score,
            grade: result.grade,
            awardedPoints: sessionAward,
            feedback: result.feedback
        )
        if let index = promptResults.firstIndex(where: { $0.prompt.id == prompt.id }) {
            promptResults[index] = promptResult
        } else {
            promptResults.append(promptResult)
        }
        persistPromptHistory()

        if newlyEarnedPoints > 0 {
            pointsStore.add(points: newlyEarnedPoints)
        }
        if drivingModeEnabled {
            drivingPromptState = .speakingFeedback
            drivingStatusText = "Reading feedback..."
            speak(text: spokenFeedback(for: result))
        } else if feedbackDetailLevel != .full {
            scheduleAutoContinue(for: prompt.id, afterSeconds: feedbackDetailLevel == .quick ? 1.6 : 4.5)
        }
    }

    private func scheduleAutoContinue(for promptID: UUID, afterSeconds: Double) {
        autoContinueTask?.cancel()
        autoContinueTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(afterSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.activePrompt?.id == promptID, self.hasScoredActivePrompt, self.showPrompt else { return }
            self.continuePlayback()
        }
    }

    func continuePlayback() {
        evaluationID = nil
        isEvaluating = false
        autoContinueTask?.cancel()
        autoContinueTask = nil
        saveActiveDraft()
        cancelDrivingFlow()
        showPrompt = false
        activePrompt = nil
        audioManager.setPlaybackHeld(false)
        prefetchUpcomingPromptNarration()
        audioManager.play()
    }

    func toggleRecording() {
        if speechManager.isRecording {
            speechManager.stopRecording()
        } else {
            Task {
                if await speechManager.startRecording() == false {
                    drivingStatusText = "Microphone and speech access are required for voice answers."
                }
            }
        }
    }

    func drivingMicTapped() {
        if drivingPromptState == .listening || speechManager.isRecording {
            Task { await stopListeningAndSubmitIfPossible() }
        } else if drivingPromptState == .idle,
                  showPrompt,
                  let activePrompt {
            beginDrivingFlow(for: activePrompt)
        }
    }

    var canUseDrivingMicrophone: Bool {
        drivingPromptState == .idle || drivingPromptState == .listening
    }

    func stopFeedbackNarration() {
        guard drivingPromptState == .speakingFeedback else { return }
        cancelActiveNarration()
        shouldResumeFeedbackAfterInterruption = false
        drivingPromptState = .idle
        drivingStatusText = "Feedback stopped. Review it below or continue the podcast."
    }

    func previewNarrationVoice() {
        guard drivingPromptState == .idle else { return }
        speak(text: "Welcome to The Agora. I’ll pause at important moments, listen to your answer, and help you reflect on what you heard.")
    }

    private func beginDrivingFlow(for prompt: Prompt) {
        cancelDrivingFlow()
        emptyListeningRetryCount = 0
        microphoneStartRetryCount = 0
        drivingPromptState = .announcingPrompt
        drivingStatusText = "Reading prompt..."
        speak(text: NaturalNarrationService.promptText(question: prompt.question), persist: true)
    }

    private func startListening() async {
        guard drivingModeEnabled else { return }
        guard showPrompt else { return }
        guard activePrompt != nil else { return }

        speechWatchdogTask?.cancel()
        drivingPromptState = .listening
        drivingStatusText = "Connecting to microphone..."
        answerText = ""
        transcriptUpdateDate = Date()
        listeningStartDate = Date()

        // Give the audio route a moment to move from text-to-speech to microphone input.
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard drivingModeEnabled, showPrompt, drivingPromptState == .listening else { return }
        var started = await speechManager.startRecording()
        guard !Task.isCancelled, drivingModeEnabled, showPrompt, drivingPromptState == .listening else {
            speechManager.stopRecording()
            return
        }
        if !started, !speechManager.authorizationNeedsSettings, microphoneStartRetryCount == 0 {
            microphoneStartRetryCount += 1
            drivingStatusText = "Reconnecting to the microphone..."
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard drivingModeEnabled, showPrompt, drivingPromptState == .listening else { return }
            started = await speechManager.startRecording()
        }
        guard !Task.isCancelled, drivingModeEnabled, showPrompt, drivingPromptState == .listening else {
            speechManager.stopRecording()
            return
        }
        guard started else {
            if speechManager.authorizationNeedsSettings {
                drivingPromptState = .idle
                drivingModeEnabled = false
                handsFreeNeedsSettings = true
                drivingStatusText = "Microphone and Speech Recognition access must be enabled in Settings."
            } else {
                drivingPromptState = .speakingFeedback
                drivingStatusText = "Microphone unavailable. Continuing playback..."
                speak(text: "I couldn't connect to the microphone. I'll continue the podcast, and you can revisit this question later.")
            }
            return
        }
        microphoneStartRetryCount = 0
        listeningStartDate = Date()
        drivingStatusText = "Listening on \(speechManager.inputName)..."
        drivingStatusText += " Pause to submit; up to 90 seconds per answer."
        startSilenceWatch()
    }

    private func startSilenceWatch() {
        silenceWatchTask?.cancel()
        silenceWatchTask = Task { @MainActor in
            while !Task.isCancelled && drivingPromptState == .listening && showPrompt {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, drivingModeEnabled, drivingPromptState == .listening, showPrompt else { return }
                let transcript = speechManager.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let listenTime = Date().timeIntervalSince(listeningStartDate)

                if transcript.isEmpty {
                    if !speechManager.isRecording {
                        silenceWatchTask = nil
                        await handleEmptyListeningAttempt()
                        return
                    }
                    if listenTime >= 15, !speechManager.hasDetectedVoice {
                        await handleEmptyListeningAttempt()
                        return
                    }
                    if listenTime >= 25, speechManager.hasDetectedVoice {
                        await handleEmptyListeningAttempt()
                        return
                    }
                    continue
                }

                if !speechManager.isRecording {
                    if transcript.isEmpty {
                        await handleEmptyListeningAttempt()
                    } else {
                        // Release the watcher handle without cancelling the task that performs grading.
                        silenceWatchTask = nil
                        await stopListeningAndSubmitIfPossible()
                    }
                    return
                }

                let latestActivity = max(transcriptUpdateDate, speechManager.lastVoiceActivityDate)
                let silence = Date().timeIntervalSince(latestActivity)
                if (silence >= 3.5 && listenTime >= 3.5) || listenTime >= 90 {
                    // Cancelling this task here would also cancel its URLSession grading request.
                    silenceWatchTask = nil
                    await stopListeningAndSubmitIfPossible()
                    return
                }
            }
        }
    }

    private func stopListeningAndSubmitIfPossible() async {
        guard drivingPromptState == .listening else { return }
        let listeningSession = promptSessionGeneration
        drivingPromptState = .submitting
        drivingStatusText = "Finishing your response..."
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        let transcript = await speechManager.finishRecording()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard drivingModeEnabled, showPrompt, promptSessionGeneration == listeningSession else { return }
        guard !transcript.isEmpty else {
            await handleEmptyListeningAttempt()
            return
        }

        if let command = handsFreeCommand(from: transcript) {
            answerText = ""
            switch command {
            case .repeatQuestion:
                guard let prompt = activePrompt else { return }
                drivingPromptState = .announcingPrompt
                drivingStatusText = "Repeating the question..."
                speak(text: NaturalNarrationService.promptText(question: prompt.question), persist: true)
            case .startOver:
                drivingPromptState = .retryingListening
                drivingStatusText = "Starting your answer over..."
                speak(text: "Okay. Start your answer again after I finish speaking.")
            case .skipQuestion:
                drivingPromptState = .speakingFeedback
                drivingStatusText = "Skipping this question..."
                speak(text: "No problem. I'll save this question for later and continue the podcast.")
            }
            return
        }

        answerText = transcript
        guard let pointsStore else {
            drivingPromptState = .idle
            drivingStatusText = "Unable to grade right now."
            return
        }
        await submitAnswer(pointsStore: pointsStore)
    }

    private func handleEmptyListeningAttempt() async {
        if speechManager.isRecording {
            speechManager.stopRecording()
        }
        silenceWatchTask?.cancel()

        if emptyListeningRetryCount == 0, drivingModeEnabled, showPrompt {
            emptyListeningRetryCount += 1
            drivingPromptState = .retryingListening
            drivingStatusText = "No answer heard. Trying once more..."
            speak(text: "I didn't hear an answer. Please try again now.")
        } else {
            drivingPromptState = .speakingFeedback
            drivingStatusText = "No answer heard. Continuing playback..."
            speak(text: "I couldn't hear an answer, so I'll continue the podcast. You can revisit this prompt later.")
        }
    }

    private enum HandsFreeCommand {
        case repeatQuestion
        case startOver
        case skipQuestion
    }

    private func handsFreeCommand(from transcript: String) -> HandsFreeCommand? {
        let normalized = transcript
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if [
            "repeat the question",
            "repeat that question",
            "say the question again",
            "ask the question again",
            "can you repeat",
            "could you repeat"
        ].contains(where: { normalized.contains($0) }) {
            return .repeatQuestion
        }

        if ["start over", "start my answer over", "erase my answer", "let me try again"]
            .contains(where: { normalized.contains($0) }) {
            return .startOver
        }

        let wordCount = normalized.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount <= 7,
           ["skip this question", "skip the question", "continue the podcast", "move on"]
            .contains(where: { normalized.contains($0) }) {
            return .skipQuestion
        }
        return nil
    }

    func appDidEnterBackground() {
        persistPlaybackPosition(force: true)
    }

    func appDidBecomeActive() {
        Task { await CloudAnalysisClient.retryAcknowledgements() }
        restorePlaybackPositionIfReady(duration: audioManager.duration)
        guard handsFreePausedForInterruption else { return }
        handsFreePausedForInterruption = false
        guard drivingModeEnabled, showPrompt, let activePrompt else { return }
        beginDrivingFlow(for: activePrompt)
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard drivingModeEnabled, showPrompt else { return }
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            switch drivingPromptState {
            case .announcingPrompt, .listening, .retryingListening:
                handsFreePausedForInterruption = true
                silenceWatchTask?.cancel()
                silenceWatchTask = nil
                speechWatchdogTask?.cancel()
                speechWatchdogTask = nil
                speechManager.stopRecording()
                cancelActiveNarration()
                drivingPromptState = .idle
                drivingStatusText = "Hands-free paused for another audio session."
            case .speakingFeedback:
                shouldResumeFeedbackAfterInterruption = true
                cancelActiveNarration()
                drivingPromptState = .idle
                drivingStatusText = "Feedback paused for another audio session."
            default:
                break
            }
        case .ended:
            if shouldResumeFeedbackAfterInterruption,
               activePrompt != nil,
               hasScoredActivePrompt {
                shouldResumeFeedbackAfterInterruption = false
                let result = AIResult(
                    score: lastScore,
                    grade: lastGrade,
                    feedback: feedbackText,
                    awardedPoints: lastAwardedPoints
                )
                drivingPromptState = .speakingFeedback
                drivingStatusText = "Reading feedback..."
                speak(text: spokenFeedback(for: result))
            } else {
                appDidBecomeActive()
            }
        @unknown default:
            break
        }
    }

    private func cancelDrivingFlow() {
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil
        if speechManager.isRecording {
            speechManager.stopRecording()
        }
        drivingPromptState = .idle
        drivingStatusText = ""
        handsFreePausedForInterruption = false
        shouldResumeFeedbackAfterInterruption = false
        cancelActiveNarration()
    }

    private func activatePrompt(_ prompt: Prompt, beginDriving: Bool) {
        evaluationID = nil
        isEvaluating = false
        audioManager.setPlaybackHeld(true)
        markPromptEncountered(prompt)
        activePrompt = prompt
        showPrompt = true

        if let response = promptResponses[prompt.id] {
            answerText = response.answer
            feedbackText = response.feedback
            lastScore = response.score ?? 0
            lastGrade = response.grade ?? .f
            lastAwardedPoints = response.awardedPoints
            hasScoredActivePrompt = response.score != nil
        } else {
            answerText = ""
            feedbackText = ""
            lastScore = 0
            lastGrade = .f
            lastAwardedPoints = 0
            hasScoredActivePrompt = false
        }

        if beginDriving {
            beginDrivingFlow(for: prompt)
        } else {
            drivingPromptState = .idle
            drivingStatusText = ""
        }
    }

    private func markPromptEncountered(_ prompt: Prompt) {
        promptedIDs.insert(prompt.id)
        if !encounteredPromptIDs.contains(prompt.id) {
            encounteredPromptIDs.append(prompt.id)
        }
        persistPromptHistory()
    }

    private func saveActiveDraft() {
        guard let prompt = activePrompt else { return }
        let trimmedAnswer = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty || promptResponses[prompt.id] != nil else { return }

        var response = promptResponses[prompt.id] ?? PromptResponse(
            promptID: prompt.id,
            answer: answerText,
            score: nil,
            grade: nil,
            awardedPoints: 0,
            feedback: "",
            lastUpdated: Date()
        )
        if response.answer.trimmingCharacters(in: .whitespacesAndNewlines) != trimmedAnswer {
            response.score = nil
            response.grade = nil
            response.feedback = ""
        }
        response.answer = answerText
        response.lastUpdated = Date()
        promptResponses[prompt.id] = response
        persistPromptHistory()
    }

    private func loadPromptHistory(for episode: Episode) {
        guard let data = UserDefaults.standard.data(forKey: historyKey(for: episode.id)),
              let snapshot = try? JSONDecoder().decode(PromptHistorySnapshot.self, from: data) else {
            promptResponses = [:]
            earnedPointsByPrompt = [:]
            encounteredPromptIDs = []
            promptedIDs = []
            return
        }
        let validPromptIDs = Set(episode.prompts.map(\.id))
        earnedPointsByPrompt = snapshot.pointAwardHistory.filter { validPromptIDs.contains($0.key) }
        promptResponses = Dictionary(
            uniqueKeysWithValues: snapshot.responses
                .filter { validPromptIDs.contains($0.promptID) }
                .map { ($0.promptID, $0) }
        )
        encounteredPromptIDs = snapshot.encounteredPromptIDs.filter(validPromptIDs.contains)
        promptedIDs = Set(encounteredPromptIDs)
    }

    private func persistPromptHistory() {
        let snapshot = PromptHistorySnapshot(
            responses: Array(promptResponses.values),
            encounteredPromptIDs: encounteredPromptIDs,
            earnedPointsByPrompt: earnedPointsByPrompt
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: historyKey(for: episode.id))
    }

    private func historyKey(for episodeID: UUID) -> String {
        "TheAgoraLA.PromptHistory.\(episodeID.uuidString)"
    }

    private func preparePlaybackRestore(for episode: Episode) {
        guard !episode.audioURL.isFileURL else {
            pendingPlaybackRestore = nil
            return
        }
        let position = Self.savedPlaybackPosition(for: episode.id)
        lastPersistedEpisodeID = episode.id
        lastPersistedPosition = position
        lastPlaybackPositionWrite = Date()
        pendingPlaybackRestore = position > 0.5 ? (episode.id, position) : nil
    }

    private func restorePlaybackPositionIfReady(duration: Double) {
        guard duration.isFinite, duration > 1,
              let pending = pendingPlaybackRestore,
              pending.episodeID == episode.id,
              audioManager.loadedURL == episode.audioURL else { return }

        let target = min(max(pending.position, 0), duration)
        pendingPlaybackRestore = nil
        isApplyingPlaybackRestore = true
        audioManager.seek(to: target)
        currentTime = target
        nowPlaying.update(elapsed: target, isPlaying: false, duration: duration)
        isApplyingPlaybackRestore = false
    }

    private func persistPlaybackPosition(force: Bool = false) {
        guard !isChangingEpisode,
              !isApplyingPlaybackRestore,
              pendingPlaybackRestore == nil,
              !episode.audioURL.isFileURL,
              audioManager.loadedURL == episode.audioURL else { return }

        let rawPosition = audioManager.currentTime
        guard rawPosition.isFinite, rawPosition >= 0 else { return }
        let position = audioManager.duration.isFinite && audioManager.duration > 0
            ? min(rawPosition, audioManager.duration)
            : rawPosition
        let now = Date()
        let episodeChanged = lastPersistedEpisodeID != episode.id
        let movedBackward = !episodeChanged && position < lastPersistedPosition - 5
        let movedEnough = episodeChanged || abs(position - lastPersistedPosition) >= 2
        let enoughTimePassed = now.timeIntervalSince(lastPlaybackPositionWrite) >= 2
        guard force || movedBackward || (movedEnough && enoughTimePassed) else { return }

        UserDefaults.standard.set(position, forKey: Self.playbackPositionKey(for: episode.id))
        lastPersistedEpisodeID = episode.id
        lastPersistedPosition = position
        lastPlaybackPositionWrite = now
    }

    private static func savedPlaybackPosition(for episodeID: UUID) -> Double {
        let position = UserDefaults.standard.double(forKey: playbackPositionKey(for: episodeID))
        return position.isFinite && position >= 0 ? position : 0
    }

    private static func playbackPositionKey(for episodeID: UUID) -> String {
        playbackPositionKeyPrefix + episodeID.uuidString
    }

    private func prefetchUpcomingPromptNarration() {
        guard drivingModeEnabled, selectedNarrationVoiceID == NarrationVoiceOption.automaticID else {
            narrationPrefetchTask?.cancel()
            narrationPrefetchTask = nil
            narrationPrefetchSignature = nil
            return
        }
        let questions = episode.prompts.sorted { $0.timestampSeconds < $1.timestampSeconds }
            .filter { !promptedIDs.contains($0.id) }.prefix(2)
            .map { NaturalNarrationService.promptText(question: $0.question) }
        guard !questions.isEmpty else {
            narrationPrefetchTask?.cancel()
            narrationPrefetchTask = nil
            narrationPrefetchSignature = nil
            return
        }
        let signature = ([episode.id.uuidString] + questions).joined(separator: "\n")
        guard signature != narrationPrefetchSignature,
              let apiKey = AIAccountStore.apiKey(), !apiKey.isEmpty else { return }
        // Respect an explicit AI-processing opt-out, including when the key is still saved.
        guard AIProcessingConsent.isAllowed() else { return }
        narrationPrefetchSignature = signature
        narrationPrefetchTask?.cancel()
        narrationPrefetchTask = Task {
            // Debounce prompt edits so typing does not generate a paid clip per keystroke.
            try? await Task.sleep(nanoseconds: 600_000_000)
            for text in questions {
                guard !Task.isCancelled, AIAccountStore.apiKey() == apiKey,
                      AIProcessingConsent.isAllowed() else { return }
                _ = try? await NaturalNarrationService.shared.audio(for: text, apiKey: apiKey, persist: true)
            }
        }
    }

    private func speak(text: String, persist: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelActiveNarration()

        let expectedState = drivingPromptState
        if selectedNarrationVoiceID == NarrationVoiceOption.automaticID {
            let permitsNetwork = AIProcessingConsent.isAllowed()
            startNaturalNarration(
                text: text, apiKey: permitsNetwork ? AIAccountStore.apiKey() : nil,
                expectedState: expectedState, persist: persist
            )
        } else {
            startOnDeviceNarration(text: text, expectedState: expectedState)
        }
    }

    private func startNaturalNarration(
        text: String,
        apiKey: String?,
        expectedState: DrivingPromptState,
        persist: Bool
    ) {
        let narrationID = UUID()
        activeNaturalNarrationID = narrationID
        activeNaturalNarrationState = expectedState

        switch expectedState {
        case .speakingFeedback:
            drivingStatusText = "Preparing natural feedback voice..."
        case .announcingPrompt, .retryingListening:
            drivingStatusText = "Preparing natural voice..."
        default:
            break
        }

        naturalNarrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await NaturalNarrationService.shared.audio(for: text, apiKey: apiKey, persist: persist)
                try Task.checkCancellation()
                guard self.activeNaturalNarrationID == narrationID,
                      self.activeNaturalNarrationState == expectedState,
                      self.drivingPromptState == expectedState else { return }
                do {
                    try self.playNaturalNarration(data, narrationID: narrationID, expectedState: expectedState)
                } catch NaturalNarrationError.invalidAudio {
                    await NaturalNarrationService.shared.discardAudio(for: text)
                    throw NaturalNarrationError.invalidAudio
                }
                self.naturalNarrationTask = nil
                if expectedState == .speakingFeedback {
                    self.drivingStatusText = "Reading feedback..."
                } else if expectedState == .announcingPrompt || expectedState == .retryingListening {
                    self.drivingStatusText = "Reading prompt..."
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.activeNaturalNarrationID == narrationID,
                      self.activeNaturalNarrationState == expectedState,
                      self.drivingPromptState == expectedState else { return }
                self.activeNaturalNarrationID = nil
                self.activeNaturalNarrationState = nil
                self.naturalNarrationTask = nil
                // Never silently replace the natural narrator with a basic robotic voice.
                if let voice = Self.rankedEnglishVoices(AVSpeechSynthesisVoice.speechVoices())
                    .first(where: { $0.quality == .premium || $0.quality == .enhanced }) {
                    self.startOnDeviceNarration(text: text, expectedState: expectedState, voice: voice)
                    self.drivingStatusText = "Natural voice unavailable. Reading with your downloaded \(Self.qualityName(voice.quality).lowercased()) voice."
                } else {
                    self.drivingPromptState = .idle
                    self.drivingStatusText = "Natural voice unavailable. \(error.localizedDescription) Tap the microphone to retry the question, or continue using the text."
                }
            }
        }
    }

    private func playNaturalNarration(
        _ data: Data,
        narrationID: UUID,
        expectedState: DrivingPromptState
    ) throws {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true, options: [])
        } catch {
            throw NaturalNarrationError.unavailable
        }

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            throw NaturalNarrationError.invalidAudio
        }
        player.delegate = self
        player.volume = 1
        guard player.prepareToPlay() else { throw NaturalNarrationError.invalidAudio }
        guard player.play() else {
            throw NaturalNarrationError.unavailable
        }
        naturalNarrationPlayer = player
        activeNaturalNarrationID = narrationID
        activeNaturalNarrationState = expectedState
    }

    private func startOnDeviceNarration(text: String, expectedState: DrivingPromptState, voice: AVSpeechSynthesisVoice? = nil) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true, options: [])
        } catch {}
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? selectedNarrationVoice()
        utterance.rate = 0.47
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.12
        utterance.postUtteranceDelay = 0.22
        activeSpeechUtterance = utterance
        activeSpeechState = expectedState
        speechSynthesizer.speak(utterance)
        startSpeechWatchdog(for: expectedState, utterance: utterance)
    }

    private func cancelActiveNarration() {
        naturalNarrationTask?.cancel()
        naturalNarrationTask = nil
        activeNaturalNarrationID = nil
        activeNaturalNarrationState = nil
        naturalNarrationPlayer?.delegate = nil
        naturalNarrationPlayer?.stop()
        naturalNarrationPlayer = nil

        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil
        activeSpeechUtterance = nil
        activeSpeechState = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func startSpeechWatchdog(
        for expectedState: DrivingPromptState,
        utterance: AVSpeechUtterance
    ) {
        speechWatchdogTask?.cancel()

        speechWatchdogTask = Task { @MainActor in
            let earliestRecovery = Date().addingTimeInterval(3)
            var consecutiveStoppedChecks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                guard drivingModeEnabled, showPrompt, drivingPromptState == expectedState else { return }
                guard activeSpeechUtterance === utterance else { return }

                if speechSynthesizer.isSpeaking {
                    consecutiveStoppedChecks = 0
                    continue
                }
                guard Date() >= earliestRecovery else { continue }

                consecutiveStoppedChecks += 1
                if consecutiveStoppedChecks >= 3 {
                    activeSpeechUtterance = nil
                    activeSpeechState = nil
                    speechWatchdogTask = nil
                    await advanceAfterSpeech(from: expectedState)
                    return
                }
            }
        }
    }

    private func advanceAfterSpeech(from completedState: DrivingPromptState) async {
        guard drivingModeEnabled, showPrompt, drivingPromptState == completedState else { return }
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil

        switch completedState {
        case .announcingPrompt, .retryingListening:
            await startListening()
        case .speakingFeedback:
            // Let the spoken-audio route settle before releasing the podcast playback hold.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard drivingModeEnabled,
                  showPrompt,
                  drivingPromptState == completedState,
                  !speechSynthesizer.isSpeaking,
                  activeSpeechUtterance == nil,
                  naturalNarrationPlayer?.isPlaying != true,
                  naturalNarrationTask == nil else { return }
            continuePlayback()
        default:
            break
        }
    }

    private func spokenFeedback(for result: AIResult) -> String {
        let scoreDescription = "You scored \(result.score) out of 100."
        guard feedbackDetailLevel != .quick else { return scoreDescription }
        return "\(scoreDescription) \(result.feedback)"
    }

    private func selectedNarrationVoice() -> AVSpeechSynthesisVoice? {
        let installedVoices = AVSpeechSynthesisVoice.speechVoices()
        if selectedNarrationVoiceID != NarrationVoiceOption.automaticID,
           let selected = installedVoices.first(where: { $0.identifier == selectedNarrationVoiceID }) {
            return selected
        }
        return Self.rankedEnglishVoices(installedVoices).first
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func makeNarrationVoiceOptions() -> [NarrationVoiceOption] {
        let automatic = NarrationVoiceOption(
            id: NarrationVoiceOption.automaticID,
            name: "Natural AI Voice",
            detail: "Upcoming questions are prepared ahead and replayed with the same natural AI voice. Only a downloaded Premium or Enhanced voice is used if the service is unavailable."
        )
        let installed = Array(rankedEnglishVoices(AVSpeechSynthesisVoice.speechVoices()).prefix(8))
        return [automatic] + installed.map { voice in
            NarrationVoiceOption(
                id: voice.identifier,
                name: voice.name,
                detail: "\(qualityName(voice.quality)) · \(voice.language)"
            )
        }
    }

    private static func rankedEnglishVoices(
        _ voices: [AVSpeechSynthesisVoice]
    ) -> [AVSpeechSynthesisVoice] {
        voices
            .filter {
                $0.language.lowercased().hasPrefix("en")
                    && isNarrationAppropriate($0)
            }
            .sorted { lhs, rhs in
                let leftScore = qualityRank(lhs.quality) * 100
                    + naturalVoiceRank(lhs.name)
                    + (lhs.language.lowercased() == "en-us" ? 5 : 0)
                let rightScore = qualityRank(rhs.quality) * 100
                    + naturalVoiceRank(rhs.name)
                    + (rhs.language.lowercased() == "en-us" ? 5 : 0)
                if leftScore != rightScore { return leftScore > rightScore }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func isNarrationAppropriate(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if #available(iOS 17.0, *), voice.voiceTraits.contains(.isNoveltyVoice) {
            return false
        }
        let noveltyNames: Set<String> = [
            "albert", "bad news", "bahh", "bells", "boing", "bubbles", "cellos",
            "fred", "good news", "jester", "organ", "superstar", "trinoids",
            "whisper", "wobble", "zarvox"
        ]
        return !noveltyNames.contains(voice.name.lowercased())
    }

    private static func naturalVoiceRank(_ name: String) -> Int {
        let preferredNames = [
            "samantha", "ava", "allison", "susan", "alex", "tom", "aaron",
            "nicky", "jamie", "evan", "nathan", "daniel", "karen", "moira", "tessa"
        ]
        let normalizedName = name.lowercased()
        guard let index = preferredNames.firstIndex(where: { normalizedName.contains($0) }) else {
            return 0
        }
        return preferredNames.count - index + 10
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        @unknown default: return 0
        }
    }

    private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Standard"
        @unknown default: return "System"
        }
    }
}

extension PlayerViewModel: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.activeSpeechUtterance === utterance,
                  let completedState = self.activeSpeechState else { return }
            self.activeSpeechUtterance = nil
            self.activeSpeechState = nil
            await self.advanceAfterSpeech(from: completedState)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.activeSpeechUtterance === utterance,
                  let completedState = self.activeSpeechState else { return }
            self.speechWatchdogTask?.cancel()
            self.speechWatchdogTask = nil
            self.activeSpeechUtterance = nil
            self.activeSpeechState = nil
            self.drivingPromptState = .idle
            self.drivingStatusText = completedState == .speakingFeedback
                ? "Feedback narration stopped. Review it below, then continue when you're ready."
                : "Narration stopped. Tap the microphone to try again."
        }
    }
}

@MainActor
private final class AnswerGradingBackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Finish answer grading") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

extension PlayerViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.naturalNarrationPlayer === player,
                  let completedState = self.activeNaturalNarrationState else { return }
            self.naturalNarrationPlayer?.delegate = nil
            self.naturalNarrationPlayer = nil
            self.activeNaturalNarrationID = nil
            self.activeNaturalNarrationState = nil

            guard flag else {
                self.drivingPromptState = .idle
                self.drivingStatusText = "Narration stopped. Review the text, then continue when you're ready."
                return
            }
            await self.advanceAfterSpeech(from: completedState)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.naturalNarrationPlayer === player else { return }
            self.naturalNarrationPlayer?.delegate = nil
            self.naturalNarrationPlayer = nil
            self.activeNaturalNarrationID = nil
            self.activeNaturalNarrationState = nil
            self.drivingPromptState = .idle
            self.drivingStatusText = "Natural voice playback stopped. Review the text, then continue when you're ready."
        }
    }
}
