import { createReadStream } from "node:fs";
import OpenAI from "openai";
import type { AppConfig } from "./config.js";
import { validSegments, type TimedSegment } from "./transcriptTiming.js";

export class AgoraOpenAI {
  private readonly client: OpenAI;

  checkCancellation() { this.signal?.throwIfAborted(); }
  get cancellationSignal() { return this.signal; }

  async transcribeTimed(filePath: string): Promise<{ text: string; duration: number; segments: TimedSegment[] }> {
    this.checkCancellation();
    const result = await this.client.audio.transcriptions.create({
      file: createReadStream(filePath),
      model: this.config.models.transcription.includes("whisper") ? this.config.models.transcription : "openai/whisper-large-v3",
      response_format: "verbose_json",
      timestamp_granularities: ["segment"],
    }, { signal: this.signal });
    const segments = result.segments ?? [];
    if (!validSegments(segments, result.duration)) {
      throw new Error("The transcription provider did not return verified audio timestamps. Use a timestamp-capable transcription model.");
    }
    return { text: result.text, duration: result.duration, segments };
  }

  constructor(private readonly config: AppConfig, apiKey: string, baseURL?: string, private readonly signal?: AbortSignal) {
    this.client = new OpenAI({ apiKey, baseURL });
  }

  async structured<T>(options: {
    model: string;
    instructions: string;
    input: string;
    schemaName: string;
    schema: Record<string, unknown>;
    safetyID: string;
    effort?: "low" | "medium" | "high";
  }): Promise<T> {
    this.signal?.throwIfAborted();
    const response = await this.client.responses.create({
      model: options.model,
      instructions: options.instructions,
      input: options.input,
      reasoning: { effort: options.effort ?? "medium" },
      text: {
        verbosity: "low",
        format: {
          type: "json_schema",
          name: options.schemaName,
          strict: true,
          schema: options.schema,
        },
      },
      safety_identifier: options.safetyID,
      store: false,
    }, { signal: this.signal });
    const content = response.output_text.trim();
    if (!content) throw new Error("OpenAI returned an empty structured response.");
    return JSON.parse(content) as T;
  }

  async transcribe(filePath: string): Promise<string> {
    this.signal?.throwIfAborted();
    const result = await this.client.audio.transcriptions.create({
      file: createReadStream(filePath),
      model: this.config.models.transcription,
      response_format: "json",
    }, { signal: this.signal });
    const text = typeof result === "string" ? result : String((result as { text?: string }).text ?? "");
    return text.trim();
  }
}
