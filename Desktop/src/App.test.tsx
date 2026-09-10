import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Bootstrap, DesktopEvent, SessionRef } from './lib/api';
import App from './App';

const native = vi.hoisted(() => ({ request: vi.fn(), bootstrap: vi.fn(), listener: undefined as ((event: DesktopEvent) => void) | undefined, mounted: 0, disposed: 0 }));
vi.mock('./lib/api', async importOriginal => ({ ...await importOriginal<typeof import('./lib/api')>(), desktopAvailable: () => true,
  request: native.request, bootstrap: native.bootstrap, onDesktopEvent: async (listener: (event: DesktopEvent) => void) => { native.listener = listener; return () => { native.listener = undefined; }; } }));
vi.mock('./components/TerminalPane', async () => {
  const { useEffect } = await import('react');
  return { default: ({ session }: { session: SessionRef }) => {
    useEffect(() => { native.mounted++; return () => { native.disposed++; }; }, []);
    return <div data-testid="terminal">{session.sessionId}</div>;
  } };
});
const data: Bootstrap = { machines: [], settings: { theme: 'dark', terminalFontFamily: 'monospace', terminalFontSize: 13, refreshInterval: 0 }, snippets: [], identities: [], sshKeys: [], trustedHosts: [], capabilities: { configurationTransfer: true } };
const session = { sessionId: 'session-one', generation: 7 };
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
beforeEach(() => {
  native.request.mockReset(); native.bootstrap.mockReset(); native.mounted = 0; native.disposed = 0;
  native.bootstrap.mockResolvedValue(data);
  native.request.mockImplementation(async (method: string) => {
    if (method === 'session_open') return session;
    if (method === 'config_import_preview') return { previewId: 'preview', changes: [] };
    return null;
  });
});

describe('desktop session lifecycle', () => {
  it('keeps the same terminal mounted across navigation and configuration reload', async () => {
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: /打开本地终端/ }));
    const terminal = await screen.findByTestId('terminal');
    expect(native.mounted).toBe(1);
    fireEvent.click(screen.getByRole('button', { name: /设置/ }));
    expect(terminal.closest('.session-workspace')).toHaveAttribute('hidden');
    const reloading = deferred<Bootstrap>(); native.bootstrap.mockReturnValueOnce(reloading.promise);
    fireEvent.click(screen.getByRole('button', { name: '导入配置包' }));
    fireEvent.click(await screen.findByRole('button', { name: '应用导入' }));
    await waitFor(() => expect(native.bootstrap).toHaveBeenCalledTimes(2));
    expect(screen.getByTestId('terminal')).toBe(terminal);
    await act(async () => reloading.resolve(data));
    fireEvent.click(screen.getByRole('button', { name: /^会话/ }));
    expect(terminal.closest('.session-workspace')).not.toHaveAttribute('hidden');
    expect(native.mounted).toBe(1); expect(native.disposed).toBe(0);
    expect(native.request.mock.calls.some(([method]) => method === 'session_close')).toBe(false);
  });

  it('cancels a closed opening pane and closes its late successful connection', async () => {
    const opening = deferred<SessionRef>(); native.request.mockImplementation(async method => method === 'session_open' ? opening.promise : null);
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: /打开本地终端/ }));
    const openCall = native.request.mock.calls.find(([method]) => method === 'session_open')!;
    fireEvent.click(screen.getByRole('button', { name: '关闭面板 Windows PowerShell' }));
    await waitFor(() => expect(native.request).toHaveBeenCalledWith('session_cancel_open', { requestId: openCall[1].requestId }));
    await act(async () => opening.resolve(session));
    await waitFor(() => expect(native.request).toHaveBeenCalledWith('session_close', session));
    expect(screen.queryByTestId('terminal')).not.toBeInTheDocument();
    expect(native.mounted).toBe(0);
  });

  it('expires only the matching fingerprint prompt when multiple connections wait', async () => {
    render(<App />); await screen.findByRole('button', { name: /打开本地终端/ });
    const trust = (id: string, host: string): DesktopEvent => ({ kind: 'trust', payload: { id, requestId: id, host, port: 22, fingerprint: `SHA256:${id}`, algorithm: 'ssh-ed25519' } });
    act(() => { native.listener!(trust('one', 'first.example')); native.listener!(trust('two', 'second.example')); });
    expect(screen.getByText('first.example:22')).toBeInTheDocument();
    act(() => native.listener!({ kind: 'trust_expired', payload: { requestId: 'one' } }));
    expect(screen.getByText('second.example:22')).toBeInTheDocument();
    act(() => native.listener!({ kind: 'trust_expired', payload: { requestId: 'one' } }));
    expect(screen.getByText('second.example:22')).toBeInTheDocument();
  });
});
