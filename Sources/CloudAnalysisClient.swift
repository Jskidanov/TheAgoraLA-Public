import Foundation

enum CloudAnalysisError: LocalizedError {
    case notConfigured
    case invalidResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Cloud analysis has not been configured for this build."
        case .invalidResponse:
            return "The cloud analysis service returned an unreadable response."
        case .service(let message):
            return message
        }
    }

    static let backgroundServiceUnavailable = "Agora's background analysis service is temporarily offline. Your podcasts are still saved in the backlog; try Analyze Backlog again when the service is restored."
}

struct PendingCloudAnalysis: Codable {
    let jobID: UUID
    let expectedAudioURL: URL
}

enum CloudAnalysisJobState: String {
    case queued
    case processing
    case complete
    case failed
}

struct CloudAnalysisJobSnapshot {
    let state: CloudAnalysisJobState
    let analysis: EpisodeAnalysisResult?
    let errorMessage: String?
}

struct CloudAnalysisClient {
    private static let installationKey = "TheAgoraLA.Cloud.InstallationID"
    private static let sessionKey = "TheAgoraLA.Cloud.SessionToken"
    private static let pendingKey = "TheAgoraLA.Cloud.PendingAnalysis"
    private static let networkSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    static var isConfigured: Bool { baseURL != nil }

    static var pendingAnalysis: PendingCloudAnalysis? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(PendingCloudAnalysis.self, from: data)
    }

    func verifyAvailability() async throws {
        var request = try makeRequest(path: "health", method: "GET")
        request.timeoutInterval = 12
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAnalysisError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw CloudAnalysisError.service(
                serviceMessage(from: data, response: http)
                    ?? CloudAnalysisError.backgroundServiceUnavailable
            )
        }
    }

    func submitAndWait(
        title: String,
        audioURL: URL,
        transcript: String?,
        transcriptSource: PodcastTranscriptSource?,
        duration: Double?,
        promptCount: Int?,
        model: String,
        providerAPIKey: String,
        forceRefresh: Bool = false,
        progress: @escaping (String) -> Void
    ) async throws -> (EpisodeAnalysisResult, URL, UUID) {
        progress("Securely sending the episode to cloud analysis...")
        let pending = try await submit(
            title: title,
            audioURL: audioURL,
            transcript: transcript,
            transcriptSource: transcriptSource,
            duration: duration,
            promptCount: promptCount,
            model: model,
            providerAPIKey: providerAPIKey,
            forceRefresh: forceRefresh,
            rememberAsCurrent: true
        )
        progress("Cloud analysis is running. You can safely leave the app and return later.")
        return (try await waitForCompletion(pending, progress: progress), audioURL, pending.jobID)
    }

    func submit(
        title: String,
        audioURL: URL,
        transcript: String?,
        transcriptSource: PodcastTranscriptSource?,
        duration: Double?,
        promptCount: Int?,
        model: String,
        providerAPIKey: String,
        forceRefresh: Bool = false,
        rememberAsCurrent: Bool = false
    ) async throws -> PendingCloudAnalysis {
        guard AIAccountStore.hasDataSharingConsent else { throw AIAccountError.dataSharingPermissionRequired }
        var body: [String: Any] = [
            "title": title,
            "audio_url": audioURL.absoluteString,
            "model": model,
            "provider_api_key": providerAPIKey,
            "force_refresh": forceRefresh,
        ]
        if let promptCount {
            body["prompt_count"] = min(max(promptCount, 3), 12)
        }
        if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["transcript"] = transcript
        } else if let transcriptSource {
            body["transcript_url"] = transcriptSource.url.absoluteString
            if let type = transcriptSource.type, !type.isEmpty {
                body["transcript_type"] = type
            }
        }
        if let duration, duration > 10 { body["duration"] = duration }
        let data = try await authorizedRequest(path: "v1/episode-jobs", method: "POST", body: body)
        let job = try JSONDecoder().decode(JobEnvelope.self, from: data)
        let pending = PendingCloudAnalysis(jobID: job.id, expectedAudioURL: audioURL)
        if rememberAsCurrent { Self.savePending(pending) }
        return pending
    }

    func resumePending(progress: @escaping (String) -> Void) async throws -> (EpisodeAnalysisResult, URL, UUID)? {
        guard let pending = Self.pendingAnalysis else { return nil }
        progress("Reconnecting to your cloud analysis...")
        return (try await waitForCompletion(pending, progress: progress), pending.expectedAudioURL, pending.jobID)
    }

    func status(for pending: PendingCloudAnalysis) async throws -> CloudAnalysisJobSnapshot {
        let data = try await authorizedRequest(path: "v1/episode-jobs/\(pending.jobID.uuidString)", method: "GET")
        let job = try JSONDecoder().decode(JobEnvelope.self, from: data)
        guard let state = CloudAnalysisJobState(rawValue: job.status) else {
            throw CloudAnalysisError.invalidResponse
        }
        return CloudAnalysisJobSnapshot(
            state: state,
            analysis: job.result?.episodeAnalysis,
            errorMessage: job.error
        )
    }

    func cancel(jobID: UUID) async throws {
        _ = try await authorizedRequest(path: "v1/episode-jobs/\(jobID.uuidString)/cancel", method: "POST")
    }

    func acknowledge(jobID: UUID) async throws {
        _ = try await authorizedRequest(path: "v1/episode-jobs/\(jobID.uuidString)/acknowledge", method: "POST")
    }

    private func waitForCompletion(
        _ pending: PendingCloudAnalysis,
        progress: @escaping (String) -> Void
    ) async throws -> EpisodeAnalysisResult {
        var pollDelayNanoseconds: UInt64 = 2_000_000_000
        while true {
            try Task.checkCancellation()
            let snapshot = try await status(for: pending)
            switch snapshot.state {
            case .complete:
                guard let analysis = snapshot.analysis else { throw CloudAnalysisError.invalidResponse }
                progress("Cloud analysis complete.")
                return analysis
            case .failed:
                Self.clearPending()
                throw CloudAnalysisError.service(snapshot.errorMessage ?? "Cloud analysis could not finish this episode.")
            case .processing:
                progress("Transcribing and analyzing the complete episode in the cloud. You can leave the app.")
            case .queued:
                progress("Your episode is queued in the cloud. You can leave the app.")
            }
            try await Task.sleep(nanoseconds: pollDelayNanoseconds)
            pollDelayNanoseconds = min(pollDelayNanoseconds + 2_000_000_000, 12_000_000_000)
        }
    }

    private func authorizedRequest(path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        var token = try await sessionToken()
        for attempt in 0...1 {
            var request = try makeRequest(path: path, method: method, body: body)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { throw CloudAnalysisError.invalidResponse }
            if http.statusCode == 401, attempt == 0 {
                UserDefaults.standard.removeObject(forKey: Self.sessionKey)
                token = try await sessionToken()
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                throw CloudAnalysisError.service(
                    serviceMessage(from: data, response: http)
                        ?? "Cloud analysis is temporarily unavailable."
                )
            }
            return data
        }
        throw CloudAnalysisError.invalidResponse
    }

    private func sessionToken() async throws -> String {
        if let token = UserDefaults.standard.string(forKey: Self.sessionKey), !token.isEmpty { return token }
        let installationID: String
        if let saved = UserDefaults.standard.string(forKey: Self.installationKey), UUID(uuidString: saved) != nil {
            installationID = saved
        } else {
            installationID = UUID().uuidString
            UserDefaults.standard.set(installationID, forKey: Self.installationKey)
        }
        let request = try makeRequest(
            path: "v1/auth/device",
            method: "POST",
            body: ["installation_id": installationID]
        )
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAnalysisError.invalidResponse
        }
        guard (200...299).contains(http.statusCode),
              let token = (try? JSONDecoder().decode(SessionEnvelope.self, from: data))?.token else {
            throw CloudAnalysisError.service(
                serviceMessage(from: data, response: http)
                    ?? "The cloud session could not be started."
            )
        }
        UserDefaults.standard.set(token, forKey: Self.sessionKey)
        return token
    }

    private func makeRequest(path: String, method: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let baseURL = Self.baseURL else { throw CloudAnalysisError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let result = try await Self.networkSession.data(for: request)
                if let response = result.1 as? HTTPURLResponse,
                   [429, 502, 503, 504].contains(response.statusCode),
                   attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
                    continue
                }
                return result
            } catch {
                lastError = error
                guard attempt < 2, shouldRetryNetworkError(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
            }
        }
        throw lastError ?? CloudAnalysisError.invalidResponse
    }

    private func shouldRetryNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
            .callIsActive, .dataNotAllowed,
        ].contains(urlError.code)
    }

    private static var baseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AgoraAPIBaseURL") as? String,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private static func savePending(_ pending: PendingCloudAnalysis) {
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: pendingKey)
    }

    private static func clearPending() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    static func acknowledgeSavedAnalysis(jobID: UUID?) {
        guard let jobID else { return }
        if pendingAnalysis?.jobID == jobID { clearPending() }
        // A failed acknowledgement leaves the server result retained, never deleted early.
        Task { try? await CloudAnalysisClient().acknowledge(jobID: jobID) }
    }

    private func serviceMessage(from data: Data, response: HTTPURLResponse? = nil) -> String? {
        let decoded = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.displayMessage
        let railwayFallback = response?.value(forHTTPHeaderField: "x-railway-fallback")?.lowercased() == "true"
        let missingApplication = decoded?.localizedCaseInsensitiveContains("application not found") == true
        if railwayFallback || missingApplication {
            return CloudAnalysisError.backgroundServiceUnavailable
        }
        return decoded
    }
}

private struct SessionEnvelope: Decodable { let token: String }
private struct ErrorEnvelope: Decodable {
    let error: String?
    let message: String?

    var displayMessage: String? {
        [error, message]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private struct JobEnvelope: Decodable {
    let id: UUID
    let status: String
    let result: CloudEpisodeResult?
    let error: String?
}

private struct CloudEpisodeResult: Decodable {
    struct CloudPrompt: Decodable {
        let time: Double
        let question: String
        let expectedAnswer: String

        enum CodingKeys: String, CodingKey {
            case time, question
            case expectedAnswer = "expected_answer"
        }
    }

    let transcript: String
    let duration: Double
    let summary: String
    let prompts: [CloudPrompt]

    var episodeAnalysis: EpisodeAnalysisResult {
        EpisodeAnalysisResult(
            transcript: transcript,
            duration: duration,
            summary: summary,
            prompts: prompts.map {
                Prompt(id: UUID(), timestampSeconds: $0.time, question: $0.question, expectedAnswer: $0.expectedAnswer)
            }.sorted { $0.timestampSeconds < $1.timestampSeconds },
            recommendedPromptCount: prompts.count,
            contentDepthLabel: "Cloud analyzed"
        )
    }
}
