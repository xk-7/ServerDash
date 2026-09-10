import { useEffect, useRef, type ReactNode } from 'react';
import { X } from 'lucide-react';

export function Dialog({ title, children, onClose, wide = false, dismissible = true }: { title: string; children: ReactNode; onClose: () => void; wide?: boolean; dismissible?: boolean }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => { const dialog = ref.current; dialog?.showModal(); return () => dialog?.close(); }, []);
  return <dialog ref={ref} className={`dialog ${wide ? 'dialog-wide' : ''}`} onCancel={event => { event.preventDefault(); if (dismissible) onClose(); }} aria-label={title}>
    <div className="dialog-title"><h2>{title}</h2>{dismissible && <button className="icon-button" aria-label="关闭对话框" onClick={onClose}><X size={18} /></button>}</div>{children}
  </dialog>;
}
