import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, expect, it, vi } from 'vitest';
import type { Machine } from '../lib/api';
import MachineEditor from './MachineEditor';

const native = vi.hoisted(() => ({ request: vi.fn() }));
vi.mock('../lib/api', async importOriginal => ({ ...await importOriginal<typeof import('../lib/api')>(), request: native.request }));
const machine: Machine = { id: 'one', name: 'Host', kind: 'ssh', host: 'host.example', port: 22, username: 'ops', group: '', tags: [], notes: '', monitoringEnabled: false, authentication: 'keyThenPassword', credentialId: 'existing', privateKeyPath: 'C:\\keys\\id_ed25519' };
beforeEach(() => { native.request.mockReset(); native.request.mockImplementation(async method => method === 'credential_save' ? { credentialId: 'replacement' } : null); });

it('updates only a newly entered key passphrase while retaining the native password reference', async () => {
  const save = vi.fn(); render(<MachineEditor machine={machine} onClose={() => {}} onSave={save} />);
  fireEvent.change(screen.getByLabelText('私钥口令（可选）'), { target: { value: 'new phrase' } });
  fireEvent.click(screen.getByRole('button', { name: '保存机器' }));
  await waitFor(() => expect(save).toHaveBeenCalledOnce());
  expect(native.request).toHaveBeenCalledWith('credential_save', { secret: { passphrase: 'new phrase' }, baseCredentialId: 'existing', name: 'Host' });
  expect(native.request).toHaveBeenCalledWith('machine_save', { machine: { ...machine, credentialId: 'replacement' } });
});

it('saves serial device binding and framing settings using native field names', async () => {
  const save = vi.fn(); render(<MachineEditor machine={{ ...machine, kind: 'serial', host: 'COM7', credentialId: undefined }} onClose={() => {}} onSave={save} />);
  fireEvent.change(screen.getByLabelText('波特率'), { target: { value: '57600' } });
  fireEvent.change(screen.getByLabelText('校验位'), { target: { value: 'even' } });
  fireEvent.click(screen.getByRole('button', { name: '保存机器' }));
  await waitFor(() => expect(save).toHaveBeenCalledOnce());
  expect(native.request).toHaveBeenCalledWith('machine_save', { machine: expect.objectContaining({ devicePath: 'COM7', baudRate: 57600, dataBits: 8, parity: 'even', stopBits: 1, flowControl: 'none' }) });
  expect(native.request).not.toHaveBeenCalledWith('credential_save', expect.anything());
});
