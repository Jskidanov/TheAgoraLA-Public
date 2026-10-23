import AVFoundation
import Foundation

@MainActor
protocol PromptNarrating: AnyObject {
    func speak(
        text: String, persist: Bool, preferNatural: Bool, voice: AVSpeechSynthesisVoice?,
        status: @escaping (String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func stop()
}

/// Owns one narration at a time. Cancellation, silence, and decoding errors are never success.
@MainActor
final class PromptNarrator: NSObject, PromptNarrating {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var preparation: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var utterance: AVSpeechUtterance?
    private var requestID: UUID?
    private var completion: ((Result<Void, Error>) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        text: String, persist: Bool, preferNatural: Bool, voice: AVSpeechSynthesisVoice?,
        status: @escaping (String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        stop()
        let id = UUID()
        requestID = id
        self.completion = completion
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish(.failure(NaturalNarrationError.invalidResponse))
            return
        }
        guard preferNatural else {
            startSpeech(text: text, voice: voice, id: id)
            return
        }
        status("Preparing natural voice...")
        preparation = Task { [weak self] in
            do {
                let apiKey = AIProcessingConsent.isAllowed() ? AIAccountStore.apiKey() : nil
                let data = try await NaturalNarrationService.shared.audio(for: text, apiKey: apiKey, persist: persist)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                try self.configureSession()
                let clip: AVAudioPlayer
                do {
                    clip = try AVAudioPlayer(data: data)
                    guard clip.prepareToPlay() else { throw NaturalNarrationError.invalidAudio }
                } catch {
                    await NaturalNarrationService.shared.discardAudio(for: text)
                    throw NaturalNarrationError.invalidAudio
                }
                guard self.requestID == id, !Task.isCancelled else { return }
                clip.delegate = self
                self.player = clip
                guard clip.play() else { throw NaturalNarrationError.unavailable }
                self.preparation = nil
                status("Reading aloud...")
            } catch is CancellationError {
                // The caller owns the decision to retry or leave the check-in.
            } catch {
                guard let self, self.requestID == id else { return }
                self.preparation = nil
                self.player?.delegate = nil
                self.player?.stop()
                self.player = nil
                if let downloaded = AVSpeechSynthesisVoice.speechVoices().first(where: {
                    $0.language.lowercased().hasPrefix("en") && ($0.quality == .enhanced || $0.quality == .premium)
                }) {
                    status("Natural voice unavailable. Reading with your downloaded voice.")
                    self.startSpeech(text: text, voice: downloaded, id: id)
                } else {
                    self.finish(.failure(error))
                }
            }
        }
    }

    func stop() {
        requestID = nil
        completion = nil
        preparation?.cancel()
        preparation = nil
        watchdog?.cancel()
        watchdog = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true, options: [])
    }

    private func startSpeech(text: String, voice: AVSpeechSynthesisVoice?, id: UUID) {
        do { try configureSession() } catch {
            finish(.failure(error))
            return
        }
        let speech = AVSpeechUtterance(string: text)
        speech.voice = voice
        speech.rate = 0.47
        speech.preUtteranceDelay = 0.12
        speech.postUtteranceDelay = 0.22
        utterance = speech
        synthesizer.speak(speech)
        watchdog = Task { [weak self] in
            var stoppedChecks = 0
            // If the engine never starts or loses its completion callback, keep the check-in held.
            // isSpeaking == false alone cannot prove the listener heard any feedback.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                stoppedChecks = self.synthesizer.isSpeaking ? 0 : stoppedChecks + 1
                if stoppedChecks >= 3 {
                    self.finish(.failure(NaturalNarrationError.unavailable))
                    return
                }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let callback = completion
        stop()
        callback?(result)
    }
}

extension PromptNarrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.finish(.success(()))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.finish(.failure(NaturalNarrationError.unavailable))
        }
    }
}

extension PromptNarrator: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.finish(flag ? .success(()) : .failure(NaturalNarrationError.invalidAudio))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.finish(.failure(error ?? NaturalNarrationError.invalidAudio))
        }
    }
}
