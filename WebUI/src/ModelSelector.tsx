import { useEffect, useState } from 'octane';
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuPortal,
  DropdownMenuRadioGroup, DropdownMenuRadioItem, DropdownMenuSub,
  DropdownMenuSubContent, DropdownMenuSubTrigger, DropdownMenuTrigger,
} from '@octanejs/shadcn/DropdownMenu';
import { Button } from '@octanejs/shadcn/Button';
import { Icon } from './Icon';
import { ModelProviderIcon } from './ModelProviderIcon';
import type { ModelOption, ModelProviderSetup, NativeAction, WebsiteModelProvider } from './types';

function fullModelLabel(option: ModelOption): string {
  return option.label.split(' · ')[0];
}

export function modelOptionLabel(option: ModelOption): string {
  const label = fullModelLabel(option);
  const separator = label.indexOf(' / ');
  return separator < 0 ? label : label.slice(separator + 3);
}

function isCustomAPIWithPausedProviderID(option?: ModelOption): boolean {
  return option !== undefined && option.available !== false && option.selectable !== false
    && (option.id.startsWith('api/cerebras/model/') || option.id.startsWith('api/groq/model/'));
}

export function ModelLabel({ model, option, group }: { model: string; option?: ModelOption; group?: ModelProviderGroup }) {
  const fullLabel = option ? fullModelLabel(option) : model;
  const separator = fullLabel.indexOf(' / ');
  return <span className="model-option-label" title={fullLabel}>
    {(group?.genericAPIIcon ?? isCustomAPIWithPausedProviderID(option))
      ? <Icon name="sparkles" size={16} /> : <ModelProviderIcon model={group?.iconModel ?? model} />}
    {separator >= 0 && <span className="sr-only">{fullLabel.slice(0, separator)}: </span>}
    <span className="model-option-name">{option ? modelOptionLabel(option) : model}</span>
  </span>;
}

const websiteProviderNames: Record<WebsiteModelProvider, string> = {
  chatgpt: 'ChatGPT', gemini: 'Gemini', claude: 'Claude', groq: 'Groq', grok: 'Grok',
  kimi: 'Kimi', qwen: 'Qwen', deepseek: 'DeepSeek',
};
const websiteDefaultModels = new Set(Object.keys(websiteProviderNames).map((provider) => `browser/${provider}`));
// Account catalogs and provider-specific model filters are owned by native discovery.
function isVisibleModel(model: string): boolean {
  return (model.startsWith('browser/') || model.startsWith('api/') || model.startsWith('cli/')) && !websiteDefaultModels.has(model);
}

const providerNames: Record<string, string> = {
  ...websiteProviderNames,
  cerebras: 'Cerebras', alibaba: 'Alibaba', openai: 'OpenAI',
};

type ModelProviderGroup = { route: string; id: string; name: string; iconModel: string; genericAPIIcon: boolean; setup?: ModelProviderSetup; options: ModelOption[] };

export function groupModelOptions(options: ModelOption[], model: string, setups: ModelProviderSetup[] = []): ModelProviderGroup[] {
  const visibleOptions = options.filter((option) => option.selectable !== false && isVisibleModel(option.id));
  // Preserve an unavailable saved selection without substituting another model.
  if (model.startsWith('browser/') && isVisibleModel(model) && !options.some((option) => option.id === model)) {
    visibleOptions.push({ id: model, label: model, detail: model, highMemory: false, available: false });
  }
  const groups = new Map<string, ModelProviderGroup>();
  for (const setup of setups) {
    const [transport, provider] = setup.route.split('/');
    groups.set(setup.route, { route: setup.route, id: provider, name: setup.name, setup, options: [],
      iconModel: transport === 'api' ? 'api/alibaba' : setup.route, genericAPIIcon: false });
  }
  for (const option of visibleOptions) {
    const [transport, provider] = option.id.split('/');
    const route = transport + '/' + provider;
    let group = groups.get(route);
    if (!group) {
      const label = fullModelLabel(option);
      const separator = label.indexOf(' / ');
      const configuredName = separator > 0 ? label.slice(0, separator) : provider;
      const genericAPIIcon = isCustomAPIWithPausedProviderID(option)
        || (transport === 'api' && (Object.hasOwn(websiteProviderNames, provider) || (provider === 'alibaba' && setups.length > 0)));
      const groupID = genericAPIIcon ? route : provider;
      const name = transport !== 'cli' && !genericAPIIcon && Object.hasOwn(providerNames, provider) ? providerNames[provider] : configuredName;
      group = { route, id: groupID, name, iconModel: option.id, genericAPIIcon, options: [] };
      groups.set(route, group);
    }
    group.options.push(option);
  }
  return [...groups.values()];
}

export function ModelSelector({ options, model, label, disabled = false, className,
  setups = [], canConnect = false, boundToRuntime = false, onConnect, onRefresh, onSelect }: { boundToRuntime?: boolean; options: ModelOption[]; setups?: ModelProviderSetup[];
  onRefresh?: (action: WebsiteModelsRefreshAction) => void; canConnect?: boolean; onConnect?: (route: string) => void; model: string; label: string; disabled?: boolean;
  className?: string; onSelect: (model: string) => void }) {
  const selected = options.find((option) => option.id === model);
  const cliRoute = model.startsWith('cli/') ? model.split('/').slice(0, 2).join('/') : undefined;
  const groups = groupModelOptions(options, model, setups).filter(group =>
    !boundToRuntime || (cliRoute ? group.route === cliRoute : !group.route.startsWith('cli/')));
  const needsSelection = setups.length > 0 && (!selected || selected.available === false || selected.selectable === false);
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
          aria-label={`${label}: ${needsSelection ? 'Choose model' : selected ? fullModelLabel(selected) : model}`} title={selected?.detail ?? model}>
          {needsSelection ? <span>Choose model</span> : <ModelLabel model={model} option={selected} group={groups.find((group) => group.options.some((option) => option.id === model))} />}
          <span className="model-selector-chevron"><Icon name="chevron" size={12} /></span>
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent className="model-selector-content" align="start" collisionPadding={12} aria-label="Model providers">
        {groups.map((group) => <DropdownMenuSub key={group.route} onOpenChange={(opened: boolean) => {
          if (opened && group.route.startsWith('cli/') && group.setup && !group.setup.connected
              && group.setup.checkStatus !== 'checking' && canConnect) onConnect?.(group.route);
        }}>
          <DropdownMenuSubTrigger disabled={disabled} textValue={group.name} className="model-provider-option"
            data-provider={group.id}>
            {group.genericAPIIcon ? <Icon name="sparkles" size={16} /> : <ModelProviderIcon model={group.iconModel} />}
            <span className="model-provider-name">{group.name}</span>
          </DropdownMenuSubTrigger>
          <DropdownMenuPortal>
            <DropdownMenuSubContent className="model-selector-submenu" sideOffset={6} collisionPadding={12}
              aria-label={`${group.name} ${group.id === 'deepseek' ? 'modes' : 'models'}`}>
              <DropdownMenuRadioGroup value={model} onValueChange={selectModel}>
                {group.options.filter((option) => !group.setup || option.available !== false).map((option) => <DropdownMenuRadioItem key={option.id} value={option.id}
                  textValue={modelOptionLabel(option)} title={option.detail} disabled={disabled || option.available === false}>
                  <span className="model-option-name">{modelOptionLabel(option)}</span>
                  {option.available === false && <span className="model-option-unavailable"> (unavailable)</span>}
                </DropdownMenuRadioItem>)}
              </DropdownMenuRadioGroup>
              {group.setup && <ProviderSetupActions setup={group.setup}
                hasModels={group.options.some((option) => option.available !== false)} disabled={disabled || !canConnect}
                onConnect={() => { if (!group.route.startsWith('cli/')) setOpen(false); onConnect?.(group.route); }} onRefresh={onRefresh} />}
            </DropdownMenuSubContent>
          </DropdownMenuPortal>
        </DropdownMenuSub>)}
        {groups.length === 0 && <DropdownMenuItem disabled>No models available</DropdownMenuItem>}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function ProviderSetupActions({ setup, hasModels, disabled, onConnect, onRefresh }: {
  setup: ModelProviderSetup; hasModels: boolean; disabled: boolean; onConnect: () => void; onRefresh?: (action: WebsiteModelsRefreshAction) => void;
}) {
  if (setup.route.startsWith('cli/')) return <>
    {setup.detail && <div role="status" className="model-setup-detail">{setup.detail}</div>}
    <DropdownMenuItem disabled={disabled || setup.checkStatus === 'checking'} onSelect={(event: Event) => {
      event.preventDefault();
      onConnect();
    }}>{setup.checkStatus === 'checking' ? 'Checking available models…' : hasModels ? 'Refresh models' : 'Check available models'}</DropdownMenuItem>
  </>;
  if (hasModels) {
    return setup.route === 'browser/kimi'
      ? <DropdownMenuItem disabled={disabled} onSelect={onConnect}>Manage Kimi sign-in</DropdownMenuItem> : null;
  }
  const refresh = websiteModelsRefreshAction(setup.route);
  if (!refresh) return <DropdownMenuItem disabled={disabled} onSelect={onConnect}>
    {setup.connected ? 'Manage API connection' : 'Connect API'}
  </DropdownMenuItem>;
  const status = setup.checkStatus;
  return <>
    {(status === 'signInRequired' || status === 'unavailable') && <DropdownMenuItem disabled={disabled} onSelect={onConnect}>
      {status === 'signInRequired' ? 'Sign in to ' + setup.name : 'Open ' + setup.name}
    </DropdownMenuItem>}
    <DropdownMenuItem disabled={disabled || !onRefresh || status === 'checking'} onSelect={(event: Event) => {
      event.preventDefault();
      if (!disabled && status !== 'checking') onRefresh?.(refresh);
    }}>
      {status === 'checking' ? 'Checking available models…' : status ? 'Check again' : 'Check available models'}
    </DropdownMenuItem>
  </>;
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
