import Foundation

@main struct HandsFreePreferenceRegression {
    static func main() {
        let suite = "TheAgoraLA.HandsFreePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        precondition(HandsFreePreference.isEnabled(in: defaults))
        precondition(defaults.persistentDomain(forName: suite)?.isEmpty != false)

        HandsFreePreference.setEnabled(false, in: defaults)
        let reopened = UserDefaults(suiteName: suite)!
        precondition(!HandsFreePreference.isEnabled(in: reopened))
        precondition(!HandsFreePreference.isEnabled(in: reopened))

        HandsFreePreference.setEnabled(true, in: reopened)
        precondition(HandsFreePreference.isEnabled(in: UserDefaults(suiteName: suite)!))

        // Reading the default must not overwrite an explicitly saved choice.
        HandsFreePreference.setEnabled(false, in: defaults)
        precondition(!HandsFreePreference.isEnabled(in: defaults))
        print("PASS: hands-free defaults on; explicit off/on choices survive reopening; reading preferences never overwrites a choice.")
    }
}
