import { afterEach, describe, expect, it, vi } from "vitest";
import { lookup } from "node:dns/promises";
import { Agent } from "undici";
import { downloadRemoteTranscript, publicFetch } from "../src/transcription.js";

vi.mock("node:dns/promises", () => ({ lookup: vi.fn() }));
vi.mock("undici", () => ({ Agent: vi.fn(function () {
  return { close: vi.fn().mockResolvedValue(undefined), destroy: vi.fn().mockResolvedValue(undefined) };
}) }));

afterEach(() => { vi.unstubAllGlobals(); vi.clearAllMocks(); vi.mocked(lookup).mockReset(); });

describe("pinned public downloads", () => {
  it("uses the validated address for the connection instead of resolving it again", async () => {
    vi.mocked(lookup)
      .mockResolvedValueOnce([{ address: "8.8.8.8", family: 4 }])
      .mockResolvedValueOnce([{ address: "127.0.0.1", family: 4 }]);
    const fetch = vi.fn().mockResolvedValue(new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetch);
    await publicFetch(new URL("https://podcast.example/episode"), AbortSignal.timeout(1000));
    expect(lookup).toHaveBeenCalledTimes(1);
    const options = vi.mocked(Agent).mock.calls[0]![0]!;
    const callback = vi.fn();
    (options.connect as { lookup: Function }).lookup("podcast.example", { all: false }, callback);
    expect(callback).toHaveBeenCalledWith(null, "8.8.8.8", 4);
    expect(fetch.mock.calls[0]![1].redirect).toBe("manual");
  });

  it("rejects a redirect to a private destination before connecting to it", async () => {
    vi.mocked(lookup)
      .mockResolvedValueOnce([{ address: "8.8.8.8", family: 4 }])
      .mockResolvedValueOnce([{ address: "10.0.0.1", family: 4 }]);
    const fetch = vi.fn().mockResolvedValue(new Response(null, {
      status: 302, headers: { location: "https://internal.example/transcript" },
    }));
    vi.stubGlobal("fetch", fetch);
    await expect(downloadRemoteTranscript("https://podcast.example/transcript"))
      .rejects.toThrow("does not resolve to a public host");
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("closes the download connection when a response is rejected", async () => {
    vi.mocked(lookup).mockResolvedValueOnce([{ address: "8.8.8.8", family: 4 }]);
    const cancel = vi.fn();
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(new ReadableStream({ cancel }), {
      headers: { "content-type": "audio/mpeg" },
    })));
    await expect(downloadRemoteTranscript("https://podcast.example/transcript"))
      .rejects.toThrow("did not resolve to readable text");
    expect(cancel).toHaveBeenCalled();
  });
});
