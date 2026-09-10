import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { Activity, ArrowDownLeft, ArrowUpRight, Bot, Braces, Check, ChevronRight, CircleDot, Cpu, Folder, Gauge, Grid2X2, HardDrive, KeyRound, LayoutList, LoaderCircle, MemoryStick, Monitor, MoreHorizontal, Network, PanelLeftClose, PanelRight, Pencil, Play, Plus, Power, RefreshCw, Search, Server, Settings2, ShieldCheck, SlidersHorizontal, SquareTerminal, TerminalSquare, Trash2, UserRound, X } from 'lucide-react';
import { bootstrap, defaultSettings, desktopAvailable, errorMessage, request, onDesktopEvent, mergeTransfer, type Bootstrap, type DesktopEvent, type Machine, type Monitoring, type SessionRef, type SessionStatus, type Settings, type Snippet, type Transfer, type TransferEvent, type TrustRequest } from './lib/api';
import { addPane, bytes, filterMachines, matchesSession, movePane, type Pane, type WorkspaceTab } from './lib/workspace';
import MachineEditor from './components/MachineEditor';
import TerminalPane from './components/TerminalPane';
import FilesPanel from './components/FilesPanel';
import ConfigurationPanel from './components/ConfigurationPanel';
import AIPanel from './components/AIPanel';
import Recordings from './components/Recordings';
import { Dialog } from './components/Dialog';

type Route = 'dashboard' | 'machines' | 'terminal' | 'identities' | 'sshKeys' | 'snippets' | 'recordings' | 'trustedHosts' | 'connections' | 'settings';
const nav: { title: string; items: { route: Route; title: string; icon: typeof Server }[] }[] = [
  { title: '工作区', items: [{ route: 'dashboard', title: '仪表盘', icon: Gauge }, { route: 'machines', title: '机器', icon: Server }, { route: 'terminal', title: '会话', icon: TerminalSquare }] },
  { title: '资源', items: [{ route: 'identities', title: '身份', icon: UserRound }, { route: 'sshKeys', title: 'SSH 密钥', icon: KeyRound }, { route: 'snippets', title: '代码片段', icon: Braces }, { route: 'recordings', title: '录制', icon: CircleDot }] },
  { title: '连接与安全', items: [{ route: 'trustedHosts', title: '可信主机', icon: ShieldCheck }, { route: 'connections', title: '连接与隧道', icon: Network }] },
];
const routeTitles = Object.fromEntries(nav.flatMap(section => section.items.map(item => [item.route, item.title])));
const emptyData: Bootstrap = { machines: [], settings: defaultSettings, snippets: [], trustedHosts: [], identities: [], sshKeys: [], capabilities: {} };
const kindLabel = (kind: string) => kind === 'local' ? '本地' : kind === 'serial' ? '串口' : kind.toUpperCase();

export default function App() {
  const [data, setData] = useState<Bootstrap>(emptyData); const [loading, setLoading] = useState(true); const [bootError, setBootError] = useState('');
  const [route, setRoute] = useState<Route>('dashboard'); const [collapsed, setCollapsed] = useState(false);
  const [editor, setEditor] = useState<Machine | 'new' | null>(null); const [error, setError] = useState(''); const [toast, setToast] = useState('');
  const [tabs, setTabs] = useState<WorkspaceTab[]>([]); const [selectedTab, setSelectedTab] = useState('');
  const tabsRef = useRef(tabs); tabsRef.current = tabs;
  const ownedPanes = useRef(new Set<string>());
  const [monitoring, setMonitoring] = useState<Record<string, Monitoring>>({}); const [refreshing, setRefreshing] = useState(false);
  const [trustQueue, setTrustQueue] = useState<TrustRequest[]>([]); const [trustBusy, setTrustBusy] = useState(false);
  const [transfers, setTransfers] = useState<Transfer[]>([]); const [inspector, setInspector] = useState<'files' | 'monitor' | 'snippets' | 'ai' | null>(null);
  const [pendingDelete, setPendingDelete] = useState<Machine[]>([]); const [deleting, setDeleting] = useState(false);
  const [connectPicker, setConnectPicker] = useState<{ split: boolean } | null>(null);
  const statuses = useRef(new Map<string, SessionStatus>());
  const showError = useCallback((message: string) => setError(message), []);

  const load = useCallback(async () => {
    setBootError('');
    try { if (desktopAvailable()) setData(await bootstrap()); }
    catch (cause) { setBootError(errorMessage(cause)); } finally { setLoading(false); }
  }, []);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    const media = matchMedia('(prefers-color-scheme: dark)');
    const update = () => { document.documentElement.dataset.theme = data.settings.theme === 'system' ? media.matches ? 'dark' : 'light' : data.settings.theme; };
    update(); media.addEventListener('change', update); return () => media.removeEventListener('change', update);
  }, [data.settings.theme]);
  useEffect(() => { if (!toast) return; const timeout = setTimeout(() => setToast(''), 4000); return () => clearTimeout(timeout); }, [toast]);
  useEffect(() => {
    let disposed = false; let stop: (() => void) | undefined;
    void onDesktopEvent((event: DesktopEvent) => {
      if (disposed) return;
      if (event.kind === 'trust') { const value = event.payload as TrustRequest; setTrustQueue(queue => queue.some(item => (item.requestId ?? item.id) === (value.requestId ?? value.id)) ? queue : [...queue, value]); }
      if (event.kind === 'trust_expired') { const value = event.payload as { requestId: string }; setTrustQueue(queue => queue.filter(item => (item.requestId ?? item.id) !== value.requestId)); }
      if (event.kind === 'session_status') {
        const status = event.payload as SessionStatus; statuses.current.set(`${status.sessionId}:${status.generation}`, status);
        setTabs(previous => previous.map(tab => ({ ...tab, panes: tab.panes.map(pane => matchesSession(pane, status) ? { ...pane, status: status.status, error: status.message } : pane) })));
      }
      if (event.kind === 'monitoring') { const value = event.payload as Monitoring; setMonitoring(previous => ({ ...previous, [value.machineId]: value })); }
      if (event.kind === 'transfer') { const value = event.payload as TransferEvent; const id = value.taskId ?? value.id; if (id) setTransfers(previous => [mergeTransfer(previous.find(item => item.id === id), value), ...previous.filter(item => item.id !== id)].slice(0, 100)); }
    }).then(unlisten => { if (disposed) unlisten(); else stop = unlisten; }).catch(cause => showError(errorMessage(cause)));
    return () => { disposed = true; stop?.(); };
  }, [showError]);
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => { if (event.ctrlKey && event.key === ',') { event.preventDefault(); setRoute('settings'); } };
    window.addEventListener('keydown', onKey); return () => window.removeEventListener('keydown', onKey);
  }, []);

  const openSession = async (machine?: Machine, split = false) => {
    if (machine?.kind === 'vnc') { try { await request('vnc_open', { machineId: machine.id }); setToast('已打开外部 VNC 客户端'); } catch (cause) { showError(errorMessage(cause)); } return; }
    const kind = machine?.kind ?? 'local';
    if (kind === 'rdp' && !data.capabilities.rdp) { showError('当前构建尚未启用原生 RDP 显示适配。机器配置已保留，可在支持 RDP 的构建中连接。'); return; }
    const paneId = crypto.randomUUID();
    const pane: Pane = { id: paneId, requestId: paneId, machineId: machine?.id, title: machine?.name ?? 'Windows PowerShell', kind, status: 'connecting' };
    const current = tabsRef.current.find(tab => tab.id === selectedTab);
    if (split && current) {
      try { const updated = addPane(current, pane); setTabs(previous => previous.map(tab => tab.id === current.id ? updated : tab)); }
      catch (cause) { showError(errorMessage(cause)); return; }
    } else {
      const tab: WorkspaceTab = { id: crypto.randomUUID(), title: pane.title, panes: [pane], focusedPaneId: pane.id };
      setTabs(previous => [...previous, tab]); setSelectedTab(tab.id);
    }
    ownedPanes.current.add(pane.id);
    setRoute('terminal'); setConnectPicker(null);
    try {
      const session = await request<SessionRef>('session_open', { requestId: pane.requestId, machineId: machine?.id, kind, columns: 120, rows: 30 });
      // A user may close a connecting pane before the backend completes authentication.
      if (!ownedPanes.current.has(pane.id)) { await request('session_close', session); return; }
      const observed = statuses.current.get(`${session.sessionId}:${session.generation}`);
      setTabs(previous => previous.map(tab => ({ ...tab, panes: tab.panes.map(item => item.id === pane.id ? { ...item, session, status: observed?.status ?? 'connected', error: observed?.message } : item) })));
    } catch (cause) { setTabs(previous => previous.map(tab => ({ ...tab, panes: tab.panes.map(item => item.id === pane.id ? { ...item, status: 'failed', error: errorMessage(cause) } : item) }))); }
  };
  const closePane = async (tabId: string, paneId?: string) => {
    const closing = tabsRef.current.find(tab => tab.id === tabId); if (!closing) return;
    const panes = paneId ? closing.panes.filter(pane => pane.id === paneId) : closing.panes;
    for (const pane of panes) ownedPanes.current.delete(pane.id);
    setTabs(previous => previous.flatMap(tab => {
      if (tab.id !== tabId) return [tab];
      const remaining = paneId ? tab.panes.filter(pane => pane.id !== paneId) : [];
      return remaining.length ? [{ ...tab, panes: remaining, focusedPaneId: remaining.some(pane => pane.id === tab.focusedPaneId) ? tab.focusedPaneId : remaining[0].id }] : [];
    }));
    for (const pane of panes) {
      try { if (pane.session) await request('session_close', pane.session); else if (pane.requestId && pane.status === 'connecting') await request('session_cancel_open', { requestId: pane.requestId }); }
      catch (cause) { showError(errorMessage(cause)); }
    }
  };
  useEffect(() => { if (!tabs.some(tab => tab.id === selectedTab)) setSelectedTab(tabs[0]?.id ?? ''); }, [tabs, selectedTab]);
  const refresh = useCallback(async () => {
    if (!desktopAvailable()) return;
    setRefreshing(true);
    const machines = data.machines.filter(machine => machine.kind === 'ssh' && machine.monitoringEnabled);
    // Bound concurrent SSH handshakes for large inventories.
    for (let index = 0; index < machines.length; index += 4) await Promise.all(machines.slice(index, index + 4).map(async machine => {
      try { const snapshot = await request<Monitoring>('monitor_refresh', { machineId: machine.id }); if (snapshot) setMonitoring(previous => ({ ...previous, [machine.id]: snapshot })); }
      catch (cause) { setMonitoring(previous => ({ ...previous, [machine.id]: { ...previous[machine.id], machineId: machine.id, status: 'failed', error: errorMessage(cause) } })); }
    }));
    setRefreshing(false);
  }, [data.machines]);
  useEffect(() => { if (!data.settings.refreshInterval || route !== 'dashboard') return; const timer = setInterval(() => void refresh(), Math.max(10, data.settings.refreshInterval) * 1000); return () => clearInterval(timer); }, [refresh, data.settings.refreshInterval, route]);
  const deleteMachines = async () => {
    setDeleting(true);
    try {
      for (const machine of pendingDelete) { await request('machine_delete', { id: machine.id }); setData(previous => ({ ...previous, machines: previous.machines.filter(item => item.id !== machine.id) })); }
      setPendingDelete([]); setToast('机器已删除');
    } catch (cause) { showError(errorMessage(cause)); } finally { setDeleting(false); }
  };
  const activeTab = tabs.find(tab => tab.id === selectedTab);
  const focusedPane = activeTab?.panes.find(pane => pane.id === activeTab.focusedPaneId);
  const focusedMachine = data.machines.find(machine => machine.id === focusedPane?.machineId);
  const connectedCount = tabs.flatMap(tab => tab.panes).filter(pane => pane.status === 'connected').length;
  const trust = trustQueue[0];
  const decideTrust = async (decision: 'once' | 'store' | 'reject') => {
    setTrustBusy(true);
    try { await request('trust_decide', { requestId: trust.requestId ?? trust.id, decision }); setTrustQueue(queue => queue.filter(item => (item.requestId ?? item.id) !== (trust.requestId ?? trust.id))); }
    catch (cause) { showError(errorMessage(cause)); } finally { setTrustBusy(false); }
  };

  return <div className={`app-shell ${collapsed ? 'sidebar-collapsed' : ''}`}>
    <aside className="sidebar"><div className="brand"><div className="brand-symbol"><Server size={23} /></div><div className="brand-text"><strong>ServerDash<span> /</span></strong><small>服务器工作台</small></div></div>
      <nav aria-label="主导航">{nav.map(section => <section key={section.title}><h2>{section.title}</h2>{section.items.map(item => <button key={item.route} title={item.title} className={`nav-item ${route === item.route ? 'active' : ''}`} aria-current={route === item.route ? 'page' : undefined} onClick={() => setRoute(item.route)}><item.icon size={17} /><span>{item.title}</span>{item.route === 'terminal' && tabs.length > 0 && <small>{tabs.length}</small>}</button>)}</section>)}</nav>
      <div className="sidebar-bottom"><div className="platform-mark"><span className="status-dot" />Windows 11 <span>x64</span></div><button className={`nav-item ${route === 'settings' ? 'active' : ''}`} onClick={() => setRoute('settings')}><Settings2 size={17} /><span>设置</span><kbd>Ctrl ,</kbd></button></div>
    </aside>
    <div className="main-shell"><header className="titlebar"><div><button className="icon-button" aria-label={collapsed ? '展开侧栏' : '收起侧栏'} onClick={() => setCollapsed(value => !value)}><PanelLeftClose size={17} /></button><span className="breadcrumb">工作台 <ChevronRight size={13} /> <strong>{route === 'settings' ? '设置' : routeTitles[route]}</strong></span></div><div className="titlebar-right"><span className="connection-indicator"><span className={`status-dot ${connectedCount ? '' : 'muted-dot'}`} />{connectedCount ? `${connectedCount} 个已连接` : '暂无活动连接'}</span><span className="build-badge">WINDOWS PREVIEW</span></div></header>
    {!desktopAvailable() && <div className="preview-banner"><Monitor size={15} /><span>浏览器预览 · 启动桌面应用后可连接机器、保存配置和访问本地文件。</span></div>}
    {bootError && <div className="error-banner" role="alert"><span>{bootError}</span><button onClick={() => void load()}>重新加载</button></div>}
    <main className={route === 'terminal' ? 'main-content session-main' : 'main-content'}>
      {loading ? <div className="loading-state"><LoaderCircle className="spin" size={24} /><p>正在打开工作台…</p></div> : <>
        {route === 'dashboard' && <Dashboard machines={data.machines} monitoring={monitoring} connectedCount={connectedCount} refreshing={refreshing} onRefresh={() => void refresh()} onAdd={() => setEditor('new')} onConnect={machine => void openSession(machine)} onMachines={() => setRoute('machines')} onLocal={() => void openSession()} />}
        {route === 'machines' && <Machines machines={data.machines} monitoring={monitoring} onAdd={() => setEditor('new')} onEdit={setEditor} onDelete={setPendingDelete} onConnect={machine => void openSession(machine)} />}
        <div className="session-workspace" hidden={route !== 'terminal'}>
          {tabs.length ? <><div className="session-tabs" role="tablist" aria-label="终端会话">{tabs.map(tab => <div key={tab.id} className={`session-tab ${tab.id === selectedTab ? 'selected' : ''}`}><button role="tab" aria-selected={tab.id === selectedTab} onClick={() => setSelectedTab(tab.id)}><SquareTerminal size={14} /><span>{tab.title}</span>{tab.panes.length > 1 && <small>{tab.panes.length}</small>}</button><button className="icon-button" aria-label={`关闭 ${tab.title}`} onClick={() => void closePane(tab.id)}><X size={13} /></button></div>)}<button className="icon-button" title="新建会话" aria-label="新建会话" onClick={() => setConnectPicker({ split: false })}><Plus size={17} /></button></div>
            <div className="session-toolbar"><div><span className="status-dot" /><span>{focusedPane?.title}</span><span className="subtle mono">{focusedMachine ? `${focusedMachine.username}@${focusedMachine.host}` : '本地会话'}</span></div><div><button disabled={!activeTab || activeTab.panes.length >= 16 || activeTab.panes.some(pane => pane.kind !== 'ssh')} onClick={() => setConnectPicker({ split: true })}><Grid2X2 size={14} />分屏 <small>{activeTab?.panes.length}/16</small></button><button className={inspector ? 'selected' : ''} onClick={() => setInspector(value => value ? null : 'files')}><PanelRight size={15} />检查器</button></div></div>
            <div className="session-body"><div className="session-panels">{tabs.map(tab => <div className="terminal-grid" key={tab.id} hidden={tab.id !== selectedTab} style={{ gridTemplateColumns: `repeat(${tab.panes.length < 3 ? tab.panes.length : tab.panes.length < 7 ? 2 : tab.panes.length < 13 ? 3 : 4}, minmax(0, 1fr))` }}>{tab.panes.map(pane => <section key={pane.id} className={`terminal-pane ${pane.id === tab.focusedPaneId ? 'focused' : ''}`} onPointerDown={() => setTabs(previous => previous.map(item => item.id === tab.id ? { ...item, focusedPaneId: pane.id } : item))} onDragOver={event => event.preventDefault()} onDrop={event => { event.preventDefault(); const source = event.dataTransfer.getData('application/x-serverdash-pane'); setTabs(previous => previous.map(item => item.id === tab.id ? movePane(item, source, pane.id) : item)); }}>
              <div className="pane-title" draggable onDragStart={event => event.dataTransfer.setData('application/x-serverdash-pane', pane.id)}><span><span className={`status-dot ${pane.status === 'connected' ? '' : pane.status === 'failed' ? 'error-dot' : 'muted-dot'}`} />{pane.title}</span><div><small>{kindLabel(pane.kind)}</small><button className="icon-button" aria-label={`关闭面板 ${pane.title}`} onClick={() => void closePane(tab.id, pane.id)}><X size={12} /></button></div></div>
              {pane.session && pane.kind !== 'rdp' ? <TerminalPane session={pane.session} active={route === 'terminal' && tab.id === selectedTab && pane.id === tab.focusedPaneId} settings={data.settings} canRecord={pane.kind === 'ssh' && Boolean(data.capabilities.recording)} onError={showError} /> : <div className="terminal-placeholder">{pane.status === 'connecting' ? <><LoaderCircle className="spin" size={23} /><h3>正在建立连接</h3><p>正在连接 {pane.title}，首次连接需确认主机指纹。</p></> : <><Power size={23} /><h3>{pane.kind === 'rdp' ? '原生远程桌面' : '连接未完成'}</h3><p>{pane.error ?? '当前构建尚未支持此会话类型。'}</p><button onClick={() => void closePane(tab.id, pane.id)}>关闭会话</button></>}</div>}
              {pane.session && (pane.status === 'failed' || pane.status === 'closed') && <div className="session-ended" role="status">{pane.error ?? '连接已结束'}<button onClick={() => void closePane(tab.id, pane.id)}>关闭</button></div>}
            </section>)}</div>)}</div>{inspector && <aside className="inspector"><div className="inspector-tabs">{([{ id: 'files', icon: Folder, label: '文件' }, { id: 'monitor', icon: Activity, label: '监控' }, { id: 'snippets', icon: Braces, label: '片段' }, { id: 'ai', icon: Bot, label: 'AI' }] as const).map(item => <button key={item.id} className={inspector === item.id ? 'selected' : ''} onClick={() => setInspector(item.id)}><item.icon size={15} />{item.label}</button>)}</div>{inspector === 'files' && (focusedPane?.session && focusedPane.kind === 'ssh' ? <FilesPanel key={`${focusedPane.session.sessionId}:${focusedPane.session.generation}`} session={focusedPane.session} initialPath={focusedMachine?.defaultRemotePath ?? '.'} transfers={transfers} onError={showError} /> : <Empty title="文件工作区" description="连接 SSH 会话后浏览远程文件。" icon={Folder} compact />)}{inspector === 'monitor' && <MonitorInspector snapshot={focusedMachine ? monitoring[focusedMachine.id] : undefined} onRefresh={() => void refresh()} />}{inspector === 'snippets' && <div className="snippet-inspector"><h3>代码片段</h3><p className="subtle">复制后在终端中检查并执行。</p>{data.snippets.map(snippet => <button key={snippet.id} onClick={() => void navigator.clipboard.writeText(snippet.command).then(() => setToast('代码片段已复制')).catch(cause => showError(errorMessage(cause)))}><strong>{snippet.name}</strong><code>{snippet.command}</code></button>)}{!data.snippets.length && <p className="empty-small subtle">还没有代码片段</p>}</div>}{inspector === 'ai' && <AIPanel enabled={Boolean(data.capabilities.ai)} session={focusedPane?.kind === 'ssh' ? focusedPane.session : undefined} onError={showError} />}</aside>}</div>
            <div className="terminal-statusbar"><span>{focusedPane?.status === 'connected' ? '连接正常' : '等待连接'} <span className="subtle">· UTF-8</span></span><span>复制 Ctrl+Shift+C <i /> 粘贴 Ctrl+Shift+V <i /> 中断 Ctrl+C</span></div>
          </> : <Empty title="从一个连接开始" description="打开 SSH 终端、远程桌面，或在本地 PowerShell 中工作。切换工作区时，会话会保持连接。" icon={TerminalSquare}><button className="primary" onClick={() => setConnectPicker({ split: false })}><Plus size={15} />新建连接</button><button onClick={() => void openSession()}><SquareTerminal size={15} />本地终端</button></Empty>}
        </div>
        {route === 'snippets' && <Snippets snippets={data.snippets} onSave={snippet => setData(previous => ({ ...previous, snippets: [...previous.snippets.filter(item => item.id !== snippet.id), snippet] }))} onError={showError} />}
        {(route === 'identities' || route === 'sshKeys' || route === 'trustedHosts') && <Resources route={route} data={data} onReload={load} onError={showError} />}
        {route === 'connections' && <Connections data={data} onError={showError} onChanged={load} />}
        {route === 'recordings' && <Recordings available={Boolean(data.capabilities.recording)} onError={showError} />}
        {route === 'settings' && <SettingsPage onChanged={load} settings={data.settings} capabilities={data.capabilities} onSave={settings => { setData(previous => ({ ...previous, settings })); setToast('设置已保存'); }} onError={showError} />}
      </>}
    </main><footer className="app-statusbar"><span><span className="status-dot muted-dot" />{data.machines.length} 台机器 <span className="footer-divider">/</span> {data.machines.filter(machine => machine.monitoringEnabled).length} 台启用监控</span><span>ServerDash {data.version ?? '0.1.0'} <span className="footer-divider">/</span> 本地工作区</span></footer></div>
    {editor && <MachineEditor machine={editor === 'new' ? undefined : editor} onClose={() => setEditor(null)} onSave={machine => { setData(previous => ({ ...previous, machines: [...previous.machines.filter(item => item.id !== machine.id), machine] })); setEditor(null); setToast('机器已保存'); }} />}
    {pendingDelete.length > 0 && <Dialog title={`删除 ${pendingDelete.length} 台机器`} onClose={() => setPendingDelete([])}><p className="dialog-copy">将删除 {pendingDelete.map(machine => machine.name).join('、')} 的本机配置，并关闭相关连接。此操作不会删除远程服务器。</p><footer className="dialog-footer"><button disabled={deleting} onClick={() => setPendingDelete([])}>取消</button><button className="danger" disabled={deleting} onClick={() => void deleteMachines()}>{deleting ? '正在删除…' : '删除机器'}</button></footer></Dialog>}
    {connectPicker && <Dialog title={connectPicker.split ? '添加 SSH 分屏' : '新建会话'} onClose={() => setConnectPicker(null)}><div className="connect-list">{data.machines.filter(machine => !connectPicker.split || machine.kind === 'ssh').map(machine => <button key={machine.id} onClick={() => void openSession(machine, connectPicker.split)}><Server size={18} /><span><strong>{machine.name}</strong><small>{machine.host}</small></span><span className="pill">{kindLabel(machine.kind)}</span><ChevronRight size={15} /></button>)}{!data.machines.length && <p className="empty-small subtle">先添加一台机器，即可开始远程连接。</p>}{!connectPicker.split && <button onClick={() => void openSession()}><SquareTerminal size={18} /><span><strong>本地终端</strong><small>Windows PowerShell</small></span><ChevronRight size={15} /></button>}</div><footer className="dialog-footer"><button onClick={() => { setConnectPicker(null); setEditor('new'); }}><Plus size={15} />添加机器</button></footer></Dialog>}
    {trust && <Dialog title={trust.replacing ? '主机密钥已变化' : '确认 SSH 主机指纹'} dismissible={false} onClose={() => {}}><div className="trust-body"><div className={`trust-icon ${trust.replacing ? 'changed' : ''}`}><ShieldCheck size={28} /></div><p>{trust.replacing ? '该地址的主机密钥与之前保存的指纹不同。请先通过可信渠道核对服务器的新指纹。' : '这是首次连接此主机。请核对服务器的 SSH 公钥指纹后继续。'}</p><dl><dt>主机</dt><dd>{trust.host}:{trust.port}</dd><dt>算法</dt><dd>{trust.algorithm}</dd><dt>SHA256 指纹</dt><dd className="fingerprint">{trust.fingerprint}</dd>{trust.previousFingerprint && <><dt>原指纹</dt><dd className="fingerprint">{trust.previousFingerprint}</dd></>}</dl></div><footer className="dialog-footer"><button disabled={trustBusy} onClick={() => void decideTrust('reject')}>取消连接</button><button disabled={trustBusy} onClick={() => void decideTrust('once')}>仅本次信任</button><button className={trust.replacing ? 'danger' : 'primary'} disabled={trustBusy} onClick={() => void decideTrust('store')}>{trust.replacing ? '替换并信任' : '保存并信任'}</button></footer></Dialog>}
    {error && <div className="notification error-notification" role="alert"><div><strong>操作未完成</strong><p>{error}</p></div><button className="icon-button" aria-label="关闭错误提示" onClick={() => setError('')}><X size={17} /></button></div>}{toast && <div className="toast" role="status"><Check size={16} />{toast}</div>}
  </div>;
}

function Empty({ title, description, icon: Icon, children, compact }: { title: string; description: string; icon: typeof Server; children?: ReactNode; compact?: boolean }) {
  return <div className={`empty-state ${compact ? 'compact' : ''}`}><div className="empty-icon"><Icon size={compact ? 25 : 33} strokeWidth={1.4} /></div><h2>{title}</h2><p>{description}</p>{children && <div className="empty-actions">{children}</div>}</div>;
}

function Metric({ title, value, detail, icon: Icon, accent = false }: { title: string; value: string; detail: string; icon: typeof Server; accent?: boolean }) {
  return <div className={`metric-card ${accent ? 'metric-accent' : ''}`}><div><span>{title}</span><Icon size={17} /></div><strong>{value}</strong><small>{detail}</small></div>;
}

function Dashboard({ machines, monitoring, connectedCount, refreshing, onRefresh, onAdd, onConnect, onMachines, onLocal }: { machines: Machine[]; monitoring: Record<string, Monitoring>; connectedCount: number; refreshing: boolean; onRefresh: () => void; onAdd: () => void; onConnect: (machine: Machine) => void; onMachines: () => void; onLocal: () => void }) {
  const snapshots = Object.values(monitoring).filter(snapshot => snapshot.status !== 'failed' && snapshot.cpuPercent !== undefined);
  const meanCPU = snapshots.length ? `${(snapshots.reduce((sum, snapshot) => sum + (snapshot.cpuPercent ?? 0), 0) / snapshots.length).toFixed(1)}%` : '—';
  return <div className="page dashboard-page"><div className="page-heading"><div><div className="eyebrow">YOUR INFRASTRUCTURE, IN FOCUS</div><h1>仪表盘</h1><p>集中查看资源状态，连接机器，继续你的工作。</p></div><div className="heading-actions"><button onClick={onRefresh} disabled={refreshing || !machines.length}><RefreshCw size={15} className={refreshing ? 'spin' : ''} />刷新</button><button className="primary" onClick={onAdd}><Plus size={16} />添加机器</button></div></div>
    <div className="metric-grid"><Metric title="管理的机器" value={String(machines.length).padStart(2, '0')} detail={`${new Set(machines.map(machine => machine.group).filter(Boolean)).size} 个分组`} icon={Server} accent /><Metric title="活动连接" value={String(connectedCount).padStart(2, '0')} detail="切换页面时保持连接" icon={Activity} /><Metric title="平均 CPU 使用率" value={meanCPU} detail={snapshots.length ? `来自 ${snapshots.length} 台机器的最近快照` : '等待首次资源采集'} icon={Cpu} /><Metric title="启用监控" value={String(machines.filter(machine => machine.monitoringEnabled).length).padStart(2, '0')} detail="Linux 服务器资源监控" icon={Gauge} /></div>
    <div className="section-heading"><h2>机器概览 <span>{machines.length}</span></h2><button className="text-button" onClick={onMachines}>管理机器 <ChevronRight size={14} /></button></div>
    {!machines.length ? <div className="onboarding-panel"><div className="onboarding-visual"><div className="orbital-ring" /><div className="orbital-ring second" /><div className="server-stack"><Server size={38} strokeWidth={1.1} /><div><span /><span /><span /></div></div><span className="orbit-node one"><ShieldCheck size={16} /></span><span className="orbit-node two"><TerminalSquare size={16} /></span></div><div className="onboarding-copy"><span className="eyebrow">A PLACE FOR EVERY CONNECTION</span><h2>你的服务器，<br />一个工作台。</h2><p>从第一台机器开始。在终端、资源监控和远程文件之间流畅切换，让每一次连接井然有序。</p><button className="primary" onClick={onAdd}><Plus size={16} />添加第一台机器</button><div className="supported-protocols"><span>SSH</span><span>SFTP</span><span>PowerShell</span></div></div></div> : <div className="machine-grid">{machines.slice(0, 9).map(machine => <MachineCard key={machine.id} machine={machine} snapshot={monitoring[machine.id]} onConnect={() => onConnect(machine)} />)}</div>}
    <div className="section-heading"><h2>快捷开始</h2></div><div className="quick-actions"><button onClick={onAdd}><div className="quick-icon"><Server size={20} /></div><span><strong>添加远程机器</strong><small>保存 SSH、RDP 或 VNC 连接</small></span><ChevronRight size={17} /></button><button onClick={onLocal}><div className="quick-icon violet"><SquareTerminal size={20} /></div><span><strong>打开本地终端</strong><small>在 Windows PowerShell 中工作</small></span><ChevronRight size={17} /></button><button onClick={onMachines}><div className="quick-icon blue"><Folder size={20} /></div><span><strong>整理你的机器</strong><small>通过分组和标签快速定位</small></span><ChevronRight size={17} /></button></div>
  </div>;
}

function MachineCard({ machine, snapshot, onConnect, onEdit, selected, onSelect }: { machine: Machine; snapshot?: Monitoring; onConnect: () => void; onEdit?: () => void; selected?: boolean; onSelect?: () => void }) {
  return <article className={`machine-card ${selected ? 'selected' : ''}`}><div className="machine-card-top"><div className="machine-symbol"><Server size={19} /></div><span className="pill">{kindLabel(machine.kind)}</span>{onSelect && <input type="checkbox" aria-label={`选择 ${machine.name}`} checked={selected ?? false} onChange={onSelect} />}{onEdit && <button className="icon-button" aria-label={`编辑 ${machine.name}`} onClick={onEdit}><MoreHorizontal size={17} /></button>}</div><h3>{machine.name}</h3><p className="mono machine-address">{machine.username ? `${machine.username}@` : ''}{machine.host}:{machine.port}</p><div className="machine-tags">{machine.group && <span><Folder size={11} />{machine.group}</span>}{machine.tags.slice(0, 3).map(tag => <span key={tag}>{tag}</span>)}</div><div className="card-metrics"><div><span>CPU</span><strong>{snapshot?.cpuPercent !== undefined ? `${snapshot.cpuPercent.toFixed(1)}%` : '—'}</strong></div><div><span>内存</span><strong>{snapshot?.memoryTotalBytes ? `${((snapshot.memoryUsedBytes ?? 0) / snapshot.memoryTotalBytes * 100).toFixed(0)}%` : '—'}</strong></div><div><span>磁盘</span><strong>{snapshot?.diskTotalBytes ? `${((snapshot.diskUsedBytes ?? 0) / snapshot.diskTotalBytes * 100).toFixed(0)}%` : '—'}</strong></div></div><footer><span className={snapshot?.error ? 'danger-text' : 'subtle'}><span className={`status-dot ${snapshot?.error ? 'error-dot' : snapshot ? '' : 'muted-dot'}`} />{snapshot?.error ? '采集失败' : snapshot ? '已采集' : machine.monitoringEnabled ? '等待采集' : '未启用监控'}</span><button className="text-button" onClick={onConnect}>连接 <ArrowUpRight size={14} /></button></footer></article>;
}

function Machines({ machines, monitoring, onAdd, onEdit, onDelete, onConnect }: { machines: Machine[]; monitoring: Record<string, Monitoring>; onAdd: () => void; onEdit: (machine: Machine) => void; onDelete: (machines: Machine[]) => void; onConnect: (machine: Machine) => void }) {
  const [search, setSearch] = useState(''); const [group, setGroup] = useState(''); const [tag, setTag] = useState(''); const [monitor, setMonitor] = useState('all'); const [view, setView] = useState<'grid' | 'list'>('grid'); const [selected, setSelected] = useState<Set<string>>(new Set());
  const filtered = filterMachines(machines, search, group, tag, monitor);
  const selectedMachines = machines.filter(machine => selected.has(machine.id));
  const toggle = (id: string) => setSelected(previous => { const next = new Set(previous); if (next.has(id)) next.delete(id); else next.add(id); return next; });
  return <div className="page"><div className="page-heading"><div><div className="eyebrow">MACHINE INVENTORY</div><h1>机器 <span>{machines.length}</span></h1><p>连接与组织你的基础设施。</p></div><button className="primary" onClick={onAdd}><Plus size={16} />添加机器</button></div><div className="browser-controls"><label className="search-field"><Search size={16} /><input aria-label="搜索机器" placeholder="搜索名称、地址、标签或备注…" value={search} onChange={event => setSearch(event.target.value)} /><kbd>⌕</kbd></label><select aria-label="按分组筛选" value={group} onChange={event => setGroup(event.target.value)}><option value="">全部分组</option>{[...new Set(machines.map(machine => machine.group).filter(Boolean))].sort().map(value => <option key={value}>{value}</option>)}</select><select aria-label="按监控开关筛选" value={monitor} onChange={event => setMonitor(event.target.value)}><option value="all">全部监控状态</option><option value="enabled">启用监控</option><option value="disabled">未启用监控</option></select><div className="segmented"><button className={view === 'grid' ? 'selected' : ''} aria-label="网格视图" onClick={() => setView('grid')}><Grid2X2 size={16} /></button><button className={view === 'list' ? 'selected' : ''} aria-label="列表视图" onClick={() => setView('list')}><LayoutList size={17} /></button></div></div>
    <div className="filter-row"><div className="tag-filters"><button className={!tag ? 'selected' : ''} onClick={() => setTag('')}>全部标签</button>{[...new Set(machines.flatMap(machine => machine.tags))].sort().map(value => <button key={value} className={tag === value ? 'selected' : ''} onClick={() => setTag(value)}>{value}</button>)}</div><span className="subtle">{filtered.length} 台机器</span></div>
    {selectedMachines.length > 0 && <div className="selection-bar"><span>已选择 {selectedMachines.length} 台</span><button onClick={() => { filtered.forEach(machine => setSelected(previous => new Set([...previous, machine.id]))); }}>选择当前结果</button><button onClick={() => setSelected(new Set())}>取消选择</button><button className="danger-text" onClick={() => onDelete(selectedMachines)}><Trash2 size={14} />删除</button></div>}
    {filtered.length ? view === 'grid' ? <div className="machine-grid">{filtered.map(machine => <MachineCard key={machine.id} machine={machine} snapshot={monitoring[machine.id]} onConnect={() => onConnect(machine)} onEdit={() => onEdit(machine)} selected={selected.has(machine.id)} onSelect={() => toggle(machine.id)} />)}</div> : <div className="machine-table"><div className="machine-table-head"><span /><span>机器 / 地址</span><span>分组</span><span>协议</span><span>监控</span><span /></div>{filtered.map(machine => <div className="machine-table-row" key={machine.id}><input type="checkbox" aria-label={`选择 ${machine.name}`} checked={selected.has(machine.id)} onChange={() => toggle(machine.id)} /><div><strong>{machine.name}</strong><small className="mono">{machine.host}:{machine.port}</small></div><span>{machine.group || '未分组'}</span><span className="pill">{kindLabel(machine.kind)}</span><span className="subtle">{machine.monitoringEnabled ? '启用' : '关闭'}</span><div className="row-actions"><button className="icon-button" aria-label={`编辑 ${machine.name}`} onClick={() => onEdit(machine)}><Pencil size={15} /></button><button onClick={() => onConnect(machine)}><Play size={12} />连接</button></div></div>)}</div> : <Empty title={machines.length ? '没有匹配的机器' : '添加你的第一台机器'} description={machines.length ? '试试其他关键词，或清除分组、标签和监控筛选。' : '保存连接信息，随时打开终端、监控与远程文件。'} icon={Server}>{machines.length ? <button onClick={() => { setSearch(''); setGroup(''); setTag(''); setMonitor('all'); }}>清除筛选</button> : <button className="primary" onClick={onAdd}><Plus size={15} />添加机器</button>}</Empty>}
  </div>;
}

function MonitorInspector({ snapshot, onRefresh }: { snapshot?: Monitoring; onRefresh: () => void }) {
  return <div className="monitor-inspector"><div className="panel-title"><h3>资源监控</h3><button className="icon-button" onClick={onRefresh} aria-label="刷新监控"><RefreshCw size={15} /></button></div>{snapshot ? <>{snapshot.error && <p className="inline-error">{snapshot.error}</p>}<div className="monitor-meter"><span><Cpu size={16} />CPU</span><strong>{snapshot.cpuPercent?.toFixed(1) ?? '—'}%</strong><progress value={snapshot.cpuPercent ?? 0} max={100} /></div><div className="monitor-meter"><span><MemoryStick size={16} />内存</span><strong>{bytes(snapshot.memoryUsedBytes)}</strong><progress value={snapshot.memoryUsedBytes ?? 0} max={snapshot.memoryTotalBytes || 1} /><small>共 {bytes(snapshot.memoryTotalBytes)}</small></div><div className="monitor-meter"><span><HardDrive size={16} />磁盘</span><strong>{bytes(snapshot.diskUsedBytes)}</strong><progress value={snapshot.diskUsedBytes ?? 0} max={snapshot.diskTotalBytes || 1} /><small>共 {bytes(snapshot.diskTotalBytes)}</small></div><div className="network-stats"><span><ArrowDownLeft size={15} />{bytes(snapshot.networkRxBytesPerSecond)}/s</span><span><ArrowUpRight size={15} />{bytes(snapshot.networkTxBytesPerSecond)}/s</span></div><p className="subtle">{snapshot.capturedAt ? `采集于 ${new Date(snapshot.capturedAt).toLocaleTimeString()}` : '等待下一次采集'}</p></> : <Empty compact icon={Activity} title="等待资源采集" description="选择启用监控的 SSH 机器后，点击刷新获取真实资源快照。" />}</div>;
}

function Snippets({ snippets, onSave, onError }: { snippets: Snippet[]; onSave: (snippet: Snippet) => void; onError: (message: string) => void }) {
  const [draft, setDraft] = useState<Snippet>(); const [busy, setBusy] = useState(false);
  const save = async () => { if (!draft) return; setBusy(true); try { await request('snippet_save', { snippet: draft }); onSave(draft); setDraft(undefined); } catch (cause) { onError(errorMessage(cause)); } finally { setBusy(false); } };
  return <div className="page"><div className="page-heading"><div><div className="eyebrow">YOUR COMMAND LIBRARY</div><h1>代码片段</h1><p>保存常用命令，在每一次连接中复用。</p></div><button className="primary" onClick={() => setDraft({ id: crypto.randomUUID(), name: '', command: '', group: '' })}><Plus size={15} />新建片段</button></div>{snippets.length ? <div className="snippet-grid">{snippets.map(snippet => <article className="snippet-card" key={snippet.id}><div><Braces size={18} /><h3>{snippet.name}</h3><button className="icon-button" aria-label={`编辑 ${snippet.name}`} onClick={() => setDraft(snippet)}><Pencil size={15} /></button></div><pre>{snippet.command}</pre><footer><span className="subtle">{snippet.group || '未分组'}</span><button onClick={() => void navigator.clipboard.writeText(snippet.command).catch(cause => onError(errorMessage(cause)))}>复制命令</button></footer></article>)}</div> : <Empty title="让常用命令触手可及" description="把排查、部署和维护命令保存在这里。代码片段不会自动执行，你可以先在终端中检查。" icon={Braces}><button onClick={() => setDraft({ id: crypto.randomUUID(), name: '', command: '' })}><Plus size={15} />创建代码片段</button></Empty>}
    {draft && <Dialog title={snippets.some(item => item.id === draft.id) ? '编辑代码片段' : '新建代码片段'} onClose={() => setDraft(undefined)} wide><form onSubmit={event => { event.preventDefault(); void save(); }}><div className="form-grid"><label>名称<input required value={draft.name} onChange={event => setDraft({ ...draft, name: event.target.value })} /></label><label>分组<input value={draft.group ?? ''} onChange={event => setDraft({ ...draft, group: event.target.value })} /></label><label className="span-2">命令<textarea className="code-input" required rows={8} spellCheck={false} value={draft.command} onChange={event => setDraft({ ...draft, command: event.target.value })} /></label></div><footer className="dialog-footer"><button type="button" onClick={() => setDraft(undefined)}>取消</button><button className="primary" disabled={busy}>保存片段</button></footer></form></Dialog>}
  </div>;
}

function Resources({ route, data, onReload, onError }: { route: 'identities' | 'sshKeys' | 'trustedHosts'; data: Bootstrap; onReload: () => Promise<void>; onError: (message: string) => void }) {
  const [draft, setDraft] = useState<{ id: string; name: string; username: string; path: string; password: string }>(); const [busy, setBusy] = useState(false);
  const resources = route === 'identities' ? data.identities : route === 'sshKeys' ? data.sshKeys : data.trustedHosts;
  const Icon = route === 'identities' ? UserRound : route === 'sshKeys' ? KeyRound : ShieldCheck;
  const save = async () => { if (!draft) return; setBusy(true); try { if (route === 'identities') { let credentialId; if (draft.password) credentialId = (await request<{ credentialId: string }>('credential_save', { secret: { password: draft.password }, name: draft.name })).credentialId; await request('identity_save', { identity: { id: draft.id, name: draft.name, username: draft.username, credentialId } }); } else await request('ssh_key_save', { key: { id: draft.id, name: draft.name, path: draft.path } }); setDraft(undefined); await onReload(); } catch (cause) { onError(errorMessage(cause)); } finally { setBusy(false); } };
  return <div className="page"><div className="page-heading"><div><div className="eyebrow">{route === 'trustedHosts' ? 'CONNECTION TRUST' : 'CONNECTION RESOURCES'}</div><h1>{routeTitles[route]}</h1><p>{route === 'identities' ? '集中管理登录身份，长期凭据在本机加密保存。' : route === 'sshKeys' ? '管理本机 SSH 私钥文件引用。私钥内容不会显示在这里。' : '查看已核对并保存的 SSH 主机公钥指纹。'}</p></div>{route !== 'trustedHosts' && <button className="primary" onClick={() => setDraft({ id: crypto.randomUUID(), name: '', username: '', path: '', password: '' })}><Plus size={15} />{route === 'identities' ? '添加身份' : '添加密钥'}</button>}</div>
    {resources.length ? <div className="resource-list">{resources.map(item => <article key={item.id}><div className="resource-icon"><Icon size={20} /></div><div><h3>{'name' in item ? item.name : `${item.host}:${item.port}`}</h3><p className="mono">{'username' in item ? item.username : 'path' in item ? item.path : item.fingerprint}</p></div>{route === 'trustedHosts' && <span className="pill green"><ShieldCheck size={12} />已信任</span>}</article>)}</div> : <Empty title={route === 'identities' ? '还没有保存的身份' : route === 'sshKeys' ? '还没有 SSH 密钥引用' : '主机信任从第一次连接开始'} description={route === 'trustedHosts' ? '连接 SSH 时核对主机指纹并选择「保存并信任」，已保存的指纹会显示在这里。' : '添加资源后，即可在机器连接中管理和复用。'} icon={Icon} />}
    {draft && <Dialog title={route === 'identities' ? '添加身份' : '添加 SSH 密钥'} onClose={() => setDraft(undefined)}><form onSubmit={event => { event.preventDefault(); void save(); }}><div className="form-grid"><label className="span-2">名称<input required value={draft.name} onChange={event => setDraft({ ...draft, name: event.target.value })} /></label>{route === 'identities' ? <><label className="span-2">用户名<input required value={draft.username} onChange={event => setDraft({ ...draft, username: event.target.value })} /></label><label className="span-2">密码<input type="password" autoComplete="new-password" value={draft.password} onChange={event => setDraft({ ...draft, password: event.target.value })} /></label></> : <label className="span-2">私钥文件路径<input required placeholder="C:\Users\you\.ssh\id_ed25519" value={draft.path} onChange={event => setDraft({ ...draft, path: event.target.value })} /></label>}</div><footer className="dialog-footer"><button type="button" onClick={() => setDraft(undefined)}>取消</button><button className="primary" disabled={busy}>保存</button></footer></form></Dialog>}
  </div>;
}

function Connections({ data, onError, onChanged }: { data: Bootstrap; onError: (message: string) => void; onChanged: () => Promise<void> }) {
  return <div className="page"><div className="page-heading"><div><div className="eyebrow">CONNECTIONS</div><h1>连接与会话迁移</h1><p>导入已有 SSH 会话，检查连接能力。</p></div></div><ConfigurationPanel capabilities={data.capabilities} onError={onError} onChanged={onChanged} mode="sessions" /><div className="capability-grid">{[{ name: 'SSH Agent', key: 'sshAgent', description: '使用本机 OpenSSH Agent。' }, { name: '跳板与代理', key: 'jumpHosts', description: '引擎支持逐跳信任、SOCKS5 和 HTTP CONNECT；高级编辑器尚待完成。' }, { name: '端口转发', key: 'tunnels', description: '本地、远程、动态与 HTTP 转发尚未开放。' }].map(item => <div className="capability-card" key={item.key}><Network size={19} /><h3>{item.name}</h3><p>{item.description}</p><span className="pill">{data.capabilities[item.key] ? '引擎可用' : '尚未开放'}</span></div>)}</div></div>;
}

function SettingsPage({ settings, capabilities, onSave, onError, onChanged }: { onChanged: () => Promise<void>; settings: Settings; capabilities: Record<string, boolean>; onSave: (settings: Settings) => void; onError: (message: string) => void }) {
  const [draft, setDraft] = useState(settings); const [busy, setBusy] = useState(false);
  const save = async () => { setBusy(true); try { await request('settings_save', { settings: draft }); onSave(draft); } catch (cause) { onError(errorMessage(cause)); } finally { setBusy(false); } };
  return <div className="page settings-page"><div className="page-heading"><div><div className="eyebrow">MAKE IT YOUR WORKSPACE</div><h1>设置</h1><p>调整外观、终端和本地集成。</p></div><button className="primary" disabled={busy} onClick={() => void save()}><Check size={15} />{busy ? '正在保存…' : '保存设置'}</button></div><section className="settings-section"><div className="settings-section-title"><SlidersHorizontal size={19} /><div><h2>外观与刷新</h2><p>为你的工作环境选择合适的显示方式。</p></div></div><div className="settings-row"><label htmlFor="theme">应用主题<small>浅色、深色或跟随系统</small></label><select id="theme" value={draft.theme} onChange={event => setDraft({ ...draft, theme: event.target.value as Settings['theme'] })}><option value="dark">深色</option><option value="light">浅色</option><option value="system">跟随系统</option></select></div><div className="settings-row"><label htmlFor="refresh">资源刷新间隔<small>仅在仪表盘显示时自动采集</small></label><select id="refresh" value={draft.refreshInterval} onChange={event => setDraft({ ...draft, refreshInterval: Number(event.target.value) })}><option value={0}>手动刷新</option><option value={15}>15 秒</option><option value={30}>30 秒</option><option value={60}>60 秒</option><option value={120}>2 分钟</option></select></div></section><section className="settings-section"><div className="settings-section-title"><SquareTerminal size={19} /><div><h2>终端</h2><p>外观设置会应用到已打开的终端。</p></div></div><div className="settings-row"><label htmlFor="font">字体<small>优先使用本机已安装的等宽字体</small></label><input id="font" value={draft.terminalFontFamily} onChange={event => setDraft({ ...draft, terminalFontFamily: event.target.value })} /></div><div className="settings-row"><label htmlFor="font-size">字号<small>10–24 px</small></label><input id="font-size" type="number" min={10} max={24} value={draft.terminalFontSize} onChange={event => setDraft({ ...draft, terminalFontSize: Math.min(24, Math.max(10, Number(event.target.value))) })} /></div><div className="settings-row"><label htmlFor="shell">本地 Shell<small>留空使用 Windows PowerShell</small></label><input id="shell" placeholder="powershell.exe" value={draft.localShell ?? ''} onChange={event => setDraft({ ...draft, localShell: event.target.value })} /></div><div className="terminal-preview" style={{ fontFamily: draft.terminalFontFamily, fontSize: draft.terminalFontSize }}><span>PS C:\Users\you&gt;</span> Get-Location<br /><br /><span className="subtle">Path</span><br />C:\Users\you<span className="preview-cursor" /></div></section><section className="settings-section"><div className="settings-section-title"><Monitor size={19} /><div><h2>外部客户端</h2><p>VNC 连接由你选择的本机客户端处理。</p></div></div><div className="settings-row"><label htmlFor="vnc">TigerVNC Viewer 路径<small>客户端独立处理登录凭据</small></label><input id="vnc" placeholder="C:\Program Files\TigerVNC\vncviewer.exe" value={draft.vncViewerPath ?? ''} onChange={event => setDraft({ ...draft, vncViewerPath: event.target.value })} /></div></section><ConfigurationPanel capabilities={capabilities} onChanged={onChanged} onError={onError} /></div>;
}
