import openai from './assets/providers/openai.svg';
import gemini from './assets/providers/gemini.png';
import alibabaCloud from './assets/providers/alibaba-cloud.png';
import claude from './assets/providers/claude.svg';
import groq from './assets/providers/groq.svg';
import kimi from './assets/providers/kimi.svg';
import qwen from './assets/providers/qwen.svg';
import deepseek from './assets/providers/deepseek.svg';
import cerebras from './assets/providers/cerebras.svg';
import { Icon } from './Icon';

// Local brand marks; asset provenance and notices live beside the images.
// Preserve the official colors of Gemini and Alibaba Cloud; never fetch them at runtime.
const marks: Record<string, string> = { chatgpt: openai, openai, claude, groq, kimi, qwen, deepseek, cerebras };

export function ModelProviderIcon({ model }: { model: string }) {
  const [transport, provider] = model.split('/');
  const colorMark = provider === 'gemini' && (transport === 'browser' || transport === 'api') ? gemini
    : provider === 'alibaba' && transport === 'api' ? alibabaCloud : undefined;
  if (colorMark) return <img className={`model-provider-icon model-provider-icon-color provider-${provider}`}
    data-provider={provider} aria-hidden="true" alt="" src={colorMark} width={16} height={16} />;
  const mark = (transport === 'browser' || transport === 'api') && Object.hasOwn(marks, provider)
    ? marks[provider] : undefined;
  return mark
    ? <span className={`model-provider-icon provider-${provider}`} data-provider={provider} aria-hidden="true"
        style={{ maskImage: `url("${mark}")`, WebkitMaskImage: `url("${mark}")` }} />
    : <Icon name={transport === 'api' ? 'sparkles' : 'computer'} size={16} />;
}
