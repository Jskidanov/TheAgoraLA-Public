import Foundation

@MainActor
final class EpisodeStore: ObservableObject {
    @Published var episode: Episode
    @Published private(set) var savedEpisodes: [Episode]
    @Published private(set) var isLibraryLoaded = false
    @Published var saveError: String?
    private static let storageQueue = DispatchQueue(label: "Agora.episodeStorage", qos: .utility)
    private var saveRevision = 0
    private let storageDirectory: URL?

    private var currentStorageURL: URL? {
        storageDirectory?.appendingPathComponent("episode.json") ?? Self.storageURL
    }
    private var currentLibraryURL: URL? {
        storageDirectory?.appendingPathComponent("episode-library.json") ?? Self.libraryStorageURL
    }

    private let storageKey = "TheAgoraLA.Episode.Data"
    private static let retiredDemoID = UUID(uuidString: "A60DD4CF-8B21-4A03-9D36-E43EC6C351AE")!
    private var libraryLoadTask: Task<Result<[Episode], Error>, Never>?
    private var promptPersistenceTask: Task<Void, Never>?
    private var deferredLibraryEpisodes: [Episode] = []

    private static var storageURL: URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = applicationSupport.appendingPathComponent("TheAgoraLA", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("episode.json")
    }

    private static var libraryStorageURL: URL? {
        storageURL?.deletingLastPathComponent().appendingPathComponent("episode-library.json")
    }

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        let loadedEpisode: Episode
        if let url = storageDirectory?.appendingPathComponent("episode.json") ?? Self.storageURL,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Episode.self, from: data) {
            loadedEpisode = saved
        } else if storageDirectory == nil, let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Episode.self, from: data) {
            loadedEpisode = saved
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else {
            loadedEpisode = MockEpisodeProvider.sample
        }

        episode = loadedEpisode
        savedEpisodes = []

        if episode.id == Self.retiredDemoID {
            episode = MockEpisodeProvider.sample
        }
        syncActiveEpisodeIntoLibrary()
    }

    func loadLibraryIfNeeded() async {
        guard !isLibraryLoaded else { return }

        let task: Task<Result<[Episode], Error>, Never>
        if let libraryLoadTask {
            task = libraryLoadTask
        } else {
            let url = currentLibraryURL
            task = Task.detached(priority: .userInitiated) {
                guard let url else { return .failure(CloudAnalysisError.service("Episode storage is unavailable.")) }
                guard FileManager.default.fileExists(atPath: url.path) else { return .success([]) }
                do { return .success(try JSONDecoder().decode([Episode].self, from: Data(contentsOf: url))) }
                catch { return .failure(error) }
            }
            libraryLoadTask = task
        }

        let result = await task.value
        guard !isLibraryLoaded else { return }
        libraryLoadTask = nil
        guard case .success(let loadedEpisodes) = result else {
            saveError = "The saved episode library could not be read. Its original file has been preserved; contact support before resetting the app."
            return
        }
        savedEpisodes = loadedEpisodes
        isLibraryLoaded = true
        for saved in deferredLibraryEpisodes.reversed() { upsertSavedEpisode(saved) }
        deferredLibraryEpisodes.removeAll()
        syncActiveEpisodeIntoLibrary()
    }

    func updateEpisode(_ updated: Episode) {
        episode = updated
        persist()
    }

    func addPrompt(_ prompt: Prompt) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: (episode.prompts + [prompt]).sorted { $0.timestampSeconds < $1.timestampSeconds },
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
        )
        persist()
    }

    func updatePrompt(_ prompt: Prompt) {
        let updatedPrompts = episode.prompts.map { existing in
            existing.id == prompt.id ? prompt : existing
        }.sorted { $0.timestampSeconds < $1.timestampSeconds }
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: updatedPrompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
        )
        persistPromptsAfterTyping()
    }

    func deletePrompt(_ prompt: Prompt) {
        let updatedPrompts = episode.prompts.filter { $0.id != prompt.id }
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: updatedPrompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
        )
        persist()
    }

    func updateAudioURL(_ url: URL) {
        let sourceChanged = episode.audioURL != url
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: url,
            sourceURL: sourceChanged ? url : episode.sourceURL,
            prompts: sourceChanged ? [] : episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: sourceChanged ? nil : episode.transcript,
            summary: sourceChanged ? nil : episode.summary,
            durationSeconds: sourceChanged ? nil : episode.durationSeconds,
            artworkURL: sourceChanged ? nil : episode.artworkURL
        )
        persist()
    }

    func updateTitle(_ title: String) {
        episode = Episode(
            id: episode.id,
            title: title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
        )
        persist()
    }

    func updateTranscript(_ transcript: String?) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: transcript,
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
        )
        persist()
    }

    func updateTitleAndTranscript(title: String, transcript: String?) {
        episode = Episode(
            id: episode.id,
            title: title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: transcript,
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
        )
        persist()
    }

    func replacePrompts(_ newPrompts: [Prompt]) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: newPrompts.sorted { $0.timestampSeconds < $1.timestampSeconds },
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
        )
        persist()
    }

    func importEpisode(
        title: String,
        audioURL: URL,
        sourceURL: URL,
        feedURL: URL?,
        episodeGUID: String?,
        transcript: String?,
        summary: String?,
        durationSeconds: Double?,
        artworkURL: URL? = nil
    ) {
        syncActiveEpisodeIntoLibrary()
        let sourceChanged = !matchesResolvedEpisode(
            audioURL: audioURL,
            feedURL: feedURL,
            episodeGUID: episodeGUID
        )
        episode = Episode(
            id: sourceChanged ? UUID() : episode.id,
            title: title,
            audioURL: audioURL,
            sourceURL: sourceURL,
            prompts: sourceChanged ? [] : episode.prompts,
            feedURL: sourceChanged ? feedURL : (feedURL ?? episode.feedURL),
            episodeGUID: sourceChanged ? episodeGUID : (episodeGUID ?? episode.episodeGUID),
            transcript: transcript,
            summary: summary,
            durationSeconds: sourceChanged ? durationSeconds : (durationSeconds ?? episode.durationSeconds),
            artworkURL: sourceChanged ? artworkURL : (artworkURL ?? episode.artworkURL)
        )
        persist()
    }

    func matchesResolvedEpisode(audioURL: URL, feedURL: URL?, episodeGUID: String?) -> Bool {
        let currentGUID = normalizedIdentifier(episode.episodeGUID)
        let importedGUID = normalizedIdentifier(episodeGUID)

        if let currentGUID, let importedGUID {
            guard currentGUID == importedGUID else { return false }
            if let currentFeed = episode.feedURL, let feedURL {
                return normalizedFeedURL(currentFeed) == normalizedFeedURL(feedURL)
            }
            return true
        }

        return episode.audioURL == audioURL
    }

    func updateSummary(_ summary: String?) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
        )
        persist()
    }

    func saveAnalysis(_ analysis: EpisodeAnalysisResult, expectedAudioURL: URL) async throws {
        guard episode.audioURL == expectedAudioURL else {
            throw CloudAnalysisError.service("This analysis belongs to a different episode. Your current podcast has not been changed.")
        }
        let updated = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: analysis.prompts.sorted { $0.timestampSeconds < $1.timestampSeconds },
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: analysis.transcript,
            summary: analysis.summary,
            durationSeconds: analysis.duration,
            artworkURL: episode.artworkURL
        )
        episode = updated
        syncActiveEpisodeIntoLibrary()
        try await persistAndWait()
    }

    func updateDuration(_ duration: Double) {
        guard duration.isFinite, duration > 10,
              abs((episode.durationSeconds ?? 0) - duration) > 1 else { return }
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary,
            durationSeconds: duration,
            artworkURL: episode.artworkURL
        )
        persist()
    }

    func saveEpisode(_ savedEpisode: Episode, makeActive: Bool = false) async throws {
        await loadLibraryIfNeeded()
        let replacesActiveEpisode = savedEpisode.id == episode.id
        var updatedLibrary = savedEpisodes
        if let index = updatedLibrary.firstIndex(where: { $0.id == savedEpisode.id }) {
            updatedLibrary[index] = savedEpisode
        } else {
            updatedLibrary.insert(savedEpisode, at: 0)
        }
        if makeActive || replacesActiveEpisode {
            episode = savedEpisode
        }
        savedEpisodes = updatedLibrary
        try await persistAndWait()
    }

    @discardableResult
    func selectEpisode(id: UUID) -> Bool {
        guard let selected = savedEpisodes.first(where: { $0.id == id }) else { return false }
        episode = selected
        persist()
        return true
    }

    func deleteSavedEpisode(id: UUID) {
        guard id != episode.id else { return }
        savedEpisodes.removeAll { $0.id == id }
        persistLibrary()
    }

    private func persist() {
        syncActiveEpisodeIntoLibrary()
        persistLibrary()
    }

    private func persistPromptsAfterTyping() {
        promptPersistenceTask?.cancel()
        promptPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func syncActiveEpisodeIntoLibrary() {
        guard !episode.audioURL.isFileURL else { return }
        guard isLibraryLoaded else {
            deferredLibraryEpisodes.removeAll { $0.id == episode.id }
            deferredLibraryEpisodes.insert(episode, at: 0)
            return
        }
        upsertSavedEpisode(episode)
    }

    private func upsertSavedEpisode(_ savedEpisode: Episode) {
        if let index = savedEpisodes.firstIndex(where: { $0.id == savedEpisode.id }) {
            savedEpisodes[index] = savedEpisode
        } else {
            savedEpisodes.insert(savedEpisode, at: 0)
        }
    }

    private func persistLibrary() {
        enqueueSave { _ in }
    }

    func retrySaving() {
        persist()
    }

    private func persistAndWait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueueSave { result in continuation.resume(with: result) }
        }
    }

    // Capture immutable snapshots on the main actor; serialize disk writes so an
    // older save can never overwrite a newer edit or episode selection.
    private func enqueueSave(completion: @escaping (Result<Void, Error>) -> Void) {
        saveRevision += 1
        let revision = saveRevision
        let current = episode
        let library = isLibraryLoaded ? savedEpisodes : nil
        let deferred = deferredLibraryEpisodes
        let currentURL = currentStorageURL
        let libraryURL = currentLibraryURL
        Self.storageQueue.async {
            let result = Result<Void, Error> {
                guard let currentURL else {
                    throw CloudAnalysisError.service("Episode storage is unavailable.")
                }
                try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(current).write(to: currentURL, options: .atomic)
                guard let libraryURL else {
                    throw CloudAnalysisError.service("Library storage is unavailable.")
                }
                var savedLibrary = library ?? []
                if library == nil {
                    if FileManager.default.fileExists(atPath: libraryURL.path) {
                        savedLibrary = try JSONDecoder().decode([Episode].self, from: Data(contentsOf: libraryURL))
                    }
                    for saved in deferred.reversed() {
                        savedLibrary.removeAll { $0.id == saved.id }
                        savedLibrary.insert(saved, at: 0)
                    }
                }
                try JSONEncoder().encode(savedLibrary).write(to: libraryURL, options: .atomic)
            }
            Task { @MainActor [weak self] in
                if let self, self.saveRevision == revision {
                    switch result {
                    case .success: self.saveError = nil
                    case .failure:
                        self.saveError = "Your latest changes could not be saved. They are still open in Agora. Free some device storage if needed, then tap Retry Save before closing the app."
                    }
                }
                completion(result)
            }
        }
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedFeedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        components.query = nil
        return components.url ?? url
    }
}
