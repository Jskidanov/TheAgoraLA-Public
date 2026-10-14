import Foundation

private actor StubVoiceProvider {
    private(set) var requests: [URLRequest] = []
    var status = 200
    var contentType = "audio/mpeg"
    var body = Data([0x49, 0x44, 0x33] + Array(repeating: UInt8(0), count: 2_045))
    var delay: UInt64 = 0

    func configure(status: Int = 200, contentType: String = "audio/mpeg", body: Data? = nil, delay: UInt64 = 0) {
        self.status = status
        self.contentType = contentType
        if let body { self.body = body }
        self.delay = delay
    }

    func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return (body, HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!)
    }
}

@main struct NaturalNarrationRegression {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agora-voice-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = StubVoiceProvider()
        let transport: NaturalNarrationService.Transport = { try await provider.respond(to: $0) }
        let service = NaturalNarrationService(directory: directory, transport: transport)
        let text = NaturalNarrationService.promptText(question: "Why did the speaker change their mind?")
        let clip = try await service.audio(for: text, apiKey: "test-key", persist: true)
        let firstRequest = await provider.requests[0]
        let payload = try JSONSerialization.jsonObject(with: firstRequest.httpBody!) as! [String: Any]
        precondition(payload["model"] as? String == "microsoft/mai-voice-2")
        precondition(payload["voice"] as? String == "en-US-Harper:MAI-Voice-2")
        precondition(payload["speed"] as? Double == 0.94)
        precondition(payload["input"] as? String == text)
        precondition(firstRequest.timeoutInterval <= 8)

        // Reset/replay and even a new launch can use the clip without credentials or a connection.
        let replay = try await service.audio(for: text, apiKey: nil, persist: true)
        precondition(replay == clip)
        let reopened = NaturalNarrationService(directory: directory, transport: transport)
        let replayStart = Date()
        let reopenedClip = try await reopened.audio(for: text, apiKey: nil, persist: true)
        let replayMilliseconds = Date().timeIntervalSince(replayStart) * 1_000
        precondition(reopenedClip == clip)
        let requestCountAfterReplay = await provider.requests.count
        precondition(requestCountAfterReplay == 1)
        await reopened.discardAudio(for: text)
        do {
            _ = try await reopened.audio(for: text, apiKey: nil, persist: true)
            preconditionFailure("A decoder-rejected clip must be removed")
        } catch NaturalNarrationError.unavailable { }
        _ = try await service.audio(for: text, apiKey: nil, persist: true)

        // Prefetch and playback share a single paid request.
        await provider.configure(delay: 100_000_000)
        async let prefetch = service.audio(for: "Another prepared question", apiKey: "test-key", persist: true)
        async let playback = service.audio(for: "Another prepared question", apiKey: "test-key", persist: true)
        let concurrent = try await (prefetch, playback)
        precondition(concurrent.0 == concurrent.1)
        let concurrentCount = await provider.requests.count
        precondition(concurrentCount == 2)

        // Changed questions get new audio, rather than reading an obsolete cached question.
        precondition(NaturalNarrationService.cacheKey(for: text) != NaturalNarrationService.cacheKey(for: text + " edited"))
        _ = try await service.audio(for: text + " edited", apiKey: "test-key", persist: true)
        let afterEdit = await provider.requests.count
        precondition(afterEdit == 3)

        // Personal feedback is never written into the public prompt audio cache.
        let feedback = "Your personal answer had these strengths."
        _ = try await service.audio(for: feedback, apiKey: "test-key", persist: false)
        let feedbackPath = directory.appendingPathComponent(NaturalNarrationService.cacheKey(for: feedback) + ".mp3")
        precondition(!FileManager.default.fileExists(atPath: feedbackPath.path))

        // A canceled speaker must not speak, but its preparation can still be reused after reset.
        let canceledText = "Question interrupted by a reset"
        let canceled = Task { try await service.audio(for: canceledText, apiKey: "test-key", persist: true) }
        try await Task.sleep(nanoseconds: 20_000_000)
        canceled.cancel()
        do {
            _ = try await canceled.value
            preconditionFailure("Canceled speech must not be returned for playback")
        } catch is CancellationError { }
        _ = try await service.audio(for: canceledText, apiKey: nil, persist: true)

        // Credit/auth failures and JSON masquerading as audio do not become cache entries.
        let failures = StubVoiceProvider()
        let failureService = NaturalNarrationService(directory: directory) { try await failures.respond(to: $0) }
        await failures.configure(status: 402)
        do {
            _ = try await failureService.audio(for: "Credit failure", apiKey: "test-key", persist: true)
            preconditionFailure("Provider errors must surface")
        } catch NaturalNarrationError.serviceFailure(402) { }
        await failures.configure(body: Data(repeating: 0x7b, count: 2_048))
        do {
            _ = try await failureService.audio(for: "Invalid audio", apiKey: "test-key", persist: true)
            preconditionFailure("JSON must not be cached as MP3")
        } catch NaturalNarrationError.invalidResponse { }

        // Valid short MP3 and octet-stream responses must not cause a needless robotic fallback.
        let shortMP3 = Data([0xff, 0xfb, 0x90] + Array(repeating: UInt8(0), count: 253))
        await failures.configure(contentType: "application/octet-stream", body: shortMP3)
        let shortClip = try await failureService.audio(for: "Repeat please", apiKey: "test-key", persist: true)
        precondition(shortClip == shortMP3)

        // A corrupted disk cache is replaced rather than poisoning every replay.
        let corruptText = "Replace a corrupt cached clip"
        let corruptURL = directory.appendingPathComponent(NaturalNarrationService.cacheKey(for: corruptText) + ".mp3")
        try Data("not audio".utf8).write(to: corruptURL)
        _ = try await failureService.audio(for: corruptText, apiKey: "test-key", persist: true)
        let replacedClip = try Data(contentsOf: corruptURL)
        precondition(replacedClip == shortMP3)

        let boundedDirectory = directory.appendingPathComponent("bounded")
        let bounded = NaturalNarrationService(directory: boundedDirectory, diskBudget: 300) { try await failures.respond(to: $0) }
        _ = try await bounded.audio(for: "First bounded clip", apiKey: "test-key", persist: true)
        _ = try await bounded.audio(for: "Second bounded clip", apiKey: "test-key", persist: true)
        let cachedFiles = try FileManager.default.contentsOfDirectory(at: boundedDirectory, includingPropertiesForKeys: nil)
        precondition(cachedFiles.count == 1)

        print("PASS: same natural narrator; persistent cache replay in \(String(format: "%.1f", replayMilliseconds)) ms; deduplicated requests; cancellation safety; edited questions; feedback privacy; honest provider errors; audio validation; bounded cache.")
    }
}
