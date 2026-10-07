import { NativeSelect, NativeSelectOption } from '@octanejs/shadcn/NativeSelect';
import { Button } from '@octanejs/shadcn/Button';
import type { ModelOption } from './types';

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

export function WebsiteModelsRefresh({ refreshing = false, onRefresh }: {
  refreshing?: boolean; onRefresh: () => void }) {
  return <Button variant="ghost" size="sm" aria-label="Refresh website models"
    title="Read the model choices available in your signed-in websites"
    disabled={refreshing} onClick={onRefresh}>{refreshing ? 'Refreshing…' : 'Refresh models'}</Button>;
}
