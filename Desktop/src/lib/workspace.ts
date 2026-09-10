import type { Machine, SessionRef } from './api';

export type Pane = { id: string; requestId?: string; machineId?: string; title: string; kind: 'ssh' | 'local' | 'serial' | 'rdp'; session?: SessionRef; status: 'connecting' | 'connected' | 'closed' | 'failed'; error?: string };
export type WorkspaceTab = { id: string; title: string; panes: Pane[]; focusedPaneId: string };
export const MAX_PANES = 16;

export function addPane(tab: WorkspaceTab, pane: Pane): WorkspaceTab {
  if (tab.panes.length >= MAX_PANES) throw new Error('每个会话标签最多支持 16 个面板');
  if (tab.panes.some(item => item.kind !== 'ssh') || pane.kind !== 'ssh') throw new Error('只有 SSH 会话支持分屏');
  return { ...tab, panes: [...tab.panes, pane], focusedPaneId: pane.id };
}
export function movePane(tab: WorkspaceTab, sourceId: string, targetId: string): WorkspaceTab {
  const source = tab.panes.findIndex(item => item.id === sourceId);
  const target = tab.panes.findIndex(item => item.id === targetId);
  if (source === -1 || target === -1 || source === target) return tab;
  const panes = [...tab.panes]; const [pane] = panes.splice(source, 1); panes.splice(target, 0, pane);
  return { ...tab, panes };
}
export function matchesSession(pane: Pane, session: SessionRef) {
  return pane.session?.sessionId === session.sessionId && pane.session.generation === session.generation;
}
export function filterMachines(machines: Machine[], search: string, group: string, tag: string, monitoring = 'all') {
  const terms = search.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  return machines.filter(machine => (!group || machine.group === group) && (!tag || machine.tags.includes(tag)) && (monitoring === 'all' || machine.monitoringEnabled === (monitoring === 'enabled')) && terms.every(term => `${machine.name} ${machine.host} ${machine.username} ${machine.tags.join(' ')} ${machine.notes}`.toLocaleLowerCase().includes(term))).sort((a, b) => a.name.localeCompare(b.name, 'zh-CN', { numeric: true }));
}
export function parentPath(path: string): string { const parts = path.split('/').filter(Boolean); parts.pop(); return '/' + parts.join('/'); }
export function joinRemotePath(parent: string, name: string): string {
  if (!name || name === '.' || name === '..' || /[\0/]/.test(name)) throw new Error('名称不能为空，也不能包含 / 或空字符');
  return `${parent.replace(/\/$/, '')}/${name}`;
}
export function bytes(value?: number): string {
  if (value === undefined || !Number.isFinite(value)) return '—';
  if (value < 1024) return `${value.toFixed(0)} B`;
  const units = ['KiB', 'MiB', 'GiB', 'TiB']; let amount = value / 1024; let index = 0;
  while (amount >= 1024 && index < units.length - 1) { amount /= 1024; index++; }
  return `${amount.toFixed(amount < 10 ? 1 : 0)} ${units[index]}`;
}
