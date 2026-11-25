import { createRoot } from 'octane';
import { App } from './App';
import './shadcn.css';
import './styles.css';

// WebKit pauses CSS transitions in hidden windows. Keep their layout at its final width.
const syncVisibility = () => document.documentElement.toggleAttribute('data-page-visible', !document.hidden);
syncVisibility();
document.addEventListener('visibilitychange', syncVisibility);

const root = createRoot(document.getElementById('root')!);
root.render(App);
