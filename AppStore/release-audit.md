# Version 1.0 Release Audit

Audit date: August 9, 2026

Historical record only. The current release audit and remaining submission
requirements are in `release-audit-2026-10-08.md`. Later builds changed voice,
credential protection, review access and cloud retention behavior.

## Automated Verification Completed

- Clean Release simulator build and Apple product validation passed.
- App icon catalog compiled for iPhone and iPad.
- `Info.plist`, privacy manifest, and export options passed validation.
- Fresh installation and launch completed without an app crash or media error.
- Public website build, lint, and all five route tests passed.
- Privacy, Terms, Support, home, and OpenRouter callback URLs returned HTTP 200.
- Production dependency audits reported zero known vulnerabilities for the site
  and cloud service.
- Cloud service build, security checks, and automated tests passed. The service
  uses listener-owned provider credentials and seven-day job retention.

## Release Repairs Included

- Episode title and transcript edits now have explicit save and close actions.
- Manual prompts validate required text and episode timestamps instead of
  failing silently.
- Player buffering is visible, end-of-episode state resets correctly, and Play
  restarts an ended episode.
- Temporary AI `429` and `503` responses receive one bounded retry.
- Provider credentials use Keychain protection that requires an unlocked device.
- Privacy, Terms, and Support are available from the main app screen.
- First launch no longer opens a placeholder audio source in the background.
- The OpenRouter return page preserves the authorization query without an
  unnecessary React render cycle.
- Detached sign-in, feed-picker, resolver, starter-auth, and starter-database
  files were removed.

## Required Before Submission

- Select the nonprofit organization development team in Xcode and confirm the
  organization owns `com.theagora.la`.
- Confirm that the displayed 501(c)(3) claim and PayPal recipient are legally
  accurate, and obtain legal review of the Privacy Policy and Terms.
- Make `support@theagorala.com` operational and monitored.
- Complete physical-iPhone tests for microphone permission, speech recognition,
  narrator voices, interruptions, background playback, and hands-free grading.
- Test live OpenRouter authorization and several real podcast sources using the
  listener-owned provider account intended for review.
- Create a signed archive, upload it to TestFlight, complete the App Store privacy
  and content-rights answers, and repeat the critical path from TestFlight.

## Non-Shipping Tooling Note

The Sites build tool currently brings in an `image-size` advisory through
`vinext`. It is development-only, is not present in the deployed production
dependency set, and has no patched `image-size` release available at audit time.
Do not process untrusted image files in the local Sites build environment; update
`vinext` when its compatible patched dependency becomes available.
