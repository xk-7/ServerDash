import { useEffect, useRef, useState } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { SearchAddon } from '@xterm/addon-search';
import { ArrowDown, ArrowUp, Copy, Search, X } from 'lucide-react';
import { encodeInput, errorMessage, request, subscribeOutput, type SessionRef, type Settings } from '../lib/api';
import { registerTerminal } from '../lib/terminalRegistry';
import RecordingControls from './RecordingControls';

type Props = { session: SessionRef; active: boolean; settings: Settings; canRecord?: boolean; onError: (message: string) => void };
export default function TerminalPane({ session, active, settings, canRecord = false, onError }: Props) {
  const container = useRef<HTMLDivElement>(null);
  const terminal = useRef<Terminal | null>(null);
  const fit = useRef<FitAddon | null>(null);
  const search = useRef<SearchAddon | null>(null);
  const errorRef = useRef(onError); errorRef.current = onError;
  const [searchVisible, setSearchVisible] = useState(false);
  const [query, setQuery] = useState('');
  const [searchResult, setSearchResult] = useState('');

  useEffect(() => {
    if (!container.current) return;
    let alive = true;
    let subscribed = false;
    const current = new Terminal({ cursorBlink: true, convertEol: false, fontSize: settings.terminalFontSize, fontFamily: settings.terminalFontFamily, scrollback: 10_000, allowProposedApi: false, theme: { background: '#101419', foreground: '#d4dde8', cursor: '#6dd6b0', selectionBackground: '#344b57', black: '#17212a', red: '#ef8a84', green: '#78d5a6', yellow: '#e4c482', blue: '#8db7f5', magenta: '#c3a2f3', cyan: '#6dcbd1', white: '#d4dde8', brightBlack: '#71818f' } });
    const fitAddon = new FitAddon(); const searchAddon = new SearchAddon();
    current.loadAddon(fitAddon); current.loadAddon(searchAddon); current.open(container.current);
    const unregister = registerTerminal(session, current);
    terminal.current = current; fit.current = fitAddon; search.current = searchAddon;
    const resize = () => {
      if (!alive || !container.current?.offsetWidth || !container.current?.offsetHeight) return;
      fitAddon.fit();
      if (subscribed) void request('session_resize', { ...session, columns: current.cols, rows: current.rows }).catch(error => alive && errorRef.current(errorMessage(error)));
    };
    const observer = new ResizeObserver(resize); observer.observe(container.current); resize();
    current.attachCustomKeyEventHandler(event => {
      if (event.type !== 'keydown' || !event.ctrlKey || !event.shiftKey) return true;
      if (event.code === 'KeyC') { event.preventDefault(); void navigator.clipboard.writeText(current.getSelection()).catch(error => errorRef.current(errorMessage(error))); return false; }
      if (event.code === 'KeyV') { event.preventDefault(); void navigator.clipboard.readText().then(text => { if (alive) current.paste(text); }).catch(error => errorRef.current(errorMessage(error))); return false; }
      if (event.code === 'KeyF') { event.preventDefault(); setSearchVisible(true); return false; }
      return true;
    });
    const input = current.onData(data => { if (alive) void request('session_write', { ...session, data: encodeInput(data) }).catch(error => alive && errorRef.current(errorMessage(error))); });
    void subscribeOutput(session, (sequence, bytes) => {
      if (!alive) return;
      current.write(bytes, () => {
        if (alive) void request('session_ack', { ...session, sequence }).catch(error => alive && errorRef.current(errorMessage(error)));
      });
    }).then(() => { if (alive) { subscribed = true; resize(); } }).catch(error => alive && errorRef.current(errorMessage(error)));
    return () => { alive = false; observer.disconnect(); input.dispose(); unregister(); current.dispose(); terminal.current = null; fit.current = null; search.current = null; };
    // Terminal lifetime follows the backend connection generation, not navigation or font settings.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session.sessionId, session.generation]);

  useEffect(() => { if (terminal.current) { terminal.current.options.fontSize = settings.terminalFontSize; terminal.current.options.fontFamily = settings.terminalFontFamily; fit.current?.fit(); } }, [settings.terminalFontFamily, settings.terminalFontSize]);
  useEffect(() => { if (active) { const frame = requestAnimationFrame(() => { fit.current?.fit(); terminal.current?.focus(); }); return () => cancelAnimationFrame(frame); } }, [active]);
  const find = (backward = false) => { const options = { decorations: { matchBackground: '#50431d', matchOverviewRuler: '#9e874d', activeMatchBackground: '#a98525', activeMatchColorOverviewRuler: '#eac77a' } }; const found = backward ? search.current?.findPrevious(query, options) : search.current?.findNext(query, options); setSearchResult(found ? '' : '没有匹配项'); };
  return <div className="terminal-wrapper">
    <div className="terminal-corner-actions">{canRecord && <RecordingControls session={session} onError={onError} />}<button className="icon-button" title="搜索终端（Ctrl+Shift+F）" aria-label="搜索终端" onClick={() => setSearchVisible(value => !value)}><Search size={14} /></button><button className="icon-button" title="复制所选内容（Ctrl+Shift+C）" aria-label="复制所选终端内容" onClick={() => void navigator.clipboard.writeText(terminal.current?.getSelection() ?? '').catch(error => onError(errorMessage(error)))}><Copy size={14} /></button></div>
    {searchVisible && <form className="terminal-search" onSubmit={event => { event.preventDefault(); find(); }}><input autoFocus aria-label="终端搜索内容" placeholder="查找终端输出" value={query} onChange={event => setQuery(event.target.value)} /><span role="status">{searchResult}</span><button type="button" className="icon-button" aria-label="上一个匹配" onClick={() => find(true)}><ArrowUp size={14} /></button><button className="icon-button" aria-label="下一个匹配"><ArrowDown size={14} /></button><button type="button" className="icon-button" aria-label="关闭搜索" onClick={() => { setSearchVisible(false); search.current?.clearDecorations(); terminal.current?.focus(); }}><X size={14} /></button></form>}
    <div className="terminal-host" ref={container} />
  </div>;
}
