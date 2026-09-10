import { describe, expect, it } from 'vitest';
import { addPane, bytes, filterMachines, joinRemotePath, matchesSession, movePane, parentPath, type Pane, type WorkspaceTab } from './workspace';
import { decodeOutput, encodeInput, type Machine } from './api';

const pane = (id: string): Pane => ({ id, title: id, kind: 'ssh', status: 'connected' });
const tab: WorkspaceTab = { id: 'tab', title: 'test', panes: [pane('one'), pane('two')], focusedPaneId: 'one' };
describe('workspace lifecycle boundaries', () => {
  it('limits a tab to 16 SSH panes', () => {
    let result = tab;
    for (let i = 2; i < 16; i++) result = addPane(result, pane(String(i)));
    expect(result.panes).toHaveLength(16);
    expect(() => addPane(result, pane('overflow'))).toThrow('16');
    expect(() => addPane(tab, { ...pane('local'), kind: 'local' })).toThrow('SSH');
  });
  it('reorders panes without duplicating or changing focus', () => {
    const result = movePane(tab, 'two', 'one');
    expect(result.panes.map(p => p.id)).toEqual(['two', 'one']);
    expect(result.focusedPaneId).toBe('one');
    expect(movePane(tab, 'stale', 'one')).toBe(tab);
  });
  it('rejects output and status for a previous connection generation', () => {
    const connected = { ...pane('test'), session: { sessionId: 'session', generation: 2 } };
    expect(matchesSession(connected, { sessionId: 'session', generation: 1 })).toBe(false);
    expect(matchesSession(connected, { sessionId: 'session', generation: 2 })).toBe(true);
  });
});
describe('machine browser', () => {
  const machines = [{ id: 'one', name: '生产 2', host: '10.0.0.2', username: 'ops', group: 'prod', tags: ['北京'], notes: '数据库', monitoringEnabled: true }, { id: 'two', name: '生产 10', host: '10.0.0.10', username: 'ops', group: 'prod', tags: ['上海'], notes: 'web', monitoringEnabled: false }] as Machine[];
  it('combines search terms with group, tag and monitoring filters', () => {
    expect(filterMachines(machines, 'OPS 数据库', 'prod', '北京', 'enabled').map(m => m.id)).toEqual(['one']);
    expect(filterMachines(machines, '', 'prod', '北京', 'disabled')).toEqual([]);
    expect(filterMachines(machines, '', '', '').map(m => m.id)).toEqual(['one', 'two']);
  });
});
describe('wire and file boundaries', () => {
  it('decodes binary sequence and keeps arbitrary terminal bytes intact', () => {
    const packet = new Uint8Array(11); new DataView(packet.buffer).setBigUint64(0, 99n, true); packet.set([0x1b, 0xff, 0], 8);
    expect(decodeOutput(packet)).toEqual({ sequence: 99, bytes: new Uint8Array([0x1b, 0xff, 0]) });
    expect(() => decodeOutput([1, 2])).toThrow();
    const binary = atob(encodeInput('中文\u0003'));
    expect(new TextDecoder().decode(Uint8Array.from(binary, char => char.charCodeAt(0)))).toBe('中文\u0003');
  });
  it('joins remote paths without traversal through entry names', () => {
    expect(joinRemotePath('/home/ops/', '有 空格.txt')).toBe('/home/ops/有 空格.txt');
    expect(() => joinRemotePath('/home', '..')).toThrow();
    expect(() => joinRemotePath('/home', 'a/b')).toThrow();
    expect(parentPath('/')).toBe('/'); expect(parentPath('/a/b/')).toBe('/a');
    expect(bytes(undefined)).toBe('—');
  });
});
