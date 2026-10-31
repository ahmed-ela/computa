import openai from './assets/providers/openai.svg';
import gemini from './assets/providers/gemini.svg';
import claude from './assets/providers/claude.svg';
import cerebras from './assets/providers/cerebras.svg';
import { Icon } from './Icon';

// Local, licensed brand marks; selectors never fetch provider images at runtime.
const marks: Record<string, string> = { chatgpt: openai, openai, gemini, claude, cerebras };

export function ModelProviderIcon({ model }: { model: string }) {
  const [transport, provider] = model.split('/');
  const mark = (transport === 'browser' || transport === 'api') && Object.hasOwn(marks, provider)
    ? marks[provider] : undefined;
  return mark
    ? <span className={`model-provider-icon provider-${provider}`} data-provider={provider} aria-hidden="true"
        style={{ maskImage: `url("${mark}")`, WebkitMaskImage: `url("${mark}")` }} />
    : <Icon name={transport === 'api' ? 'sparkles' : 'computer'} size={16} />;
}
