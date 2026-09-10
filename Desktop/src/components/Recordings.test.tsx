import { act, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import Recordings from './Recordings';

const native = vi.hoisted(() => ({ request: vi.fn(), draw: vi.fn() }));
vi.mock('../lib/api', async importOriginal => ({ ...await importOriginal<typeof import('../lib/api')>(), desktopAvailable: () => true, request: native.request }));
vi.mock('../lib/terminalRegistry', () => ({ drawRecording: native.draw }));
afterEach(() => vi.useRealTimers());

it('does not repeatedly decode an unchanged paused position', async () => {
  vi.useFakeTimers(); native.request.mockReset(); native.draw.mockClear();
  native.request.mockImplementation(async method => method === 'recording_list' ? [{ id: 'recording', name: 'Trace', duration: 30, complete: true }] : {});
  render(<Recordings available onError={() => {}} />);
  await act(async () => {});
  fireEvent.click(screen.getByRole('button', { name: /Trace/ }));
  await act(async () => {});
  await act(async () => vi.advanceTimersByTimeAsync(1500));
  expect(native.request.mock.calls.filter(([method]) => method === 'recording_seek')).toHaveLength(1);
  fireEvent.change(screen.getByRole('slider', { name: '回放时间' }), { target: { value: '10' } });
  await act(async () => vi.advanceTimersByTimeAsync(200));
  expect(native.request).toHaveBeenLastCalledWith('recording_seek', { id: 'recording', time: 10 });
  expect(native.draw).toHaveBeenCalledTimes(2);
});
