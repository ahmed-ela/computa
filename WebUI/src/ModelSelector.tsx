import { NativeSelect, NativeSelectOption } from '@octanejs/shadcn/NativeSelect';
import { Button } from '@octanejs/shadcn/Button';
import type { ModelOption, NativeAction, WebsiteModelProvider } from './types';

export function modelOptionLabel(option: ModelOption): string {
  return option.label.split(' · ')[0];
}

export function ModelSelector({ options, model, label, disabled = false, className,
  onSelect }: { options: ModelOption[]; model: string; label: string; disabled?: boolean;
  className?: string; onSelect: (model: string) => void }) {
  const selected = options.find((option) => option.id === model);
  return (
    <NativeSelect className={className} aria-label={label} title={selected?.detail ?? model}
      value={model} disabled={disabled}
      onInput={(event: Event) => onSelect((event.currentTarget as HTMLSelectElement).value)}>
      {!selected && <NativeSelectOption value={model} disabled>{model}</NativeSelectOption>}
      {options.map((option) => <NativeSelectOption key={option.id} value={option.id}
        disabled={option.available === false}>{modelOptionLabel(option)}{option.available === false ? ' (unavailable)' : ''}</NativeSelectOption>)}
    </NativeSelect>
  );
}

type WebsiteModelsRefreshAction = Extract<NativeAction, { action: 'refreshWebsiteModels' }>;

export function websiteModelsRefreshAction(model?: string): WebsiteModelsRefreshAction | undefined {
  if (model === undefined) return { action: 'refreshWebsiteModels' };
  const match = /^browser\/(chatgpt|gemini|claude)(?:\/choice\/[A-Za-z0-9_-]+)?$/.exec(model);
  return match && match[0] === model ? { action: 'refreshWebsiteModels', provider: match[1] as WebsiteModelProvider } : undefined;
}

export function WebsiteModelsRefresh({ model, refreshing = false, canRefresh = false, onRefresh }: {
  model?: string; refreshing?: boolean; canRefresh?: boolean; onRefresh: (action: WebsiteModelsRefreshAction) => void }) {
  const action = websiteModelsRefreshAction(model);
  if (!action) return null;
  const provider = action.provider && ({ chatgpt: 'ChatGPT', gemini: 'Gemini', claude: 'Claude' })[action.provider];
  const label = provider ? `Refresh ${provider} models` : 'Refresh models';
  return <Button variant="ghost" size="sm" aria-label={provider ? label : 'Refresh website models'}
    title={canRefresh ? `Read the model choices available in your signed-in ${provider ? `${provider} website` : 'websites'}`
      : 'Finish active tasks and approvals before refreshing website models'}
    disabled={refreshing || !canRefresh} onClick={() => onRefresh(action)}>{refreshing ? 'Refreshing…' : label}</Button>;
}
