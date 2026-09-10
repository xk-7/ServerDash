import '../services.css';
import { useEffect, useRef, useState } from 'react';
import { Folder, Play, Pause, RefreshCw } from 'lucide-react';
import { desktopAvailable, errorMessage, request } from '../lib/api';
import { drawRecording, type Frame } from '../lib/terminalRegistry';

type Recording = { id: string; name: string; duration: number; complete: boolean; path?: string };
export default function Recordings({ available, onError }: { available: boolean; onError: (message: string) => void }) {
  const [items, setItems] = useState<Recording[]>([]); const [selected, setSelected] = useState<Recording>();
  const [position, setPosition] = useState(0); const [playing, setPlaying] = useState(false); const [speed, setSpeed] = useState(1);
  const canvas = useRef<HTMLCanvasElement>(null); const latest = useRef(0);
  const load = async () => { if (!desktopAvailable()) return; try { setItems(await request('recording_list')); } catch (e) { onError(errorMessage(e)); } };
  useEffect(() => { void load(); }, []);
  useEffect(() => {
    if (!selected) return; let alive = true; let running = false; let renderedTime: number | undefined;
    const render = async () => {
      if (running || renderedTime === latest.current) return; running = true; const target = latest.current;
      try { const frame = await request<Frame>('recording_seek', { id: selected.id, time: target }); if (alive && canvas.current && target === latest.current) { drawRecording(canvas.current, frame); renderedTime = target; } }
      catch (e) { if (alive) { setPlaying(false); onError(errorMessage(e)); } } finally { running = false; }
    };
    void render(); const timer = setInterval(() => void render(), 100); return () => { alive = false; clearInterval(timer); };
  }, [selected?.id]);
  useEffect(() => {
    if (!playing || !selected) return; let previous = performance.now();
    const timer = setInterval(() => { const now = performance.now(); const next = Math.min(selected.duration, latest.current + (now - previous) / 1000 * speed); previous = now; latest.current = next; setPosition(next); if (next >= selected.duration) setPlaying(false); }, 50);
    return () => clearInterval(timer);
  }, [playing, selected?.id, speed]);
  const select = (item: Recording) => { setPlaying(false); latest.current = 0; setPosition(0); setSelected(item); };
  const open = async () => { try { const item = await request<Recording & { cancelled?: boolean }>('recording_open'); if (!item.cancelled) { setItems(old => [item, ...old.filter(r => r.id !== item.id)]); select(item); } } catch (e) { onError(errorMessage(e)); } };
  return <div className="page"><div className="page-heading"><div><div className="eyebrow">SESSION RECORDINGS</div><h1>录制</h1><p>只读屏幕回放；录制中的命令和控制序列不会执行。</p></div><div className="toolbar-actions"><button onClick={() => void load()}><RefreshCw size={15} />刷新</button><button disabled={!available} onClick={() => void open()}><Folder size={15} />打开 .sdrec</button></div></div>
    <div className="recording-layout"><div className="recording-library">{items.map(item => <button className={item.id === selected?.id ? 'selected' : ''} key={item.id} onClick={() => select(item)}><strong>{item.name}</strong><small>{item.duration.toFixed(1)} 秒 · {item.complete ? '完整' : '可恢复的部分文件'}</small></button>)}{!items.length && <p className="subtle">在 SSH 面板右上角开始录制，或打开已有文件。</p>}</div>
    <div className="recording-player">{selected ? <><h2>{selected.name}</h2>{!selected.complete && <p role="status">文件未完整结束，正在播放已验证的部分。</p>}<div className="recording-canvas"><canvas ref={canvas} aria-label="终端录制画面" /></div><div className="recording-transport"><button aria-label={playing ? '暂停' : '播放'} onClick={() => { if (position >= selected.duration) { latest.current = 0; setPosition(0); } setPlaying(v => !v); }}>{playing ? <Pause size={16} /> : <Play size={16} />}</button><input type="range" min={0} max={selected.duration} step={0.1} value={position} aria-label="回放时间" onChange={e => { latest.current = Number(e.target.value); setPosition(latest.current); }} /><span>{position.toFixed(1)} / {selected.duration.toFixed(1)} 秒</span><select aria-label="回放速度" value={speed} onChange={e => setSpeed(Number(e.target.value))}>{[0.5, 1, 2, 4].map(v => <option key={v} value={v}>{v}×</option>)}</select></div></> : <p className="subtle">选择录制开始回放</p>}</div></div></div>;
}
