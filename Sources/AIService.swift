import Foundation

struct AIResult {
    let score: Int
    let grade: PromptGrade
    let feedback: String
    let awardedPoints: Int
    let usedOfflineEstimate: Bool

    init(
        score: Int,
        grade: PromptGrade,
        feedback: String,
        awardedPoints: Int,
        usedOfflineEstimate: Bool = false
    ) {
        self.score = score
        self.grade = grade
        self.feedback = feedback
        self.awardedPoints = awardedPoints
        self.usedOfflineEstimate = usedOfflineEstimate
    }
}

enum AIServiceError: LocalizedError {
    case transcriptTooShort
    case invalidResponse
    case noQualityPrompts

    var errorDescription: String? {
        switch self {
        case .transcriptTooShort:
            return "The transcript is too short to create reliable questions."
        case .invalidResponse:
            return "The AI service returned an invalid response."
        case .noQualityPrompts:
            return "The AI could not produce questions that passed the transcript-grounding checks."
        }
    }
}

struct TranscriptionResult {
    let transcript: String
    let duration: Double?
}

struct EpisodeAnalysisResult {
    let transcript: String
    let duration: Double
    let summary: String
    let prompts: [Prompt]
    let recommendedPromptCount: Int
    let contentDepthLabel: String
}

enum PodcastPromptPolicy {
    static func minimumCount(for duration: Double) -> Int {
        switch duration {
        case ..<900: return 3
        case ..<1_800: return 4
        case ..<2_700: return 6
        case ..<3_900: return 8
        case ..<5_400: return 10
        default: return 12
        }
    }

    static func leadIn(for duration: Double) -> Double {
        guard duration >= 1_800 else { return 0 }
        return min(180, max(120, duration * 0.04))
    }

    static func hasAdequateCoverage(_ prompts: [Prompt], duration: Double) -> Bool {
        guard duration >= 1_800, prompts.count >= 6 else { return true }
        let regionCount = timelineRegionCount(promptCount: prompts.count, duration: duration)
        let regions = Set(prompts.map { prompt in
            min(regionCount - 1, Int((prompt.timestampSeconds / max(duration, 1)) * Double(regionCount)))
        })
        let quarterCounts = Dictionary(grouping: prompts) { prompt in
            min(3, Int((prompt.timestampSeconds / max(duration, 1)) * 4))
        }.values.map(\.count)
        let maximumPerQuarter = Int(ceil(Double(prompts.count) / 4.0))
        let latestPrompt = prompts.map(\.timestampSeconds).max() ?? 0
        return regions.count == regionCount
            && quarterCounts.allSatisfy { $0 <= maximumPerQuarter }
            && latestPrompt >= duration * 0.80
    }

    static func timelineRegionCount(promptCount: Int, duration: Double) -> Int {
        guard duration >= 1_800 else { return min(4, max(promptCount, 1)) }
        let tenMinuteRegions = Int(ceil(duration / 600))
        return min(max(promptCount, 1), max(4, min(8, tenMinuteRegions)))
    }

    static func transcriptAppearsComplete(_ transcript: String, duration: Double?) -> Bool {
        let words = transcript.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        guard words >= 120 else { return false }
        guard let duration, duration.isFinite, duration >= 600 else { return true }
        return Double(words) >= duration * 1.25
    }
}

struct EpisodeLearningPlan: Decodable {
    struct Priority: Decodable {
        let id: String
        let title: String
        let importanceReason: String
        let evidenceQuote: String
        let startSeconds: Double
        let endSeconds: Double

        enum CodingKeys: String, CodingKey {
            case id, title
            case importanceReason = "importance_reason"
            case evidenceQuote = "evidence_quote"
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
        }
    }

    let contentDepthScore: Double
    let recommendedPromptCount: Int
    let priorities: [Priority]

    enum CodingKeys: String, CodingKey {
        case contentDepthScore = "content_depth_score"
        case recommendedPromptCount = "recommended_prompt_count"
        case priorities
    }

    var depthLabel: String {
        switch contentDepthScore {
        case 0.8...: return "Deep"
        case 0.58..<0.8: return "Substantial"
        case 0.38..<0.58: return "Focused"
        default: return "Light"
        }
    }
}

private struct GeneratedPrompt: Decodable {
    struct Scores: Decodable {
        let overall: Double?
        let importance: Double?
        let specificity: Double?
        let answerAlignment: Double?
        let grounding: Double?

        enum CodingKeys: String, CodingKey {
            case overall
            case importance = "importance_to_listener"
            case specificity = "episode_specificity"
            case answerAlignment = "answer_alignment"
            case grounding
        }
    }

    struct Evidence: Decodable {
        let quote: String
        let startSeconds: Double?
        let endSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case quote
            case startSeconds
            case endSeconds
            case startSecondsSnake = "start_seconds"
            case endSecondsSnake = "end_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            quote = try container.decodeIfPresent(String.self, forKey: .quote) ?? ""
            startSeconds = try container.decodeIfPresent(Double.self, forKey: .startSeconds)
                ?? container.decodeIfPresent(Double.self, forKey: .startSecondsSnake)
            endSeconds = try container.decodeIfPresent(Double.self, forKey: .endSeconds)
                ?? container.decodeIfPresent(Double.self, forKey: .endSecondsSnake)
        }
    }

    let time: Double?
    let priorityID: String?
    let question: String
    let expectedAnswer: String
    let scores: Scores?
    let evidence: [Evidence]
    let passesQualityGates: Bool?

    enum CodingKeys: String, CodingKey {
        case time
        case priorityID
        case priorityIDSnake = "priority_id"
        case question
        case expectedAnswer
        case expectedAnswerSnake = "expected_answer"
        case scores
        case evidence
        case passesQualityGates
        case passesQualityGatesSnake = "passes_quality_gates"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decodeIfPresent(Double.self, forKey: .time)
        priorityID = try container.decodeIfPresent(String.self, forKey: .priorityID)
            ?? container.decodeIfPresent(String.self, forKey: .priorityIDSnake)
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        expectedAnswer = try container.decodeIfPresent(String.self, forKey: .expectedAnswer)
            ?? container.decodeIfPresent(String.self, forKey: .expectedAnswerSnake)
            ?? ""
        scores = try container.decodeIfPresent(Scores.self, forKey: .scores)
        evidence = try container.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
        passesQualityGates = try container.decodeIfPresent(Bool.self, forKey: .passesQualityGates)
            ?? container.decodeIfPresent(Bool.self, forKey: .passesQualityGatesSnake)
    }
}

private struct GeneratedPromptEnvelope: Decodable {
    let prompts: [GeneratedPrompt]
}

private struct FastEpisodeAnalysisEnvelope: Decodable {
    let summary: String
    let contentDepthScore: Double
    let recommendedPromptCount: Int
    let priorities: [EpisodeLearningPlan.Priority]
    let prompts: [GeneratedPrompt]

    enum CodingKeys: String, CodingKey {
        case summary, priorities, prompts
        case contentDepthScore = "content_depth_score"
        case recommendedPromptCount = "recommended_prompt_count"
    }
}

protocol AnswerEvaluating {
    func evaluateAnswer(
        question: String, expectedAnswer: String, userAnswer: String,
        transcript: String?, progressSeconds: Double?, analysisDepth: AnswerAnalysisDepth
    ) async -> AIResult
}

final class AIService: AnswerEvaluating {
    private let personalAI = OpenRouterClient()

    func evaluateAnswer(
        question: String,
        expectedAnswer: String,
        userAnswer: String,
        transcript: String? = nil,
        progressSeconds: Double? = nil,
        analysisDepth: AnswerAnalysisDepth = .deepest
    ) async -> AIResult {
        do {
            let score = try await personalAI.score(
                question: question,
                expectedAnswer: expectedAnswer,
                userAnswer: userAnswer,
                analysisDepth: analysisDepth
            )
            let boundedScore = min(max(score.score, 0), 100)
            let grade = PromptGrade.from(score: boundedScore)
            let remote = AIResult(
                score: boundedScore,
                grade: grade,
                feedback: score.feedback,
                awardedPoints: grade.pointsAwarded
            )
            return remote
        } catch {
#if DEBUG
            print("[AIService] Online grading failed: \(String(describing: error))")
#endif
            let local = localScore(
                expectedAnswer: expectedAnswer,
                userAnswer: userAnswer,
                progressSeconds: progressSeconds
            )
            return AIResult(
                score: local.score,
                grade: local.grade,
                feedback: "\(offlineGradingExplanation(for: error)) \(local.feedback)",
                awardedPoints: local.awardedPoints,
                usedOfflineEstimate: true
            )
        }
    }

    private func offlineGradingExplanation(for error: Error) -> String {
        if let providerError = error as? OpenRouterClientError {
            switch providerError {
            case .notConnected:
                return "No AI key was available for this grading request, so this is an offline estimate."
            case .insufficientCredits:
                return "Your AI account is connected, but the provider reported that it needs credits. This is an offline estimate."
            case .authenticationExpired:
                return "Your saved AI sign-in has expired. This is an offline estimate until you reconnect."
            case .service, .invalidResponse, .audioUnavailable, .audioTooLarge:
                return "Your AI account is connected, but online grading was temporarily unavailable. This is an offline estimate."
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Your AI account is connected, but online grading took too long. This is an offline estimate."
            case .notConnectedToInternet, .networkConnectionLost:
                return "Your AI account is connected, but the network was unavailable. This is an offline estimate."
            default:
                break
            }
        }
        return "Your AI account is connected, but online grading could not finish. This is an offline estimate."
    }

    func generatePrompts(
        transcript: String,
        audioDuration: Double,
        desiredCount: Int = 3
    ) async throws -> [Prompt] {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(trimmedTranscript) >= 120 else { throw AIServiceError.transcriptTooShort }

        let duration = resolvedDuration(audioDuration: audioDuration, transcript: trimmedTranscript)
        let requestedCount = max(3, min(12, desiredCount))
        let learningPlan = try await personalAI.analyzeLearningPlan(
            transcript: trimmedTranscript,
            duration: duration
        )
        let candidates = try await fetchPromptCandidates(
            transcript: trimmedTranscript,
            duration: duration,
            count: min(20, max(8, requestedCount * 2)),
            learningPlan: learningPlan
        )
        let selected = selectBestCandidates(
            candidates,
            desiredCount: requestedCount,
            duration: duration
        )
        guard !selected.isEmpty else { throw AIServiceError.noQualityPrompts }
        return selected.sorted { $0.timestampSeconds < $1.timestampSeconds }
    }

    func transcribeAudio(
        at audioURL: URL,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TranscriptionResult {
        try await personalAI.transcribe(audioURL: audioURL, progress: progress)
    }

    func summarizeEpisode(transcript: String) async throws -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(trimmedTranscript) >= 120 else { throw AIServiceError.transcriptTooShort }
        let summary = try await personalAI.summarize(transcript: trimmedTranscript)
        guard wordCount(summary) >= 30 else { throw AIServiceError.invalidResponse }
        return summary
    }

    func analyzeEpisode(
        title: String,
        audioURL: URL?,
        transcript: String?,
        audioDuration: Double?,
        desiredCount: Int? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in },
        onTranscriptReady: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> EpisodeAnalysisResult {
        let completeTranscript = transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableTranscript = completeTranscript.flatMap { value -> String? in
            let segments = TranscriptTiming.segments(in: value)
            guard let last = segments.last,
                  segments.allSatisfy({ $0.end <= (audioDuration ?? last.end) + 2 }),
                  last.end >= (audioDuration ?? last.end) * 0.90,
                  PodcastPromptPolicy.transcriptAppearsComplete(TranscriptTiming.plainText(value), duration: audioDuration) else { return nil }
            return value
        }
        let resolvedTranscript: String
        let transcriptionDuration: Double?
        if let usableTranscript {
            resolvedTranscript = usableTranscript
            transcriptionDuration = nil
        } else if let audioURL {
            let transcription = try await personalAI.transcribe(audioURL: audioURL, progress: progress)
            resolvedTranscript = transcription.transcript
            transcriptionDuration = transcription.duration
        } else {
            throw AIServiceError.transcriptTooShort
        }

        let duration = resolvedDuration(
            audioDuration: transcriptionDuration ?? audioDuration ?? 0,
            transcript: resolvedTranscript
        )
        await onTranscriptReady(resolvedTranscript)
        let automaticMinimum = PodcastPromptPolicy.minimumCount(for: duration)
        progress("Scanning every section of the transcript in parallel...")
        let editorial: FastEpisodeAnalysisEnvelope
        do {
            let fastData = try await personalAI.analyzeEpisodeFast(
                transcript: resolvedTranscript,
                duration: duration,
                desiredCount: desiredCount,
                automaticMinimum: automaticMinimum
            )
            guard let decoded = try? JSONDecoder().decode(FastEpisodeAnalysisEnvelope.self, from: fastData),
                  !decoded.priorities.isEmpty,
                  !decoded.prompts.isEmpty else {
                throw AIServiceError.invalidResponse
            }
            editorial = decoded
        } catch {
            try Task.checkCancellation()
            if let networkError = error as? URLError,
               [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(networkError.code) {
                throw networkError
            }
            if let providerError = error as? OpenRouterClientError {
                switch providerError {
                case .notConnected, .insufficientCredits, .authenticationExpired:
                    throw providerError
                case .service, .invalidResponse, .audioUnavailable, .audioTooLarge:
                    break
                }
            }
            progress("Using the full-depth editorial fallback...")
            return try await analyzeEpisodeLegacy(
                transcript: resolvedTranscript,
                duration: duration,
                desiredCount: desiredCount
            )
        }
        let learningPlan = EpisodeLearningPlan(
            contentDepthScore: editorial.contentDepthScore,
            recommendedPromptCount: editorial.recommendedPromptCount,
            priorities: editorial.priorities
        )
        let recommendedCount = automaticPromptCount(learningPlan: learningPlan, duration: duration)
        let requestedCount = desiredCount.map { max(3, min(12, $0)) } ?? recommendedCount
        progress("Verifying evidence and selecting the strongest questions...")
        var validated = editorial.prompts.compactMap {
            validate($0, transcript: resolvedTranscript, duration: duration)
        }
        var promptValues = selectBestCandidates(
            validated,
            desiredCount: requestedCount,
            duration: duration
        )
        if promptValues.count < requestedCount || !PodcastPromptPolicy.hasAdequateCoverage(promptValues, duration: duration) {
            progress("Strengthening coverage across the complete episode...")
            if let supplemental = try? await fetchPromptCandidates(
                transcript: resolvedTranscript,
                duration: duration,
                count: min(20, max(12, requestedCount * 2)),
                learningPlan: learningPlan
            ) {
                validated.append(contentsOf: supplemental)
                promptValues = selectBestCandidates(
                    validated,
                    desiredCount: requestedCount,
                    duration: duration
                )
            }
        }
        guard promptValues.count == requestedCount,
              PodcastPromptPolicy.hasAdequateCoverage(promptValues, duration: duration) else {
            throw AIServiceError.noQualityPrompts
        }
        let summaryValue = editorial.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(summaryValue) >= 30 else { throw AIServiceError.invalidResponse }
        return EpisodeAnalysisResult(
            transcript: resolvedTranscript,
            duration: duration,
            summary: summaryValue,
            prompts: promptValues.sorted { $0.timestampSeconds < $1.timestampSeconds },
            recommendedPromptCount: recommendedCount,
            contentDepthLabel: learningPlan.depthLabel
        )
    }

    private func analyzeEpisodeLegacy(
        transcript: String,
        duration: Double,
        desiredCount: Int?
    ) async throws -> EpisodeAnalysisResult {
        async let summaryTask = personalAI.summarize(transcript: transcript)
        let learningPlan = try await personalAI.analyzeLearningPlan(transcript: transcript, duration: duration)
        let recommendedCount = automaticPromptCount(learningPlan: learningPlan, duration: duration)
        let requestedCount = desiredCount.map { max(3, min(12, $0)) } ?? recommendedCount
        async let promptsTask = generatePersonalPrompts(
            transcript: transcript,
            duration: duration,
            requestedCount: requestedCount,
            learningPlan: learningPlan
        )
        let (summary, prompts) = try await (summaryTask, promptsTask)
        return EpisodeAnalysisResult(
            transcript: transcript,
            duration: duration,
            summary: summary,
            prompts: prompts,
            recommendedPromptCount: recommendedCount,
            contentDepthLabel: learningPlan.depthLabel
        )
    }

    private struct ValidatedCandidate {
        let prompt: Prompt
        let score: Double
        let priorityID: String?
    }

    private func fetchPromptCandidates(
        transcript: String,
        duration: Double,
        count: Int,
        learningPlan: EpisodeLearningPlan
    ) async throws -> [ValidatedCandidate] {
        let data = try await personalAI.generatePromptData(
            transcript: transcript,
            duration: duration,
            candidateCount: count,
            learningPlan: learningPlan
        )
        let generated = decodeGeneratedPrompts(from: data)
        guard !generated.isEmpty else { throw AIServiceError.invalidResponse }
        return generated.compactMap {
            validate($0, transcript: transcript, duration: duration)
        }
    }

    private func generatePersonalPrompts(
        transcript: String,
        duration: Double,
        requestedCount: Int,
        learningPlan: EpisodeLearningPlan
    ) async throws -> [Prompt] {
        let candidates = try await fetchPromptCandidates(
            transcript: transcript,
            duration: duration,
            count: min(20, max(8, requestedCount * 2)),
            learningPlan: learningPlan
        )
        let selected = selectBestCandidates(
            candidates,
            desiredCount: requestedCount,
            duration: duration
        )
        guard !selected.isEmpty else { throw AIServiceError.noQualityPrompts }
        return selected.sorted { $0.timestampSeconds < $1.timestampSeconds }
    }

    private func validate(
        _ generated: GeneratedPrompt,
        transcript: String,
        duration: Double
    ) -> ValidatedCandidate? {
        guard generated.passesQualityGates == true else { return nil }
        let scores = generated.scores
        guard scores?.overall.map({ $0 >= 0.78 }) ?? false else { return nil }
        guard scores?.importance.map({ $0 >= 0.78 }) ?? true else { return nil }
        guard scores?.specificity.map({ $0 >= 0.78 }) ?? true else { return nil }
        guard scores?.answerAlignment.map({ $0 >= 0.78 }) ?? true else { return nil }
        guard scores?.grounding.map({ $0 >= 0.78 }) ?? true else { return nil }

        let question = cleanedQuestion(generated.question)
        let answer = cleanedAnswer(generated.expectedAnswer)
        guard !isStockQuestion(question), wordCount(question) >= 7, wordCount(question) <= 36 else { return nil }
        guard wordCount(answer) >= 10, wordCount(answer) <= 110 else { return nil }

        let transcriptKey = normalizedText(TranscriptTiming.plainText(transcript))
        let validEvidence = generated.evidence.filter { evidence in
            let key = normalizedText(evidence.quote)
            return key.count >= 20 && transcriptKey.contains(key)
        }
        let evidenceQuotes = validEvidence
            .map(\.quote)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !evidenceQuotes.isEmpty, validEvidence.count == generated.evidence.count else { return nil }

        let evidenceTokens = meaningfulTokens(evidenceQuotes.joined(separator: " "))
        let questionTokens = meaningfulTokens(question)
        let answerTokens = meaningfulTokens(answer)
        guard !evidenceTokens.isEmpty, !questionTokens.isEmpty, !answerTokens.isEmpty else { return nil }

        let questionHits = questionTokens.intersection(evidenceTokens).count
        let answerCoverage = Double(answerTokens.intersection(evidenceTokens).count) / Double(answerTokens.count)
        let questionAnswerHits = questionTokens.intersection(answerTokens).count
        guard questionHits >= 2, answerCoverage >= 0.18, questionAnswerHits >= 1 else { return nil }

        let questionCoverage = Double(questionHits) / Double(max(min(questionTokens.count, 5), 1))
        guard questionCoverage >= 0.4 else { return nil }

        guard let timestamp = promptTimestamp(
            generatedTime: generated.time,
            evidence: validEvidence,
            normalizedTranscript: transcript,
            duration: duration
        ) else { return nil }
        let combinedScore = ((scores?.overall ?? 0) * 0.30)
            + ((scores?.importance ?? 0) * 0.25)
            + ((scores?.specificity ?? 0) * 0.15)
            + ((scores?.answerAlignment ?? 0) * 0.15)
            + ((scores?.grounding ?? 0) * 0.10)
            + (questionCoverage * 0.03)
            + (answerCoverage * 0.02)
        return ValidatedCandidate(
            prompt: Prompt(
                id: UUID(),
                timestampSeconds: timestamp,
                question: question,
                expectedAnswer: answer,
                leadTimeSeconds: 0,
                timingVerified: true
            ),
            score: combinedScore,
            priorityID: generated.priorityID
        )
    }

    private func promptTimestamp(
        generatedTime: Double?,
        evidence: [GeneratedPrompt.Evidence],
        normalizedTranscript: String,
        duration: Double
    ) -> Double? {
        let answerEndCandidates = evidence.compactMap {
            TranscriptTiming.evidenceEnd(quote: $0.quote, transcript: normalizedTranscript)
        }
        guard answerEndCandidates.count == evidence.count else { return nil }
        guard let answerEnd = answerEndCandidates.max(), answerEnd.isFinite, answerEnd <= duration + 2 else { return nil }
        let leadIn = PodcastPromptPolicy.leadIn(for: duration)
        guard leadIn == 0 || answerEnd >= leadIn else { return nil }
        let listeningBuffer = min(12, max(6, duration * 0.0025))
        let earliestUsefulPrompt = min(20, max(6, duration * 0.03))
        return min(duration, max(answerEnd + listeningBuffer, earliestUsefulPrompt))
    }

    private func selectBestCandidates(
        _ candidates: [ValidatedCandidate],
        desiredCount: Int,
        duration: Double
    ) -> [Prompt] {
        var selected: [ValidatedCandidate] = []
        let leadIn = PodcastPromptPolicy.leadIn(for: duration)
        let afterIntroduction = candidates.filter { $0.prompt.timestampSeconds >= leadIn }
        var remaining = leadIn > 0 ? afterIntroduction : candidates
        let idealSpacing = max(duration / Double(max(desiredCount + 1, 2)), 30)

        // Seed strong questions from broad timeline regions before filling by quality.
        let regionCount = PodcastPromptPolicy.timelineRegionCount(
            promptCount: desiredCount,
            duration: duration
        )
        let highestQuality = remaining.map(\.score).max() ?? 0
        let coverageCandidates = duration >= 1_800
            ? remaining
            : remaining.filter { $0.score >= highestQuality - 0.12 }
        for region in 0..<regionCount {
            let lowerBound = duration * Double(region) / Double(regionCount)
            let upperBound = duration * Double(region + 1) / Double(regionCount)
            let regional = coverageCandidates.filter { candidate in
                candidate.prompt.timestampSeconds >= lowerBound
                    && (region == regionCount - 1
                        ? candidate.prompt.timestampSeconds <= upperBound
                        : candidate.prompt.timestampSeconds < upperBound)
                    && isDistinct(candidate, from: selected)
            }
            if let best = regional.max(by: { $0.score < $1.score }) {
                selected.append(best)
                remaining.removeAll { $0.prompt.id == best.prompt.id }
            }
        }

        while selected.count < desiredCount, !remaining.isEmpty {
            let distinct = remaining.filter { candidate in
                isDistinct(candidate, from: selected)
                    && canAddToTimeline(candidate, selected: selected, desiredCount: desiredCount, duration: duration)
            }
            guard let highestQuality = distinct.map(\.score).max() else { break }

            // Timing helps choose among comparable ideas, but never displaces a clearly better question.
            let comparable = distinct.filter { $0.score >= highestQuality - 0.08 }
            guard let best = comparable.max(by: { left, right in
                selectionScore(left, selected: selected, idealSpacing: idealSpacing)
                    < selectionScore(right, selected: selected, idealSpacing: idealSpacing)
            }) else { break }

            selected.append(best)
            remaining.removeAll { $0.prompt.id == best.prompt.id }
        }
        return selected.map(\.prompt)
    }

    private func canAddToTimeline(
        _ candidate: ValidatedCandidate,
        selected: [ValidatedCandidate],
        desiredCount: Int,
        duration: Double
    ) -> Bool {
        guard duration >= 1_800 else { return true }
        let quarter = min(3, Int((candidate.prompt.timestampSeconds / max(duration, 1)) * 4))
        let quarterCount = selected.filter {
            min(3, Int(($0.prompt.timestampSeconds / max(duration, 1)) * 4)) == quarter
        }.count
        return quarterCount < Int(ceil(Double(desiredCount) / 4.0))
    }

    private func isDistinct(
        _ candidate: ValidatedCandidate,
        from selected: [ValidatedCandidate]
    ) -> Bool {
        selected.allSatisfy { existing in
            jaccardSimilarity(
                meaningfulTokens(existing.prompt.question),
                meaningfulTokens(candidate.prompt.question)
            ) < 0.68 && jaccardSimilarity(
                meaningfulTokens(existing.prompt.expectedAnswer),
                meaningfulTokens(candidate.prompt.expectedAnswer)
            ) < 0.76
        }
    }

    private func selectionScore(
        _ candidate: ValidatedCandidate,
        selected: [ValidatedCandidate],
        idealSpacing: Double
    ) -> Double {
        guard !selected.isEmpty else { return candidate.score }
        let nearestDistance = selected
            .map { abs($0.prompt.timestampSeconds - candidate.prompt.timestampSeconds) }
            .min() ?? idealSpacing
        let temporalNovelty = min(nearestDistance / idealSpacing, 1)
        let coversNewPriority = candidate.priorityID.map { id in
            !selected.contains { $0.priorityID == id }
        } ?? true
        return (candidate.score * 0.82)
            + (temporalNovelty * 0.13)
            + (coversNewPriority ? 0.05 : 0)
    }

    private func automaticPromptCount(learningPlan: EpisodeLearningPlan, duration: Double) -> Int {
        let modelCount = max(3, min(12, learningPlan.recommendedPromptCount))
        let lengthMinimum = PodcastPromptPolicy.minimumCount(for: duration)
        let depthMinimum = learningPlan.contentDepthScore >= 0.78
            ? min(12, lengthMinimum + 1)
            : lengthMinimum
        return max(modelCount, depthMinimum)
    }

    private func decodeGeneratedPrompts(from data: Data) -> [GeneratedPrompt] {
        if let direct = try? JSONDecoder().decode([GeneratedPrompt].self, from: data) {
            return direct
        }
        if let envelope = try? JSONDecoder().decode(GeneratedPromptEnvelope.self, from: data) {
            return envelope.prompts
        }
        struct NestedEnvelope: Decodable {
            struct DataEnvelope: Decodable {
                let prompts: [GeneratedPrompt]
            }
            let data: DataEnvelope
        }
        return (try? JSONDecoder().decode(NestedEnvelope.self, from: data).data.prompts) ?? []
    }

    private func localScore(
        expectedAnswer: String,
        userAnswer: String,
        progressSeconds: Double?
    ) -> AIResult {
        let score = heuristicScore(expectedAnswer: expectedAnswer, userAnswer: userAnswer)
        let prefix: String
        if let progressSeconds, progressSeconds.isFinite {
            prefix = "You've listened up to \(formatTime(progressSeconds)). "
        } else {
            prefix = ""
        }

        let feedback: String
        switch score {
        case 85...100:
            feedback = prefix + "Strong answer. You captured the main idea; any missing detail is a refinement, not a major error."
        case 65..<85:
            feedback = prefix + "You're in the right ballpark and earned solid credit. To make the answer stronger, add this detail: \(expectedAnswer)"
        case 40..<65:
            feedback = prefix + "You identified part of the idea. Here is the key point to add: \(expectedAnswer)"
        default:
            feedback = prefix + "Not quite. The podcast's answer is: \(expectedAnswer)"
        }

        let grade = PromptGrade.from(score: score)
        return AIResult(score: score, grade: grade, feedback: feedback, awardedPoints: grade.pointsAwarded)
    }

    private func heuristicScore(expectedAnswer: String, userAnswer: String) -> Int {
        let expectedTokens = semanticTokens(expectedAnswer)
        let userTokens = semanticTokens(userAnswer)
        guard !expectedTokens.isEmpty, !userTokens.isEmpty else { return 0 }

        let overlap = expectedTokens.intersection(userTokens).count
        let precision = Double(overlap) / Double(userTokens.count)
        let recall = Double(overlap) / Double(expectedTokens.count)
        let f1 = precision + recall > 0 ? (2 * precision * recall) / (precision + recall) : 0
        var score = max(f1, (precision * 0.7) + (recall * 0.3)) * 100

        let expectedConcepts = conceptTokens(expectedAnswer)
        let userConcepts = conceptTokens(userAnswer)
        if expectedConcepts.count >= 3, userConcepts.count >= 2 {
            let conceptOverlap = expectedConcepts.intersection(userConcepts).count
            let conceptRecall = Double(conceptOverlap) / Double(expectedConcepts.count)
            let conceptPrecision = Double(conceptOverlap) / Double(userConcepts.count)
            let conceptScore = ((conceptRecall * 0.8) + (conceptPrecision * 0.2)) * 100
            score = max(score, conceptScore)
        }

        if recall >= 0.75 {
            score += 10
        } else if recall >= 0.55 {
            score += 5
        }

        // A short answer can express the central idea without repeating every word
        // in a longer reference answer. Reward strong signal in the listener's words.
        if overlap >= 2, precision >= 0.7 {
            score = max(score, 85)
        } else if overlap >= 2, precision >= 0.45 {
            score = max(score, 72)
        } else if overlap >= 1, precision >= 0.5 {
            score = max(score, 60)
        }
        return min(100, max(0, Int(score.rounded())))
    }

    private func semanticTokens(_ text: String) -> Set<String> {
        Set(meaningfulTokens(text).map(canonicalToken))
    }

    private func conceptTokens(_ text: String) -> Set<String> {
        let normalized = normalizedText(text)
        var concepts = Set(meaningfulTokens(text).compactMap(conceptToken))
        let independencePhrases = [
            "from memory",
            "own words",
            "on your own",
            "without looking",
            "without the source",
            "without rereading",
            "without the transcript",
        ]
        if independencePhrases.contains(where: normalized.contains) {
            concepts.insert("independent")
        }
        return concepts
    }

    private func canonicalToken(_ token: String) -> String {
        conceptToken(token) ?? stemmedToken(token)
    }

    private func conceptToken(_ token: String) -> String? {
        let stem = stemmedToken(token)
        let concepts: [String: Set<String>] = [
            "retrieve": ["recall", "remember", "retriev"],
            "reveal": ["detect", "discover", "expos", "find", "highlight", "identif", "reveal", "show", "surfac", "uncover"],
            "gap": ["gap", "miss", "omission", "weakness"],
            "strengthen": ["build", "deepen", "improv", "reinforc", "solidif", "strengthen"],
            "memory": ["memor", "retention"],
            "reread": ["reread", "review", "revisit"],
            "familiarity": ["familiar", "recognit", "recogniz"],
            "independent": ["independent"],
        ]
        return concepts.first(where: { entry in
            entry.value.contains { alias in
                stem == alias || (min(stem.count, alias.count) >= 4 && (stem.hasPrefix(alias) || alias.hasPrefix(stem)))
            }
        })?.key
    }

    private func stemmedToken(_ token: String) -> String {
        var value = token
        let suffixes = ["ingly", "edly", "ation", "ition", "ment", "ness", "ingly", "ing", "ied", "ies", "ed", "es", "s"]
        for suffix in suffixes where value.count - suffix.count >= 4 && value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            if suffix == "ied" || suffix == "ies" { value.append("y") }
            break
        }
        return value
    }

    private func cleanedQuestion(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        value = value.prefix(1).uppercased() + value.dropFirst()
        if !value.hasSuffix("?") { value.append("?") }
        return value
    }

    private func cleanedAnswer(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isStockQuestion(_ question: String) -> Bool {
        let normalized = normalizedText(question)
        let bannedPhrases = [
            "what is the main idea",
            "summarize the episode",
            "what did they talk about",
            "what happened in this section",
            "what is this section about",
            "what is the strongest reason the speaker gives",
            "what assumption is doing the most work",
            "what should listeners take away",
            "what would a careful listener",
            "what hidden assumption",
            "what unresolved issue",
            "how does this segment",
            "how does this section",
            "according to the speaker",
            "what does the speaker say about",
            "which consequence of the argument",
            "what practical conclusion follows",
            "what thread introduced here",
            "do you agree",
            "what do you think",
            "in your opinion",
            "how would you apply",
        ]
        return normalized.isEmpty || bannedPhrases.contains { normalized.contains($0) }
    }

    private func meaningfulTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with", "is", "are", "was",
            "were", "it", "this", "that", "as", "by", "at", "from", "be", "has", "have", "had", "do", "does",
            "did", "not", "we", "you", "they", "he", "she", "i", "me", "our", "your", "their", "about", "into",
            "out", "up", "down", "what", "why", "how", "when", "where", "which", "who", "according", "episode",
            "podcast", "speaker", "speakers", "says", "said", "claim", "claims", "idea", "point",
        ]
        return Set(
            normalizedText(text)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }

    private func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func jaccardSimilarity(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let union = left.union(right)
        return union.isEmpty ? 0 : Double(left.intersection(right).count) / Double(union.count)
    }

    private func resolvedDuration(audioDuration: Double, transcript: String) -> Double {
        if audioDuration.isFinite, audioDuration > 10 { return min(audioDuration, 86_400) }
        return max(180, min(86_400, Double(wordCount(transcript)) / 2.6))
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(Int(seconds), 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
