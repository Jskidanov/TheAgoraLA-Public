# TestFlight 1.0.2 (5) — October 22, 2026

## Binary and source

- App: The Agora LA (`com.theagora.la`), App Store Connect ID `6815117178`.
- Version: `1.0.2`; build: `5`. App Store Connect already had build 4, so both Xcode configurations were incremented from the repository's stale build 3 to build 5.
- Contains the playback fixes in `e2f63730a3815e23ba4dd3dd2e36deaf3f98dfa0`; release configuration is committed as `ec71ef0`. No functional code changes were made during release preparation.
- Full normal Release archive completed with automatic signing and all assets included. The archive was built outside the cloud-synced Documents folder after Finder metadata in that folder caused code-signing failures.
- The archived app passed strict signature verification, and the app and dSYM UUIDs match: `E527482F-A34D-3D07-805C-C457A54AE0B4` (arm64).
- Existing `ITSAppUsesNonExemptEncryption=false` declaration was retained. Xcode's upload configuration does not automatically change build numbers.
- The signed archive ZIP SHA-256 is `b5c20fbd945eb95241023066ad2a3f1e69ed21f751d1174f84a906c8e8ce5897`.

## Upload and distribution

- Xcode reported `Upload succeeded` and `EXPORT SUCCEEDED`.
- App Store Connect confirms build 5 was received on October 22, 2026 at 9:44 PM Pacific, upload/build identifier `7cceae90-7c04-49ae-8d4a-99b02c52efdc`.
- Apple finished processing build 5. The existing internal group, **Friends of Shane**, was attached automatically.
- Added the existing external group, **Friends and Family** (15 testers), and submitted the build through its TestFlight review flow with **Automatically notify testers** checked.
- After submission, App Store Connect displayed build 5 as **Testing**, with **both groups** attached and 90 days until expiry. No pending-review state remained in the final build list.
- TestFlight was instructed to send the new-build alert through Apple's notification system. Delivery to each tester's inbox/device was not independently verified; no separate email or text campaign was sent.
- Tester notes below were saved to the build before notification/distribution.
- This is a TestFlight release; no App Store production version was submitted or released.

## Test instructions

Build 5 fixes early podcast resumption and missing feedback. Please test the full check-in flow: listen to the question, take your time starting a spoken answer, pause to submit, and hear the complete feedback before the podcast resumes. Try Quick, Balanced, and Full feedback, typed answers, Stop Feedback/Read Feedback, and a phone or audio interruption. If microphone or narration fails, the question should remain paused so you can retry. Update in TestFlight before testing. Existing saved episodes can still be used.

## Validation

The functional changes passed 20 hosted iOS simulator flow tests, all five existing Swift regression scripts, and the backend's 44 tests in the preceding repair task. The final full signed archive and App Store Connect upload also succeeded. Physical microphone/Bluetooth/CarPlay behavior and live grading/narration still need testing from this exact TestFlight candidate. See `playback-regression-audit-2026-10-22.md` for detailed coverage and the unrelated website lockfile limitation.
