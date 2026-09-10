import { useEffect, useState } from 'react';
import { ArrowDownToLine, ArrowUpFromLine, Check, Cloud, FileJson, Folder, KeyRound, LoaderCircle, RefreshCw, ShieldCheck } from 'lucide-react';
import { desktopAvailable, errorMessage, request, type Capabilities } from '../lib/api';
import { Dialog } from './Dialog';
import './ConfigurationPanel.css';

type PortableObject = { id: string; kind: string; fields: Record<string, string>; deleted: boolean };
type Choice = 'unresolved' | 'local' | 'remote' | 'both';
type Change = { id: string; local?: PortableObject | null; remote?: PortableObject | null; choice: Choice; conflict: boolean };
type Preview = { previewId: string; changes: Change[]; ignoredDeletions?: number; cancelled?: boolean };
type SyncSettings = { url: string; username: string; hasPassword: boolean; hasRecoveryKey: boolean };
type Candidate = { index: number; duplicate: boolean; record: { name: string; host: string; port: number; username: string; group?: string; authentication?: string }; source: string; sourcePath: string; warnings: string[]; errors: string[] };
type SessionPreview = { previewId: string; candidates: Candidate[]; warnings: string[]; cancelled?: boolean };
const formats = [['automatic', '自动识别'], ['serverDash', 'ServerDash'], ['openSSH', 'OpenSSH Config'], ['xShell', 'Xshell'], ['secureCRT', 'SecureCRT'], ['mobaXterm', 'MobaXterm'], ['finalShell', 'FinalShell'], ['xTerminal', 'XTerminal'], ['putty', 'PuTTY']];
const exportFormats = formats.filter(([id]) => !['automatic', 'secureCRT', 'finalShell'].includes(id));
const initialSync: SyncSettings = { url: '', username: '', hasPassword: false, hasRecoveryKey: false };

export default function ConfigurationPanel({ capabilities, onChanged, onError, mode = 'all' }: { capabilities: Capabilities; onChanged: () => Promise<void>; onError: (message: string) => void; mode?: 'all' | 'sessions' }) {
  const [busy, setBusy] = useState(''); const [message, setMessage] = useState('');
  const [preview, setPreview] = useState<(Preview & { type: 'config' | 'sync' })>();
  const [sync, setSync] = useState<SyncSettings>(initialSync); const [savedSync, setSavedSync] = useState<SyncSettings>(initialSync); const [password, setPassword] = useState('');
  const [format, setFormat] = useState('automatic'); const [exportFormat, setExportFormat] = useState('serverDash');
  const [sessionPreview, setSessionPreview] = useState<SessionPreview>(); const [selection, setSelection] = useState<Record<number, 'skip' | 'import' | 'copy'>>({});
  const [allowPasswords, setAllowPasswords] = useState(false); const [keyAction, setKeyAction] = useState<'sync_key_generate' | 'sync_key_import'>();
  const transferAvailable = Boolean(capabilities.configurationTransfer) && desktopAvailable();
  const syncAvailable = Boolean(capabilities.webdavSync) && desktopAvailable();
  const syncDirty = sync.url !== savedSync.url || sync.username !== savedSync.username || Boolean(password);
  const updateSync = (value: SyncSettings) => { setSavedSync(value); setSync(value); setPassword(''); };

  useEffect(() => {
    let mounted = true;
    if (syncAvailable && mode !== 'sessions') void request<SyncSettings>('sync_settings_get').then(value => { if (mounted) updateSync(value); }).catch(error => { if (mounted) onError(errorMessage(error)); });
    return () => { mounted = false; };
  }, [syncAvailable, mode]);
  const run = async (operation: string, action: () => Promise<void>) => {
    if (busy) return; setBusy(operation); setMessage('');
    try { await action(); } catch (error) { onError(errorMessage(error)); } finally { setBusy(''); }
  };
  const exportConfig = () => run('config_export', async () => { const result = await request<{ path?: string | null }>('config_export'); if (result.path) setMessage(`配置已导出到 ${result.path}`); });
  const previewConfig = () => run('config_preview', async () => { const result = await request<Preview>('config_import_preview'); if (!result.cancelled) setPreview({ ...result, type: 'config' }); });
  const previewSync = () => run('sync_preview', async () => { const result = await request<Preview>('sync_preview'); if (!result.cancelled) setPreview({ ...result, type: 'sync' }); });
  const apply = () => run(preview?.type === 'sync' ? 'sync_apply' : 'config_apply', async () => {
    if (!preview) return;
    await request(preview.type === 'sync' ? 'sync_apply' : 'config_import_apply', { previewId: preview.previewId, choices: preview.changes.map(change => ({ id: change.id, choice: change.choice })) });
    setPreview(undefined); setMessage(preview.type === 'sync' ? '同步已完成' : '配置已导入'); await onChanged();
  });
  const saveSync = () => run('sync_settings', async () => { updateSync(await request<SyncSettings>('sync_settings_save', { url: sync.url.trim(), username: sync.username, password: password || undefined })); setMessage('WebDAV 设置已保存'); });
  const operateKey = (action: 'sync_key_generate' | 'sync_key_import' | 'sync_key_export') => run(action, async () => {
    const result = await request<SyncSettings & { path?: string | null; cancelled?: boolean }>(action);
    if (result.cancelled) return;
    if (action === 'sync_key_export') { if (result.path) setMessage(`恢复密钥已保存到 ${result.path}`); }
    else { updateSync(result); setMessage(action === 'sync_key_generate' ? '新的恢复密钥已生成，请导出备份。' : '恢复密钥已导入'); }
    setKeyAction(undefined);
  });
  const inspectSessions = (selection: 'file' | 'directory') => run('sessions_preview', async () => {
    const result = await request<SessionPreview>('sessions_import_preview', { format, selection });
    if (result.cancelled) return;
    setSelection(Object.fromEntries(result.candidates.map(candidate => [candidate.index, candidate.errors.length || candidate.duplicate ? 'skip' : 'import'])));
    setAllowPasswords(false); setSessionPreview(result);
  });
  const importSessions = () => run('sessions_apply', async () => {
    if (!sessionPreview) return;
    const selected = sessionPreview.candidates.filter(candidate => selection[candidate.index] !== 'skip' && !candidate.errors.length).map(candidate => ({ index: candidate.index, asCopy: selection[candidate.index] === 'copy' }));
    const result = await request<{ imported: number }>('sessions_import_apply', { previewId: sessionPreview.previewId, selected, allowPlaintextPasswords: allowPasswords });
    setSessionPreview(undefined); setMessage(`已导入 ${result.imported} 个 SSH 会话`); await onChanged();
  });
  const exportSessions = () => run('sessions_export', async () => { const result = await request<{ path?: string | null; warnings?: string[] }>('sessions_export', { format: exportFormat }); if (result.path) setMessage(`会话已导出到 ${result.path}${result.warnings?.length ? `；${result.warnings.join('；')}` : ''}`); });
  return <div className="configuration-panel">
    {mode === 'all' && <section className="settings-section"><div className="settings-section-title"><FileJson size={19} /><div><h2>本地配置包</h2><p>在 Mac 与 Windows 之间交换机器、分组、标签和连接设置。</p></div><span className="pill">{capabilities.configurationTransfer ? 'v1' : '尚未开放'}</span></div><p className="settings-description">配置包不包含密码、私钥、主机信任或本机文件访问权限。导入前可以查看每项变更；省略的项目不会删除本机配置。</p><div className="configuration-actions"><button disabled={!transferAvailable || Boolean(busy)} onClick={() => void previewConfig()}><ArrowDownToLine size={15} />导入配置包</button><button disabled={!transferAvailable || Boolean(busy)} onClick={() => void exportConfig()}><ArrowUpFromLine size={15} />导出配置包</button></div></section>}
    <section className="settings-section"><div className="settings-section-title"><Folder size={19} /><div><h2>客户端会话迁移</h2><p>导入现有 SSH 会话，在应用前检查地址、重复项和格式警告。</p></div></div><div className="session-transfer-row"><label>导入格式<select value={format} onChange={event => setFormat(event.target.value)}>{formats.map(([id, label]) => <option value={id} key={id}>{label}</option>)}</select></label><button disabled={!transferAvailable || Boolean(busy)} onClick={() => void inspectSessions('file')}><ArrowDownToLine size={15} />选择文件或压缩包</button><button disabled={!transferAvailable || Boolean(busy)} onClick={() => void inspectSessions('directory')}><Folder size={15} />选择目录</button></div><div className="session-transfer-row"><label>导出格式<select value={exportFormat} onChange={event => setExportFormat(event.target.value)}>{exportFormats.map(([id, label]) => <option value={id} key={id}>{label}</option>)}</select></label><button disabled={!transferAvailable || Boolean(busy)} onClick={() => void exportSessions()}><ArrowUpFromLine size={15} />导出全部 SSH 会话</button></div><p className="settings-description compact-note">导出不包含凭据。SecureCRT 与 FinalShell 导出尚未通过验收，暂不开放。</p></section>
    {mode === 'all' && <section className="settings-section"><div className="settings-section-title"><Cloud size={19} /><div><h2>WebDAV 配置同步</h2><p>端到端加密的配置交换，每次同步前预览合并结果。</p></div><span className="pill">{capabilities.webdavSync ? '手动同步' : '尚未开放'}</span></div><form onSubmit={event => { event.preventDefault(); void saveSync(); }}><div className="form-grid"><label className="span-2">WebDAV 文件地址<input type="url" required value={sync.url} disabled={!syncAvailable || Boolean(busy)} onChange={event => setSync({ ...sync, url: event.target.value })} placeholder="https://dav.example.com/ServerDash/config.enc" /></label><label>用户名<input value={sync.username} disabled={!syncAvailable || Boolean(busy)} onChange={event => setSync({ ...sync, username: event.target.value })} autoComplete="off" /></label><label>密码<input type="password" autoComplete="new-password" value={password} disabled={!syncAvailable || Boolean(busy)} placeholder={sync.hasPassword ? '已保存；留空保持现有密码' : 'WebDAV 密码'} onChange={event => setPassword(event.target.value)} /></label></div><div className="configuration-actions"><button disabled={!syncAvailable || Boolean(busy) || !syncDirty || !sync.url.trim()}><Check size={15} />保存同步设置</button>{syncDirty && <span className="subtle">先保存设置，再操作恢复密钥或同步。</span>}</div></form><div className="recovery-section"><div><KeyRound size={17} /><span><strong>恢复密钥</strong><small>{savedSync.hasRecoveryKey ? '已保存在本机。换设备时导入同一个恢复密钥。' : '首次使用请生成并备份；已有远端配置请导入原密钥。'}</small></span></div><div className="configuration-actions"><button disabled={!syncAvailable || !savedSync.url || syncDirty || Boolean(busy)} onClick={() => savedSync.hasRecoveryKey ? setKeyAction('sync_key_generate') : void operateKey('sync_key_generate')}>生成密钥</button><button disabled={!syncAvailable || !savedSync.url || syncDirty || Boolean(busy)} onClick={() => savedSync.hasRecoveryKey ? setKeyAction('sync_key_import') : void operateKey('sync_key_import')}>导入密钥</button><button disabled={!syncAvailable || !savedSync.hasRecoveryKey || syncDirty || Boolean(busy)} onClick={() => void operateKey('sync_key_export')}>备份密钥</button></div></div><div className="configuration-actions sync-footer"><button className="primary" disabled={!syncAvailable || !savedSync.hasRecoveryKey || syncDirty || Boolean(busy)} onClick={() => void previewSync()}><RefreshCw size={15} />预览同步</button>{busy.startsWith('sync') && <button onClick={() => void request('sync_cancel').catch(error => onError(errorMessage(error)))}>取消同步</button>}<span className="subtle"><ShieldCheck size={13} />凭据与主机信任不会同步</span></div></section>}
    {busy && <p className="operation-status" role="status"><LoaderCircle size={15} className="spin" />正在处理…</p>}{message && <p className="operation-status success" role="status"><Check size={15} />{message}</p>}
    {preview && <Dialog title={preview.type === 'sync' ? '预览配置同步' : '预览配置导入'} onClose={() => !busy && setPreview(undefined)} wide><p className="dialog-copy">共 {preview.changes.length} 项变更。{preview.changes.some(change => change.choice === 'unresolved') ? '请先为冲突项选择保留的版本。' : '请检查将要应用的结果。'}{Boolean(preview.ignoredDeletions) && `已忽略配置包中的 ${preview.ignoredDeletions} 项删除标记。`}</p><div className="change-list">{preview.changes.map(change => <article key={change.id} className={change.conflict ? 'conflict' : ''}><div className="change-heading"><span className="pill">{(change.local ?? change.remote)?.kind}</span><strong>{(change.local ?? change.remote)?.fields.name ?? (change.local ?? change.remote)?.fields.title ?? change.id}</strong>{change.conflict && <span className="danger-text">冲突</span>}<select aria-label={`选择 ${change.id} 的版本`} value={change.choice} onChange={event => setPreview({ ...preview, changes: preview.changes.map(item => item.id === change.id ? { ...item, choice: event.target.value as Choice } : item) })}><option value="unresolved" disabled>请选择</option><option value="local">保留本机</option><option value="remote">采用{preview.type === 'sync' ? '远端' : '导入'}版本</option>{change.local && !change.local.deleted && ['ssh', 'rdp', 'vnc', 'serial', 'snippet'].includes(change.local.kind) && <option value="both">同时保留（本机副本）</option>}</select></div><div className="change-versions"><ChangeVersion title="本机" value={change.local} /><ChangeVersion title={preview.type === 'sync' ? '远端' : '导入'} value={change.remote} /></div></article>)}{!preview.changes.length && <p className="empty-small subtle">配置已一致，无需变更。</p>}</div><footer className="dialog-footer"><button disabled={Boolean(busy)} onClick={() => setPreview(undefined)}>取消</button><button className="primary" disabled={Boolean(busy) || preview.changes.some(change => change.choice === 'unresolved')} onClick={() => void apply()}>应用{preview.type === 'sync' ? '同步' : '导入'}</button></footer></Dialog>}
    {sessionPreview && <Dialog title="检查会话导入" onClose={() => !busy && setSessionPreview(undefined)} wide><p className="dialog-copy">发现 {sessionPreview.candidates.length} 个会话。重复地址默认跳过；你可以明确选择导入副本。私钥路径需要在导入后重新选择。</p>{sessionPreview.warnings.map(warning => <p key={warning} className="inline-error">{warning}</p>)}<div className="session-import-list">{sessionPreview.candidates.map(candidate => <article key={candidate.index}><div><strong>{candidate.record.name}</strong><span className="pill">{candidate.source}</span><select aria-label={`导入 ${candidate.record.name}`} value={selection[candidate.index]} disabled={Boolean(candidate.errors.length)} onChange={event => setSelection({ ...selection, [candidate.index]: event.target.value as 'skip' | 'import' | 'copy' })}><option value="skip">跳过</option>{!candidate.duplicate && <option value="import">导入</option>}<option value="copy">导入副本</option></select></div><p className="mono">{candidate.record.username}@{candidate.record.host}:{candidate.record.port}</p><small>{candidate.sourcePath}{candidate.duplicate ? ' · 已有同地址会话' : ''}</small>{candidate.errors.map(error => <p className="danger-text" key={error}>{error}</p>)}{candidate.warnings.map(warning => <p className="subtle" key={warning}>{warning}</p>)}</article>)}</div><label className="checkbox-label password-import"><input type="checkbox" checked={allowPasswords} onChange={event => setAllowPasswords(event.target.checked)} />允许将文件中的明文密码加密保存到本机</label><footer className="dialog-footer"><span className="subtle">已选择 {Object.values(selection).filter(value => value !== 'skip').length} 项</span><button disabled={Boolean(busy)} onClick={() => setSessionPreview(undefined)}>取消</button><button className="primary" disabled={Boolean(busy) || !Object.values(selection).some(value => value !== 'skip')} onClick={() => void importSessions()}>导入所选会话</button></footer></Dialog>}
    {keyAction && <Dialog title="替换本机恢复密钥" onClose={() => setKeyAction(undefined)}><p className="dialog-copy">本机已有恢复密钥。替换后，使用原密钥加密的远端配置仍需要原密钥才能解密。请确认已备份原密钥。</p><footer className="dialog-footer"><button onClick={() => setKeyAction(undefined)}>取消</button><button className="danger" disabled={Boolean(busy)} onClick={() => void operateKey(keyAction)}>继续{keyAction === 'sync_key_generate' ? '生成' : '导入'}</button></footer></Dialog>}
  </div>;
}

function ChangeVersion({ title, value }: { title: string; value?: PortableObject | null }) {
  return <div><h4>{title}</h4>{!value ? <p className="subtle">不存在</p> : value.deleted ? <p className="danger-text">删除标记</p> : <dl>{Object.entries(value.fields).map(([key, value]) => <div key={key}><dt>{key}</dt><dd>{value || '—'}</dd></div>)}</dl>}</div>;
}
