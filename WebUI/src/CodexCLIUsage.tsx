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

export function quotaNearLimit(buckets: CodexCLIUsageBucket[] | undefined, now: number): boolean {
  return buckets?.some(({ primary, secondary }) => [primary, secondary].some(window => {
    return window && (resetMillis(window) ?? Infinity) > now && quotaLeft(window.usedPercent) <= 10;
  })) ?? false;
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
  const nearLimit = quotaNearLimit(buckets, now);
  const nextReset = (buckets ?? []).flatMap(({ primary, secondary }) => [primary, secondary])
    .reduce((next: number, window) => {
      const reset = window && resetMillis(window);
      return reset !== undefined && reset > now ? Math.min(next, reset) : next;
    }, Infinity);
  useEffect(() => {
    if (!Number.isFinite(nextReset)) return;
    const timeout = setTimeout(() => setClock(Date.now()),
      Math.min(0x7fffffff, Math.max(0, nextReset - Date.now())));
    return () => clearTimeout(timeout);
  }, [nextReset, now]);

  return (
    <Popover onOpenChange={(open: boolean) => { if (open && !blocked && !refreshing) onRefresh(); }}>
      <PopoverTrigger className="codex-usage-trigger" data-warning={nearLimit ? 'true' : undefined}
        aria-label={nearLimit ? 'Codex usage, quota low' : 'Codex usage'} disabled={blocked}>Usage</PopoverTrigger>
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
