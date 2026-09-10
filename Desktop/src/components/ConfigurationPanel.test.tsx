import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, expect, it, vi } from 'vitest';
import ConfigurationPanel from './ConfigurationPanel';

const native = vi.hoisted(() => ({ request: vi.fn() }));
vi.mock('../lib/api', async importOriginal => ({ ...await importOriginal<typeof import('../lib/api')>(), desktopAvailable: () => true, request: native.request }));
const changed = vi.fn(async () => {}); const errors = vi.fn();
beforeEach(() => { native.request.mockReset(); changed.mockClear(); errors.mockClear(); });

it('requires an explicit conflict choice before applying the preview', async () => {
  native.request.mockImplementation(async method => method === 'config_import_preview' ? { previewId: 'preview', changes: [{ id: 'host', conflict: true, choice: 'unresolved', local: { id: 'host', kind: 'ssh', fields: { name: 'Local' }, deleted: false }, remote: { id: 'host', kind: 'ssh', fields: { name: 'Imported' }, deleted: false } }] } : null);
  render(<ConfigurationPanel capabilities={{ configurationTransfer: true }} onChanged={changed} onError={errors} />);
  fireEvent.click(screen.getByRole('button', { name: '导入配置包' }));
  const apply = await screen.findByRole('button', { name: '应用导入' });
  expect(apply).toBeDisabled();
  fireEvent.change(screen.getByRole('combobox', { name: '选择 host 的版本' }), { target: { value: 'remote' } });
  fireEvent.click(apply);
  await waitFor(() => expect(native.request).toHaveBeenCalledWith('config_import_apply', { previewId: 'preview', choices: [{ id: 'host', choice: 'remote' }] }));
  expect(changed).toHaveBeenCalledOnce();
});

it('skips duplicate and invalid sessions by default and excludes passwords without consent', async () => {
  const candidate = (index: number, duplicate: boolean, invalid = false) => ({ index, duplicate, record: { name: `Host ${index}`, host: `${index}.example`, port: 22, username: 'ops' }, source: 'OpenSSH', sourcePath: 'config', warnings: [], errors: invalid ? ['Invalid host'] : [] });
  native.request.mockImplementation(async method => method === 'sessions_import_preview' ? { previewId: 'sessions', warnings: [], candidates: [candidate(0, false), candidate(1, true), candidate(2, false, true)] } : { imported: 1 });
  render(<ConfigurationPanel mode="sessions" capabilities={{ configurationTransfer: true }} onChanged={changed} onError={errors} />);
  fireEvent.click(screen.getByRole('button', { name: '选择文件或压缩包' }));
  expect(await screen.findByRole('combobox', { name: '导入 Host 1' })).toHaveValue('skip');
  expect(screen.getByRole('combobox', { name: '导入 Host 2' })).toBeDisabled();
  expect(screen.getByRole('checkbox')).not.toBeChecked();
  fireEvent.click(screen.getByRole('button', { name: '导入所选会话' }));
  await waitFor(() => expect(native.request).toHaveBeenCalledWith('sessions_import_apply', { previewId: 'sessions', selected: [{ index: 0, asCopy: false }], allowPlaintextPasswords: false }));
});
