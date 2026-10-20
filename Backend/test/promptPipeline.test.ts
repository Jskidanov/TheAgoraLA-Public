import { describe, expect, it } from "vitest";
import {
  minimumPromptCountForDuration,
  selectDistributedPrompts,
  validateAndRankPrompts,
  type EpisodePrompt,
} from "../src/promptPipeline.js";

const evidence = "The host argues that attention is a form of respect because it allows another person's reasoning to change your mind.";
const transcript = `${evidence} Later, the guest distinguishes passive hearing from active listening by requiring the listener to reconstruct the argument before responding.`;
const timed = [{ start: 30, end: 50, text: evidence }];

function prompt(overrides: Partial<EpisodePrompt> = {}): EpisodePrompt {
  return {
    time: 45,
    question: "Why does the host describe attention as a form of respect?",
    expected_answer: "Because genuine attention lets another person's reasoning affect and potentially change the listener's own view.",
    evidence: [{ quote: evidence, start_seconds: 30, end_seconds: 50 }],
    scores: {
      overall: 0.91,
      importance_to_listener: 0.9,
      episode_specificity: 0.88,
      answer_alignment: 0.92,
      grounding: 0.95,
    },
    passes_quality_gates: true,
    ...overrides,
  };
}

describe("prompt quality gates", () => {
  it("ignores invented early times and waits for real supporting audio", () => {
    const [result] = validateAndRankPrompts([prompt({ evidence: [{ quote: evidence, start_seconds: 0, end_seconds: 36 }] })], transcript, 3600,
      [{ start: 2100, end: 2140, text: evidence }]);
    expect(result?.time).toBe(2143);
    expect(result?.timing_verified).toBe(true);
  });

  it("never invents timing for an untimed transcript", () => {
    expect(validateAndRankPrompts([prompt()], transcript, 120, [])).toHaveLength(0);
  });
  it("waits until the supporting passage ends, even when it starts at zero", () => {
    const [result] = validateAndRankPrompts([prompt()], transcript, 120, timed);
    expect(result!.time).toBe(53);
  });

  it("uses the supplied evidence time when the same words occur earlier", () => {
    const repeatedTranscript = `${evidence} Some unrelated discussion. ${evidence}`;
    const [result] = validateAndRankPrompts([
      prompt({ evidence: [{ quote: evidence, start_seconds: 88, end_seconds: 104 }] }),
    ], repeatedTranscript, 120, [...timed, { start: 88, end: 104, text: evidence }]);
    expect(result!.time).toBe(107);
  });

  it("rejects a fabricated second passage even when the first is real", () => {
    const candidate = prompt();
    candidate.evidence.push({ quote: "Fabricated evidence about respect that never appeared in this episode at all.", start_seconds: 50, end_seconds: 60 });
    expect(validateAndRankPrompts([candidate], transcript, 120, timed)).toHaveLength(0);
  });

  it("keeps an episode-specific question with exact transcript evidence", () => {
    expect(validateAndRankPrompts([prompt()], transcript, 120, timed)).toHaveLength(1);
  });

  it("rejects stock questions even when the model marks them as passing", () => {
    const result = validateAndRankPrompts([prompt({ question: "What is the main idea of this episode?" })], transcript, 120, timed);
    expect(result).toHaveLength(0);
  });

  it("rejects evidence that does not occur in the transcript", () => {
    const result = validateAndRankPrompts([
      prompt({ evidence: [{ quote: "A fabricated quote that does not occur anywhere in the supplied podcast transcript.", start_seconds: 30, end_seconds: 50 }] }),
    ], transcript, 120, timed);
    expect(result).toHaveLength(0);
  });

  it("rejects an expected answer that is unrelated to the evidence", () => {
    const result = validateAndRankPrompts([
      prompt({ expected_answer: "The episode recommends buying specialized running shoes before beginning marathon training." }),
    ], transcript, 120, timed);
    expect(result).toHaveLength(0);
  });
});

describe("prompt distribution", () => {
  it("requires eight substantive checks for a 54-minute episode", () => {
    expect(minimumPromptCountForDuration(54 * 60 + 6)).toBe(8);
  });

  it("spreads similarly strong learning moments instead of clustering them", () => {
    const candidates = [
      prompt({
        time: 60,
        question: "Why is attentive listening described as respect for another person's reasoning?",
        expected_answer: "Attentive listening shows respect by treating another person's reasoning as worthy of serious consideration.",
      }),
      prompt({
        time: 72,
        question: "How can attention allow another person's reasoning to alter a listener's view?",
        expected_answer: "Attention leaves the listener genuinely open to changing a prior belief when the other person's reasoning warrants it.",
      }),
      prompt({
        time: 310,
        question: "What distinction does the guest draw between passive hearing and reconstructing an argument?",
        expected_answer: "Passive hearing merely receives words, while active listening reconstructs the speaker's argument before judging it.",
      }),
      prompt({
        time: 560,
        question: "Why does the concluding argument require listeners to reconstruct reasoning before responding?",
        expected_answer: "The conclusion says listeners should understand the complete chain of reasoning before they formulate a response.",
      }),
    ];
    const selected = selectDistributedPrompts(candidates, 3, 600);
    expect(selected.map((item) => item.time)).toEqual([60, 310, 560]);
  });

  it("keeps a substantially more important moment even when it is near another question", () => {
    const strongest = prompt({ time: 70 });
    const nearby = prompt({
      time: 80,
      question: "How does focused attention let a listener reconstruct this particular argument?",
      expected_answer: "Focused attention preserves each premise so the listener can reconstruct the argument accurately before responding.",
      scores: { overall: 0.99, importance_to_listener: 0.99, episode_specificity: 0.99, answer_alignment: 0.99, grounding: 0.99 },
    });
    const distant = prompt({
      time: 500,
      question: "What later listening example illustrates the episode's secondary observation?",
      expected_answer: "The later example briefly notes that a listener can remember a speaker's words without understanding their reasoning.",
      scores: { overall: 0.72, importance_to_listener: 0.72, episode_specificity: 0.72, answer_alignment: 0.72, grounding: 0.72 },
    });
    const selected = selectDistributedPrompts([strongest, nearby, distant], 2, 600);
    expect(selected).toContain(nearby);
    expect(selected).not.toContain(distant);
  });

  it("covers a long episode instead of selecting opening prompts", () => {
    const times = [34, 420, 760, 1_080, 1_420, 1_760, 2_100, 2_480, 2_850, 3_150];
    const concepts = [
      "attention and respect", "tradition and reform", "community practices", "moral imagination",
      "historical interpretation", "institutional responsibility", "personal discipline", "social repair",
      "hopeful action", "the concluding challenge",
    ];
    const candidates = times.map((time, index) => prompt({
      time,
      question: `What does the guest argue about ${concepts[index]} in this part of the discussion?`,
      expected_answer: `The discussion develops ${concepts[index]} through a distinct claim, supporting example, and consequence for listeners.`,
    }));
    const selected = selectDistributedPrompts(candidates, 8, 3_246);
    expect(selected).toHaveLength(8);
    expect(selected[0]!.time).toBeGreaterThan(34);
    expect(selected.at(-1)!.time).toBeGreaterThanOrEqual(2_480);
    expect(new Set(selected.map((item) => Math.min(5, Math.floor(item.time / 3_246 * 6)))).size).toBe(6);
    const quarterCounts = [0, 0, 0, 0];
    for (const item of selected) {
      const quarter = Math.min(3, Math.floor(item.time / 3_246 * 4));
      quarterCounts[quarter] = (quarterCounts[quarter] ?? 0) + 1;
    }
    expect(Math.max(...quarterCounts)).toBeLessThanOrEqual(2);
  });

  it("refuses an opening-only candidate set for a long episode", () => {
    const candidates = Array.from({ length: 10 }, (_, index) => prompt({
      time: 180 + index * 45,
      question: `What distinct opening claim number ${index + 1} does the guest develop in this discussion?`,
      expected_answer: `Opening claim number ${index + 1} develops a specific argument supported by the episode's introductory evidence.`,
    }));
    const selected = selectDistributedPrompts(candidates, 8, 3_246);
    expect(selected.length).toBeLessThan(8);
  });
});
