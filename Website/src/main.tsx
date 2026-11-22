import { createRoot } from 'octane';
import './style.css';

createRoot(document.getElementById('root')!).render(
  <main>
    <img src="/computa-pastel.png" alt="Computa" />
    <a href="/download">Download for macOS</a>
    <p>Apple Silicon · macOS 14 or later</p>
    <a className="notes" href="https://github.com/ahmed-ela/computa/releases">Release notes and checksums</a>
  </main>,
);
