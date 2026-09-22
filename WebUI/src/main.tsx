import { createRoot } from 'octane';
import { App } from './App';
import './styles.css';

const root = createRoot(document.getElementById('root')!);
root.render(App);
