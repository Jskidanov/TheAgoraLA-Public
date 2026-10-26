# Handoff: Agora Lite research

**For:** Shane, and Claude Code running in Shane's canonical workspace.
**Prepared:** October 25, 2026, during an evaluation of whether The Agora LA can scale.
**Branch:** `research/agora-lite-handoff`. Documentation and planning only; no app or backend code was changed.

---

## Pull this branch and work on your own copy

The branch lives on a fork because the evaluator has read-only access to `shane448/TheAgoraLA-Public`. Work happens on Shane's own branch, `shane/agora-lite`, made from it.

```bash
cd /Users/shanereid/Documents/Codex/TheAgoraLA-release
git remote add jskidanov https://github.com/Jskidanov/TheAgoraLA-Public.git
git fetch jskidanov research/agora-lite-handoff
git switch -c shane/agora-lite jskidanov/research/agora-lite-handoff
git push -u claude shane/agora-lite
```

To bring in later research from the evaluator: `git fetch jskidanov && git merge jskidanov/research/agora-lite-handoff`.

When everyone agrees the work is done, merge through a pull request from `shane/agora-lite` into `main`. In that merge, delete the "Research Branch Notice" sections from `CLAUDE.md` and `AGENTS.md`, run every check in `CLAUDE.md`, then push `main`.

`CLAUDE.md` and `AGENTS.md` on this branch carry a notice that points agents here and stops them from pushing to `main` early.

---

## Where things stand

| Area | Status on October 25, 2026 |
|---|---|
| Production backend | `https://agora-api-production-0aa0.up.railway.app/health` returned `404 Application not found`. Build 5 falls back to analyzing on the phone. |
| Simulator test | "Being in the Way, Ep. 40 – Nature of Consciousness" (28.7 min, feed has no transcript tags): Whisper produced a complete 4,634-word timed transcript, then question writing failed with "The AI returned an unreadable response." Zero prompts saved. |
| Likely cause | The phone pipeline caps curation at 10,000 tokens while asking gpt-5.6-terra for high reasoning (`Sources/OpenRouterClient.swift:316–317`). Reasoning tokens can use the whole cap, leaving empty or truncated JSON. Not yet confirmed; check the request's finish reason at openrouter.ai/activity. |
| Infrastructure | Scales with modest changes (Postgres queue with `SKIP LOCKED`, claim tokens, heartbeats). |
| Main constraints | Cost per episode (~$0.40–0.80 on the default tier, paid by each listener) and onboarding (every listener must fund an OpenRouter account). |

---

## Decisions made

1. **MCP strategy dropped.** Letting listeners bring their Claude or ChatGPT plan through an MCP connector works only as a chat the listener starts, can't grade in real time, and servers can't use a listener's subscription under Anthropic's and OpenAI's policies. MCP sampling was deprecated in the 2026-07-28 spec. Details are kept in `findings-2026-10-25.md` section 7 for reference.
2. **Direction: "Agora Lite" on Google Cloud.** Cloud Run service plus a Cloud Run job per episode, Cloud SQL Postgres, Secret Manager, models through OpenRouter (or Vertex AI). Full plan: `gcp-small-scale-testing.md`.
3. **Transcription: prefer open-source models.** Qwen3-ASR-1.7B (Apache-2.0) is the most accurate open model and costs the same as Whisper large-v3 on OpenRouter ($0.0288/hour, `qwen/qwen3-asr-1.7b`).
4. **Client: keep SwiftUI.** Move all pipeline logic to the server so any future client stays thin; retire the duplicate Swift pipeline.

## Decisions Shane needs to make

1. **Project-paid AI for testing?** The repo forbids an Agora-owned AI key. A capped OpenRouter key kept in Secret Manager would let testers skip OpenRouter sign-up (~3–6¢ per episode). Otherwise testers keep using the app's OpenRouter sign-in.
2. **Google Cloud project and billing account** for the Agora Lite sandbox.
3. **Railway:** is the production service gone, renamed, or paused?
4. **Shared transcript cache:** the privacy policy promises deletion of cloud job records within 7 days; caching transcripts across listeners needs a policy update.
5. **Repo access** for the evaluator (`Jskidanov`) if this work should continue in the shared repo directly.

---

## Next steps (in order)

Each step lists where to work and how to know it's done. Estimates assume someone familiar with the codebase.

| # | Step | Where | Done when | Estimate |
|---|---|---|---|---|
| 1 | Fix the phone-path token cap: raise `max_tokens` for curation and extraction, or lower `reasoning.effort`, so reasoning can't consume the whole budget | `Sources/OpenRouterClient.swift:222`, `:316–317` | Re-importing the Ep. 40 test episode saves a summary and at least 4 prompts | 1–2 h |
| 2 | Transcription A/B script: transcribe one real episode with `openai/whisper-large-v3` and `qwen/qwen3-asr-1.7b` through OpenRouter (`verbose_json`, segment and word granularity) | new `Backend/scripts/compare-transcription-models.mjs` | Both transcripts saved side by side; segment timestamps present for both; decision recorded in `findings` | 2–3 h |
| 3 | Allow non-Whisper speech models behind config | `Backend/src/openAIClient.ts:16`, `Sources/OpenRouterClient.swift:957` | Tests pass with a non-Whisper model ID that returns segments | 2–4 h |
| 4 | Cheap-model quality test: run the curation harness with `anthropic/claude-haiku-5.5` and `openai/gpt-6-luna`; let the extraction model follow the listener's tier | `Backend/scripts/compare-curation-models.mjs`, `Backend/src/analysisService.ts:74–76` | Pass rate on the real gates compared against gpt-5.6-terra | 2–4 h |
| 5 | Agora Lite entrypoints: split `api` (no worker loop) from `analyze-job` (process one `JOB_ID`, exit); start a Cloud Run job execution after inserting a job | `Backend/src/server.ts`, new `Backend/src/analyzeJob.ts`, `Backend/src/app.ts` | `npm run check` passes; local run processes one job end to end | 1 day |
| 6 | Deploy the sandbox and smoke-test three real episodes | Google Cloud (see the deployment sketch in `gcp-small-scale-testing.md`) | App pointed at the Cloud Run URL produces timed questions for all three | 0.5–1 day |

---

## Rules for work on this branch

- Commit to the current working branch (for Shane, `shane/agora-lite`) and push with `git push claude HEAD:<current branch name>`. Never push to `main` or merge into it until the team agrees.
- Never commit `.env` files, provider keys, or service-account keys; secrets go in Secret Manager.
- Run the checks in `CLAUDE.md` before committing code (`npm run check` in `Backend`, the iOS build).
- Keep iOS 16 compatibility.
- Record new findings in `findings-2026-10-25.md` (or a new dated file) and update the README index.

---

## Files

| File | What it holds |
|---|---|
| `HANDOFF.md` | This entry point: status, decisions, next steps |
| `findings-2026-10-25.md` | All research notes: code review, simulator test, costs, transcription, media sources, MCP (dropped), on-device AI, platform advice, sources |
| `gcp-small-scale-testing.md` | The Agora Lite plan: architecture, service-to-service flow, trade-offs, monthly cost, build plan, deployment sketch, price data |
| `agora-scale-review-2026-10-25.html` | Designed scale-review page (open in a browser); its MCP sections are superseded |
