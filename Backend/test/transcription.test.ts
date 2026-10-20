import { describe, expect, it } from "vitest";
import { isPrivateAddress, normalizePublishedTranscript } from "../src/transcription.js";
import { parsePublishedSegments, evidenceEnd } from "../src/transcriptTiming.js";

describe("cloud audio network safety", () => {
  it("blocks private IPv4 and IPv4-mapped IPv6 destinations", () => {
    expect(isPrivateAddress("127.0.0.1")).toBe(true);
    expect(isPrivateAddress("10.2.3.4")).toBe(true);
    expect(isPrivateAddress("192.168.1.20")).toBe(true);
    expect(isPrivateAddress("::ffff:127.0.0.1")).toBe(true);
    expect(isPrivateAddress("::ffff:10.2.3.4")).toBe(true);
    expect(isPrivateAddress("::ffff:192.168.1.20")).toBe(true);
    expect(isPrivateAddress("::ffff:7f00:1")).toBe(true);
    expect(isPrivateAddress("fe90::1")).toBe(true);
    expect(isPrivateAddress("2001:db8::1")).toBe(true);
  });

  it("allows ordinary public addresses", () => {
    expect(isPrivateAddress("8.8.8.8")).toBe(false);
    expect(isPrivateAddress("2606:4700:4700::1111")).toBe(false);
  });

  it("blocks local and multicast IPv6 destinations", () => {
    expect(isPrivateAddress("::1")).toBe(true);
    expect(isPrivateAddress("fc00::1")).toBe(true);
    expect(isPrivateAddress("fe80::1")).toBe(true);
    expect(isPrivateAddress("ff02::1")).toBe(true);
  });
});

describe("published transcript normalization", () => {
  it("retains caption times for evidence spanning multiple cues", () => {
    const segments = parsePublishedSegments("WEBVTT\n\n1\n00:35:00.000 --> 00:35:03.000\nAttention lets another person's reasoning\n\n2\n00:35:03.000 --> 00:35:07.000\nchange your view of the argument.\n");
    expect(segments).toHaveLength(2);
    expect(evidenceEnd("Attention lets another person's reasoning change your view of the argument", segments)).toBe(2107);
  });
  it("preserves ordered speech from JSON transcript segments", () => {
    const data = Buffer.from(JSON.stringify({
      segments: [
        { start: 0, text: "The host introduces the central question." },
        { start: 4, text: "The guest answers it with a distinction." },
      ],
    }));
    expect(normalizePublishedTranscript(data, "application/json"))
      .toBe("The host introduces the central question. The guest answers it with a distinction.");
  });

  it("removes caption timing while keeping the spoken text", () => {
    const data = Buffer.from("WEBVTT\n\n1\n00:00:00.000 --> 00:00:03.000\nFirst important claim.\n\n2\n00:00:03.000 --> 00:00:07.000\nSecond supporting reason.");
    expect(normalizePublishedTranscript(data, "text/vtt"))
      .toBe("First important claim. Second supporting reason.");
  });

  it("removes HTML navigation and decodes transcript prose", () => {
    const data = Buffer.from("<html><style>hidden</style><body><p>Attention &amp; memory matter.</p><script>ignore()</script></body></html>");
    expect(normalizePublishedTranscript(data, "text/html"))
      .toBe("Attention & memory matter.");
  });
});
