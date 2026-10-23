# Playback regression investigation — October 22, 2026

## Finding and release recommendation

The Swift app contains several independently reproducible paths that explain premature podcast resumption and missing useful feedback. These require a new iOS binary; a backend deployment or reanalysis of saved episodes does not install the repairs.

Keep marketing version 1.0.2 if it is still the intended TestFlight version. Before the next upload, increment `CURRENT_PROJECT_VERSION` above the highest build already uploaded for that version. The repository and the inspected local archive both say build 3, so build 4 is appropriate only if App Store Connect has no later build. This task deliberately leaves the build number at 3 and performs no signing, upload, TestFlight submission, or App Store submission.

## Evidence and limits on attribution

- Inspected shared `main` at `6bb67bad421c7e66ab3ccb4aba42f005990411a1` and its Swift history.
- Inspected the local October 18, 2026 archive's metadata: bundle ID `com.theagora.la`, marketing version 1.0.2, build 3, created 21:48:06 UTC.
- Read the compiled archive executable's strings. It contains `No answer heard. Continuing playback...`, `Microphone unavailable. Continuing playback...`, both corresponding spoken auto-resume messages, and the quick-feedback/automatic-resume UI text. This establishes that the unsafe paths reached an archived binary, not just current source.
- The archive has no trustworthy embedded source revision that maps it exactly to a Git commit. App Store Connect's currently distributed build and the listener's installed build were not verified. An archive is not proof of an upload; it would be incorrect to claim an exact TestFlight build match from these local records.
- The October 20 Play-command change postdates that archive. It is a confirmed defect in current `main`, but cannot be attributed to the October 18 archive based on the available evidence.
- No runtime recording or device logs from the reported session were available. The code paths below explain the symptoms; the particular path taken on Shane's phone remains unproven.

## Causes and repairs

| Area | Existing failure path | Resulting behavior |
| --- | --- | --- |
| Microphone startup | After one connection retry, failure used `.speakingFeedback` for an apology; its completion called Continue. | Keep the question and playback hold. Show retry/typed-answer recovery instead of resuming. Permission denial still offers Settings. |
| Empty speech recognition | Recognition could end with no words immediately, or hit the 15/25-second empty-input limits. After one retry, another apology automatically resumed the episode. | Retry once, then remain paused for the listener. Empty input never becomes an automatic skip. |
| Feedback detail | `6a4dfc8` introduced quick hands-free narration containing only the numeric score. The UI nevertheless promised feedback about what was missed. Quick and balanced written feedback disappeared after 1.6/4.5 seconds. | Always narrate the useful feedback with the score. Remove timed dismissal of written feedback. Update settings copy to describe the behavior accurately. |
| Narration completion | The on-device watchdog treated three `isSpeaking == false` polls as successful completion. That also describes an engine that never spoke or stopped without its delegate callback. | Move narration ownership into `PromptNarrator`. Only a matching successful synthesis/audio-player completion advances the flow. Cancellation, silent-engine recovery, decoding errors, and playback failures keep the check-in held. |
| Media Play | `6bb67ba` made normal in-app and remote Play dismiss an active question, invalidating in-progress grading or stopping feedback. | Play preserves active check-ins. Disable the in-app Play button during a check-in with an accessibility hint directing the listener to Continue. Explicit Continue and exact spoken skip commands still work. |
| Spoken commands | Substring matching interpreted an answer such as “They chose to move on” as Skip. Similar repeat/start-over substrings could replace an answer. | Match whole normalized command phrases, including supported polite repeat variants. Ordinary answers containing command words are graded. |
| Asynchronous lifecycle | Pending narration, microphone starts, final recognition, and grading could outlive a prompt/reset/mode change; repeated state values or reopening the same question were insufficient identity checks. | Invalidate the interaction generation on flow cancellation/activation, bind asynchronous transitions to that generation, and invalidate old speech callbacks before releasing recognition resources. Preserve final recognition before grading and manual recording completion. |
| Interruptions and edits | Audio interruption during grading was not handled; foregrounding could restart listening while another audio session remained active. Editing an answer could leave obsolete feedback advancing the flow. | Hold ready feedback during interruptions; replay it when the system allows resumption, or offer Read Feedback. Keep foreground transitions paused until the interruption ends. Cancel obsolete feedback when an answer changes. |

Natural narration still uses the existing provider, prompt cache, consent check, and enhanced/premium downloaded-voice fallback. Personal feedback remains excluded from the persistent prompt-audio cache. Scoring models, transcript-grounding behavior, prompt scheduling, provider URLs, iOS 16 deployment target, and release signing settings are unchanged. Debug and Release use the same interaction code and grading path; this is not a Debug-only fix.

## Automated coverage

`Tests/PlaybackFlowTests.swift` is a hosted XCTest target exercising the actual `PlayerViewModel` and `AudioPlayerManager` with a real local silent audio file. Speech recognition, grading, and narration are injected deterministic substitutes, so the tests do not require microphone permissions, provider credentials, or paid requests. A controlled clock advances silence deadlines without waiting through the real no-answer limits.

The suite covers the scheduled first prompt; narration-to-listening transition; final rather than partial recognition; silence-based submission without cancellation of grading; saved answers and feedback; completion before resume at all three detail levels; Play while held; permission denial; microphone startup failure/retry; both empty-input timeout and early-recognition-end paths; narration errors; Stop Feedback and late completions; stale grading/final recognition/narration after reset or reopening; ordinary answers containing “move on”; explicit spoken skip; written feedback past both former timers; interrupted and deferred feedback replay; foregrounding during interruption; reset during the feedback-completion delay; editing during feedback; offline feedback and regrading without duplicate points.

The shared `TheAgoraLA` scheme now includes `PlaybackFlowTests`, and Debug enables testability. Run on a machine with an available simulator:

```sh
sh Scripts/test-playback-flow.sh
# Or select a different installed simulator:
AGORA_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' sh Scripts/test-playback-flow.sh
```

## Validation on this machine

- Final playback suite: 20 tests, zero failures, iPhone 17 Pro simulator running iOS 26.2, using Xcode 26.6 / iOS 26.5 SDK.
- All five pre-existing Swift regression scripts passed: natural narration/cache/privacy, prompt replay/points, hands-free preferences, AI-processing consent, and storage/timing.
- Debug simulator app/test compilation and unsigned Release arm64 iOS code compilation/linking passed. Actual app asset catalog compilation also passed in a separate invocation.
- Environment workaround: unrestricted Xcode project opening stalled in `NSFileCoordinator`; sandboxed asset compilation could not reach CoreSimulator. Built the canonical project with `EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets`, then ran its generated `.xctestrun` outside the sandbox and compiled the unchanged assets separately with `actool`. No second app source checkout was created. This validates code, resources, and coordinator behavior, but is not a successful normal signed archive/export of the complete app.
- Backend `npm ci` and `npm run check` passed: TypeScript build and 44 tests across 8 files. Installation reported 5 existing dependency advisories (1 low, 4 moderate); dependencies were not changed.
- Website `npm ci` failed because the existing lockfile is missing an `@emnapi/runtime` entry. Website tests could not run from a clean install; no website or lockfile edits were included in this iOS repair.
- No physical microphone, Bluetooth/CarPlay route, lock-screen/background recording, real phone call, live OpenRouter grading/TTS, production backend deployment, or signed distribution archive was validated.

Before distributing: make a normal signed archive, verify the uploaded build number, install the exact candidate through TestFlight, and exercise the first question through a real spoken answer and complete corrective feedback. Repeat with denied permissions, quiet/slow answers, a recognition failure, downloaded and natural voices, network/provider failures, lock screen/Bluetooth, and a phone interruption. Confirm podcast audio never overlaps narration and only resumes after completed feedback or explicit Continue/Skip.
