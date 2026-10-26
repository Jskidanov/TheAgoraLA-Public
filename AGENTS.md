# The Agora LA Development Guide

## Research Branch Notice

You are on a research branch: `research/agora-lite-handoff` or a working branch made from it, such as `shane/agora-lite`. It carries an evaluation and a plan for a small Google Cloud version of the app ("Agora Lite"), not shipped app changes. Read `docs/research/HANDOFF.md` before doing anything else.

While you are on such a branch, this notice overrides the publishing step below: commit to the current branch and push it with `git push Codex HEAD:<current branch name>`. Never push to `main` or merge into it until the team agrees. When this work is merged into `main`, delete this notice from `CLAUDE.md` and `AGENTS.md` as part of the merge.

## Project Map

- `TheAgoraLAPod.xcodeproj`: open this project for the iOS app.
- `Sources/`: active SwiftUI application code.
- `TheAgoraLA/`: app resources, `Info.plist`, privacy manifest, and assets.
- `Backend/`: Node.js cloud analysis API and worker deployed to Railway.
- `Website/`: public support, privacy, terms, and OpenRouter return pages.
- `AppStore/`: release metadata, review notes, and submission checklists.

The old standalone podcast prototype and third-party sample recording are intentionally excluded from this public repository. They are not dependencies of the current app.

## Canonical Workspace And Publishing

Always work from this repository folder:

    /Users/shanereid/Documents/Codex/TheAgoraLA-release

This is the Xcode project the team uses. Do not create or edit a second copy of
the app elsewhere.

The shared GitHub destination is the `Codex` remote's `main` branch:

    https://github.com/shane448/TheAgoraLA-Public.git

After a requested change is implemented and the relevant checks pass, commit
only the task's files and publish the result with:

    git push Codex HEAD:main

Do this as the normal completion step unless the user explicitly asks not to
publish. Do not push Xcode user settings, breakpoints, build products, secrets,
or unrelated uncommitted work. The `origin` remote is only a local backup clone,
not the shared release destination.

## Product Behavior

`Import, Analyze & Save` is the single episode workflow. It resolves a supported podcast URL, obtains or creates the transcript, prepares the summary, selects high-quality transcript-grounded questions, generates expected answers from podcast evidence, schedules prompts after the relevant passages, and saves the complete episode.

Listeners use their own OpenRouter account. Never add an Agora-owned AI key to the app or repository. Provider credentials must remain encrypted and short-lived in cloud jobs, and must never be logged.

## Verification

Run backend checks:

```bash
cd Backend
npm ci
npm run check
```

Run website checks:

```bash
cd Website
npm ci
npm test
```

Build the iOS app:

```bash
xcodebuild -project TheAgoraLAPod.xcodeproj \
  -scheme TheAgoraLA \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Engineering Guardrails

- Preserve the one-button import, analysis, prompt generation, and save flow.
- Questions and expected answers must be grounded in the complete transcript, not stock templates.
- Prompt playback times must occur after the listener has heard all supporting evidence.
- Keep long podcast analysis resumable through the cloud job system.
- Do not commit `.env` files, provider keys, signing keys, provisioning profiles, Xcode user state, build products, or `node_modules`.
- Maintain iOS 16 compatibility unless the deployment target is intentionally changed.
- Run the relevant checks before committing changes.
