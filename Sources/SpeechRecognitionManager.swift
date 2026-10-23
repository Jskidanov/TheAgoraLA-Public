import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
protocol SpeechRecognizing: AnyObject {
    var transcript: String { get }
    var transcriptPublisher: AnyPublisher<String, Never> { get }
    var updates: AnyPublisher<Void, Never> { get }
    var isRecording: Bool { get }
    var inputName: String { get }
    var inputLevel: Double { get }
    var hasDetectedVoice: Bool { get }
    var lastVoiceActivityDate: Date { get }
    var authorizationNeedsSettings: Bool { get }
    func requestAuthorization() async -> Bool
    func startRecording() async -> Bool
    func finishRecording() async -> String
    func stopRecording()
}

@MainActor
final class SpeechRecognitionManager: ObservableObject, SpeechRecognizing {
    var transcriptPublisher: AnyPublisher<String, Never> { $transcript.eraseToAnyPublisher() }
    var updates: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
    func stopRecording() { stopRecording(restorePlaybackSession: true) }

    @Published private(set) var transcript: String = ""
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var inputName: String = "Microphone"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var hasDetectedVoice = false
    private(set) var lastVoiceActivityDate = Date.distantPast

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()
    private var hasInstalledInputTap = false
    private var recognitionSessionID = UUID()
    private var recordingStartID = UUID()
    private var finalizationContinuation: CheckedContinuation<String, Never>?
    private var finalizationTimeoutTask: Task<Void, Never>?

    var authorizationNeedsSettings: Bool {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let microphoneStatus = AVAudioSession.sharedInstance().recordPermission
        return speechStatus == .denied
            || speechStatus == .restricted
            || microphoneStatus == .denied
    }

    func requestAuthorization() async -> Bool {
        let speechAuthorized: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechAuthorized = true
        case .notDetermined:
            speechAuthorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            speechAuthorized = false
        }

        guard speechAuthorized else { return false }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    @discardableResult
    func startRecording() async -> Bool {
        guard !isRecording else { return true }
        let startID = UUID()
        recordingStartID = startID
        guard await requestAuthorization() else { return false }
        guard !Task.isCancelled, recordingStartID == startID else { return false }
        stopRecording(restorePlaybackSession: false)
        transcript = ""
        lastErrorMessage = nil
        inputLevel = 0
        hasDetectedVoice = false
        lastVoiceActivityDate = .distantPast

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: [])
            // Let the system honor the listener's headset or selected microphone.
            try? session.setPreferredInput(nil)
            #if targetEnvironment(simulator)
            inputName = "Mac microphone"
            #else
            inputName = session.currentRoute.inputs.first?.portName
                ?? session.preferredInput?.portName
                ?? "Microphone"
            #endif

            let node = audioEngine.inputNode
            let recordingFormat = node.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                throw SpeechRecognitionError.inputUnavailable
            }

            let newRequest = SFSpeechAudioBufferRecognitionRequest()
            guard recognizer?.isAvailable == true else {
                throw SpeechRecognitionError.recognizerUnavailable
            }
            newRequest.shouldReportPartialResults = true
            newRequest.taskHint = .dictation
            request = newRequest

            let sessionID = UUID()
            recognitionSessionID = sessionID
            recognitionTask = recognizer?.recognitionTask(with: newRequest) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.recognitionSessionID == sessionID else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if result?.isFinal == true || error != nil {
                        if let error, self.transcript.isEmpty {
                            self.lastErrorMessage = error.localizedDescription
                        }
                        self.recognitionDidFinish()
                    }
                }
            }
            guard recognitionTask != nil else {
                throw SpeechRecognitionError.recognizerUnavailable
            }

            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 2048, format: recordingFormat) { [weak self] buffer, _ in
                newRequest.append(buffer)
                let level = Self.normalizedInputLevel(for: buffer)
                Task { @MainActor in
                    guard let self, self.recognitionSessionID == sessionID else { return }
                    self.inputLevel = level
                    if level >= 0.2 {
                        self.hasDetectedVoice = true
                        self.lastVoiceActivityDate = Date()
                    }
                }
            }
            hasInstalledInputTap = true
            try audioEngine.start()
            isRecording = true
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            stopRecording()
            return false
        }
    }

    func finishRecording() async -> String {
        guard isRecording else { return transcript }

        stopAudioCapture()
        return await withCheckedContinuation { continuation in
            finalizationContinuation = continuation
            request?.endAudio()
            finalizationTimeoutTask?.cancel()
            finalizationTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                self?.completeFinalization()
            }
        }
    }

    func stopRecording(restorePlaybackSession: Bool) {
        recordingStartID = UUID()
        stopAudioCapture()
        recognitionSessionID = UUID()
        request?.endAudio()
        recognitionTask?.cancel()
        completeFinalization(restorePlaybackSession: restorePlaybackSession)
        clearRecognitionResources(restorePlaybackSession: restorePlaybackSession)
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }
        isRecording = false
        inputLevel = 0
    }

    private func recognitionDidFinish() {
        stopAudioCapture()
        completeFinalization()
        clearRecognitionResources()
    }

    private func completeFinalization(restorePlaybackSession: Bool = true) {
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        guard let continuation = finalizationContinuation else { return }
        finalizationContinuation = nil
        let finalTranscript = transcript
        clearRecognitionResources(restorePlaybackSession: restorePlaybackSession)
        continuation.resume(returning: finalTranscript)
    }

    private func clearRecognitionResources(restorePlaybackSession: Bool = true) {
        recognitionSessionID = UUID()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        if restorePlaybackSession {
            restorePlaybackAudioSession()
        }
    }

    private func restorePlaybackAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Keep Agora as the active media owner so a paused car app is not invited to resume.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {}
    }

    private nonisolated static func normalizedInputLevel(for buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?.pointee else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let decibels = 20 * log10(max(rms, 0.000_000_1))
        return min(max(Double((decibels + 55) / 45), 0), 1)
    }
}

private enum SpeechRecognitionError: LocalizedError {
    case inputUnavailable
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            return "No microphone input is available."
        case .recognizerUnavailable:
            return "Speech recognition is temporarily unavailable."
        }
    }
}
