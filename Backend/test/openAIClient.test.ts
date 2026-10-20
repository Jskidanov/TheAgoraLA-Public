import { afterEach, describe, expect, it, vi } from "vitest";
import type { AppConfig } from "../src/config.js";

const mocks = vi.hoisted(() => ({ transcribe: vi.fn() }));

vi.mock("openai", () => ({
  default: class MockOpenAI {
    audio = { transcriptions: { create: mocks.transcribe } };
  },
}));

import { AgoraOpenAI } from "../src/openAIClient.js";

afterEach(() => vi.clearAllMocks());

describe("AgoraOpenAI transcription", () => {
  it("uses a timestamp-capable model for old deployments configured with JSON-only transcription", async () => {
    const segments = [{ start: 0, end: 5, text: "A complete podcast transcript." }];
    mocks.transcribe.mockResolvedValue({ text: segments[0]!.text, duration: 5, segments });
    const client = new AgoraOpenAI({ models: { transcription: "openai/gpt-4o-mini-transcribe" } } as AppConfig, "test-key");
    await expect(client.transcribeTimed("/dev/null")).resolves.toEqual({ text: segments[0]!.text, duration: 5, segments });
    expect(mocks.transcribe).toHaveBeenCalledWith(expect.objectContaining({ model: "openai/whisper-large-v3", response_format: "verbose_json", timestamp_granularities: ["segment"] }), { signal: undefined });
  });

  it("rejects a transcription without usable audio timings", async () => {
    mocks.transcribe.mockResolvedValue({ text: "Text only", duration: 5 });
    const client = new AgoraOpenAI({ models: { transcription: "openai/whisper-large-v3" } } as AppConfig, "test-key");
    await expect(client.transcribeTimed("/dev/null")).rejects.toThrow("verified audio timestamps");
  });
  it("requests OpenRouter's supported JSON response format", async () => {
    mocks.transcribe.mockResolvedValue({ text: "A complete podcast transcript." });
    const config = {
      models: { transcription: "openai/gpt-4o-mini-transcribe" },
    } as AppConfig;
    const client = new AgoraOpenAI(config, "test-key", "https://openrouter.ai/api/v1");

    await expect(client.transcribe("/dev/null")).resolves.toBe("A complete podcast transcript.");
    expect(mocks.transcribe).toHaveBeenCalledWith(expect.objectContaining({
      model: "openai/gpt-4o-mini-transcribe",
      response_format: "json",
    }), { signal: undefined });
  });

  it("does not start another billed request after cancellation", async () => {
    const controller = new AbortController();
    controller.abort();
    const client = new AgoraOpenAI({ models: { transcription: "test" } } as AppConfig, "test-key", undefined, controller.signal);
    await expect(client.transcribe("/dev/null")).rejects.toThrow();
    expect(mocks.transcribe).not.toHaveBeenCalled();
  });

  it("passes cancellation to an in-flight provider request", async () => {
    const controller = new AbortController();
    mocks.transcribe.mockResolvedValue({ text: "Transcript" });
    const client = new AgoraOpenAI({ models: { transcription: "test" } } as AppConfig, "test-key", undefined, controller.signal);
    await client.transcribe("/dev/null");
    expect(mocks.transcribe.mock.calls[0]?.[1]).toEqual({ signal: controller.signal });
  });
});
