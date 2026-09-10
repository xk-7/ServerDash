import { Channel, invoke, isTauri } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

export type MachineKind = 'ssh' | 'rdp' | 'vnc' | 'serial';
export type Machine = {
  id: string; name: string; kind: MachineKind; host: string; port: number; username: string;
  group: string; tags: string[]; notes: string; monitoringEnabled: boolean;
  authentication: 'password' | 'privateKey' | 'keyThenPassword' | 'agent'; privateKeyPath?: string;
  credentialId?: string; defaultRemotePath?: string;
  devicePath?: string; baudRate?: number; dataBits?: number; stopBits?: number;
  parity?: 'none' | 'odd' | 'even'; flowControl?: 'none' | 'hardware' | 'software';
};
export type Settings = { theme: 'dark' | 'light' | 'system'; terminalFontSize: number; terminalFontFamily: string; refreshInterval: number; localShell?: string; vncViewerPath?: string };
export const defaultSettings: Settings = { theme: 'dark', terminalFontSize: 13, terminalFontFamily: 'Cascadia Code, SFMono-Regular, Consolas, monospace', refreshInterval: 30 };
export type Snippet = { id: string; name: string; command: string; group?: string };
export type TrustedHost = { id: string; host: string; port: number; fingerprint: string; algorithm?: string };
export type Identity = { id: string; name: string; username: string; credentialId?: string };
export type SSHKey = { id: string; name: string; path: string; fingerprint?: string };
export type Capabilities = Record<string, boolean>;
export type Bootstrap = { machines: Machine[]; settings: Settings; snippets: Snippet[]; trustedHosts: TrustedHost[]; identities: Identity[]; sshKeys: SSHKey[]; capabilities: Capabilities; version?: string };
export type SessionRef = { sessionId: string; generation: number };
export type SessionStatus = SessionRef & { status: 'connecting' | 'connected' | 'closed' | 'failed'; message?: string };
export type TrustRequest = { id: string; requestId?: string; host: string; port: number; fingerprint: string; algorithm: string; replacing?: boolean; previousFingerprint?: string };
export type Monitoring = { machineId: string; capturedAt?: string; hostname?: string; cpuPercent?: number; memoryUsedBytes?: number; memoryTotalBytes?: number; diskUsedBytes?: number; diskTotalBytes?: number; networkRxBytesPerSecond?: number; networkTxBytesPerSecond?: number; uptimeSeconds?: number; loadAverage?: number[]; status?: string; error?: string; raw?: unknown };
export type FileEntry = { name: string; path: string; isDirectory: boolean; isSymlink?: boolean; size: number; modifiedAt?: string; permissions?: string };
export type Transfer = { id: string; taskId?: string; name: string; direction: string; transferred: number; total: number; status: string; error?: string };
export type TransferEvent = Partial<Transfer> & { taskId?: string; bytesTransferred?: number; totalBytes?: number };
export type DesktopEvent = { kind: 'trust' | 'trust_expired' | 'session_status' | 'monitoring' | 'transfer' | 'ai' | 'recording' | 'resync'; payload: TrustRequest | SessionStatus | Monitoring | TransferEvent | Record<string, unknown> };

export function mergeTransfer(previous: Transfer | undefined, event: TransferEvent): Transfer {
  return { id: event.taskId ?? event.id ?? previous?.id ?? '', taskId: event.taskId ?? previous?.taskId,
    name: event.name ?? previous?.name ?? '文件传输', direction: event.direction ?? previous?.direction ?? '',
    transferred: event.bytesTransferred ?? event.transferred ?? previous?.transferred ?? 0,
    total: event.totalBytes ?? event.total ?? previous?.total ?? 0, status: event.status ?? previous?.status ?? 'running',
    error: event.error };
}

export const desktopAvailable = () => isTauri();
export function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === 'string') return error;
  if (typeof error === 'object' && error !== null && 'message' in error) return String(error.message);
  return '操作未完成，请重试。';
}

export async function request<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (!desktopAvailable()) throw new Error('当前为浏览器预览。请启动 ServerDash 桌面应用以连接机器和保存配置。');
  return invoke<T>('desktop_request', { method, params });
}
export async function bootstrap(): Promise<Bootstrap> {
  const response = await request<Partial<Bootstrap>>('bootstrap');
  return { machines: response.machines ?? [], settings: { ...defaultSettings, ...response.settings }, snippets: response.snippets ?? [], trustedHosts: response.trustedHosts ?? [], identities: response.identities ?? [], sshKeys: response.sshKeys ?? [], capabilities: response.capabilities ?? {}, version: response.version };
}
export async function onDesktopEvent(callback: (event: DesktopEvent) => void) {
  if (!desktopAvailable()) return () => {};
  return listen<DesktopEvent>('desktop:event', ({ payload }) => callback(payload));
}
export function encodeInput(data: string): string {
  const bytes = new TextEncoder().encode(data);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}
export function decodeOutput(packet: ArrayBuffer | number[] | Uint8Array): { sequence: number; bytes: Uint8Array } {
  const bytes = packet instanceof ArrayBuffer ? new Uint8Array(packet) : new Uint8Array(packet);
  if (bytes.byteLength < 8) throw new Error('终端输出帧不完整');
  const sequence = Number(new DataView(bytes.buffer, bytes.byteOffset, 8).getBigUint64(0, true));
  if (!Number.isSafeInteger(sequence)) throw new Error('终端输出序号越界');
  return { sequence, bytes: bytes.subarray(8) };
}
export async function subscribeOutput(session: SessionRef, callback: (sequence: number, bytes: Uint8Array) => void) {
  const channel = new Channel<ArrayBuffer | number[]>();
  channel.onmessage = packet => { const { sequence, bytes } = decodeOutput(packet); callback(sequence, bytes); };
  await invoke('session_subscribe', { ...session, onOutput: channel });
  return channel;
}
export function normalizeFiles(response: FileEntry[] | { entries: FileEntry[] }): FileEntry[] {
  return Array.isArray(response) ? response : response.entries;
}
