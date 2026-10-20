# Release Checklist - 1.0.2 (3)

This is a submission checklist, not a declaration that all manual checks have
passed. See `release-audit-2026-10-08.md` for verified results and remaining gates.

## Nonprofit Enrollment

- Confirm the organization is an officially recognized nonprofit legal entity.
- Confirm the applicant has authority to bind the organization.
- Confirm the exact legal name, D-U-N-S number, physical address, public website, organization-domain email, and phone match official records.
- Withdraw the pending individual enrollment only after those records are ready, then restart as an organization and request the fee waiver during enrollment.
- Confirm Apple's current enrollment and agreement requirements for the organization. The current app is free and contains no in-app purchases or sales of digital goods by The Agora.

## Website and Support

- Confirm `/privacy`, `/terms`, and `/support` remain public at `https://the-agora-la-app.shareid.chatgpt.site` with valid TLS.
- Make `support@theagorala.com` operational and monitored.
- Have a qualified attorney review the initial Privacy Policy and Terms.

## App Store Connect

- Create the App ID `com.theagora.la` without In-App Purchase or Sign in with Apple capabilities.
- Create the app record and select the nonprofit organization team in Xcode.
- Set price to Free and do not create in-app purchase products.
- Complete the metadata, privacy questionnaire, age rating, content-rights questions, and review notes from this folder.
- Upload polished iPhone and iPad screenshots with no transparency.
- Use manual release for version 1.0.2 (3).
- Provide the dedicated, prefunded and budget-capped OpenRouter review key and an authorized public review-episode URL in confidential review information. Neither belongs in GitHub.

## Production Verification

- Test OpenRouter authorization, cancellation, disconnect, expired access, insufficient provider balance, and network failures on a physical iPhone.
- Confirm the Release build contains no StoreKit purchase flow or Sign in with Apple entitlement. Its configured Agora cloud-service URL is required for background analysis.
- Test AI-processing permission on first use and after revocation. The current build has no offline sample lesson; do not describe an account-free live-AI demonstration to reviewers.
- Test Apple Podcasts show links, episode links, direct RSS links, published transcripts, and direct audio links.
- Test one short, one 60-minute, and one 2-hour episode with a listener-owned provider account.
- Reanalyze older saved episodes to replace previously estimated prompt times with verified audio timings. Check that questions occur only after their supporting passages and cover the whole episode.
- Test importing two episodes before opening the backlog, relaunching and selecting both from the library.
- Test lock-screen hands-free narration, spoken answers, real interruptions, grading, feedback and playback resumption on a physical iPhone. Verify podcast audio never overlaps feedback.
- Test poor connectivity, expiration, server cancellation, app termination and retries without duplicate paid jobs.
- Test Delete My Cloud Data and verify that local episodes remain available.
- Confirm podcast audio and transcripts pass through the encrypted Agora cloud job only to the provider authorized by the listener, credentials are erased at job completion, and cloud job records expire within seven days.
- Verify the updated backend is actually deployed and its database-aware health check succeeds; a local build is not proof of live deployment.
- Archive with a distribution certificate, validate the archive, upload it, install through TestFlight, and repeat the critical path.

## Operational Review

- Confirm the podcast ingestion and private transcript workflow is permitted by publisher terms and applicable law.
- Keep the OpenRouter OAuth endpoints and supported model identifiers under release monitoring.
- Establish a support response and incident-response process before release.
