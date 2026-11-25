import { useEffect, useState } from 'octane';
import { Popover, PopoverContent, PopoverTrigger } from '@octanejs/shadcn/Popover';
import { Button } from '@octanejs/shadcn/Button';
import type { CodexCLIUsageBucket, CodexCLIUsageWindow } from './types';

export function isCodexCLIModel(model: string): boolean {
  const prefix = 'cli/codex/model/';
  const slug = model.slice(prefix.length);
  return model.startsWith(prefix) && slug.length > 0 && slug.length <= 256 && !/[^!-~]/.test(slug);
}

export function quotaLeft(usedPercent: number): number {
  return 100 - Math.max(0, Math.min(100, usedPercent));
}

export function quotaWindowLabel(minutes: number | undefined, slot: 'primary' | 'secondary'): string {
  if (minutes && minutes > 0) {
    for (const [unitMinutes, unit] of [[10080, 'week'], [1440, 'day'], [60, 'hour'], [1, 'minute']] as const) {
      if (minutes % unitMinutes === 0) return `${minutes / unitMinutes}-${unit} window`;
    }
  }
  return slot === 'primary' ? 'Primary window' : 'Secondary window';
}

function resetMillis(window: CodexCLIUsageWindow): number | undefined {
  const time = (window.resetsAt ?? 0) * 1000;
  return time > 0 && time <= 8.64e15 ? time : undefined;
}

export function quotaSummary(buckets: CodexCLIUsageBucket[] | undefined, now: number) {
  let remaining: number | undefined;
  let nextReset = Infinity;
  for (const { primary, secondary } of buckets ?? []) {
    for (const window of [primary, secondary]) {
      if (!window) continue;
      const reset = resetMillis(window) ?? Infinity;
      if (reset <= now) continue;
      remaining = Math.min(remaining ?? 100, quotaLeft(window.usedPercent));
      nextReset = Math.min(nextReset, reset);
    }
  }
  return { remaining, nextReset };
}

const resetFormat = new Intl.DateTimeFormat(undefined, {
  month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
});

function QuotaWindow({ window, slot, now }: {
  window: CodexCLIUsageWindow;
  slot: 'primary' | 'secondary';
  now: number;
}) {
  const remaining = quotaLeft(window.usedPercent);
  const reset = resetMillis(window);
  const expired = reset !== undefined && reset <= now;
  return (
    <li className="codex-quota-window">
      <div className="codex-quota-row">
        <span>{quotaWindowLabel(window.windowDurationMins, slot)}</span>
        {!expired ? <strong className={remaining <= 10 ? 'tone-orange' : ''}>{remaining}% left</strong> : null}
      </div>
      <span className="codex-quota-detail">{expired ? 'Reset time passed. Refresh for current usage.'
        : reset !== undefined ? `Resets ${resetFormat.format(reset)}` : 'Reset time unavailable'}</span>
    </li>
  );
}

export function CodexCLIUsage({ buckets, refreshing, blocked, onRefresh }: {
  buckets?: CodexCLIUsageBucket[];
  refreshing: boolean;
  blocked: boolean;
  onRefresh: () => void;
}) {
  const [, setClock] = useState(0);
  const now = Date.now();
  const { remaining, nextReset } = quotaSummary(buckets, now);
  const hint = remaining !== undefined ? `${remaining}% left` : refreshing ? 'Checking usage…' : 'Usage unavailable';
  const needsQuota = remaining === undefined && !blocked;
  function refreshMissing() {
    if (needsQuota && !refreshing) onRefresh();
  }
  // Read once when a meter first needs data. A failed read can be retried on hover or focus.
  useEffect(refreshMissing, [needsQuota]);
  useEffect(() => {
    if (!Number.isFinite(nextReset)) return;
    const timeout = setTimeout(() => setClock(Date.now()),
      Math.min(0x7fffffff, Math.max(0, nextReset - Date.now())));
    return () => clearTimeout(timeout);
  }, [nextReset, now]);

  return (
    <Popover onOpenChange={(open: boolean) => { if (open && !blocked && !refreshing) onRefresh(); }}>
      <PopoverTrigger className="codex-usage-trigger" disabled={blocked} data-hint={hint}
        data-warning={remaining !== undefined && remaining <= 10 ? 'true' : undefined}
        aria-label={`Codex usage, ${hint}`} onPointerEnter={refreshMissing} onFocus={refreshMissing}>
        <svg className="codex-usage-ring" width="16" height="16" viewBox="0 0 16 16" fill="none"
          stroke="currentColor" strokeWidth="2" aria-hidden="true" focusable="false">
          <circle className="codex-usage-track" cx="8" cy="8" r="6"
            strokeDasharray={remaining === undefined ? '2 2' : undefined} />
          {remaining !== undefined && remaining > 0 ? <circle cx="8" cy="8" r="6" pathLength="100"
            strokeDasharray={`${remaining} 100`} strokeLinecap="round" transform="rotate(-90 8 8)" /> : null}
        </svg>
      </PopoverTrigger>
      <PopoverContent className="codex-usage-popover" side="top" align="start" sideOffset={8} aria-label="Codex usage">
        <header className="codex-quota-row">
          <h2>Codex usage</h2>
          <Button variant="ghost" size="sm" disabled={blocked || refreshing} onClick={onRefresh}>Refresh</Button>
        </header>
        <div aria-live="polite" aria-busy={refreshing}>
          {refreshing ? <p className="codex-quota-detail">Checking Codex quota…</p>
            : !buckets ? <p className="codex-quota-detail">Quota is unavailable. Check your Codex CLI account in the model picker and try again.</p>
            : buckets.length === 0 ? <p className="codex-quota-detail">Codex CLI did not report any quota windows.</p>
            : buckets.map(bucket => (
              <section className="codex-quota-bucket" key={bucket.id}>
                <h3>{bucket.label?.trim() || (bucket.id === 'codex' ? 'Codex' : bucket.id)}</h3>
                <ul>
                  {bucket.primary ? <QuotaWindow slot="primary" window={bucket.primary} now={now} /> : null}
                  {bucket.secondary ? <QuotaWindow slot="secondary" window={bucket.secondary} now={now} /> : null}
                </ul>
              </section>
            ))}
        </div>
      </PopoverContent>
    </Popover>
  );
}
