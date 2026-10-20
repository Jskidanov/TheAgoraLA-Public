import { z } from "zod";

const environmentSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  PORT: z.coerce.number().int().positive().default(8787),
  DATABASE_URL: z.string().min(1),
  DATABASE_SSL_MODE: z.enum(["disable", "require", "verify-full"]).default("verify-full"),
  AGORA_SESSION_SECRET: z.string().min(32),
  PROVIDER_CREDENTIAL_ENCRYPTION_KEY: z.string().regex(/^[0-9a-fA-F]{64}$/),
  APPLE_BUNDLE_ID: z.string().default("com.theagora.la"),
  APPLE_CLIENT_ID: z.string().optional(),
  APPLE_TEAM_ID: z.string().optional(),
  APPLE_KEY_ID: z.string().optional(),
  APPLE_PRIVATE_KEY: z.string().optional(),
  APPLE_PRIVATE_KEY_PATH: z.string().optional(),
  APPLE_TOKEN_ENCRYPTION_KEY: z.string().regex(/^[0-9a-fA-F]{64}$/).optional(),
  APPLE_ENVIRONMENT: z.enum(["Sandbox", "Production"]).default("Sandbox"),
  APPLE_APP_ID: z.string().optional(),
  APPLE_ROOT_CA_PATHS: z.string().default(""),
  WELCOME_CREDITS: z.coerce.number().int().min(0).default(0),
  DAILY_SCORE_LIMIT: z.coerce.number().int().positive().default(60),
  ALLOW_DEV_AUTH: z.string().default("false"),
  MAX_AUDIO_BYTES: z.coerce.number().int().positive().default(262_144_000),
  TRANSCRIPTION_CONCURRENCY: z.coerce.number().int().min(1).max(6).default(3),
  ANALYSIS_CONCURRENCY: z.coerce.number().int().min(1).max(8).default(4),
  JOB_WORKER_CONCURRENCY: z.coerce.number().int().min(1).max(4).default(2),
  JOB_RETENTION_DAYS: z.coerce.number().int().min(1).max(30).default(7),
  OPENAI_EXTRACTION_MODEL: z.string().default("openai/gpt-5.6-terra"),
  OPENAI_CURATION_MODEL: z.string().default("openai/gpt-6-astra"),
  OPENAI_SCORING_MODEL: z.string().default("openai/gpt-5.6-terra"),
  OPENAI_TRANSCRIPTION_MODEL: z.string().default("openai/whisper-large-v3"),
  CREDIT_PRODUCT_GRANTS: z.string().default(
    "com.theagora.la.credits.5:5,com.theagora.la.credits.20:22,com.theagora.la.credits.50:60",
  ),
});

export type AppConfig = ReturnType<typeof loadConfig>;

export function loadConfig() {
  const env = environmentSchema.parse(process.env);
  const creditProductGrants = new Map<string, number>();
  for (const entry of env.CREDIT_PRODUCT_GRANTS.split(",")) {
    const [productID, amount] = entry.trim().split(":");
    const parsedAmount = Number(amount);
    if (productID && Number.isInteger(parsedAmount) && parsedAmount > 0) {
      creditProductGrants.set(productID, parsedAmount);
    }
  }
  if (creditProductGrants.size === 0) {
    throw new Error("CREDIT_PRODUCT_GRANTS must contain at least one product.");
  }

  return {
    nodeEnv: env.NODE_ENV,
    port: env.PORT,
    databaseURL: env.DATABASE_URL,
    databaseSSLMode: env.DATABASE_SSL_MODE,
    sessionSecret: env.AGORA_SESSION_SECRET,
    providerCredentialEncryptionKey: env.PROVIDER_CREDENTIAL_ENCRYPTION_KEY,
    appleBundleID: env.APPLE_BUNDLE_ID,
    appleClientID: env.APPLE_CLIENT_ID,
    appleTeamID: env.APPLE_TEAM_ID,
    appleKeyID: env.APPLE_KEY_ID,
    applePrivateKey: env.APPLE_PRIVATE_KEY?.replace(/\\n/g, "\n"),
    applePrivateKeyPath: env.APPLE_PRIVATE_KEY_PATH,
    appleTokenEncryptionKey: env.APPLE_TOKEN_ENCRYPTION_KEY,
    appleEnvironment: env.APPLE_ENVIRONMENT,
    appleAppID: env.APPLE_APP_ID ? Number(env.APPLE_APP_ID) : undefined,
    appleRootCAPaths: env.APPLE_ROOT_CA_PATHS.split(",").map((value) => value.trim()).filter(Boolean),
    welcomeCredits: env.WELCOME_CREDITS,
    dailyScoreLimit: env.DAILY_SCORE_LIMIT,
    allowDevAuth: env.ALLOW_DEV_AUTH.toLowerCase() === "true",
    maxAudioBytes: env.MAX_AUDIO_BYTES,
    transcriptionConcurrency: env.TRANSCRIPTION_CONCURRENCY,
    analysisConcurrency: env.ANALYSIS_CONCURRENCY,
    jobWorkerConcurrency: env.JOB_WORKER_CONCURRENCY,
    jobRetentionDays: env.JOB_RETENTION_DAYS,
    models: {
      extraction: env.OPENAI_EXTRACTION_MODEL,
      curation: env.OPENAI_CURATION_MODEL,
      scoring: env.OPENAI_SCORING_MODEL,
      transcription: env.OPENAI_TRANSCRIPTION_MODEL,
    },
    creditProductGrants,
  };
}
