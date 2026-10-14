import CryptoKit
import Foundation

enum NaturalNarrationError: LocalizedError {
    case unavailable
    case invalidResponse
    case invalidAudio
    case serviceFailure(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Connect your AI account to prepare the natural voice."
        case .invalidResponse: return "The voice service did not return playable audio."
        case .invalidAudio: return "The prepared voice clip could not be played. Please retry."
        case .serviceFailure(let status):
            if status == 401 || status == 403 { return "Reconnect your AI account to use the natural voice." }
            if status == 402 { return "Your AI provider needs credits to prepare the natural voice." }
            return "The natural voice service is temporarily unavailable. Please retry."
        }
    }
}

actor NaturalNarrationService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = NaturalNarrationService()
    static let model = "microsoft/mai-voice-2"
    static let voice = "en-US-Harper:MAI-Voice-2"
    static let speed = 0.94
    private static let maximumAudioBytes = 5 * 1_024 * 1_024

    private struct Flight {
        let id: UUID
        let task: Task<Data, Error>
    }

    private struct CachedAudio {
        let data: Data
        var lastUsed: Date
    }

    private let directory: URL?
    private let transport: Transport
    private let diskBudget: Int
    private var memory: [String: CachedAudio] = [:]
    private var inFlight: [String: Flight] = [:]

    init(
        directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AgoraNaturalPromptVoice", isDirectory: true),
        diskBudget: Int = 40 * 1_024 * 1_024,
        transport: Transport? = nil
    ) {
        self.directory = directory
        self.diskBudget = diskBudget
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration)
            self.transport = { request in try await session.data(for: request) }
        }
    }

    nonisolated static func promptText(question: String) -> String {
        "Here\u{2019}s your Agora check-in. \(question) Take your time."
    }

    nonisolated static func cacheKey(for text: String) -> String {
        let identity = "v1|\(model)|\(voice)|\(speed)|\(input(for: text))"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // Only question narration is persisted. Personal answer feedback stays in memory.
    func audio(for text: String, apiKey: String?, persist: Bool) async throws -> Data {
        try Task.checkCancellation()
        let key = Self.cacheKey(for: text)
        if var cached = memory[key] {
            cached.lastUsed = Date()
            memory[key] = cached
            if persist { storeOnDisk(cached.data, key: key) }
            return cached.data
        }
        if persist, let url = fileURL(for: key),
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size <= Self.maximumAudioBytes,
           let data = try? Data(contentsOf: url), Self.hasAudioHeader(data) {
            remember(data, key: key)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return data
        }
        if persist, let url = fileURL(for: key), FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let flight: Flight
        if let existing = inFlight[key] {
            flight = existing
        } else {
            guard let apiKey, !apiKey.isEmpty else { throw NaturalNarrationError.unavailable }
            let request = try Self.request(text: text, apiKey: apiKey)
            let transport = self.transport
            flight = Flight(id: UUID(), task: Task {
                let (data, response) = try await transport(request)
                return try Self.validatedAudio(data, response: response)
            })
            inFlight[key] = flight
        }

        do {
            let data = try await flight.task.value
            if inFlight[key]?.id == flight.id {
                inFlight[key] = nil
                remember(data, key: key)
            }
            if persist { storeOnDisk(data, key: key) }
            // A canceled speaker must not play; the shared preparation can still finish caching.
            try Task.checkCancellation()
            return data
        } catch {
            if inFlight[key]?.id == flight.id { inFlight[key] = nil }
            throw error
        }
    }

    nonisolated private static func input(for text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
    }

    func discardAudio(for text: String) {
        let key = Self.cacheKey(for: text)
        memory[key] = nil
        if let url = fileURL(for: key) { try? FileManager.default.removeItem(at: url) }
    }

    nonisolated private static func request(text: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppLinks.home.absoluteString, forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Agora Interactive Podcast", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "input": input(for: text), "voice": voice,
            "response_format": "mp3", "speed": speed,
        ])
        return request
    }

    nonisolated static func hasAudioHeader(_ data: Data) -> Bool {
        guard data.count >= 128 else { return false }
        let bytes = Array(data.prefix(3))
        return bytes == [0x49, 0x44, 0x33]
            || (bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0)
    }

    nonisolated private static func validatedAudio(_ data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw NaturalNarrationError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw NaturalNarrationError.serviceFailure(http.statusCode) }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard (type.contains("audio") || type.contains("application/octet-stream")),
              data.count <= maximumAudioBytes, hasAudioHeader(data) else {
            throw NaturalNarrationError.invalidResponse
        }
        return data
    }

    private func remember(_ data: Data, key: String) {
        memory[key] = CachedAudio(data: data, lastUsed: Date())
        var bytes = memory.values.reduce(0) { $0 + $1.data.count }
        for entry in memory.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            guard bytes > 8 * 1_024 * 1_024 else { break }
            memory[entry.key] = nil
            bytes -= entry.value.data.count
        }
    }

    private func fileURL(for key: String) -> URL? {
        directory?.appendingPathComponent(key).appendingPathExtension("mp3")
    }

    private func storeOnDisk(_ data: Data, key: String) {
        guard let directory, let url = fileURL(for: key) else { return }
        if FileManager.default.fileExists(atPath: url.path) { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            trimDiskCache()
        } catch {
            // A full device must not stop playback; the in-memory audio is still usable.
        }
    }

    private func trimDiskCache() {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
              ) else { return }
        let entries = urls.filter { $0.pathExtension == "mp3" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        for entry in entries {
            guard bytes > diskBudget else { break }
            try? FileManager.default.removeItem(at: entry.0)
            bytes -= entry.1
        }
    }
}
