import { useCallback, useEffect, useState } from 'react';
import { ArrowDownToLine, ArrowLeft, ArrowUpFromLine, File, FilePenLine, Folder, FolderPlus, RefreshCw, Trash2 } from 'lucide-react';
import { errorMessage, normalizeFiles, request, type FileEntry, type SessionRef, type Transfer } from '../lib/api';
import { bytes, joinRemotePath, parentPath } from '../lib/workspace';
import { Dialog } from './Dialog';

type Props = { session: SessionRef; initialPath: string; transfers: Transfer[]; onError: (message: string) => void };
export default function FilesPanel({ session, initialPath, transfers, onError }: Props) {
  const [path, setPath] = useState(initialPath); const [inputPath, setInputPath] = useState(initialPath);
  const [entries, setEntries] = useState<FileEntry[]>([]); const [busy, setBusy] = useState(false);
  const [selected, setSelected] = useState<FileEntry>();
  const [operation, setOperation] = useState<'mkdir' | 'rename' | 'delete' | null>(null); const [name, setName] = useState('');
  const [editor, setEditor] = useState<{ path: string; text: string; original: string; version?: string }>();
  const [editorError, setEditorError] = useState(''); const [dirtyClose, setDirtyClose] = useState(false);
  const [inlineError, setInlineError] = useState('');
  const load = useCallback(async (nextPath: string) => {
    setBusy(true); setInlineError('');
    try {
      const result = await request<FileEntry[] | { entries: FileEntry[]; path?: string }>('file_list', { ...session, path: nextPath });
      setEntries(normalizeFiles(result).sort((a, b) => Number(b.isDirectory) - Number(a.isDirectory) || a.name.localeCompare(b.name, 'zh-CN', { numeric: true })));
      const canonical = Array.isArray(result) ? nextPath : result.path ?? nextPath;
      setPath(canonical); setInputPath(canonical); setSelected(undefined);
    } catch (error) { setInlineError(errorMessage(error)); } finally { setBusy(false); }
  }, [session.sessionId, session.generation]);
  useEffect(() => { void load(initialPath); }, [initialPath, load]);

  const mutate = async () => {
    setBusy(true); setInlineError('');
    try {
      if (operation === 'mkdir') await request('file_mkdir', { ...session, path: joinRemotePath(path, name) });
      else if (operation === 'rename' && selected) await request('file_rename', { ...session, from: selected.path, to: joinRemotePath(path, name) });
      else if (operation === 'delete' && selected) await request('file_delete', { ...session, path: selected.path, isDirectory: selected.isDirectory });
      setOperation(null); await load(path);
    } catch (error) { setInlineError(errorMessage(error)); } finally { setBusy(false); }
  };
  const transfer = async (direction: 'upload' | 'download') => {
    setBusy(true);
    try {
      const picked = await request<{ path: string | null }>('file_choose_local', { mode: direction === 'upload' ? 'open' : 'save', name: selected?.name });
      if (!picked.path) return;
      const remotePath = direction === 'upload' ? joinRemotePath(path, picked.path.split(/[\\/]/).at(-1)!) : selected!.path;
      await request(`file_${direction}`, { ...session, localPath: picked.path, remotePath, overwrite: false });
      if (direction === 'upload') await load(path);
    } catch (error) { onError(errorMessage(error)); } finally { setBusy(false); }
  };
  const edit = async () => {
    if (!selected) return;
    setBusy(true);
    try { const response = await request<{ text: string; version?: string }>('file_read', { ...session, path: selected.path }); setEditor({ path: selected.path, ...response, original: response.text }); setEditorError(''); }
    catch (error) { onError(errorMessage(error)); } finally { setBusy(false); }
  };
  const saveEditor = async () => {
    if (!editor) return; setBusy(true); setEditorError('');
    try { const result = await request<{ version?: string }>('file_write', { ...session, path: editor.path, text: editor.text, version: editor.version }); setEditor({ ...editor, original: editor.text, version: result?.version }); await load(path); }
    catch (error) { setEditorError(errorMessage(error)); } finally { setBusy(false); }
  };
  return <div className="files-panel">
    <div className="panel-title"><h3>远程文件</h3><span className="pill">SFTP</span></div>
    <form className="path-bar" onSubmit={event => { event.preventDefault(); void load(inputPath); }}><button className="icon-button" type="button" title="上一级" aria-label="上一级目录" disabled={busy || path === '/'} onClick={() => void load(parentPath(path))}><ArrowLeft size={16} /></button><input aria-label="远程目录路径" value={inputPath} onChange={event => setInputPath(event.target.value)} spellCheck={false} /><button className="icon-button" aria-label="刷新目录" disabled={busy}><RefreshCw size={15} className={busy ? 'spin' : ''} /></button></form>
    <div className="file-actions"><button disabled={busy} onClick={() => void transfer('upload')}><ArrowUpFromLine size={14} />上传</button><button disabled={busy || !selected || selected.isDirectory} onClick={() => void transfer('download')} title="下载选中的文件"><ArrowDownToLine size={14} /></button><button disabled={busy} onClick={() => { setName(''); setOperation('mkdir'); }} title="新建文件夹"><FolderPlus size={14} /></button><button disabled={busy || !selected || selected.isDirectory || selected.size > 1024 * 1024} title="编辑文本文件（最大 1 MiB）" onClick={() => void edit()}><FilePenLine size={14} /></button><button disabled={busy || !selected} title="重命名" onClick={() => { setName(selected?.name ?? ''); setOperation('rename'); }}>重命名</button><button disabled={busy || !selected} title="删除" onClick={() => setOperation('delete')}><Trash2 size={14} /></button></div>
    {inlineError && <p className="inline-error" role="alert">{inlineError}</p>}
    <div className="file-list" role="listbox" aria-label="远程文件" aria-busy={busy}>{entries.map(entry => <button key={entry.path} role="option" aria-selected={selected?.path === entry.path} className={`file-row ${selected?.path === entry.path ? 'selected' : ''}`} onClick={() => setSelected(entry)} onDoubleClick={() => entry.isDirectory && void load(entry.path)} title={`${entry.path}${entry.isSymlink ? ' · 符号链接' : ''}`}>
      {entry.isDirectory ? <Folder size={16} className="folder-icon" /> : <File size={16} />}<span>{entry.name}</span><small>{entry.isDirectory ? '目录' : bytes(entry.size)}</small>
    </button>)}{!busy && entries.length === 0 && !inlineError && <p className="subtle empty-small">此目录为空</p>}</div>
    <div className="transfers"><h4>传输队列 <span>{transfers.length}</span></h4>{transfers.length === 0 ? <p className="subtle">暂无传输任务</p> : transfers.map(item => <div className="transfer" key={item.id}><span>{item.name}</span><small>{item.error ?? `${bytes(item.transferred)} / ${bytes(item.total)} · ${item.status}`}</small><progress value={item.transferred} max={item.total || 1} /></div>)}</div>
    {operation && <Dialog title={operation === 'mkdir' ? '新建文件夹' : operation === 'rename' ? '重命名' : '删除远程文件'} onClose={() => setOperation(null)}><form onSubmit={event => { event.preventDefault(); void mutate(); }}>
      {operation === 'delete' ? <p className="dialog-copy">确定删除 <strong>{selected?.name}</strong>？远程文件不会移入回收站。目录必须为空才能删除。</p> : <label className="dialog-field">名称<input autoFocus required value={name} onChange={event => setName(event.target.value)} /></label>}
      {inlineError && <p className="inline-error">{inlineError}</p>}<footer className="dialog-footer"><button type="button" onClick={() => setOperation(null)}>取消</button><button className={operation === 'delete' ? 'danger' : 'primary'} disabled={busy}>{operation === 'delete' ? '删除' : '保存'}</button></footer>
    </form></Dialog>}
    {editor && <Dialog title={`编辑 · ${editor.path.split('/').at(-1)}`} onClose={() => { if (editor.text !== editor.original) setDirtyClose(true); else setEditor(undefined); }} wide><p className="editor-path">{editor.path}</p><textarea className="remote-editor" spellCheck={false} value={editor.text} onChange={event => setEditor({ ...editor, text: event.target.value })} aria-label="远程文件内容" />{editorError && <p className="inline-error" role="alert">{editorError}</p>}{dirtyClose ? <footer className="dialog-footer"><span>有未保存的修改</span><button onClick={() => setDirtyClose(false)}>继续编辑</button><button className="danger" onClick={() => { setEditor(undefined); setDirtyClose(false); }}>放弃修改</button></footer> : <footer className="dialog-footer"><span className="subtle">{editor.text === editor.original ? '已保存' : '尚未保存'}</span><button className="primary" onClick={() => void saveEditor()} disabled={busy || editor.text === editor.original}>保存到服务器</button></footer>}</Dialog>}
  </div>;
}
