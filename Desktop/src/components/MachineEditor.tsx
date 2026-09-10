import { useState } from 'react';
import { LockKeyhole, Server } from 'lucide-react';
import { errorMessage, request, type Machine, type MachineKind } from '../lib/api';
import { Dialog } from './Dialog';

export default function MachineEditor({ machine, onClose, onSave }: { machine?: Machine; onClose: () => void; onSave: (machine: Machine) => void }) {
  const [draft, setDraft] = useState<Machine>(machine ?? { id: crypto.randomUUID(), name: '', kind: 'ssh', host: '', port: 22, username: '', group: '', tags: [], notes: '', monitoringEnabled: true, authentication: 'password', defaultRemotePath: '.' });
  const [secret, setSecret] = useState(''); const [passphrase, setPassphrase] = useState(''); const [error, setError] = useState(''); const [saving, setSaving] = useState(false);
  const set = <K extends keyof Machine>(key: K, value: Machine[K]) => setDraft(previous => ({ ...previous, [key]: value }));
  const save = async () => {
    setSaving(true); setError('');
    try {
      let credentialId = draft.credentialId;
      if (secret || passphrase) {
        const patch = draft.authentication === 'privateKey' ? { passphrase: secret } : draft.authentication === 'keyThenPassword' ? { ...(secret ? { password: secret } : {}), ...(passphrase ? { passphrase } : {}) } : { password: secret };
        const saved = await request<{ credentialId: string }>('credential_save', { secret: patch, baseCredentialId: draft.credentialId, name: draft.name });
        credentialId = saved.credentialId; set('credentialId', credentialId); setSecret(''); setPassphrase('');
      }
      const value = { ...draft, name: draft.name.trim(), host: draft.host.trim(), username: draft.username.trim(), credentialId,
        ...(draft.kind === 'serial' ? { devicePath: draft.host.trim(), baudRate: draft.baudRate ?? 115200, dataBits: draft.dataBits ?? 8, parity: draft.parity ?? 'none', stopBits: draft.stopBits ?? 1, flowControl: draft.flowControl ?? 'none' } : {}) };
      const saved = await request<Machine | null>('machine_save', { machine: value }); onSave(saved ?? value);
    } catch (cause) { setError(errorMessage(cause)); } finally { setSaving(false); }
  };
  return <Dialog title={machine ? '编辑机器' : '添加机器'} onClose={onClose} wide>
    <form onSubmit={event => { event.preventDefault(); void save(); }}>
      <div className="protocol-picker">{(['ssh', 'rdp', 'vnc', 'serial'] as MachineKind[]).map(kind => <button key={kind} type="button" className={draft.kind === kind ? 'selected' : ''} onClick={() => setDraft(previous => ({ ...previous, kind, port: kind === 'rdp' ? 3389 : kind === 'vnc' ? 5900 : 22, monitoringEnabled: kind === 'ssh' }))}><Server size={16} />{kind === 'serial' ? '串口' : kind.toUpperCase()}</button>)}</div>
      <div className="form-grid"><label className="span-2">名称<input required maxLength={150} placeholder="例如：生产环境 · 北京" value={draft.name} onChange={event => set('name', event.target.value)} /></label><label>{draft.kind === 'serial' ? '设备路径' : '主机地址'}<input required autoCapitalize="none" spellCheck={false} placeholder={draft.kind === 'serial' ? 'COM3' : '192.168.1.100'} value={draft.host} onChange={event => set('host', event.target.value)} /></label><label>端口<input type="number" required min={1} max={65535} value={draft.port} onChange={event => set('port', Number(event.target.value))} disabled={draft.kind === 'serial'} /></label>
      {(draft.kind === 'ssh' || draft.kind === 'rdp') && <><label>用户名<input required autoComplete="off" placeholder="用户名" value={draft.username} onChange={event => set('username', event.target.value)} /></label><label>认证方式<select value={draft.authentication} onChange={event => set('authentication', event.target.value as Machine['authentication'])}><option value="password">密码</option>{draft.kind === 'ssh' && <><option value="privateKey">私钥文件</option><option value="keyThenPassword">密钥后尝试密码</option><option value="agent">SSH Agent</option></>}</select></label>{(draft.authentication === 'privateKey' || draft.authentication === 'keyThenPassword') && <label className="span-2">私钥文件路径<input required={draft.authentication === 'privateKey'} placeholder="C:\Users\you\.ssh\id_ed25519" value={draft.privateKeyPath ?? ''} onChange={event => set('privateKeyPath', event.target.value)} /></label>}{draft.authentication === 'keyThenPassword' && <label className="span-2">私钥口令（可选）<input type="password" autoComplete="new-password" value={passphrase} onChange={event => setPassphrase(event.target.value)} placeholder="加密私钥的口令" /></label>}{draft.authentication !== 'agent' && <label className="span-2">{draft.authentication === 'privateKey' ? '私钥口令（可选）' : '密码'}<input type="password" autoComplete="new-password" placeholder={draft.credentialId ? '已安全保存；留空保留现有凭据' : '使用 Windows 用户凭据加密保存'} value={secret} onChange={event => setSecret(event.target.value)} /></label>}</>}
      {draft.kind === 'serial' && <><label>波特率<input type="number" min={300} max={921600} required value={draft.baudRate ?? 115200} onChange={event => set('baudRate', Number(event.target.value))} /></label><label>数据位<select value={draft.dataBits ?? 8} onChange={event => set('dataBits', Number(event.target.value))}>{[5, 6, 7, 8].map(bits => <option key={bits}>{bits}</option>)}</select></label><label>校验位<select value={draft.parity ?? 'none'} onChange={event => set('parity', event.target.value as Machine['parity'])}><option value="none">无</option><option value="odd">奇校验</option><option value="even">偶校验</option></select></label><label>停止位<select value={draft.stopBits ?? 1} onChange={event => set('stopBits', Number(event.target.value))}><option>1</option><option>2</option></select></label><label>流控<select value={draft.flowControl ?? 'none'} onChange={event => set('flowControl', event.target.value as Machine['flowControl'])}><option value="none">无</option><option value="hardware">RTS/CTS</option><option value="software">XON/XOFF</option></select></label></>}
      <label>分组<input placeholder="未分组" value={draft.group} onChange={event => set('group', event.target.value)} /></label><label>标签<input placeholder="用逗号分隔" value={draft.tags.join(', ')} onChange={event => set('tags', event.target.value.split(/[,，]/).map(tag => tag.trim()).filter(Boolean))} /></label><label className="span-2">备注<textarea rows={2} value={draft.notes} onChange={event => set('notes', event.target.value)} placeholder="连接用途或维护说明" /></label>
      {draft.kind === 'ssh' && <><label className="span-2">默认远程目录<input value={draft.defaultRemotePath ?? '.'} onChange={event => set('defaultRemotePath', event.target.value)} /></label><label className="checkbox-label span-2"><input type="checkbox" checked={draft.monitoringEnabled} onChange={event => set('monitoringEnabled', event.target.checked)} />启用 Linux 资源监控</label></>}
      </div><p className="form-note"><LockKeyhole size={14} />长期凭据在本机加密存储，保存后不会返回界面。</p>
      {error && <p className="inline-error" role="alert">{error}</p>}<footer className="dialog-footer"><button type="button" onClick={onClose} disabled={saving}>取消</button><button className="primary" disabled={saving}>{saving ? '正在保存…' : '保存机器'}</button></footer>
    </form>
  </Dialog>;
}
