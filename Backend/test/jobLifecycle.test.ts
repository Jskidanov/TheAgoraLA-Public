import { describe, expect, it, vi } from "vitest";
import type { AppConfig } from "../src/config.js";
import type { Database } from "../src/database.js";
import { buildApp } from "../src/app.js";
import { deleteExpiredJobs } from "../src/worker.js";

vi.mock("../src/auth.js", () => ({
  verifySessionToken: vi.fn(async () => ({ userID: "owner" })),
  createSessionToken: vi.fn(),
  verifyAppleIdentityToken: vi.fn(),
}));

const id = "b6dbb1f3-3f1d-4b60-9d13-d4d0f2c61ff8";

describe("cloud job lifecycle", () => {
  it("reports database failures instead of advertising a healthy cloud service", async () => {
    const query = vi.fn().mockRejectedValue(new Error("Database unavailable"));
    const app = buildApp({ config: {} as AppConfig, database: { query } as unknown as Database });
    try {
      const response = await app.inject({ method: "GET", url: "/health" });
      expect(response.statusCode).toBe(503);
      expect(response.json()).toEqual({ status: "unavailable", database: "unavailable" });
    } finally { await app.close(); }
  });

  it("requires an authenticated owner before canceling", async () => {
    const query = vi.fn().mockResolvedValue({ rows: [{ id }], rowCount: 1 });
    const app = buildApp({ config: {} as AppConfig, database: { query } as unknown as Database });
    try {
      const rejected = await app.inject({ method: "POST", url: `/v1/episode-jobs/${id}/cancel` });
      expect(rejected.statusCode).toBe(401);
      expect(query).not.toHaveBeenCalled();
      const accepted = await app.inject({ method: "POST", url: `/v1/episode-jobs/${id}/cancel`, headers: { authorization: "Bearer test" } });
      expect(accepted.statusCode).toBe(200);
      expect(query.mock.calls[0]?.[1]).toEqual([id, "owner"]);
      expect(query.mock.calls[0]?.[0]).toContain("claim_token = NULL");
      expect(query.mock.calls[0]?.[0]).toContain("provider_credential_encrypted = NULL");
    } finally { await app.close(); }
  });

  it("does not acknowledge another user's or unfinished result", async () => {
    const query = vi.fn().mockResolvedValue({ rows: [], rowCount: 0 });
    const app = buildApp({ config: {} as AppConfig, database: { query } as unknown as Database });
    try {
      const response = await app.inject({ method: "POST", url: `/v1/episode-jobs/${id}/acknowledge`, headers: { authorization: "Bearer test" } });
      expect(response.statusCode).toBe(404);
      expect(query.mock.calls[0]?.[0]).toContain("status = 'complete'");
      expect(query.mock.calls[0]?.[1]).toEqual([id, "owner"]);
    } finally { await app.close(); }
  });

  it("expires every job after the promised retention window, even without acknowledgement", async () => {
    const query = vi.fn().mockResolvedValue({ rows: [], rowCount: 0 });
    await deleteExpiredJobs({ query } as unknown as Database, 7);
    const sql = query.mock.calls[0]?.[0];
    expect(sql).toContain("created_at < NOW() - make_interval(days => $1)");
    expect(sql).not.toContain("acknowledged_at");
  });
});
