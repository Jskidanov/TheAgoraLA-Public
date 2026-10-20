import { createHash } from "node:crypto";
import type { AppConfig } from "./config.js";
import type { AgoraOpenAI } from "./openAIClient.js";
import { analyzeTranscript } from "./promptPipeline.js";
import { annotatedTranscript, parsePublishedSegments, validSegments, type TimedSegment } from "./transcriptTiming.js";
import {
  downloadRemoteTranscript,
  transcribeRemoteAudio,
} from "./transcription.js";

export interface AnalysisJobInput {
  title?: string;
  audio_url?: string;
  transcript?: string;
  transcript_url?: string;
  transcript_type?: string;
  duration?: number;
  prompt_count?: number;
  model?: string;
}

export function transcriptAppearsComplete(transcript: string, duration?: number): boolean {
  const wordCount = transcript.split(/\s+/).filter(Boolean).length;
  if (wordCount < 120) return false;
  if (!duration || !Number.isFinite(duration) || duration < 600) return true;
  return wordCount >= duration * 1.25;
}

export async function processEpisodeAnalysis(options: {
  input: AnalysisJobInput;
  userID: string;
  openAI: AgoraOpenAI;
  config: AppConfig;
}) {
  let transcript = options.input.transcript?.replace(/\s+/g, " ").trim() ?? "";
  let segments: TimedSegment[] = parsePublishedSegments(options.input.transcript ?? "");
  if (segments.length) transcript = segments.map((segment) => segment.text).join(" ");
  let measuredDuration: number | undefined;
  const knownDuration = options.input.duration;
  if (!segments.length && options.input.transcript_url) {
    try {
      const published = await downloadRemoteTranscript(
        options.input.transcript_url,
        options.input.transcript_type,
      );
      transcript = published.transcript;
      segments = published.segments;
    } catch (error) {
      if (!options.input.audio_url) throw error;
    }
  }
  const lastCaption = segments.at(-1)?.end ?? 0;
  const hasCompleteTiming = validSegments(segments, knownDuration)
    && (!knownDuration || lastCaption >= knownDuration * 0.90)
    && transcriptAppearsComplete(transcript, knownDuration);
  if (!hasCompleteTiming) {
    if (!options.input.audio_url) throw new Error("A complete transcript or public audio URL is required.");
    const transcription = await transcribeRemoteAudio(options.input.audio_url, options.openAI, options.config);
    transcript = transcription.transcript;
    segments = transcription.segments;
    measuredDuration = transcription.duration;
  }
  const wordCount = transcript.split(/\s+/).filter(Boolean).length;
  if (wordCount < 120 || wordCount > 100_000) {
    throw new Error("The transcript length is outside the supported range.");
  }
  const estimatedDuration = wordCount / 2.45;
  const duration = measuredDuration ?? (knownDuration && knownDuration > 10
    ? knownDuration
    : Math.max(lastCaption, estimatedDuration));
  if (!validSegments(segments, duration) || (segments.at(-1)?.end ?? 0) < duration * 0.80) {
    throw new Error("The transcript did not cover the complete audio timeline. Please retry this episode.");
  }
  const analysisConfig = options.input.model
    ? { ...options.config, models: { ...options.config.models, curation: options.input.model } }
    : options.config;
  const analysis = await analyzeTranscript({
    transcript,
    segments,
    duration,
    ...(options.input.prompt_count == null
      ? {}
      : { desiredCount: Math.max(3, Math.min(12, options.input.prompt_count)) }),
    safetyID: createHash("sha256").update(options.userID).digest("hex"),
    openAI: options.openAI,
    config: analysisConfig,
  });
  return {
    title: options.input.title ?? "Podcast Episode",
    transcript: annotatedTranscript(segments),
    duration,
    summary: analysis.summary,
    prompts: analysis.prompts,
    full_transcript_processed: true,
  };
}
