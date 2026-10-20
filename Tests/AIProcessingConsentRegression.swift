import Foundation

@main struct AIProcessingConsentRegression {
    static func main() {
        let suite = "TheAgoraLA.ConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        precondition(!AIProcessingConsent.isAllowed(in: defaults))
        precondition(AIProcessingConsent.nextStep(isConnected: true, allowsProcessing: false) == .askPermission)
        precondition(AIProcessingConsent.nextStep(isConnected: false, allowsProcessing: false) == .askPermission)
        // Not Now leaves permission unset; no analysis or account connection is authorized.
        precondition(!AIProcessingConsent.isAllowed(in: UserDefaults(suiteName: suite)!))
        precondition(defaults.persistentDomain(forName: suite)?.isEmpty != false)

        AIProcessingConsent.setAllowed(true, in: defaults)
        let reopened = UserDefaults(suiteName: suite)!
        precondition(AIProcessingConsent.isAllowed(in: reopened))
        precondition(AIProcessingConsent.nextStep(isConnected: true, allowsProcessing: AIProcessingConsent.isAllowed(in: reopened)) == .analyze)
        precondition(AIProcessingConsent.nextStep(isConnected: false, allowsProcessing: true) == .connectAccount)

        // Consent from the existing Settings toggle is reused, not requested again.
        defaults.set(true, forKey: "TheAgoraLA.AI.DataSharingConsent.v1")
        precondition(AIProcessingConsent.isAllowed(in: defaults))
        AIProcessingConsent.setAllowed(false, in: defaults)
        precondition(!AIProcessingConsent.isAllowed(in: reopened))
        precondition(AIProcessingConsent.nextStep(isConnected: true, allowsProcessing: AIProcessingConsent.isAllowed(in: reopened)) == .askPermission)

        for requiredDisclosure in ["OpenRouter", "OpenAI", "Microsoft", "NVIDIA", "answers", "transcripts", "narration", "Agora's server", "temporary provider key", "AI Settings"] {
            precondition(AIProcessingConsent.disclosure.contains(requiredDisclosure))
        }
        print("PASS: no assumed consent; cancellation preserves privacy; approval persists and proceeds directly to analysis; disconnected users route to setup; existing consent is reused; revocation blocks analysis; disclosure identifies data and recipients.")
    }
}
