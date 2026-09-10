import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { expect, it, vi } from 'vitest';
import AIPanel from './AIPanel';

const native = vi.hoisted(() => ({ request: vi.fn() }));
vi.mock('../lib/api', async importOriginal => ({ ...await importOriginal<typeof import('../lib/api')>(), desktopAvailable: () => true, request: native.request, onDesktopEvent: async () => () => {} }));
vi.mock('../lib/terminalRegistry', () => ({ terminalContext: () => '' }));

it('cancels an AI stream that starts after the inspector was closed', async () => {
  let resolve!: (value: { requestId: string }) => void;
  const opening = new Promise<{ requestId: string }>(r => { resolve = r; });
  native.request.mockImplementation(async method => {
    if (method === 'ai_profile_list') return [{ id: 'profile', provider: 'ollama', baseURL: 'http://localhost:11434', model: 'local' }];
    if (method === 'ai_conversation_list') return [];
    if (method === 'ai_send') return opening;
    return null;
  });
  const panel = render(<AIPanel enabled onError={() => {}} />);
  await waitFor(() => expect(screen.getByLabelText('AI 提供商配置')).toHaveValue('profile'));
  fireEvent.change(screen.getByLabelText('发送给 AI 的问题'), { target: { value: 'Explain this' } });
  fireEvent.click(screen.getByRole('button', { name: '发送' }));
  await waitFor(() => expect(native.request).toHaveBeenCalledWith('ai_send', expect.anything()));
  panel.unmount();
  await act(async () => resolve({ requestId: 'late-request' }));
  expect(native.request).toHaveBeenCalledWith('ai_cancel', { requestId: 'late-request' });
});
