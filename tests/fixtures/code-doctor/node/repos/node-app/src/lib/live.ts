import { formatElapsed, slugify } from "./helpers";

export function summarize(words: string[]): string {
  return words.map(slugify).join(" ") + " in " + formatElapsed(words.length);
}

export function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const rest = Math.floor(seconds % 60);
  const parts: string[] = [];
  if (hours > 0) parts.push(`${hours}h`);
  if (minutes > 0) parts.push(`${minutes}m`);
  parts.push(`${rest}s`);
  return parts.join(" ");
}
