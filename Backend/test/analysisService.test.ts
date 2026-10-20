import { describe, expect, it } from "vitest";
import { transcriptAppearsComplete } from "../src/analysisService.js";

describe("transcript completeness", () => {
  it("rejects a third of a one-hour episode instead of claiming it is complete", () => {
    expect(transcriptAppearsComplete(Array.from({ length: 3500 }, () => "discussion").join(" "), 3600)).toBe(false);
  });
  it("rejects show notes presented as a transcript for a long episode", () => {
    const showNotes = Array.from({ length: 500 }, () => "summary").join(" ");
    expect(transcriptAppearsComplete(showNotes, 54 * 60 + 6)).toBe(false);
  });

  it("accepts a plausible full transcript for a long episode", () => {
    const transcript = Array.from({ length: 4_500 }, () => "discussion").join(" ");
    expect(transcriptAppearsComplete(transcript, 54 * 60 + 6)).toBe(true);
  });
});
