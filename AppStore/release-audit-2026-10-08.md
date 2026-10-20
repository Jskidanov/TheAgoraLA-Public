# Release Readiness Repairs - October 8, 2026

Target: Agora Interactive Podcast 1.0.2 (3), `TheAgoraLAPod.xcodeproj`.
Status: engineering repairs verified locally; App Store submission is not complete.

## Repairs

- Regular imports are written into the saved library even if the backlog has never been opened. Encoding and library writes run on a serial background queue. A corrupt library is preserved and reported instead of overwritten.
- Answer evaluations are bound to the original episode, question and response. A stale request cannot score a different question or narrate feedback after the listener has moved on. Unchanged answers graded offline can be resubmitted online.
- Generated questions use supporting passages' actual caption or recognition timestamps rather than model guesses or transcript word-position estimates. Timed transcription covers every audio part; missing or incomplete timing fails clearly. The existing strongest analysis and semantic grading configurations are retained.
- Network polling failures retain the cloud job instead of starting duplicate direct-provider work. Server cancellation, expired-job recovery, stable prompt IDs and persistent acknowledgement retries are supported.
- Screen locking alone no longer stops hands-free narration. Actual audio interruptions still pause voice handling; grading requests receive a temporary iOS background assertion. This does not guarantee unlimited background execution or operation after force-quitting.
- Provider keys use device-only Keychain protection available after first unlock so a legitimate background request can complete. Explicit AI-sharing permission is required, and users can delete their cloud data from AI Setup.
- Public audio/transcript downloads reject private, reserved and mapped IP destinations, pin the validated DNS address and revalidate redirects. Rejected streams are closed. Transcription processes have cancellation and bounded execution.
- All cloud jobs expire seven days after creation, including uncollected results. The health endpoint checks the database. Old cached analyses are invalidated by the new timing pipeline version.
- Review instructions match the real app, version/build are updated, public disclosures describe the actual data flow, and JPEG screenshot exports have no alpha channel.

## Verification

- Unsigned iOS Release device build passed. This is not a signed distribution archive or a TestFlight upload.
- Foundation regression harness passed: multiple imports survive relaunch before opening the library, the active episode restores, cross-caption evidence times are accurate, old prompt decoding is compatible, and corrupt libraries are retained.
- Backend TypeScript checks and 44 automated tests passed, including database-health failure, retention, cancellation ownership, grounded prompt timing, mapped/private addresses, DNS pinning and redirect rejection.
- Website production build and five production-runtime route checks passed.
- Production dependency audits report zero known vulnerabilities for both backend and website. The backend full dependency audit is also clean.

The website full dependency audit still reports 12 development-tool advisories
(8 high, 4 moderate) in transitive build/lint packages. Production audit results
do not mean the development toolchain is advisory-free. Do not process untrusted
build inputs or fonts; update compatible upstream releases when available rather
than forcing incompatible dependency downgrades.

## Required Before App Store Submission

- Deploy the updated backend and verify real database connectivity, worker operation, credential deletion and seven-day cleanup in production.
- Supply a dedicated prefunded review key and authorized short public review episode in confidential App Store Connect review information. No key has been added to this repository.
- Test live provider sign-in, full short/long podcast analysis, grading and account revocation from the exact submitted TestFlight build. Automated tests did not consume paid AI credits.
- Test complete hands-free mode on a physical iPhone, including lock screen, microphone/speech permissions, Bluetooth/car interruptions, repeat/start-over/skip commands and feedback finishing before playback resumes.
- Reanalyze previously saved episodes whose question times were estimated; these repairs do not rewrite old questions automatically.
- Confirm publisher/content rights, monitored support, organization enrollment, donation claims, privacy questionnaire and age rating with the responsible owner. Obtain appropriate legal review.
- Create and validate a signed archive, upload to TestFlight, repeat the critical user journey, and then submit for review. No App Store or TestFlight upload was performed by these repairs.
