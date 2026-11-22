import { createRoot } from 'octane';
import { Logo } from './Logo';
import './style.css';

createRoot(document.getElementById('root')!).render(
  <main>
    <Logo />
    <a href="/download">Download for macOS</a>
    <p>Apple Silicon · macOS 14 or later</p>
    <a className="notes" href="https://github.com/ahmed-ela/kolmogor/releases">Release notes and checksums</a>
  </main>,
);
