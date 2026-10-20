import type { AppConfig } from "./config.js";
import type { Database } from "./database.js";
import { processEpisodeAnalysis, type AnalysisJobInput } from "./analysisService.js";
import { withTransaction } from "./database.js";
import { decryptProviderCredential } from "./providerCredential.js";
import { AgoraOpenAI } from "./openAIClient.js";

interface ClaimedJob {
  id: string;
  user_id: string;
  input: AnalysisJobInput;
  credit_cost: number;
  provider_credential_encrypted: string;
  claim_token: string;
}

export function startAnalysisWorker(database: Database, config: AppConfig) {
  let stopped = false;
  let claiming = false;
  const activeJobs = new Set<Promise<void>>();

  const tick = async () => {
    if (stopped || claiming || activeJobs.size >= config.jobWorkerConcurrency) return;
    claiming = true;
    try {
      while (!stopped && activeJobs.size < config.jobWorkerConcurrency) {
        const job = await claimNextJob(database);
        if (!job) break;
        const task = processClaimedJob(database, config, job)
          .catch((error) => console.error("Analysis worker job failed", error));
        activeJobs.add(task);
        void task.finally(() => {
          activeJobs.delete(task);
          runTick();
        });
      }
    } finally {
      claiming = false;
    }
  };

  const runTick = () => {
    void tick().catch((error) => console.error("Analysis worker tick failed", error));
  };
  const timer = setInterval(runTick, 1_000);
  const recoveryTimer = setInterval(() => {
    void requeueStaleJobs(database).catch((error) => console.error("Stale job recovery failed", error));
  }, 60_000);
  const retentionTimer = setInterval(() => {
    void deleteExpiredJobs(database, config.jobRetentionDays)
      .catch((error) => console.error("Expired job cleanup failed", error));
  }, 60_000);
  void deleteExpiredJobs(database, config.jobRetentionDays)
    .catch((error) => console.error("Initial expired job cleanup failed", error));
  void requeueStaleJobs(database).then(runTick).catch((error) => {
    console.error("Could not recover stale analysis jobs", error);
    runTick();
  });
  return async () => {
    stopped = true;
    clearInterval(timer);
    clearInterval(recoveryTimer);
    clearInterval(retentionTimer);
    await Promise.allSettled(Array.from(activeJobs));
  };
}

async function processClaimedJob(database: Database, config: AppConfig, job: ClaimedJob): Promise<void> {
  const controller = new AbortController();
  const heartbeat = setInterval(() => {
    void database.query(
      "UPDATE analysis_jobs SET updated_at = NOW() WHERE id = $1 AND status = 'processing' AND claim_token = $2",
      [job.id, job.claim_token],
    ).then((result) => {
      if (result.rowCount === 0) controller.abort();
    }).catch((error) => console.error("Analysis job heartbeat failed", error));
  }, 2_000);
  try {
    const providerKey = decryptProviderCredential(job.provider_credential_encrypted, config);
    const openAI = new AgoraOpenAI(config, providerKey, "https://openrouter.ai/api/v1", controller.signal);
    const result = await processEpisodeAnalysis({ input: job.input, userID: job.user_id, openAI, config });
    await database.query(
      `UPDATE analysis_jobs
       SET status = 'complete', result = $2, model_version = $3,
           provider_credential_encrypted = NULL, updated_at = NOW(), completed_at = NOW()
       WHERE id = $1 AND status = 'processing' AND claim_token = $4`,
      [
        job.id,
        JSON.stringify(result),
        `${config.models.transcription}+${config.models.extraction}+${job.input.model ?? config.models.curation}`,
        job.claim_token,
      ],
    );
  } catch (error) {
    const message = error instanceof Error ? error.message.slice(0, 1_000) : "Episode analysis failed.";
    await refundFailedJob(database, job, message);
  } finally {
    clearInterval(heartbeat);
  }
}

export async function deleteExpiredJobs(database: Database, retentionDays: number): Promise<void> {
  await database.query(
    `DELETE FROM analysis_jobs
     WHERE created_at < NOW() - make_interval(days => $1)`,
    [retentionDays],
  );
}

async function requeueStaleJobs(database: Database): Promise<void> {
  await database.query(
    `UPDATE analysis_jobs
     SET status = 'queued', claim_token = NULL, updated_at = NOW()
     WHERE status = 'processing' AND updated_at < NOW() - INTERVAL '3 minutes'`,
  );
}

async function claimNextJob(database: Database): Promise<ClaimedJob | undefined> {
  const result = await database.query<ClaimedJob>(
    `WITH next_job AS (
       SELECT id FROM analysis_jobs
       WHERE status = 'queued' AND provider_credential_encrypted IS NOT NULL
       ORDER BY created_at
       FOR UPDATE SKIP LOCKED
       LIMIT 1
     )
     UPDATE analysis_jobs AS jobs
     SET status = 'processing', claim_token = gen_random_uuid(), updated_at = NOW()
     FROM next_job
     WHERE jobs.id = next_job.id
     RETURNING jobs.id, jobs.user_id, jobs.input, jobs.credit_cost, jobs.provider_credential_encrypted, jobs.claim_token`,
  );
  return result.rows[0];
}

async function refundFailedJob(database: Database, job: ClaimedJob, message: string): Promise<void> {
  await withTransaction(database, async (client) => {
    const failed = await client.query(
      "UPDATE analysis_jobs SET status = 'failed', error = $2, provider_credential_encrypted = NULL, updated_at = NOW(), completed_at = NOW() WHERE id = $1 AND status = 'processing' AND claim_token = $3",
      [job.id, message, job.claim_token],
    );
    if (failed.rowCount !== 1) return;
    if (job.credit_cost <= 0) return;
    await client.query(
      `INSERT INTO credit_ledger(user_id, delta, reason, reference, metadata)
       VALUES ($1, $2, 'analysis_refund', $3, $4)
       ON CONFLICT (reference) DO NOTHING`,
      [job.user_id, job.credit_cost, `analysis-refund:${job.id}`, JSON.stringify({ job_id: job.id })],
    );
  });
}
