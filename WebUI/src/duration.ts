const durationUnits = [
  { label: 'w', seconds: 7 * 24 * 60 * 60 },
  { label: 'd', seconds: 24 * 60 * 60 },
  { label: 'h', seconds: 60 * 60 },
  { label: 'm', seconds: 60 },
  { label: 's', seconds: 1 },
] as const;

/** Sidebar elapsed time uses one unit, including hours beyond a day. */
export function formatElapsedDuration(seconds: number): string {
  const elapsed = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0;
  if (elapsed >= 3_600) return `${Math.floor(elapsed / 3_600)}h`;
  if (elapsed >= 60) return `${Math.floor(elapsed / 60)}m`;
  return `${elapsed}s`;
}

export function formatWorkedFor(seconds: number): string {
  let remaining = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0;
  const parts: string[] = [];

  for (const unit of durationUnits) {
    const count = Math.floor(remaining / unit.seconds);
    if (count > 0) parts.push(`${count}${unit.label}`);
    remaining %= unit.seconds;
    if (parts.length === 2) break;
  }

  return parts.length > 0 ? parts.join(' ') : '0s';
}
