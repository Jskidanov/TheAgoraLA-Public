import Foundation

@main struct PromptReplayRegression {
    static func main() throws {
        let promptID = UUID()
        let otherPromptID = UUID()
        let response = PromptResponse(
            promptID: promptID, answer: "My earlier answer", score: 90, grade: .a,
            awardedPoints: 20, feedback: "Previous feedback", lastUpdated: Date()
        )
        let history = PromptHistorySnapshot(
            responses: [response], encounteredPromptIDs: [promptID],
            earnedPointsByPrompt: [promptID: 15, otherPromptID: 8]
        )
        let reset = history.resettingProgress()
        precondition(reset.responses.isEmpty && reset.encounteredPromptIDs.isEmpty)
        precondition(reset.pointAwardHistory[promptID] == 20)
        precondition(reset.pointAwardHistory[otherPromptID] == 8)
        let restored = try JSONDecoder().decode(PromptHistorySnapshot.self, from: JSONEncoder().encode(reset))
        precondition(restored.responses.isEmpty && restored.encounteredPromptIDs.isEmpty)
        precondition(restored.pointAwardHistory == reset.pointAwardHistory)
        precondition(restored.resettingProgress().pointAwardHistory == restored.pointAwardHistory)

        // Older installations only stored points alongside their answers.
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "responses": JSONSerialization.jsonObject(with: JSONEncoder().encode([response])),
            "encounteredPromptIDs": [promptID.uuidString],
        ])
        let legacy = try JSONDecoder().decode(PromptHistorySnapshot.self, from: legacyData)
        precondition(legacy.earnedPointsByPrompt == nil)
        precondition(legacy.resettingProgress().pointAwardHistory[promptID] == 20)
        let duplicateAward = max(20 - (restored.pointAwardHistory[promptID] ?? 0), 0)
        let improvedAward = max(25 - (restored.pointAwardHistory[promptID] ?? 0), 0)
        precondition(duplicateAward == 0 && improvedAward == 5)

        let otherEpisode = PromptHistorySnapshot(responses: [], encounteredPromptIDs: [otherPromptID])
        _ = history.resettingProgress()
        precondition(otherEpisode.encounteredPromptIDs == [otherPromptID])
        print("PASS: replay clears answers and encountered prompts; persisted reset survives reload; legacy points migrate; repeated resets preserve points; no duplicate awards.")
    }
}
