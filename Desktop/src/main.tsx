import ReactDOM from 'react-dom/client';
import App from './App';
import './styles.css';
import '@xterm/xterm/css/xterm.css';

// A native session owns one bounded output receiver. StrictMode's development-only
// effect replay would consume that receiver twice and discard its first output.
ReactDOM.createRoot(document.getElementById('root')!).render(<App />);
