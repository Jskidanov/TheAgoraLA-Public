export interface TimedSegment { start: number; end: number; text: string }

export function validSegments(segments: TimedSegment[], duration?: number): boolean {
  return segments.length > 0 && segments.every((segment, index) =>
    Number.isFinite(segment.start) && Number.isFinite(segment.end)
    && segment.start >= 0 && segment.end > segment.start && segment.text.trim().length > 0
    && (duration == null || segment.end <= duration + 2)
    && (index === 0 || segment.start >= segments[index - 1]!.start));
}

export function annotatedTranscript(segments: TimedSegment[]): string {
  return segments.map((segment) => `[[AUDIO_SECONDS ${segment.start.toFixed(2)}-${segment.end.toFixed(2)}]] ${segment.text}`).join("\n");
}

export function normalizeSpeech(text: string): string {
  return text.toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, " ").replace(/\s+/g, " ").trim();
}

// Look up the actual caption/recognizer passage; model-supplied times are not evidence.
export function evidenceEnd(quote: string, segments: TimedSegment[]): number | undefined {
  const key = normalizeSpeech(quote);
  if (key.length < 20) return undefined;
  const spans: { lower: number; upper: number; end: number }[] = [];
  let text = "";
  for (const segment of segments) {
    const words = normalizeSpeech(segment.text);
    if (!words) continue;
    if (text) text += " ";
    spans.push({ lower: text.length, upper: text.length + words.length, end: segment.end });
    text += words;
  }
  // Repeated evidence is scheduled after its last occurrence, never before it was heard.
  const index = text.lastIndexOf(key);
  if (index < 0) return undefined;
  return spans.find((span) => span.upper >= index + key.length)?.end;
}

export function parsePublishedSegments(raw: string): TimedSegment[] {
  const markers = [...raw.matchAll(/\[\[AUDIO_SECONDS ([0-9.]+)-([0-9.]+)\]\]/g)];
  if (markers.length) {
    const segments = markers.map((match, index) => ({
      start: Number(match[1]), end: Number(match[2]),
      text: raw.slice(match.index! + match[0].length, markers[index + 1]?.index ?? raw.length).trim(),
    }));
    if (validSegments(segments)) return segments;
  }
  try {
    const value = JSON.parse(raw) as { segments?: TimedSegment[] } | TimedSegment[];
    const segments = Array.isArray(value) ? value : value.segments;
    if (Array.isArray(segments) && validSegments(segments)) return segments;
  } catch { /* Caption formats are parsed below. */ }
  const segments: TimedSegment[] = [];
  const cue = /(?:(\d{2}):)?(\d{2}):(\d{2})[.,](\d{3})\s*-->\s*(?:(\d{2}):)?(\d{2}):(\d{2})[.,](\d{3})[^\n]*\n([\s\S]*?)(?=\n\s*\n|$)/g;
  for (const match of raw.matchAll(cue)) {
    const start = Number(match[1] ?? 0) * 3600 + Number(match[2]) * 60 + Number(match[3]) + Number(match[4]) / 1000;
    const end = Number(match[5] ?? 0) * 3600 + Number(match[6]) * 60 + Number(match[7]) + Number(match[8]) / 1000;
    const text = match[9]!.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
    if (text) segments.push({ start, end, text });
  }
  return validSegments(segments) ? segments : [];
}
