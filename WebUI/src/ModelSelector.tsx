import { useEffect, useState } from 'octane';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@octanejs/shadcn/Select';
import { Button } from '@octanejs/shadcn/Button';
import { ModelProviderIcon } from './ModelProviderIcon';
import type { ModelOption, NativeAction, WebsiteModelProvider } from './types';

function fullModelLabel(option: ModelOption): string {
  return option.label.split(' · ')[0];
}

export function modelOptionLabel(option: ModelOption): string {
  const label = fullModelLabel(option);
  const separator = label.indexOf(' / ');
  return separator < 0 ? label : label.slice(separator + 3);
}

export function ModelLabel({ model, option }: { model: string; option?: ModelOption }) {
  const fullLabel = option ? fullModelLabel(option) : model;
  const separator = fullLabel.indexOf(' / ');
  return <span className="model-option-label" title={fullLabel}>
    <ModelProviderIcon model={model} />
    {separator >= 0 && <span className="sr-only">{fullLabel.slice(0, separator)}: </span>}
    <span className="model-option-name">{option ? modelOptionLabel(option) : model}</span>
  </span>;
}

const websiteDefaultModels = new Set(['browser/chatgpt', 'browser/gemini', 'browser/claude']);

// Offer specific website/API models only. Keep hidden local/default selections
// and runtime support intact without silently substituting a different model.
function isVisibleModel(model: string): boolean {
  return (model.startsWith('browser/') || model.startsWith('api/')) && !websiteDefaultModels.has(model);
}

export function ModelSelector({ options, model, label, disabled = false, className,
  onSelect }: { options: ModelOption[]; model: string; label: string; disabled?: boolean;
  className?: string; onSelect: (model: string) => void }) {
  const selected = options.find((option) => option.id === model);
  const visibleOptions = options.filter((option) => isVisibleModel(option.id));
  const [open, setOpen] = useState(false);
  useEffect(() => { if (disabled) setOpen(false); }, [disabled]);
  // Preserve a missing remote selection without silently choosing another model.
  if (isVisibleModel(model) && !visibleOptions.some((option) => option.id === model)) {
    visibleOptions.push({ id: model, label: model, detail: model, highMemory: false, available: false });
  }
  return (
    <Select value={model} disabled={disabled} open={open && !disabled} onOpenChange={setOpen}
      onValueChange={(value: string) => { if (!disabled) onSelect(value); }}>
      <SelectTrigger className={`model-selector-trigger ${className ?? ''}`}
        aria-label={`${label}: ${selected ? fullModelLabel(selected) : model}`} title={selected?.detail ?? model}>
        <SelectValue><ModelLabel model={model} option={selected} /></SelectValue>
      </SelectTrigger>
      <SelectContent className="model-selector-content" position="popper" align="start">
        {visibleOptions.map((option) => <SelectItem key={option.id} value={option.id}
          textValue={modelOptionLabel(option)} title={option.detail} disabled={disabled || option.available === false}>
          <ModelLabel model={option.id} option={option} />
          {option.available === false && <span className="model-option-unavailable"> (unavailable)</span>}
        </SelectItem>)}
      </SelectContent>
    </Select>
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
