import Foundation

enum AIProcessingConsent {
    private static let key = "TheAgoraLA.AI.DataSharingConsent.v1"

    enum NextStep: Equatable {
        case askPermission
        case connectAccount
        case analyze
    }

    static let disclosure = "Podcast audio and transcripts, typed or spoken answers, and narration text are sent to OpenRouter and model providers OpenAI, Microsoft, or NVIDIA to create questions, grade answers, and generate speech. Cloud analysis also sends the selected episode and an encrypted temporary provider key to Agora's server. Your saved account key stays in this iPhone's Keychain. You can turn this off anytime in AI Settings."

    static func isAllowed(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setAllowed(_ allowed: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(allowed, forKey: key)
    }

    static func nextStep(isConnected: Bool, allowsProcessing: Bool) -> NextStep {
        guard allowsProcessing else { return .askPermission }
        return isConnected ? .analyze : .connectAccount
    }
}

enum HandsFreePreference {
    private static let key = "TheAgoraLA.CompleteHandsFree"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

enum PromptGrade: String, Codable {
    case a = "A"
    case b = "B"
    case c = "C"
    case f = "F"

    var pointsAwarded: Int {
        switch self {
        case .a: return 10
        case .b: return 8
        case .c: return 6
        case .f: return 0
        }
    }

    static func from(score: Int) -> PromptGrade {
        let bounded = min(max(score, 0), 100)
        switch bounded {
        case 85...100: return .a
        case 60..<85: return .b
        case 30..<60: return .c
        default: return .f
        }
    }
}

enum AnswerAnalysisDepth: Int, CaseIterable {
    case quick = 0
    case thorough = 1
    case deepest = 2

    var reasoningEffort: String {
        switch self {
        case .quick: return "low"
        case .thorough: return "medium"
        case .deepest: return "high"
        }
    }

    // Reasoning tokens draw from the same budget as the JSON grade, so deeper
    // settings need headroom or the response truncates into the offline fallback.
    var maxTokens: Int {
        switch self {
        case .quick: return 1_100
        case .thorough: return 1_600
        case .deepest: return 2_400
        }
    }

    var timeoutInterval: TimeInterval {
        switch self {
        case .quick: return 40
        case .thorough: return 60
        case .deepest: return 90
        }
    }
}

struct Episode: Identifiable, Codable {
    let id: UUID
    let title: String
    let audioURL: URL
    let sourceURL: URL?
    let prompts: [Prompt]
    let feedURL: URL?
    let episodeGUID: String?
    let transcript: String?
    let summary: String?
    let durationSeconds: Double?
    let artworkURL: URL?

    init(
        id: UUID,
        title: String,
        audioURL: URL,
        sourceURL: URL? = nil,
        prompts: [Prompt],
        feedURL: URL? = nil,
        episodeGUID: String? = nil,
        transcript: String? = nil,
        summary: String? = nil,
        durationSeconds: Double? = nil,
        artworkURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.audioURL = audioURL
        self.sourceURL = sourceURL
        self.prompts = prompts
        self.feedURL = feedURL
        self.episodeGUID = episodeGUID
        self.transcript = transcript
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, audioURL, sourceURL, prompts, feedURL, episodeGUID, transcript, summary, durationSeconds, artworkURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        audioURL = try container.decode(URL.self, forKey: .audioURL)
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        prompts = try container.decode([Prompt].self, forKey: .prompts)
        feedURL = try container.decodeIfPresent(URL.self, forKey: .feedURL)
        episodeGUID = try container.decodeIfPresent(String.self, forKey: .episodeGUID)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(audioURL, forKey: .audioURL)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encode(prompts, forKey: .prompts)
        try container.encodeIfPresent(feedURL, forKey: .feedURL)
        try container.encodeIfPresent(episodeGUID, forKey: .episodeGUID)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(artworkURL, forKey: .artworkURL)
    }
}

struct Prompt: Identifiable, Codable {
    let id: UUID
    let timestampSeconds: Double
    let question: String
    let expectedAnswer: String
    // Kept under its original storage name; this is now an optional delay after the answer ends.
    let leadTimeSeconds: Double
    let timingVerified: Bool

    init(id: UUID, timestampSeconds: Double, question: String, expectedAnswer: String, leadTimeSeconds: Double = 0, timingVerified: Bool = false) {
        self.id = id
        self.timestampSeconds = timestampSeconds
        self.question = question
        self.expectedAnswer = expectedAnswer
        self.leadTimeSeconds = leadTimeSeconds
        self.timingVerified = timingVerified
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timestampSeconds
        case question
        case expectedAnswer
        case leadTimeSeconds
        case timingVerified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestampSeconds = try container.decode(Double.self, forKey: .timestampSeconds)
        question = try container.decode(String.self, forKey: .question)
        expectedAnswer = try container.decode(String.self, forKey: .expectedAnswer)
        leadTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .leadTimeSeconds) ?? 0
        timingVerified = try container.decodeIfPresent(Bool.self, forKey: .timingVerified) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestampSeconds, forKey: .timestampSeconds)
        try container.encode(question, forKey: .question)
        try container.encode(expectedAnswer, forKey: .expectedAnswer)
        try container.encode(leadTimeSeconds, forKey: .leadTimeSeconds)
        try container.encode(timingVerified, forKey: .timingVerified)
    }
}

struct TimedTranscriptSegment {
    let start: Double
    let end: Double
    let text: String
}

enum TranscriptTiming {
    static let markerPattern = #"\[\[AUDIO_SECONDS ([0-9.]+)-([0-9.]+)\]\]"#

    static func segments(in transcript: String) -> [TimedTranscriptSegment] {
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return [] }
        let source = transcript as NSString
        let matches = regex.matches(in: transcript, range: NSRange(location: 0, length: source.length))
        return matches.enumerated().compactMap { index, match in
            guard let start = Double(source.substring(with: match.range(at: 1))),
                  let end = Double(source.substring(with: match.range(at: 2))),
                  start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            let lower = NSMaxRange(match.range)
            let upper = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            let text = source.substring(with: NSRange(location: lower, length: upper - lower)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimedTranscriptSegment(start: start, end: end, text: text)
        }
    }

    static func annotate(_ segments: [TimedTranscriptSegment]) -> String {
        segments.map { "[[AUDIO_SECONDS \(String(format: "%.2f", $0.start))-\(String(format: "%.2f", $0.end))]] \($0.text)" }.joined(separator: "\n")
    }

    static func plainText(_ transcript: String) -> String {
        transcript.replacingOccurrences(of: markerPattern, with: " ", options: .regularExpression)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func evidenceEnd(quote: String, transcript: String) -> Double? {
        let key = normalized(quote)
        guard key.count >= 20 else { return nil }
        var text = ""
        var spans: [(upper: Int, end: Double)] = []
        for segment in segments(in: transcript) {
            if !text.isEmpty { text += " " }
            text += normalized(segment.text)
            spans.append((text.count, segment.end))
        }
        guard let range = text.range(of: key, options: .backwards) else { return nil }
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        return spans.first { $0.upper >= upper }?.end
    }
}

struct PromptHistorySnapshot: Codable {
    let responses: [PromptResponse]
    let encounteredPromptIDs: [UUID]
    let earnedPointsByPrompt: [UUID: Int]?

    init(responses: [PromptResponse], encounteredPromptIDs: [UUID], earnedPointsByPrompt: [UUID: Int]? = nil) {
        self.responses = responses
        self.encounteredPromptIDs = encounteredPromptIDs
        self.earnedPointsByPrompt = earnedPointsByPrompt
    }

    var pointAwardHistory: [UUID: Int] {
        var awards = (earnedPointsByPrompt ?? [:]).mapValues { max($0, 0) }
        for response in responses {
            awards[response.promptID] = max(awards[response.promptID] ?? 0, response.awardedPoints)
        }
        return awards
    }

    func resettingProgress() -> PromptHistorySnapshot {
        PromptHistorySnapshot(responses: [], encounteredPromptIDs: [], earnedPointsByPrompt: pointAwardHistory)
    }
}

struct PromptResult: Identifiable {
    let id = UUID()
    let prompt: Prompt
    let answer: String
    let score: Int
    let grade: PromptGrade
    let awardedPoints: Int
    let feedback: String
}

struct PromptResponse: Identifiable, Codable {
    var id: UUID { promptID }

    let promptID: UUID
    var answer: String
    var score: Int?
    var grade: PromptGrade?
    var awardedPoints: Int
    var feedback: String
    var lastUpdated: Date
    var usedOfflineEstimate: Bool? = nil
}
