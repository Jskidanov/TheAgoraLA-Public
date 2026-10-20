import SwiftUI
import Foundation
import UIKit

private enum PodcastBacklogStatus: String, Codable {
    case waiting
    case resolving
    case submitting
    case queued
    case processing
    case complete
    case failed

    var title: String {
        switch self {
        case .waiting: return "Ready to submit"
        case .resolving: return "Finding episode"
        case .submitting: return "Sending to cloud"
        case .queued: return "Queued"
        case .processing: return "Analyzing"
        case .complete: return "Ready to listen"
        case .failed: return "Needs attention"
        }
    }

    var isActive: Bool {
        [.resolving, .submitting, .queued, .processing].contains(self)
    }
}

private struct PodcastBrowsedPick: Codable, Hashable {
    let guid: String?
    let title: String

    var matchKey: String {
        if let guid, !guid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return guid }
        return title
    }
}

private struct PodcastBacklogItem: Identifiable, Codable {
    let id: UUID
    let episodeID: UUID
    let sourceURL: URL
    /// Set when the item came from browsing: `sourceURL` is then the show's
    /// feed and this picks one episode out of it. Absent for pasted links.
    var browsedPick: PodcastBrowsedPick?
    var title: String?
    var audioURL: URL?
    var feedURL: URL?
    var episodeGUID: String?
    var publisherSummary: String?
    var transcriptURL: URL?
    var transcriptType: String?
    var durationSeconds: Double?
    var artworkURL: URL?
    var jobID: UUID?
    var status: PodcastBacklogStatus
    var errorMessage: String?
    let createdAt: Date

    var displayTitle: String {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? (sourceURL.host ?? "Podcast episode") : cleaned
    }

    var transcriptSource: PodcastTranscriptSource? {
        transcriptURL.map { PodcastTranscriptSource(url: $0, type: transcriptType) }
    }

    /// Two episodes of one show share a feed URL, so the picked episode is part
    /// of what makes a backlog entry distinct.
    var identity: String {
        let base = PodcastSourceParser.identity(for: sourceURL)
        guard let browsedPick else { return base }
        return "\(base)#\(browsedPick.matchKey)"
    }
}

private enum PodcastTranscriptCheckpoint {
    private static func fileURL(for episodeID: UUID) -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = applicationSupport
            .appendingPathComponent("TheAgoraLA", isDirectory: true)
            .appendingPathComponent("backlog-transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(episodeID.uuidString).txt")
    }

    static func load(for episodeID: UUID) async -> String? {
        await Task.detached(priority: .utility) {
            guard let url = fileURL(for: episodeID) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.value
    }

    static func save(_ transcript: String, for episodeID: UUID) async {
        await Task.detached(priority: .utility) {
            guard let url = fileURL(for: episodeID) else { return }
            try? transcript.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    static func remove(for episodeID: UUID) async {
        await Task.detached(priority: .utility) {
            guard let url = fileURL(for: episodeID) else { return }
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}

@MainActor
private final class PodcastBacklogStore: ObservableObject {
    @Published private(set) var items: [PodcastBacklogItem]
    @Published private(set) var isSubmitting = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isUsingDirectFallback = false
    @Published private(set) var cloudUnavailable = false
    @Published var notice = ""
    @Published private(set) var storageError: String?

    private static var storageURL: URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = applicationSupport.appendingPathComponent("TheAgoraLA", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("podcast-backlog.json")
    }

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var forceRefreshIDs = Set<UUID>()

    init() {
        if let url = Self.storageURL,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([PodcastBacklogItem].self, from: data) {
            items = saved.map { storedItem in
                var item = storedItem
                if item.errorMessage?.localizedCaseInsensitiveContains("application not found") == true {
                    item.errorMessage = CloudAnalysisError.backgroundServiceUnavailable
                }
                if item.status.isActive, item.jobID == nil {
                    item.status = .waiting
                    item.errorMessage = "The previous preparation was interrupted. This podcast is ready to try again."
                }
                return item
            }
        } else {
            items = []
        }
        cloudUnavailable = !CloudAnalysisClient.isConfigured
        observeAppLifecycle()
    }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Keeps the process alive briefly after the app is backgrounded so an in-flight
    /// cloud poll or on-device analysis chain can keep running instead of freezing
    /// mid-request. This only postpones suspension; it cannot survive a force-quit.
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.beginBackgroundExecutionIfNeeded() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.endBackgroundExecution() }
            },
        ]
    }

    private func beginBackgroundExecutionIfNeeded() {
        guard backgroundTaskID == .invalid, hasActiveJobs || isSubmitting else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Agora Podcast Backlog") { [weak self] in
            Task { @MainActor in self?.endBackgroundExecution() }
        }
    }

    private func endBackgroundExecution() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    var hasActiveJobs: Bool { items.contains { $0.status.isActive } }
    var hasStartableItems: Bool { items.contains { $0.status == .waiting || $0.status == .failed } }
    var completedCount: Int { items.filter { $0.status == .complete }.count }
    var activeCount: Int { items.filter { $0.status.isActive }.count }
    var waitingCount: Int { items.filter { $0.status == .waiting }.count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }
    var orderedItems: [PodcastBacklogItem] {
        items.sorted { lhs, rhs in
            let lhsRank = displayRank(for: lhs.status)
            let rhsRank = displayRank(for: rhs.status)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.createdAt > rhs.createdAt
        }
    }
    var startButtonTitle: String {
        if cloudUnavailable { return "Prepare Remaining on This iPhone" }
        return hasActiveJobs ? "Add Remaining to Running Backlog" : "Analyze Backlog"
    }

    func checkCloudAvailability() async {
        guard CloudAnalysisClient.isConfigured else { return }
        do {
            try await CloudAnalysisClient().verifyAvailability()
            cloudUnavailable = false
        } catch {
            cloudUnavailable = true
            notice = "Cloud preparation is offline. Your backlog is saved. On-phone preparation may pause after you lock your phone or switch apps, and resumes when Agora is reopened."
        }
    }

    func auditCompletedEpisodes(episodeStore: EpisodeStore) {
        var rebuildCount = 0
        for index in items.indices where items[index].status == .complete {
            guard let episode = episodeStore.savedEpisodes.first(where: { $0.id == items[index].episodeID }) else {
                continue
            }
            let transcriptWords = episode.transcript?.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count ?? 0
            let estimatedDuration = transcriptWords > 0 ? Double(transcriptWords) / 2.6 : 0
            let duration = items[index].durationSeconds ?? estimatedDuration
            let minimumCount = PodcastPromptPolicy.minimumCount(for: duration)
            let hasCoverage = PodcastPromptPolicy.hasAdequateCoverage(episode.prompts, duration: duration)
            guard episode.prompts.count < minimumCount || !hasCoverage else { continue }

            items[index].status = .waiting
            items[index].jobID = nil
            items[index].durationSeconds = duration > 10 ? duration : items[index].durationSeconds
            items[index].errorMessage = "This earlier analysis needs stronger coverage. It is ready to rebuild with more questions across the full episode."
            rebuildCount += 1
        }
        guard rebuildCount > 0 else { return }
        persist()
        notice = "Found \(rebuildCount) episode\(rebuildCount == 1 ? "" : "s") that needs better prompt coverage. Tap Analyze Backlog to rebuild it."
    }

    @discardableResult
    func addLinks(from entries: [String]) -> Bool {
        let filledEntries = entries.enumerated().filter {
            !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !filledEntries.isEmpty else {
            notice = "Paste at least one complete podcast link beginning with https://."
            return false
        }

        var urls: [URL] = []
        for (index, entry) in filledEntries {
            let detected = PodcastSourceParser.urls(in: entry)
            guard detected.count == 1 else {
                notice = detected.isEmpty
                    ? "Podcast \(index + 1) needs one complete podcast or RSS link."
                    : "Podcast \(index + 1) contains multiple links. Use one link in each podcast slot."
                return false
            }
            urls.append(detected[0])
        }

        var requested = Set<String>()
        let unique = urls.filter { requested.insert(normalizedURL($0)).inserted }
        var newURLs: [URL] = []
        var restoredCount = 0
        var waitingCount = 0
        var runningCount = 0
        var completeCount = 0

        for url in unique {
            let identity = normalizedURL(url)
            guard let index = items.firstIndex(where: { $0.identity == identity }) else {
                newURLs.append(url)
                continue
            }

            switch items[index].status {
            case .failed:
                items[index].status = .waiting
                items[index].jobID = nil
                items[index].errorMessage = nil
                restoredCount += 1
            case .waiting:
                waitingCount += 1
            case .resolving, .submitting, .queued, .processing:
                runningCount += 1
            case .complete:
                completeCount += 1
            }
        }

        let additions = newURLs.map { url in
            PodcastBacklogItem(
                id: UUID(),
                episodeID: UUID(),
                sourceURL: url,
                browsedPick: nil,
                title: nil,
                audioURL: nil,
                feedURL: nil,
                episodeGUID: nil,
                publisherSummary: nil,
                transcriptURL: nil,
                transcriptType: nil,
                durationSeconds: nil,
                artworkURL: nil,
                jobID: nil,
                status: .waiting,
                errorMessage: nil,
                createdAt: Date()
            )
        }
        items.append(contentsOf: additions)
        persist()
        if restoredCount > 0 {
            let addedText = additions.isEmpty
                ? ""
                : " and added \(additions.count) new podcast\(additions.count == 1 ? "" : "s")"
            notice = "Restored \(restoredCount) failed podcast\(restoredCount == 1 ? "" : "s")\(addedText). Analysis will begin automatically."
        } else if !additions.isEmpty {
            notice = "Added \(additions.count) podcast\(additions.count == 1 ? "" : "s"). Starting analysis..."
        } else if runningCount > 0 {
            notice = "That podcast is already being analyzed in your backlog."
        } else if waitingCount > 0 {
            notice = "That podcast is already waiting to be analyzed."
        } else if completeCount > 0 {
            notice = "That podcast is already prepared and ready to listen to below."
        } else {
            notice = "Those podcasts are already in your backlog."
        }
        return true
    }

    /// Queues episodes chosen in the browse sheet. They arrive already
    /// identified, so there is nothing to parse out of pasted text.
    func addBrowsedEpisodes(_ picks: [PodcastSearchSelection]) -> Bool {
        guard !picks.isEmpty else { return false }

        var additions: [PodcastBacklogItem] = []
        var restoredCount = 0
        var duplicateCount = 0
        var seen = Set<String>()

        for pick in picks {
            let candidate = PodcastBacklogItem(
                id: UUID(),
                episodeID: UUID(),
                sourceURL: pick.feedURL,
                browsedPick: PodcastBrowsedPick(guid: pick.guid, title: pick.title),
                title: pick.title,
                audioURL: nil,
                feedURL: pick.feedURL,
                episodeGUID: pick.guid,
                publisherSummary: nil,
                transcriptURL: nil,
                transcriptType: nil,
                durationSeconds: nil,
                artworkURL: nil,
                jobID: nil,
                status: .waiting,
                errorMessage: nil,
                createdAt: Date()
            )
            guard seen.insert(candidate.identity).inserted else { continue }

            if let index = items.firstIndex(where: { $0.identity == candidate.identity }) {
                if items[index].status == .failed {
                    items[index].status = .waiting
                    items[index].jobID = nil
                    items[index].errorMessage = nil
                    restoredCount += 1
                } else {
                    duplicateCount += 1
                }
                continue
            }
            additions.append(candidate)
        }

        items.append(contentsOf: additions)
        persist()

        if additions.isEmpty, restoredCount == 0 {
            notice = duplicateCount == 1
                ? "That episode is already in your backlog."
                : "Those episodes are already in your backlog."
            return false
        }
        if restoredCount > 0, additions.isEmpty {
            notice = "Restored \(restoredCount) failed episode\(restoredCount == 1 ? "" : "s"). Analysis will begin automatically."
        } else {
            let skipped = duplicateCount > 0 ? " \(duplicateCount) already queued." : ""
            notice = "Added \(additions.count) episode\(additions.count == 1 ? "" : "s"). Starting analysis...\(skipped)"
        }
        return true
    }

    func startAll(episodeStore: EpisodeStore) async {
        if isSubmitting {
            notice = "New podcasts will join as soon as the current submissions finish."
            return
        }
        guard let providerKey = AIAccountStore.apiKey() else {
            notice = "Connect your AI account before starting the backlog."
            return
        }
        guard hasStartableItems else {
            notice = hasActiveJobs ? "Your backlog is already running in the cloud." : "Add podcast links to begin."
            return
        }

        isSubmitting = true
        defer {
            isSubmitting = false
            isUsingDirectFallback = false
        }

        var attemptedIDs = Set<UUID>()
        var submittedToCloud = false
        while !Task.isCancelled {
            let ids = items.filter {
                ($0.status == .waiting || $0.status == .failed) && !attemptedIDs.contains($0.id)
            }.map(\.id)
            guard !ids.isEmpty else { break }
            attemptedIDs.formUnion(ids)

            if !CloudAnalysisClient.isConfigured {
                cloudUnavailable = true
                isUsingDirectFallback = true
                await prepareDirectly(ids: ids, episodeStore: episodeStore)
                isUsingDirectFallback = false
                continue
            }

            notice = "Checking the background analysis service..."
            do {
                try await CloudAnalysisClient().verifyAvailability()
            } catch {
                cloudUnavailable = true
                isUsingDirectFallback = true
                await prepareDirectly(ids: ids, episodeStore: episodeStore)
                isUsingDirectFallback = false
                continue
            }
            cloudUnavailable = false
            isUsingDirectFallback = false

            notice = "Preparing and submitting \(ids.count) podcast\(ids.count == 1 ? "" : "s")..."
            for start in stride(from: 0, to: ids.count, by: 3) {
                let end = min(start + 3, ids.count)
                let tasks = ids[start..<end].map { id in
                    Task { await self.submit(id: id, providerKey: providerKey) }
                }
                for task in tasks { await task.value }
            }
            submittedToCloud = true
            await refreshAll(episodeStore: episodeStore)
        }
        guard submittedToCloud, !cloudUnavailable else { return }
        let failures = items.filter { $0.status == .failed }.count
        notice = failures == 0
            ? "Backlog submitted. You can leave the app while the cloud finishes."
            : "The cloud accepted the available episodes. Review any item marked Needs attention."
    }

    func refreshAll(episodeStore: EpisodeStore) async {
        guard !isRefreshing, CloudAnalysisClient.isConfigured else { return }
        let pendingIDs = items.filter { $0.jobID != nil && ($0.status == .queued || $0.status == .processing) }.map(\.id)
        guard !pendingIDs.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        for id in pendingIDs {
            guard let item = item(with: id), let jobID = item.jobID, let audioURL = item.audioURL else { continue }
            do {
                let snapshot = try await CloudAnalysisClient().status(
                    for: PendingCloudAnalysis(jobID: jobID, expectedAudioURL: audioURL)
                )
                cloudUnavailable = false
                switch snapshot.state {
                case .queued:
                    update(id) {
                        $0.status = .queued
                        $0.errorMessage = nil
                    }
                case .processing:
                    update(id) {
                        $0.status = .processing
                        $0.errorMessage = nil
                    }
                case .failed:
                    update(id) {
                        $0.status = .failed
                        $0.errorMessage = snapshot.errorMessage ?? "Cloud analysis could not finish this episode."
                    }
                case .complete:
                    guard let analysis = snapshot.analysis else {
                        throw CloudAnalysisError.invalidResponse
                    }
                    do {
                        try validateAutomaticAnalysis(analysis)
                    } catch {
                        update(id) {
                            $0.status = .failed
                            $0.errorMessage = "The analysis did not produce enough well-distributed questions. Tap Retry to generate a fresh analysis."
                        }
                        continue
                    }
                    let completed = Episode(
                        id: item.episodeID,
                        title: item.displayTitle,
                        audioURL: audioURL,
                        sourceURL: item.sourceURL,
                        prompts: analysis.prompts.sorted { $0.timestampSeconds < $1.timestampSeconds },
                        feedURL: item.feedURL,
                        episodeGUID: item.episodeGUID,
                        transcript: analysis.transcript,
                        summary: analysis.summary,
                        durationSeconds: analysis.duration,
                        artworkURL: item.artworkURL
                    )
                    try await episodeStore.saveEpisode(completed)
                    await PodcastTranscriptCheckpoint.remove(for: item.episodeID)
                    update(id) {
                        $0.status = .complete
                        $0.durationSeconds = analysis.duration
                        $0.errorMessage = nil
                    }
                    CloudAnalysisClient.acknowledgeSavedAnalysis(jobID: jobID)
                }
            } catch {
                if case CloudAnalysisError.invalidResponse = error {
                    update(id) {
                        $0.status = .failed
                        $0.errorMessage = "The cloud returned an incomplete analysis. Tap Retry to generate a fresh analysis."
                    }
                    continue
                }
                if error is DecodingError {
                    update(id) {
                        $0.status = .failed
                        $0.errorMessage = "The cloud returned an unreadable analysis. Tap Retry to generate a fresh analysis."
                    }
                    continue
                }
                if let urlError = error as? URLError,
                   [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlError.code) {
                    continue
                }
                let message = error.localizedDescription
                if message == CloudAnalysisError.backgroundServiceUnavailable {
                    cloudUnavailable = true
                    update(id) {
                        $0.errorMessage = "The cloud service is offline. This job is saved and will refresh when it returns."
                    }
                    notice = "Cloud preparation is offline. Existing jobs are saved. On-phone preparation may pause in the background and resumes when Agora is reopened."
                    break
                }
                if message == "Analysis job not found." {
                    update(id) {
                        $0.status = .failed
                        $0.jobID = nil
                        $0.errorMessage = "This cloud job is no longer available. Tap Retry to prepare it again."
                    }
                    continue
                }
                update(id) {
                    $0.errorMessage = episodeStore.saveError
                        ?? "Status will refresh when the cloud is reachable. \(message)"
                }
            }
        }
    }

    func retry(_ id: UUID) {
        if item(with: id)?.jobID != nil { forceRefreshIDs.insert(id) }
        update(id) {
            $0.status = .waiting
            $0.jobID = nil
            $0.errorMessage = nil
        }
    }

    func reanalyze(_ id: UUID) async {
        guard let episodeID = item(with: id)?.episodeID else { return }
        forceRefreshIDs.insert(id)
        update(id) {
            $0.title = nil
            $0.audioURL = nil
            $0.feedURL = nil
            $0.episodeGUID = nil
            $0.publisherSummary = nil
            $0.transcriptURL = nil
            $0.transcriptType = nil
            $0.durationSeconds = nil
            $0.artworkURL = nil
            $0.jobID = nil
            $0.status = .waiting
            $0.errorMessage = "Refreshing the exact episode from its original link..."
        }
        await PodcastTranscriptCheckpoint.remove(for: episodeID)
    }

    func remove(_ id: UUID) async {
        if let item = item(with: id), item.status.isActive, let jobID = item.jobID {
            do {
                try await CloudAnalysisClient().cancel(jobID: jobID)
            } catch {
                notice = "Could not cancel cloud preparation. The episode is still in your backlog. Please try again when connected."
                return
            }
        }
        let episodeID = item(with: id)?.episodeID
        items.removeAll { $0.id == id }
        persist()
        if let episodeID {
            Task { await PodcastTranscriptCheckpoint.remove(for: episodeID) }
        }
    }

    /// Browsed items carry a feed plus the GUID of the episode chosen from it;
    /// pasted items are resolved from their link as before.
    private func resolveImport(for item: PodcastBacklogItem) async throws -> PodcastImportResult {
        let service = PodcastImportService()
        guard let pick = item.browsedPick else {
            return try await service.importMetadata(from: item.sourceURL)
        }
        return try await service.importEpisode(
            feedURL: item.sourceURL,
            guid: pick.guid,
            title: pick.title
        )
    }

    private func submit(id: UUID, providerKey: String) async {
        guard let original = item(with: id) else { return }
        update(id) {
            $0.status = .resolving
            $0.errorMessage = nil
        }
        do {
            let imported = try await resolveImport(for: original)
            update(id) {
                $0.title = imported.title
                $0.audioURL = imported.audioURL
                $0.feedURL = imported.feedURL
                $0.episodeGUID = imported.episodeGUID
                $0.publisherSummary = imported.publisherSummary
                $0.transcriptURL = imported.transcriptSource?.url
                $0.transcriptType = imported.transcriptSource?.type
                $0.durationSeconds = imported.durationSeconds
                $0.artworkURL = imported.artworkURL
                $0.status = .submitting
            }
            let duration = imported.durationSeconds
            let pending = try await CloudAnalysisClient().submit(
                title: imported.title,
                audioURL: imported.audioURL,
                transcript: nil,
                transcriptSource: imported.transcriptSource,
                duration: duration,
                promptCount: nil,
                model: AIAccountStore.selectedModelID(),
                providerAPIKey: providerKey,
                forceRefresh: forceRefreshIDs.contains(id) || (original.status == .failed && original.jobID != nil)
            )
            forceRefreshIDs.remove(id)
            update(id) {
                $0.jobID = pending.jobID
                $0.status = .queued
                $0.errorMessage = nil
            }
        } catch {
            update(id) {
                $0.status = .failed
                let message = error.localizedDescription
                $0.errorMessage = message.localizedCaseInsensitiveContains("application not found")
                    ? CloudAnalysisError.backgroundServiceUnavailable
                    : message
            }
        }
    }

    private func prepareDirectly(ids: [UUID], episodeStore: EpisodeStore) async {
        await episodeStore.loadLibraryIfNeeded()
        for (offset, id) in ids.enumerated() {
            notice = "Cloud background processing is unavailable. Preparing podcast \(offset + 1) of \(ids.count) through your connected AI. Keep Agora open for the fastest result; interrupted work is saved for retry."
            await prepareDirectly(id: id, episodeStore: episodeStore)
        }

        let completed = ids.filter { id in item(with: id)?.status == .complete }.count
        let failures = ids.count - completed
        if failures == 0 {
            notice = "Your backlog is ready. All \(completed) podcast\(completed == 1 ? " was" : "s were") prepared through your connected AI."
        } else if completed > 0 {
            notice = "Prepared \(completed) podcast\(completed == 1 ? "" : "s"). Review the \(failures) item\(failures == 1 ? "" : "s") marked Needs attention."
        } else {
            notice = "Direct preparation could not finish. Review the message under the first podcast, then tap Analyze Backlog to retry."
        }
    }

    private func prepareDirectly(id: UUID, episodeStore: EpisodeStore) async {
        guard let original = item(with: id) else { return }
        update(id) {
            $0.status = .resolving
            $0.jobID = nil
            $0.errorMessage = "Finding the episode and its published transcript..."
        }

        do {
            let imported: PodcastImportResult
            if let audioURL = original.audioURL {
                imported = PodcastImportResult(
                    title: original.displayTitle,
                    audioURL: audioURL,
                    feedURL: original.feedURL,
                    episodeGUID: original.episodeGUID,
                    publisherSummary: original.publisherSummary,
                    transcriptSource: original.transcriptSource,
                    durationSeconds: original.durationSeconds,
                    artworkURL: original.artworkURL
                )
            } else {
                imported = try await resolveImport(for: original)
            }

            update(id) {
                $0.title = imported.title
                $0.audioURL = imported.audioURL
                $0.feedURL = imported.feedURL
                $0.episodeGUID = imported.episodeGUID
                $0.publisherSummary = imported.publisherSummary
                $0.transcriptURL = imported.transcriptSource?.url
                $0.transcriptType = imported.transcriptSource?.type
                $0.durationSeconds = imported.durationSeconds
                $0.artworkURL = imported.artworkURL
                $0.status = .processing
                $0.errorMessage = "Reading the complete episode..."
            }

            var publishedTranscript = await PodcastTranscriptCheckpoint.load(for: original.episodeID)
            if publishedTranscript == nil, let source = imported.transcriptSource {
                publishedTranscript = try? await PodcastImportService().downloadTranscript(from: source)
            }
            if let publishedTranscript,
               PodcastPromptPolicy.transcriptAppearsComplete(
                   publishedTranscript,
                   duration: imported.durationSeconds
               ) {
                await PodcastTranscriptCheckpoint.save(publishedTranscript, for: original.episodeID)
            }
            let analysis = try await AIService().analyzeEpisode(
                title: imported.title,
                audioURL: imported.audioURL,
                transcript: publishedTranscript,
                audioDuration: imported.durationSeconds,
                desiredCount: nil,
                progress: { status in
                    Task { @MainActor in
                        self.update(id) { $0.errorMessage = status }
                    }
                },
                onTranscriptReady: { transcript in
                    await PodcastTranscriptCheckpoint.save(transcript, for: original.episodeID)
                }
            )
            try Task.checkCancellation()
            try validateAutomaticAnalysis(analysis)
            let completedEpisode = Episode(
                id: original.episodeID,
                title: imported.title,
                audioURL: imported.audioURL,
                sourceURL: original.sourceURL,
                prompts: analysis.prompts.sorted { $0.timestampSeconds < $1.timestampSeconds },
                feedURL: imported.feedURL,
                episodeGUID: imported.episodeGUID,
                transcript: analysis.transcript,
                summary: analysis.summary,
                durationSeconds: analysis.duration,
                artworkURL: imported.artworkURL
            )
            try await episodeStore.saveEpisode(completedEpisode)
            forceRefreshIDs.remove(id)
            await PodcastTranscriptCheckpoint.remove(for: original.episodeID)
            update(id) {
                $0.status = .complete
                $0.durationSeconds = analysis.duration
                $0.errorMessage = nil
            }
        } catch {
            let checkpointed = await PodcastTranscriptCheckpoint.load(for: original.episodeID) != nil
            let interruptedStage = item(with: id)?.errorMessage?
                .replacingOccurrences(of: "...", with: "")
                .lowercased() ?? "preparing this episode"
            let networkError = error as? URLError
            let interrupted = networkError.map {
                [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains($0.code)
            } ?? false
            update(id) {
                $0.status = .failed
                $0.jobID = nil
                $0.errorMessage = interrupted
                    ? "The connection was interrupted while \(interruptedStage). \(checkpointed ? "The transcript is saved, so Retry will skip downloading and transcribing the episode again." : "Any episode details already found are saved. Retry when reception improves.")"
                    : error.localizedDescription
            }
        }
    }

    private func item(with id: UUID) -> PodcastBacklogItem? {
        items.first { $0.id == id }
    }

    private func validateAutomaticAnalysis(_ analysis: EpisodeAnalysisResult) throws {
        guard analysis.prompts.count >= PodcastPromptPolicy.minimumCount(for: analysis.duration),
              PodcastPromptPolicy.hasAdequateCoverage(analysis.prompts, duration: analysis.duration) else {
            throw AIServiceError.noQualityPrompts
        }
    }

    private func update(_ id: UUID, change: (inout PodcastBacklogItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items[index]
        change(&updated)
        items[index] = updated
        persist()
        if !hasActiveJobs, !isSubmitting {
            endBackgroundExecution()
        }
    }

    func persist() {
        do {
            guard let url = Self.storageURL else {
                throw CloudAnalysisError.service("Backlog storage is unavailable.")
            }
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
            storageError = nil
        } catch {
            storageError = "Your latest backlog changes have not been saved. Keep Agora open, check available device storage, then retry."
        }
    }

    private func normalizedURL(_ url: URL) -> String {
        PodcastSourceParser.identity(for: url)
    }

    private func displayRank(for status: PodcastBacklogStatus) -> Int {
        switch status {
        case .complete: return 0
        case .processing, .submitting, .resolving: return 1
        case .queued: return 2
        case .waiting: return 3
        case .failed: return 4
        }
    }
}

private struct PodcastLinkDraft: Identifiable {
    let id = UUID()
    var text = ""
}

struct PodcastBacklogView: View {
    private enum AnalysisAction {
        case start
        case retry(UUID)
        case reanalyze(UUID)
    }

    @ObservedObject var episodeStore: EpisodeStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var aiAccount: AIAccountStore
    @StateObject private var backlog = PodcastBacklogStore()
    @State private var linkDrafts = [PodcastLinkDraft()]
    @State private var showPodcastSearch = false
    @State private var showAIAccount = false
    @State private var showAIProcessingConsent = false
    @State private var pendingAnalysisAction: AnalysisAction?
    @State private var resumeAnalysisAfterSearch = false
    @FocusState private var focusedLinkID: UUID?

    var body: some View {
        ZStack {
            AgoraBackgroundView()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    header
                    introductionCard
                    addLinksCard
                    backlogControls
                    if let error = backlog.storageError {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(error).foregroundColor(AgoraTheme.ink)
                            Button("Retry Save") { backlog.persist() }
                                .buttonStyle(AgoraOutlineButtonStyle())
                        }
                    }

                    if backlog.items.isEmpty {
                        emptyCard
                    } else {
                        ForEach(backlog.orderedItems) { item in
                            PodcastBacklogRow(
                                item: item,
                                isSelected: episodeStore.episode.id == item.episodeID,
                                onUse: {
                                    Task {
                                        await episodeStore.loadLibraryIfNeeded()
                                        if episodeStore.selectEpisode(id: item.episodeID) { dismiss() }
                                    }
                                },
                                onRetry: {
                                    requestAnalysis(.retry(item.id))
                                },
                                onReanalyze: {
                                    requestAnalysis(.reanalyze(item.id))
                                },
                                onRemove: {
                                    Task {
                                        if item.status == .complete {
                                            await episodeStore.loadLibraryIfNeeded()
                                            episodeStore.deleteSavedEpisode(id: item.episodeID)
                                        }
                                        await backlog.remove(item.id)
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(16)
                .padding(.vertical, 8)
            }
        }
        .task {
            await episodeStore.loadLibraryIfNeeded()
            backlog.auditCompletedEpisodes(episodeStore: episodeStore)
            await backlog.checkCloudAvailability()
            while !Task.isCancelled {
                await backlog.refreshAll(episodeStore: episodeStore)
                let delay: UInt64 = backlog.cloudUnavailable
                    ? 60_000_000_000
                    : (backlog.hasActiveJobs ? 8_000_000_000 : 15_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        .aiProcessingConsent(isPresented: $showAIProcessingConsent, onAllow: {
            aiAccount.allowsAIProcessing = true
            Task { @MainActor in
                await Task.yield()
                continueRequestedAnalysis()
            }
        }, onCancel: { pendingAnalysisAction = nil })
        .sheet(isPresented: $showAIAccount, onDismiss: {
            guard aiAccount.isConnected, aiAccount.allowsAIProcessing else {
                pendingAnalysisAction = nil
                return
            }
            continueRequestedAnalysis()
        }) {
            AIAccountView()
                .environmentObject(aiAccount)
        }
        .sheet(isPresented: $showPodcastSearch, onDismiss: {
            guard resumeAnalysisAfterSearch else { return }
            resumeAnalysisAfterSearch = false
            requestAnalysis()
        }) {
            PodcastSearchView(mode: .multiple) { picks in
                addBrowsedAndStart(picks)
            }
        }
    }

    private func addBrowsedAndStart(_ picks: [PodcastSearchSelection]) {
        focusedLinkID = nil
        guard backlog.addBrowsedEpisodes(picks) else { return }
        resumeAnalysisAfterSearch = true
    }

    private func requestAnalysis(_ action: AnalysisAction = .start) {
        pendingAnalysisAction = action
        continueRequestedAnalysis()
    }

    private func continueRequestedAnalysis() {
        guard let action = pendingAnalysisAction else { return }
        switch AIProcessingConsent.nextStep(isConnected: aiAccount.isConnected, allowsProcessing: aiAccount.allowsAIProcessing) {
        case .askPermission:
            showAIProcessingConsent = true
        case .connectAccount:
            showAIAccount = true
        case .analyze:
            pendingAnalysisAction = nil
            Task {
                switch action {
                case .start: break
                case .retry(let id): backlog.retry(id)
                case .reanalyze(let id): await backlog.reanalyze(id)
                }
                await backlog.startAll(episodeStore: episodeStore)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Podcast Backlog")
                    .font(AgoraTheme.cardValueFont)
                    .foregroundColor(AgoraTheme.ink)
                Text("Prepare several episodes while you do something else.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(AgoraOutlineButtonStyle())
        }
    }

    private var introductionCard: some View {
        AgoraCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: backlog.isUsingDirectFallback ? "iphone.gen3" : "cloud.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(AgoraTheme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(backlog.isUsingDirectFallback ? "Preparing on this iPhone" : backlog.cloudUnavailable ? "Cloud backlog is offline" : "Cloud preparation continues")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)
                    Text(
                        backlog.isUsingDirectFallback
                            ? "Each episode is prepared through your connected AI. Keep Agora open for on-phone preparation; interrupted work is saved and can resume when you return."
                            : backlog.cloudUnavailable
                                ? "Your links and existing cloud jobs are saved. On-phone preparation may pause in the background; cloud jobs refresh when the service returns."
                                : "Once every item says Queued or Analyzing, you may close Agora. Return later and choose any completed episode."
                    )
                        .font(AgoraTheme.bodyFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }
            }
        }
    }

    private var addLinksCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add Podcasts")
                    .font(AgoraTheme.cardTitleFont)
                    .foregroundColor(AgoraTheme.ink)
                Text("Browse for episodes, or paste one episode, show, public RSS feed, or direct audio link into each slot. Copied share messages also work.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)

                Button {
                    showPodcastSearch = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Browse Podcasts")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AgoraOutlineButtonStyle())
                .accessibilityHint("Search podcasts and pick several episodes for the backlog")

                ForEach(Array(linkDrafts.enumerated()), id: \.element.id) { index, draft in
                    let position = index + 1
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label("Podcast \(position)", systemImage: "waveform")
                                .font(AgoraTheme.tagFont.weight(.semibold))
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer()
                            if linkDrafts.count > 1 {
                                Button {
                                    removeDraft(id: draft.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove podcast \(position)")
                            }
                        }

                        HStack(alignment: .top, spacing: 8) {
                            TextField("Paste podcast link", text: draftTextBinding(for: draft.id), axis: .vertical)
                                .font(AgoraTheme.bodyFont)
                                .foregroundColor(AgoraTheme.ink)
                                .tint(AgoraTheme.accent)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .lineLimit(2...3)
                                .focused($focusedLinkID, equals: draft.id)

                            if !draft.text.isEmpty {
                                Button {
                                    clearDraft(id: draft.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(AgoraTheme.inkMuted)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear podcast \(position) link")
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.88))
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                        )
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(AgoraTheme.cardSurface.opacity(0.58))
                    )
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        addAnotherButton
                        pasteCopiedButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        addAnotherButton
                        pasteCopiedButton
                    }
                }

                Button("Add & Analyze") {
                    submitDraftsAndStart()
                }
                .buttonStyle(AgoraPillButtonStyle())
                .disabled(linkDrafts.allSatisfy {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            }
        }
    }

    @ViewBuilder
    private var addAnotherButton: some View {
        if linkDrafts.count < 10 {
            Button {
                addDraft()
            } label: {
                Label("Add Another", systemImage: "plus.circle.fill")
            }
            .buttonStyle(AgoraOutlineButtonStyle())
        }
    }

    private var pasteCopiedButton: some View {
        Button {
            pasteCopiedLinks()
        } label: {
            Label("Paste Copied", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(AgoraOutlineButtonStyle())
    }

    private func addDraft() {
        guard linkDrafts.count < 10 else { return }
        let draft = PodcastLinkDraft()
        withAnimation(.easeInOut(duration: 0.2)) {
            linkDrafts.append(draft)
        }
        focusedLinkID = draft.id
    }

    private func draftTextBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                linkDrafts.first(where: { $0.id == id })?.text ?? ""
            },
            set: { newValue in
                guard let index = linkDrafts.firstIndex(where: { $0.id == id }) else { return }
                linkDrafts[index].text = newValue
            }
        )
    }

    private func clearDraft(id: UUID) {
        guard let index = linkDrafts.firstIndex(where: { $0.id == id }) else { return }
        linkDrafts[index].text = ""
    }

    private func submitDraftsAndStart() {
        let entries = linkDrafts.map(\.text)
        focusedLinkID = nil
        guard backlog.addLinks(from: entries) else { return }

        linkDrafts = [PodcastLinkDraft()]
        requestAnalysis()
    }

    private func pasteCopiedLinks() {
        guard let copiedText = UIPasteboard.general.string else {
            backlog.notice = "Copy a podcast link first, then tap Paste Copied."
            return
        }
        let urls = PodcastSourceParser.urls(in: copiedText)
        guard !urls.isEmpty else {
            backlog.notice = "The clipboard does not contain a supported podcast link."
            return
        }

        let existing = Set(linkDrafts.flatMap { PodcastSourceParser.urls(in: $0.text) }.map(\.absoluteString))
        let additions = urls.filter { !existing.contains($0.absoluteString) }
        guard !additions.isEmpty else {
            backlog.notice = "Those copied links are already in the boxes above."
            return
        }
        let availableSlots = max(10 - linkDrafts.filter { !$0.text.isEmpty }.count, 0)
        let accepted = additions.prefix(availableSlots)
        var filled = linkDrafts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        filled.append(contentsOf: accepted.map { url in
            var draft = PodcastLinkDraft()
            draft.text = url.absoluteString
            return draft
        })
        linkDrafts = filled.isEmpty ? [PodcastLinkDraft()] : filled
        backlog.notice = "Pasted \(accepted.count) podcast link\(accepted.count == 1 ? "" : "s"). Tap Add & Analyze when ready."
    }

    private func removeDraft(id: UUID) {
        guard linkDrafts.count > 1 else { return }
        if focusedLinkID == id { focusedLinkID = nil }
        withAnimation(.easeInOut(duration: 0.2)) {
            linkDrafts.removeAll { $0.id == id }
        }
    }

    private var backlogControls: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(backlog.completedCount) ready · \(backlog.activeCount) working · \(backlog.waitingCount) waiting")
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)
                        Text(backlog.notice.isEmpty ? "The strongest final AI review is used for every episode." : backlog.notice)
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }
                    Spacer()
                    if backlog.isRefreshing { ProgressView() }
                }

                if !aiAccount.isConnected {
                    Button("Connect Your AI") { showAIAccount = true }
                        .buttonStyle(AgoraOutlineButtonStyle())
                }

                Button(backlog.startButtonTitle) {
                    requestAnalysis()
                }
                .buttonStyle(AgoraPillButtonStyle())
                .disabled(!backlog.hasStartableItems)

                if backlog.failedCount > 0 {
                    Text("\(backlog.failedCount) podcast\(backlog.failedCount == 1 ? " needs" : "s need") attention. Retry from its card without restarting completed work.")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyCard: some View {
        AgoraCard {
            VStack(spacing: 10) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(AgoraTheme.accent)
                Text("Your backlog is empty")
                    .font(AgoraTheme.cardTitleFont)
                    .foregroundColor(AgoraTheme.ink)
                Text("Add several podcast links above, then start them with one button.")
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct PodcastBacklogRow: View {
    let item: PodcastBacklogItem
    let isSelected: Bool
    let onUse: () -> Void
    let onRetry: () -> Void
    let onReanalyze: () -> Void
    let onRemove: () -> Void

    var body: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle)
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)
                        Text(item.status.title)
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(item.status == .failed ? Color.red : AgoraTheme.accent)
                    }
                    Spacer()
                    if isSelected { AgoraTag(text: "Selected") }
                }

                Text(item.sourceURL.absoluteString)
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)
                    .lineLimit(2)

                if let error = item.errorMessage, !error.isEmpty {
                    AgoraExpandableText(
                        text: error,
                        collapsedLineLimit: 2,
                        expansionThreshold: 120,
                        font: AgoraTheme.tagFont,
                        color: AgoraTheme.inkMuted
                    )
                }

                HStack {
                    if item.status == .complete {
                        Button(isSelected ? "Currently Selected" : "Use This Episode", action: onUse)
                            .buttonStyle(AgoraPillButtonStyle())
                            .disabled(isSelected)
                    } else if item.status == .failed {
                        Button("Retry", action: onRetry)
                            .buttonStyle(AgoraOutlineButtonStyle())
                    }
                    Spacer()
                    if !isSelected {
                        Button(role: .destructive, action: onRemove) {
                            Label(item.status.isActive ? "Cancel & Remove" : "Remove", systemImage: "trash")
                        }
                        .disabled(item.status.isActive && item.jobID == nil)
                        .font(AgoraTheme.buttonFont)
                    }
                }

                if item.status.isActive, item.jobID != nil {
                    Text("Cancel stops further cloud work. AI usage already processed may still be charged by your provider.")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }

                if item.status == .complete {
                    HStack {
                        Button("Reanalyze", action: onReanalyze)
                            .buttonStyle(AgoraOutlineButtonStyle())
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if item.status.isActive {
            ProgressView()
                .tint(AgoraTheme.accent)
        } else {
            Image(systemName: item.status == .complete ? "checkmark.circle.fill" : item.status == .failed ? "exclamationmark.triangle.fill" : "clock.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(item.status == .failed ? .red : AgoraTheme.accent)
        }
    }
}
