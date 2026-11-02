import { useEffect, useState } from 'octane';
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuPortal,
  DropdownMenuRadioGroup, DropdownMenuRadioItem, DropdownMenuSub,
  DropdownMenuSubContent, DropdownMenuSubTrigger, DropdownMenuTrigger,
} from '@octanejs/shadcn/DropdownMenu';
import { Button } from '@octanejs/shadcn/Button';
import { Icon } from './Icon';
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

const websiteProviderNames: Record<WebsiteModelProvider, string> = {
  chatgpt: 'ChatGPT', gemini: 'Gemini', claude: 'Claude', groq: 'Groq',
  kimi: 'Kimi', qwen: 'Qwen', deepseek: 'DeepSeek',
};
const websiteDefaultModels = new Set(Object.keys(websiteProviderNames).map((provider) => `browser/${provider}`));
// Temporarily hide the other Alibaba catalog models, including dated duplicates.
// Keep their saved configuration and runtime support; only expose Qwen3.7 Flash.
const showAdditionalAlibabaModels = false;
const alibabaQwen37Flash = 'api/alibaba/model/cXdlbjMuNy1mbGFzaA'; // qwen3.7-flash

// Offer specific website/API models only. Keep hidden local/default selections
// and runtime support intact without silently substituting a different model.
function isVisibleModel(model: string): boolean {
  if (model.startsWith('api/alibaba/')) return showAdditionalAlibabaModels || model === alibabaQwen37Flash;
  return (model.startsWith('browser/') || model.startsWith('api/')) && !websiteDefaultModels.has(model);
}

const providerNames: Record<string, string> = {
  ...websiteProviderNames,
  cerebras: 'Cerebras', alibaba: 'Alibaba', openai: 'OpenAI',
};

type ModelProviderGroup = { id: string; name: string; iconModel: string; options: ModelOption[] };

export function groupModelOptions(options: ModelOption[], model: string): ModelProviderGroup[] {
  const visibleOptions = options.filter((option) => isVisibleModel(option.id));
  // Preserve an unavailable saved selection without substituting another model.
  if (isVisibleModel(model) && !visibleOptions.some((option) => option.id === model)) {
    visibleOptions.push({ id: model, label: model, detail: model, highMemory: false, available: false });
  }
  const groups = new Map<string, ModelProviderGroup>();
  for (const option of visibleOptions) {
    const provider = option.id.split('/')[1];
    let group = groups.get(provider);
    if (!group) {
      const label = fullModelLabel(option);
      const separator = label.indexOf(' / ');
      const name = Object.hasOwn(providerNames, provider) ? providerNames[provider]
        : separator > 0 ? label.slice(0, separator) : provider;
      group = { id: provider, name, iconModel: option.id, options: [] };
      groups.set(provider, group);
    }
    group.options.push(option);
  }
  return [...groups.values()];
}

export function ModelSelector({ options, model, label, disabled = false, className,
  onSelect }: { options: ModelOption[]; model: string; label: string; disabled?: boolean;
  className?: string; onSelect: (model: string) => void }) {
  const selected = options.find((option) => option.id === model);
  const groups = groupModelOptions(options, model);
  const [open, setOpen] = useState(false);
  useEffect(() => { if (disabled) setOpen(false); }, [disabled]);
  const selectModel = (value: string) => {
    if (disabled || !groups.some((group) => group.options.some((option) => option.id === value && option.available !== false))) return;
    if (value !== model) onSelect(value);
    setOpen(false);
  };
  return (
    <DropdownMenu open={open && !disabled} onOpenChange={(next: boolean) => setOpen(next && !disabled)}>
      <DropdownMenuTrigger asChild disabled={disabled}>
        <Button type="button" variant="outline" size="sm" disabled={disabled}
          className={`model-selector-trigger ${className ?? ''}`}
          aria-label={`${label}: ${selected ? fullModelLabel(selected) : model}`} title={selected?.detail ?? model}>
          <ModelLabel model={model} option={selected} />
          <span className="model-selector-chevron"><Icon name="chevron" size={12} /></span>
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent className="model-selector-content" align="start" collisionPadding={12} aria-label="Model providers">
        {groups.map((group) => <DropdownMenuSub key={group.id}>
          <DropdownMenuSubTrigger disabled={disabled} textValue={group.name} className="model-provider-option"
            data-provider={group.id}>
            <ModelProviderIcon model={group.iconModel} />
            <span className="model-provider-name">{group.name}</span>
          </DropdownMenuSubTrigger>
          <DropdownMenuPortal>
            <DropdownMenuSubContent className="model-selector-submenu" sideOffset={6} collisionPadding={12}
              aria-label={`${group.name} ${group.id === 'deepseek' ? 'modes' : 'models'}`}>
              <DropdownMenuRadioGroup value={model} onValueChange={selectModel}>
                {group.options.map((option) => <DropdownMenuRadioItem key={option.id} value={option.id}
                  textValue={modelOptionLabel(option)} title={option.detail} disabled={disabled || option.available === false}>
                  <span className="model-option-name">{modelOptionLabel(option)}</span>
                  {option.available === false && <span className="model-option-unavailable"> (unavailable)</span>}
                </DropdownMenuRadioItem>)}
              </DropdownMenuRadioGroup>
            </DropdownMenuSubContent>
          </DropdownMenuPortal>
        </DropdownMenuSub>)}
        {groups.length === 0 && <DropdownMenuItem disabled>No models available</DropdownMenuItem>}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

type WebsiteModelsRefreshAction = Extract<NativeAction, { action: 'refreshWebsiteModels' }>;

export function websiteModelsRefreshAction(model?: string): WebsiteModelsRefreshAction | undefined {
  if (model === undefined) return { action: 'refreshWebsiteModels' };
  if (model === 'browser/deepseek/mode/chat' || model === 'browser/deepseek/mode/deepthink')
    return { action: 'refreshWebsiteModels', provider: 'deepseek' };
  const match = /^browser\/([a-z][a-z0-9_-]*)(?:\/choice\/[A-Za-z0-9_-]+)?$/.exec(model);
  return match && match[0] === model && Object.hasOwn(websiteProviderNames, match[1])
    ? { action: 'refreshWebsiteModels', provider: match[1] as WebsiteModelProvider } : undefined;
}

export function WebsiteModelsRefresh({ model, refreshing = false, canRefresh = false, onRefresh }: {
  model?: string; refreshing?: boolean; canRefresh?: boolean; onRefresh: (action: WebsiteModelsRefreshAction) => void }) {
  const action = websiteModelsRefreshAction(model);
  if (!action) return null;
  const provider = action.provider && websiteProviderNames[action.provider];
  const label = provider ? `Refresh ${provider} models` : 'Refresh models';
  return <Button variant="ghost" size="sm" aria-label={provider ? label : 'Refresh website models'}
    title={canRefresh ? `Read the model choices available in your signed-in ${provider ? `${provider} website` : 'websites'}`
      : 'Finish active tasks and approvals before refreshing website models'}
    disabled={refreshing || !canRefresh} onClick={() => onRefresh(action)}>{refreshing ? 'Refreshing…' : label}</Button>;
}
