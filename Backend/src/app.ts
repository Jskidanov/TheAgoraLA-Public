import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import Fastify from "fastify";
import rateLimit from "@fastify/rate-limit";
import { z } from "zod";
import type { AppConfig } from "./config.js";
import type { Database } from "./database.js";
import { creditBalance, withTransaction } from "./database.js";
import { createSessionToken, verifyAppleIdentityToken, verifySessionToken } from "./auth.js";
import { verifyAppleNotification, verifyApplePurchase } from "./appleBilling.js";
import {
  decryptAppleToken,
  encryptAppleToken,
  exchangeAppleAuthorizationCode,
  revokeAppleRefreshToken,
} from "./appleOAuth.js";
import { AgoraOpenAI } from "./openAIClient.js";
import { encryptProviderCredential } from "./providerCredential.js";
import { graciousGradingInstructions, graciousScore, type UnderstandingLevel } from "./gradingPolicy.js";

const appleSignInSchema = z.object({
  identity_token: z.string().min(20),
  authorization_code: z.string().min(1),
  nonce: z.string().min(16),
  email: z.string().email().optional(),
  display_name: z.string().trim().min(1).max(120).optional(),
});

const analysisJobSchema = z.object({
  title: z.string().trim().max(300).optional(),
  audio_url: z.string().url().startsWith("https://").optional(),
  transcript: z.string().max(2_000_000).optional(),
  transcript_url: z.string().url().startsWith("https://").max(2_000).optional(),
  transcript_type: z.string().trim().max(120).optional(),
  duration: z.number().positive().max(86_400).optional(),
  prompt_count: z.number().int().min(3).max(12).optional(),
  model: z.string().trim().min(3).max(150).optional(),
  force_refresh: z.boolean().optional().default(false),
  provider_api_key: z.string().trim().startsWith("sk-or-").max(500),
}).refine(
  (value) => Boolean(value.audio_url || value.transcript || value.transcript_url),
  "An audio URL, transcript, or published transcript URL is required.",
);

const scoreSchema = z.object({
  question: z.string().min(5).max(500),
  expected_answer: z.string().min(5).max(4_000),
  user_answer: z.string().min(1).max(4_000),
  provider_api_key: z.string().trim().startsWith("sk-or-").max(500),
});

const publicDirectory = new URL("../public/", import.meta.url);
const analysisPipelineVersion = "2026-10-08.verified-timing";

interface AnalysisJobRow {
  id: string;
  status: string;
  result: unknown;
  error: string | null;
  created_at: Date;
  completed_at: Date | null;
}

export function buildApp(options: { config: AppConfig; database: Database }) {
  const { config, database } = options;
  const app = Fastify({ logger: true, bodyLimit: 2_500_000, trustProxy: true });

  void app.register(rateLimit, { max: 120, timeWindow: "1 minute" });
  app.addHook("onSend", async (request, reply, payload) => {
    reply.header("X-Request-ID", request.id);
    reply.header("Cache-Control", "no-store");
    return payload;
  });

  app.get("/health", async (_request, reply) => {
    try {
      await database.query("SELECT 1");
      return { status: "ok", database: "available" };
    } catch {
      return reply.code(503).send({ status: "unavailable", database: "unavailable" });
    }
  });

  app.get("/privacy", async (_request, reply) => {
    return reply.type("text/html; charset=utf-8").send(await readFile(new URL("privacy.html", publicDirectory), "utf8"));
  });

  app.get("/terms", async (_request, reply) => {
    return reply.type("text/html; charset=utf-8").send(await readFile(new URL("terms.html", publicDirectory), "utf8"));
  });

  app.get("/support", async (_request, reply) => {
    return reply.type("text/html; charset=utf-8").send(await readFile(new URL("support.html", publicDirectory), "utf8"));
  });

  app.get("/legal.css", async (_request, reply) => {
    return reply.type("text/css; charset=utf-8").send(await readFile(new URL("legal.css", publicDirectory), "utf8"));
  });

  app.post("/v1/auth/apple", async (request, reply) => {
    const body = appleSignInSchema.parse(request.body);
    const identity = await verifyAppleIdentityToken(body.identity_token, body.nonce, config);
    const encryptedRefreshToken = encryptAppleToken(
      await exchangeAppleAuthorizationCode(body.authorization_code, config),
      config,
    );
    const result = await database.query<{ id: string; email: string | null; display_name: string | null }>(
      `INSERT INTO users(apple_subject, email, display_name, apple_refresh_token_encrypted)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (apple_subject) DO UPDATE SET
         email = COALESCE(users.email, EXCLUDED.email),
         display_name = COALESCE(users.display_name, EXCLUDED.display_name),
         apple_refresh_token_encrypted = EXCLUDED.apple_refresh_token_encrypted,
         updated_at = NOW()
       RETURNING id, email, display_name`,
      [identity.subject, identity.email ?? body.email ?? null, body.display_name ?? null, encryptedRefreshToken],
    );
    const user = result.rows[0];
    if (!user) return reply.code(500).send({ error: "Account creation failed." });
    if (config.welcomeCredits > 0) {
      await database.query(
        `INSERT INTO credit_ledger(user_id, delta, reason, reference)
         VALUES ($1, $2, 'welcome', $3)
         ON CONFLICT (reference) DO NOTHING`,
        [user.id, config.welcomeCredits, `welcome:${user.id}`],
      );
    }
    return {
      token: await createSessionToken(user.id, config),
      user: { id: user.id, email: user.email, display_name: user.display_name },
      credits: await creditBalance(database, user.id),
    };
  });

  app.post("/v1/auth/dev", async (request, reply) => {
    if (!config.allowDevAuth || config.nodeEnv === "production") return reply.code(404).send({ error: "Not found." });
    const body = z.object({ name: z.string().trim().min(1).max(80).default("Local Tester") }).parse(request.body ?? {});
    const result = await database.query<{ id: string; display_name: string }>(
      `INSERT INTO users(apple_subject, display_name)
       VALUES ($1, $2)
       ON CONFLICT (apple_subject) DO UPDATE SET display_name = EXCLUDED.display_name
       RETURNING id, display_name`,
      ["dev-local-account", body.name],
    );
    const user = result.rows[0];
    if (!user) return reply.code(500).send({ error: "Development account failed." });
    await database.query(
      `INSERT INTO credit_ledger(user_id, delta, reason, reference)
       VALUES ($1, $2, 'development', $3)
       ON CONFLICT (reference) DO NOTHING`,
      [user.id, Math.max(config.welcomeCredits, 5), `development:${user.id}`],
    );
    return {
      token: await createSessionToken(user.id, config),
      user: { id: user.id, email: null, display_name: user.display_name },
      credits: await creditBalance(database, user.id),
    };
  });

  app.post("/v1/auth/device", { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } }, async (request) => {
    const { installation_id } = z.object({ installation_id: z.string().uuid() }).parse(request.body);
    const subject = `device:${createHash("sha256").update(`${installation_id}:${config.sessionSecret}`).digest("hex")}`;
    const result = await database.query<{ id: string }>(
      `INSERT INTO users(apple_subject, display_name)
       VALUES ($1, 'Agora Listener')
       ON CONFLICT (apple_subject) DO UPDATE SET updated_at = NOW()
       RETURNING id`,
      [subject],
    );
    const user = result.rows[0];
    if (!user) throw new Error("Device session creation failed.");
    return { token: await createSessionToken(user.id, config) };
  });

  app.get("/v1/me", async (request) => {
    const session = await requireSession(request.headers.authorization, config);
    const result = await database.query<{ id: string; email: string | null; display_name: string | null }>(
      "SELECT id, email, display_name FROM users WHERE id = $1",
      [session.userID],
    );
    const user = result.rows[0];
    if (!user) throw unauthorizedError();
    return { user, credits: await creditBalance(database, session.userID) };
  });

  app.delete("/v1/me", async (request, reply) => {
    const session = await requireSession(request.headers.authorization, config);
    const tokenResult = await database.query<{ apple_refresh_token_encrypted: string | null }>(
      "SELECT apple_refresh_token_encrypted FROM users WHERE id = $1",
      [session.userID],
    );
    const encryptedToken = tokenResult.rows[0]?.apple_refresh_token_encrypted;
    if (encryptedToken) {
      try {
        await revokeAppleRefreshToken(decryptAppleToken(encryptedToken, config), config);
      } catch (error) {
        request.log.error(error, "Apple token revocation failed during account deletion");
      }
    }
    await database.query("DELETE FROM users WHERE id = $1", [session.userID]);
    return reply.code(204).send();
  });

  app.post("/v1/billing/apple", async (request, reply) => {
    const session = await requireSession(request.headers.authorization, config);
    const { signed_transaction } = z.object({ signed_transaction: z.string().min(50) }).parse(request.body);
    const purchase = await verifyApplePurchase(signed_transaction, config);
    const grant = config.creditProductGrants.get(purchase.productID);
    if (!grant) return reply.code(400).send({ error: "This App Store product is not configured for Agora credits." });
    if (purchase.appAccountToken && purchase.appAccountToken.toLowerCase() !== session.userID.toLowerCase()) {
      return reply.code(403).send({ error: "This purchase belongs to a different Agora account." });
    }
    await withTransaction(database, async (client) => {
      const inserted = await client.query(
        `INSERT INTO purchase_transactions(
           transaction_id, original_transaction_id, user_id, product_id, environment, purchased_at, raw_payload
         ) VALUES ($1, $2, $3, $4, $5, $6, $7)
         ON CONFLICT (transaction_id) DO NOTHING
         RETURNING transaction_id`,
        [
          purchase.transactionID, purchase.originalTransactionID ?? null, session.userID, purchase.productID,
          purchase.environment, purchase.purchaseDate ?? null, JSON.stringify(purchase.rawPayload),
        ],
      );
      if ((inserted.rowCount ?? 0) > 0) {
        await client.query(
          `INSERT INTO credit_ledger(user_id, delta, reason, reference, metadata)
           VALUES ($1, $2, 'app_store_purchase', $3, $4)`,
          [session.userID, grant, `app-store:${purchase.transactionID}`, JSON.stringify({ product_id: purchase.productID })],
        );
      }
    });
    return { credits: await creditBalance(database, session.userID) };
  });

  app.post("/v1/billing/apple/notifications", async (request, reply) => {
    const { signedPayload } = z.object({ signedPayload: z.string().min(50) }).parse(request.body);
    const notification = await verifyAppleNotification(signedPayload, config);
    if (!notification.transactionID || !notification.productID) {
      return reply.code(200).send({ received: true });
    }
    const grant = config.creditProductGrants.get(notification.productID);
    if (!grant) return reply.code(200).send({ received: true });
    const purchase = await database.query<{ user_id: string }>(
      "SELECT user_id FROM purchase_transactions WHERE transaction_id = $1",
      [notification.transactionID],
    );
    const userID = purchase.rows[0]?.user_id;
    if (!userID) return reply.code(200).send({ received: true });

    if (notification.notificationType === "REFUND" || notification.notificationType === "REVOKE") {
      await database.query(
        `INSERT INTO credit_ledger(user_id, delta, reason, reference, metadata)
         VALUES ($1, $2, 'app_store_refund', $3, $4)
         ON CONFLICT (reference) DO NOTHING`,
        [userID, -grant, `app-store-refund:${notification.transactionID}`, JSON.stringify(notification)],
      );
    } else if (notification.notificationType === "REFUND_REVERSED") {
      await database.query(
        `INSERT INTO credit_ledger(user_id, delta, reason, reference, metadata)
         SELECT $1, $2, 'app_store_refund_reversed', $3, $4
         WHERE EXISTS (SELECT 1 FROM credit_ledger WHERE reference = $5)
         ON CONFLICT (reference) DO NOTHING`,
        [
          userID, grant, `app-store-refund-reversed:${notification.transactionID}`,
          JSON.stringify(notification), `app-store-refund:${notification.transactionID}`,
        ],
      );
    }
    return reply.code(200).send({ received: true });
  });

  app.post("/v1/episode-jobs", { config: { rateLimit: { max: 12, timeWindow: "1 minute" } } }, async (request, reply) => {
    const session = await requireSession(request.headers.authorization, config);
    const parsed = analysisJobSchema.parse(request.body);
    const { provider_api_key: providerAPIKey, force_refresh: forceRefresh, ...input } = parsed;
    const sourceHash = createHash("sha256").update(JSON.stringify({
      pipeline_version: analysisPipelineVersion,
      title: input.title?.replace(/\s+/g, " ").trim() ?? null,
      audio_url: input.audio_url ?? null,
      transcript: input.transcript?.replace(/\s+/g, " ").trim() ?? null,
      transcript_url: input.transcript_url ?? null,
      transcript_type: input.transcript_type ?? null,
      duration: input.duration ?? null,
      prompt_count: input.prompt_count ?? null,
      model: input.model ?? null,
    })).digest("hex");
    const jobID = randomUUID();
    let existingJob: AnalysisJobRow | undefined;
    try {
      await withTransaction(database, async (client) => {
        await client.query("SELECT id FROM users WHERE id = $1 FOR UPDATE", [session.userID]);
        const existing = forceRefresh ? { rows: [] as AnalysisJobRow[] } : await client.query<AnalysisJobRow>(
          `SELECT id, status, result, error, created_at, completed_at
           FROM analysis_jobs
           WHERE user_id = $1 AND source_hash = $2 AND status IN ('queued', 'processing', 'complete')
           ORDER BY CASE WHEN status = 'complete' THEN 0 ELSE 1 END, created_at DESC
           LIMIT 1`,
          [session.userID, sourceHash],
        );
        existingJob = existing.rows[0];
        if (existingJob) {
          // A fresh consumer must save this result before its retention clock starts.
          await client.query("UPDATE analysis_jobs SET acknowledged_at = NULL WHERE id = $1", [existingJob.id]);
          return;
        }
        await client.query(
          `INSERT INTO analysis_jobs(
             id, user_id, source_hash, status, input, credit_cost, provider_credential_encrypted
           ) VALUES ($1, $2, $3, 'queued', $4, 0, $5)`,
          [jobID, session.userID, sourceHash, JSON.stringify(input), encryptProviderCredential(providerAPIKey, config)],
        );
      });
    } catch (error) {
      if (isStatusError(error, 402)) return reply.code(402).send({ error: error.message });
      throw error;
    }
    if (existingJob) {
      const response = { ...existingJob, cached: existingJob.status === "complete" };
      return existingJob.status === "complete" ? response : reply.code(202).send(response);
    }
    return reply.code(202).send({ id: jobID, status: "queued", cached: false });
  });

  app.post("/v1/episode-jobs/:id/acknowledge", async (request, reply) => {
    const session = await requireSession(request.headers.authorization, config);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const result = await database.query(
      `UPDATE analysis_jobs SET acknowledged_at = COALESCE(acknowledged_at, NOW())
       WHERE id = $1 AND user_id = $2 AND status = 'complete' RETURNING id`,
      [id, session.userID],
    );
    if (!result.rows[0]) return reply.code(404).send({ error: "Completed analysis job not found." });
    return { saved: true };
  });

  app.post("/v1/episode-jobs/:id/cancel", async (request, reply) => {
    const session = await requireSession(request.headers.authorization, config);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const result = await database.query(
      `UPDATE analysis_jobs SET status = 'failed', error = 'Canceled by you.',
       provider_credential_encrypted = NULL, claim_token = NULL,
       completed_at = NOW(), updated_at = NOW()
       WHERE id = $1 AND user_id = $2 AND status IN ('queued', 'processing') RETURNING id`,
      [id, session.userID],
    );
    if (!result.rows[0]) {
      const existing = await database.query("SELECT id FROM analysis_jobs WHERE id = $1 AND user_id = $2", [id, session.userID]);
      if (!existing.rows[0]) return reply.code(404).send({ error: "Analysis job not found." });
    }
    return { canceled: true };
  });

  app.get("/v1/episode-jobs/:id", async (request, reply) => {
    const session = await requireSession(request.headers.authorization, config);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const result = await database.query(
      `SELECT id, status, result, error, created_at, completed_at
       FROM analysis_jobs WHERE id = $1 AND user_id = $2`,
      [id, session.userID],
    );
    if (!result.rows[0]) return reply.code(404).send({ error: "Analysis job not found." });
    return result.rows[0];
  });

  app.post("/v1/answers/score", { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } }, async (request) => {
    const session = await requireSession(request.headers.authorization, config);
    const body = scoreSchema.parse(request.body);
    const promptAccess = await database.query<{ allowed: boolean }>(
      `SELECT EXISTS (
         SELECT 1
         FROM analysis_jobs jobs
         CROSS JOIN LATERAL jsonb_array_elements(COALESCE(jobs.result->'prompts', '[]'::jsonb)) prompt
         WHERE jobs.user_id = $1
           AND jobs.status = 'complete'
           AND prompt->>'question' = $2
           AND prompt->>'expected_answer' = $3
       ) AS allowed`,
      [session.userID, body.question, body.expected_answer],
    );
    if (!promptAccess.rows[0]?.allowed) {
      throw statusError(403, "This question is not part of your completed Agora analysis.");
    }
    const dailyUsage = await database.query<{ count: string }>(
      `SELECT COUNT(*)::text AS count FROM answer_scores
       WHERE user_id = $1 AND created_at >= NOW() - INTERVAL '24 hours'`,
      [session.userID],
    );
    if (Number(dailyUsage.rows[0]?.count ?? 0) >= config.dailyScoreLimit) {
      throw statusError(429, "You reached today's answer-feedback limit. Please try again later.");
    }
    const listenerAI = new AgoraOpenAI(config, body.provider_api_key, "https://openrouter.ai/api/v1");
    const response = await listenerAI.structured<{ understanding: UnderstandingLevel; score: number; feedback: string }>({
      model: config.models.scoring,
      safetyID: createHash("sha256").update(session.userID).digest("hex"),
      effort: "low",
      schemaName: "listener_answer_score",
      schema: {
        type: "object", additionalProperties: false, required: ["understanding", "score", "feedback"],
        properties: {
          understanding: { type: "string", enum: ["correct", "mostly_correct", "partial", "incorrect"] },
          score: { type: "integer", minimum: 0, maximum: 100 },
          feedback: { type: "string" },
        },
      },
      instructions: graciousGradingInstructions,
      input: `Question: ${body.question}\nPodcast-supported answer: ${body.expected_answer}\nListener answer: ${body.user_answer}`,
    });
    const boundedScore = graciousScore(response.score, response.understanding);
    await database.query(
      "INSERT INTO answer_scores(user_id, question_hash, score, model_version) VALUES ($1, $2, $3, $4)",
      [session.userID, createHash("sha256").update(body.question).digest("hex"), boundedScore, config.models.scoring],
    );
    return { score: boundedScore, feedback: response.feedback };
  });

  app.setErrorHandler((error, request, reply) => {
    request.log.error(error);
    if (error instanceof z.ZodError) {
      return reply.code(400).send({ error: "The request is invalid.", request_id: request.id });
    }
    if (isStatusError(error, 401)) {
      return reply.code(401).send({ error: error.message, request_id: request.id });
    }
    if (isClientStatusError(error)) {
      return reply.code(error.statusCode).send({ error: error.message, request_id: request.id });
    }
    return reply.code(500).send({ error: "The Agora service could not complete this request.", request_id: request.id });
  });

  return app;
}

async function requireSession(authorization: string | undefined, config: AppConfig) {
  if (!authorization?.startsWith("Bearer ")) throw unauthorizedError();
  try {
    return await verifySessionToken(authorization.slice(7), config);
  } catch {
    throw unauthorizedError();
  }
}

function unauthorizedError() {
  return statusError(401, "Sign in to your Agora account again.");
}

function statusError(statusCode: number, message: string): Error & { statusCode: number } {
  return Object.assign(new Error(message), { statusCode });
}

function isStatusError(error: unknown, statusCode: number): error is Error & { statusCode: number } {
  return error instanceof Error && "statusCode" in error && error.statusCode === statusCode;
}

function isClientStatusError(error: unknown): error is Error & { statusCode: number } {
  return error instanceof Error
    && "statusCode" in error
    && typeof error.statusCode === "number"
    && error.statusCode >= 400
    && error.statusCode < 500;
}
