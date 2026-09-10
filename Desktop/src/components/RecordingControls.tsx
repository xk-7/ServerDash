import { useEffect, useRef, useState } from 'react';
import { Circle, Square } from 'lucide-react';
import { errorMessage, onDesktopEvent, request, type SessionRef } from '../lib/api';
import { terminalFrame } from '../lib/terminalRegistry';

export default function RecordingControls({ session, onError }: { session: SessionRef; onError: (message: string) => void }) {
  const [recording, setRecording] = useState(false); const [busy, setBusy] = useState(false);
  const active = useRef(false); const errors = useRef(onError); errors.current = onError;
  useEffect(() => {
    let mounted = true; let inFlight = false; let previous = ''; let stop: (() => void) | undefined;
    const timer = setInterval(async () => {
      if (!active.current || inFlight) return;
      try {
        const frame = terminalFrame(session); const encoded = JSON.stringify(frame);
        if (encoded === previous) return;
        inFlight = true; await request('recording_frame', { ...session, frame }); previous = encoded;
      } catch (cause) { active.current = false; if (mounted) { setRecording(false); errors.current(errorMessage(cause)); } }
      finally { inFlight = false; }
    }, 100);
    void onDesktopEvent(event => {
      const payload = event.payload as unknown as { sessionId?: string; generation?: number; status?: string; error?: string };
      if (event.kind as string !== 'recording' || payload.sessionId !== session.sessionId || payload.generation !== session.generation) return;
      if (['saved', 'failed', 'stopped'].includes(payload.status ?? '')) { active.current = false; if (mounted) setRecording(false); if (payload.error) errors.current(payload.error); }
    }).then(unlisten => { if (mounted) stop = unlisten; else unlisten(); });
    return () => { mounted = false; clearInterval(timer); stop?.(); if (active.current) void request('recording_stop', session).catch(() => {}); active.current = false; };
  }, [session.sessionId, session.generation]);
  const toggle = async () => {
    setBusy(true);
    try {
      if (active.current) { active.current = false; await request('recording_stop', session); setRecording(false); }
      else { await request('recording_start', { ...session, frame: terminalFrame(session), name: 'SSH 会话' }); active.current = true; setRecording(true); }
    } catch (cause) { onError(errorMessage(cause)); } finally { setBusy(false); }
  };
  return <button className="icon-button" disabled={busy} onClick={() => void toggle()} title={recording ? '停止录制' : '开始录制'} aria-label={recording ? '停止录制' : '开始录制'}>{recording ? <Square size={14} color="#ee7777" /> : <Circle size={14} />}</button>;
}
