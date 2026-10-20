import { spawn, execFile } from "node:child_process";
import { lookup } from "node:dns/promises";
import { mkdtemp, open, readdir, rm } from "node:fs/promises";
import ipaddr from "ipaddr.js";
import { Agent } from "undici";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import { promisify } from "node:util";
import type { AppConfig } from "./config.js";
import type { AgoraOpenAI } from "./openAIClient.js";
import { parsePublishedSegments, type TimedSegment } from "./transcriptTiming.js";

export async function transcribeRemoteAudio(
  audioURL: string,
  openAI: AgoraOpenAI,
  config: AppConfig,
): Promise<{ transcript: string; segments: TimedSegment[]; duration: number }> {
  const directory = await mkdtemp(join(tmpdir(), "agora-audio-"));
  try {
    const downloaded = await downloadPublicAudio(audioURL, directory, config.maxAudioBytes, openAI.cancellationSignal);
    openAI.checkCancellation();
    const parts = await splitAudio(downloaded, directory, openAI.cancellationSignal);
    const transcriptParts = await mapConcurrent(
      parts,
      config.transcriptionConcurrency,
      async (part) => {
        openAI.checkCancellation();
        const { stdout } = await promisify(execFile)("ffprobe", [
          "-v", "error", "-protocol_whitelist", "file,pipe", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", part,
        ], { timeout: 30_000, ...(openAI.cancellationSignal ? { signal: openAI.cancellationSignal } : {}) });
        const duration = Number(stdout.trim());
        if (!Number.isFinite(duration) || duration <= 0 || duration > 482) throw new Error("An audio part had an invalid duration.");
        const result = await openAI.transcribeTimed(part);
        if ((result.segments.at(-1)?.end ?? 0) < duration * 0.80
          || result.segments.some((segment) => segment.end > duration + 2)) {
          throw new Error("One audio part was only partially transcribed. Retry the episode; incomplete questions were not saved.");
        }
        return { ...result, duration };
      },
    );
    const transcript = transcriptParts.map((part) => part.text).join(" ").replace(/\s+/g, " ").trim();
    if (transcript.split(/\s+/).length < 120) {
      throw new Error("The audio transcription was too short to analyze reliably.");
    }
    let duration = 0;
    const segments = transcriptParts.flatMap((part) => {
      const offset = duration;
      duration += part.duration;
      return part.segments.map((segment) => ({ ...segment, start: segment.start + offset, end: segment.end + offset }));
    });
    return { transcript, segments, duration };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

export async function downloadRemoteTranscript(
  input: string,
  declaredType?: string,
): Promise<{ transcript: string; segments: TimedSegment[] }> {
  const maximumBytes = 25_000_000;
  let url = new URL(input);
  for (let redirect = 0; redirect <= 3; redirect += 1) {
    const response = await publicFetch(url, AbortSignal.timeout(60_000));
    try {
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) throw new Error("The transcript host returned an invalid redirect.");
      url = new URL(location, url);
      await response.body?.cancel();
      continue;
    }
    if (!response.ok) throw new Error(`The transcript host returned HTTP ${response.status}.`);
    const responseType = (response.headers.get("content-type") ?? "").toLowerCase();
    if (responseType.startsWith("audio/") || responseType.startsWith("video/")
      || responseType.startsWith("image/")) {
      throw new Error("The published transcript link did not resolve to readable text.");
    }
    const statedLength = Number(response.headers.get("content-length") ?? 0);
    if (statedLength > maximumBytes) throw new Error("The published transcript is larger than the server limit.");
    const data = await readResponseBytes(response, maximumBytes);
    const type = [declaredType, responseType, extname(url.pathname)]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    const transcript = normalizePublishedTranscript(data, type);
    if (transcript.split(/\s+/).filter(Boolean).length < 120) {
      throw new Error("The published transcript was too short to analyze reliably.");
    }
    return { transcript, segments: parsePublishedSegments(Buffer.from(data).toString("utf8")) };
    } finally {
      if (!response.body?.locked) await response.body?.cancel().catch(() => {});
    }
  }
  throw new Error("The transcript URL redirected too many times.");
}

export function normalizePublishedTranscript(data: Uint8Array, type: string): string {
  const raw = Buffer.from(data).toString("utf8").replace(/^\uFEFF/, "");
  if (type.includes("json") || raw.trimStart().startsWith("{") || raw.trimStart().startsWith("[")) {
    try {
      const text = collectTranscriptText(JSON.parse(raw));
      if (text) return normalizeWhitespace(text);
    } catch {
      // Some feeds label plain transcript text as JSON; fall through to text parsing.
    }
  }
  if (type.includes("html") || /<html[\s>]/i.test(raw)) {
    return normalizeWhitespace(decodeHTMLEntities(raw
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
      .replace(/<[^>]+>/g, " ")));
  }
  if (type.includes("vtt") || type.includes("srt") || raw.startsWith("WEBVTT") || raw.includes(" --> ")) {
    return normalizeWhitespace(raw
      .split(/\r?\n/)
      .filter((line) => !/^\s*(WEBVTT|NOTE|\d+)\s*$/.test(line))
      .filter((line) => !line.includes(" --> "))
      .join(" ")
      .replace(/<[^>]+>/g, " "));
  }
  return normalizeWhitespace(raw);
}

async function downloadPublicAudio(input: string, directory: string, maxBytes: number, signal?: AbortSignal): Promise<string> {
  let url = new URL(input);
  for (let redirect = 0; redirect <= 3; redirect += 1) {
    const timeout = AbortSignal.timeout(120_000);
    const response = await publicFetch(url, signal ? AbortSignal.any([signal, timeout]) : timeout);
    try {
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) throw new Error("The audio host returned an invalid redirect.");
      url = new URL(location, url);
      await response.body?.cancel();
      continue;
    }
    if (!response.ok) throw new Error(`The audio host returned HTTP ${response.status}.`);
    const contentType = (response.headers.get("content-type") ?? "").toLowerCase();
    if (contentType.includes("text/html") || contentType.includes("application/json")
      || contentType.includes("mpegurl") || url.pathname.toLowerCase().endsWith(".m3u8")) {
      throw new Error("The podcast link did not resolve to a downloadable audio file.");
    }
    const statedLength = Number(response.headers.get("content-length") ?? 0);
    if (statedLength > maxBytes) throw new Error("This podcast audio file is larger than the server limit.");
    const suffix = safeExtension(url.pathname);
    const path = join(directory, `episode${suffix}`);
    await streamResponseToFile(response, path, maxBytes);
    return path;
    } finally {
      if (!response.body?.locked) await response.body?.cancel().catch(() => {});
    }
  }
  throw new Error("The audio URL redirected too many times.");
}

async function streamResponseToFile(response: Response, path: string, maxBytes: number): Promise<void> {
  if (!response.body) throw new Error("The audio host returned an empty response.");
  const file = await open(path, "wx");
  const reader = response.body.getReader();
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel();
        throw new Error("This podcast audio file is larger than the server limit.");
      }
      let offset = 0;
      while (offset < value.byteLength) {
        const { bytesWritten } = await file.write(value, offset, value.byteLength - offset);
        if (bytesWritten === 0) throw new Error("The audio file could not be written.");
        offset += bytesWritten;
      }
    }
    if (totalBytes === 0) throw new Error("The audio host returned an empty response.");
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
    await file.close();
  }
}

async function readResponseBytes(response: Response, maxBytes: number): Promise<Uint8Array> {
  if (!response.body) throw new Error("The transcript host returned an empty response.");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    totalBytes += value.byteLength;
    if (totalBytes > maxBytes) {
      await reader.cancel();
      throw new Error("The published transcript is larger than the server limit.");
    }
    chunks.push(value);
  }
  if (totalBytes === 0) throw new Error("The transcript host returned an empty response.");
  const result = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

export async function assertPublicHTTPSURL(url: URL) {
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password) {
    throw new Error("Only public HTTPS audio URLs are supported.");
  }
  const hostname = url.hostname.replace(/^\[|\]$/g, "");
  const addresses = ipaddr.isValid(hostname)
    ? [{ address: hostname, family: ipaddr.parse(hostname).kind() === "ipv4" ? 4 : 6 }]
    : await lookup(hostname, { all: true, verbatim: true });
  if (addresses.length === 0 || addresses.some(({ address }) => isPrivateAddress(address))) {
    throw new Error("The audio URL does not resolve to a public host.");
  }
  return addresses;
}

export function isPrivateAddress(address: string): boolean {
  if (!ipaddr.isValid(address)) return true;
  return ipaddr.process(address).range() !== "unicast";
}

export async function publicFetch(url: URL, signal: AbortSignal): Promise<Response> {
  const addresses = await assertPublicHTTPSURL(url);
  const address = addresses[0]!;
  // Pin the validated DNS result for this connection, including after every redirect.
  const dispatcher = new Agent({ connect: { lookup: (_hostname, options, callback) => {
    if (options.all) callback(null, [address]);
    else callback(null, address.address, address.family);
  } } });
  try {
    const response = await fetch(url, { redirect: "manual", signal, dispatcher } as RequestInit & { dispatcher: Agent });
    if (!response.body) { await dispatcher.close(); return response; }
    const reader = response.body.getReader();
    const body = new ReadableStream<Uint8Array>({
      async pull(controller) {
        try {
          const item = await reader.read();
          if (item.done) { controller.close(); await dispatcher.close(); }
          else controller.enqueue(item.value);
        } catch (error) { controller.error(error); await dispatcher.destroy(); }
      },
      async cancel() { await reader.cancel(); await dispatcher.destroy(); },
    });
    return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
  } catch (error) { await dispatcher.destroy(); throw error; }
}

function safeExtension(path: string): string {
  const value = extname(path).toLowerCase();
  return [".mp3", ".m4a", ".mp4", ".aac", ".wav", ".flac", ".ogg", ".webm"].includes(value) ? value : ".mp3";
}

async function splitAudio(input: string, directory: string, signal?: AbortSignal): Promise<string[]> {
  const outputPattern = join(directory, "segment-%03d.m4a");
  await runProcess("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file,pipe", "-i", input,
    "-f", "segment", "-segment_time", "480", "-reset_timestamps", "1", "-vn", "-c:a", "aac", "-b:a", "64k", outputPattern,
  ], signal);
  const parts = (await readdir(directory))
    .filter((name) => name.startsWith("segment-") && name.endsWith(".m4a"))
    .sort()
    .map((name) => join(directory, name));
  if (parts.length === 0) throw new Error("The server could not split this podcast for transcription.");
  return parts;
}

function runProcess(command: string, args: string[], signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const timeout = AbortSignal.timeout(300_000);
    const child = spawn(command, args, { stdio: ["ignore", "ignore", "pipe"], signal: signal ? AbortSignal.any([signal, timeout]) : timeout });
    let errorOutput = "";
    child.stderr.on("data", (chunk) => { errorOutput = (errorOutput + String(chunk)).slice(-2_000); });
    child.on("error", reject);
    child.on("close", (code) => code === 0 ? resolve() : reject(new Error(errorOutput || `${command} exited with ${code}.`)));
  });
}

async function mapConcurrent<T, R>(
  items: T[],
  concurrency: number,
  work: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let nextIndex = 0;
  async function runner() {
    while (nextIndex < items.length) {
      const index = nextIndex++;
      const item = items[index];
      if (item !== undefined) results[index] = await work(item, index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(Math.max(concurrency, 1), items.length) }, () => runner()));
  return results;
}

function collectTranscriptText(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(collectTranscriptText).filter(Boolean).join(" ");
  if (!value || typeof value !== "object") return "";
  const object = value as Record<string, unknown>;
  const preferredKeys = ["transcript", "body", "segments", "utterances", "results", "items", "text", "content"];
  for (const key of preferredKeys) {
    if (!(key in object)) continue;
    const result = collectTranscriptText(object[key]);
    if (result) return result;
  }
  return "";
}

function decodeHTMLEntities(value: string): string {
  return value
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, "\"")
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">");
}

function normalizeWhitespace(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}
