import Foundation

// Foundation-only harness for the production models and storage code.
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
enum CloudAnalysisError: Error { case service(String) }
struct EpisodeAnalysisResult {
    let transcript: String
    let duration: Double
    let summary: String
    let prompts: [Prompt]
}

@main struct StorageAndTimingRegression {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agora-regression-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpisodeStore(storageDirectory: directory)
        let analysis = EpisodeAnalysisResult(transcript: "Prepared transcript", duration: 3600, summary: "Prepared summary", prompts: [])
        for name in ["first", "second"] {
            let url = URL(string: "https://example.com/\(name).mp3")!
            store.importEpisode(title: name, audioURL: url, sourceURL: url, feedURL: nil, episodeGUID: nil, transcript: nil, summary: nil, durationSeconds: 3600)
            try await store.saveAnalysis(analysis, expectedAudioURL: url)
        }
        let reopened = EpisodeStore(storageDirectory: directory)
        await reopened.loadLibraryIfNeeded()
        precondition(Set(reopened.savedEpisodes.map(\.title)).isSuperset(of: ["first", "second"]), "An import disappeared before the library was opened.")
        precondition(reopened.episode.title == "second", "The active episode was not restored.")

        let text = TranscriptTiming.annotate([
            TimedTranscriptSegment(start: 2100, end: 2103, text: "Attention lets another person's reasoning"),
            TimedTranscriptSegment(start: 2103, end: 2107, text: "change your view of the argument."),
        ])
        precondition(TranscriptTiming.evidenceEnd(quote: "Attention lets another person's reasoning change your view of the argument", transcript: text) == 2107)
        precondition(TranscriptTiming.evidenceEnd(quote: "An invented passage that was never spoken in this episode", transcript: text) == nil)
        let legacy = Data(#"{"id":"11111111-1111-1111-1111-111111111111","timestampSeconds":42,"question":"Question","expectedAnswer":"Answer"}"#.utf8)
        let legacyPrompt = try JSONDecoder().decode(Prompt.self, from: legacy)
        precondition(legacyPrompt.timingVerified == false)

        let libraryURL = directory.appendingPathComponent("episode-library.json")
        let damaged = Data("intentionally damaged test data".utf8)
        try damaged.write(to: libraryURL)
        let damagedStore = EpisodeStore(storageDirectory: directory)
        await damagedStore.loadLibraryIfNeeded()
        precondition(!damagedStore.isLibraryLoaded && damagedStore.saveError != nil)
        do {
            try await damagedStore.saveAnalysis(analysis, expectedAudioURL: damagedStore.episode.audioURL)
            preconditionFailure("A damaged library was silently replaced.")
        } catch { }
        let retained = try Data(contentsOf: libraryURL)
        precondition(retained == damaged)
        print("PASS: multiple imports survive relaunch; caption evidence timing; legacy decoding; damaged library preservation.")
    }
}
