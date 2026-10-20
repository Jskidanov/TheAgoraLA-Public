# Agora Cloud Analysis

This service runs long podcast transcription and prompt generation outside the iPhone process. A submitted job continues when the listener backgrounds or closes the app. The phone sends only episode metadata and a provider credential; the server fetches published transcripts or audio over its own connection.

## Processing pipeline

- Published RSS transcripts are preferred and normalized from JSON, WebVTT, SRT, HTML, or plain text, avoiding transcription entirely when possible.
- Audio is downloaded by the server, split only when needed, and transcribed concurrently while preserving episode order.
- Transcript sections are scanned concurrently by the extraction model. Exact quotes are validated against the full transcript before one high-reasoning curation pass selects the final summary and prompts.
- `TRANSCRIPTION_CONCURRENCY` and `ANALYSIS_CONCURRENCY` bound parallel requests so deployments can tune latency without weakening quality checks.
- `JOB_WORKER_CONCURRENCY` lets a small number of backlog episodes advance together while preserving the full quality pipeline for each one.

## Privacy and billing

- Each request uses the listener's OpenRouter credential. The Agora does not provide or pay for AI usage.
- Credentials are encrypted with AES-256-GCM before entering PostgreSQL, decrypted only in worker memory, and erased when a job completes or fails.
- All cloud-job records expire after `JOB_RETENTION_DAYS` from creation (seven days by default), regardless of acknowledgement. Cleanup runs at startup and every minute. Provider credentials are also removed on completion, failure or cancellation.

## Verified Audio Timing

Analysis preserves publisher caption timestamps when the full timeline is present. Otherwise the worker transcribes every eight-minute audio part using timestamp-capable Whisper, verifies each part against its measured audio duration, and offsets timestamps onto the full episode timeline. Questions are scheduled after their actual supporting passages; model-supplied timestamps are not trusted. Incomplete or untimed results fail clearly rather than becoming ready episodes. The extraction and final editorial-review models remain unchanged.

Older deployments configured with a JSON-only transcription model automatically use `openai/whisper-large-v3` for timed analysis. Set `OPENAI_TRANSCRIPTION_MODEL` to a compatible Whisper model; `/health` now also checks database connectivity.
- The API never returns provider credentials and Fastify request-body logging is not enabled.
- Anonymous installation sessions avoid requiring an Agora account or Sign in with Apple.

## Deploy

1. Provision PostgreSQL and a container host that supports long-running workers, at least 2 GB RAM, persistent outbound HTTPS, and FFmpeg. Google Cloud Run with minimum instances, Railway, Render, or Fly.io are suitable; request-based serverless functions are not.
2. Copy `.env.example` into the host's secret manager. Generate independent values for `AGORA_SESSION_SECRET` and `PROVIDER_CREDENTIAL_ENCRYPTION_KEY`.
3. Deploy `Backend/Dockerfile`. Its startup command runs all ordered SQL migrations before starting the API and worker.
4. Confirm `GET /health` returns `{ "status": "ok" }` over HTTPS.
5. Set the iOS target build setting `AGORA_API_BASE_URL` to that HTTPS origin, for example `https://api.example.org`, then rebuild the app.

Generate secrets locally with `openssl rand -hex 32`. Do not place `.env`, database credentials, provider keys, or production secrets in source control.

## Verify

Run `npm run check`, then submit a test episode, close the iOS app after it reports that cloud analysis is running, and reopen the editor after the job completes. Verify that the transcript, summary, and prompts appear without resubmitting.
