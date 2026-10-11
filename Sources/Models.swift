import Foundation

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

    init(id: UUID, timestampSeconds: Double, question: String, expectedAnswer: String, leadTimeSeconds: Double = 0) {
        self.id = id
        self.timestampSeconds = timestampSeconds
        self.question = question
        self.expectedAnswer = expectedAnswer
        self.leadTimeSeconds = leadTimeSeconds
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timestampSeconds
        case question
        case expectedAnswer
        case leadTimeSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestampSeconds = try container.decode(Double.self, forKey: .timestampSeconds)
        question = try container.decode(String.self, forKey: .question)
        expectedAnswer = try container.decode(String.self, forKey: .expectedAnswer)
        leadTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .leadTimeSeconds) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestampSeconds, forKey: .timestampSeconds)
        try container.encode(question, forKey: .question)
        try container.encode(expectedAnswer, forKey: .expectedAnswer)
        try container.encode(leadTimeSeconds, forKey: .leadTimeSeconds)
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
}
