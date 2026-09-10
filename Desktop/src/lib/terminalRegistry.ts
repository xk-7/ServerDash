import type { IBufferCell, Terminal } from '@xterm/xterm';
import type { SessionRef } from './api';

export type Cell = { text: string; width: number; foreground: number; background: number; style: number };
export type Frame = {
  screen: { columns: number; rows: number; lines: { cells: Cell[]; mode: number }[]; cursorColumn: number; cursorRow: number; cursorVisible: boolean; cursorStyle: string; foreground: number; background: number; hasImages: boolean };
  appearance: { fontName: string; fontSize: number; cellWidth: number; cellHeight: number };
  changedRows?: number[];
};
const terminals = new Map<string, Terminal>();
const key = (s: SessionRef) => `${s.sessionId}:${s.generation}`;
export function registerTerminal(session: SessionRef, terminal: Terminal) {
  terminals.set(key(session), terminal);
  return () => { if (terminals.get(key(session)) === terminal) terminals.delete(key(session)); };
}
export function terminalContext(session: SessionRef): string {
  const terminal = terminals.get(key(session));
  if (!terminal) throw new Error('原终端已关闭');
  const buffer = terminal.buffer.active;
  const lines = [];
  for (let row = Math.max(0, buffer.baseY - 100); row < buffer.baseY + terminal.rows; row++) lines.push(buffer.getLine(row)?.translateToString(true) ?? '');
  // Limit UTF-8 bytes, without splitting a code point.
  let result = lines.join('\n').slice(-8000);
  while (new TextEncoder().encode(result).length > 32768) result = result.slice(256);
  return result;
}
const colors = ['17212a', 'ef8a84', '78d5a6', 'e4c482', '8db7f5', 'c3a2f3', '6dcbd1', 'd4dde8', '71818f', 'ff0000', '00ff00', 'ffff00', '0000ff', 'ff00ff', '00ffff', 'ffffff'].map(v => parseInt(v, 16));
function palette(index: number) {
  if (index < 16) return colors[index] ?? 0;
  if (index >= 232) { const c = 8 + (index - 232) * 10; return c * 0x010101; }
  const n = index - 16; const steps = [0, 95, 135, 175, 215, 255];
  return (steps[Math.floor(n / 36)] << 16) | (steps[Math.floor(n / 6) % 6] << 8) | steps[n % 6];
}
function cell(c?: IBufferCell): Cell {
  if (!c) return { text: '', width: 1, foreground: 0xd4dde8, background: 0x101419, style: 0 };
  return { text: c.getChars(), width: c.getWidth(), foreground: c.isFgRGB() ? c.getFgColor() : c.isFgPalette() ? palette(c.getFgColor()) : 0xd4dde8,
    background: c.isBgRGB() ? c.getBgColor() : c.isBgPalette() ? palette(c.getBgColor()) : 0x101419,
    style: (c.isBold() ? 1 : 0) | (c.isUnderline() ? 2 : 0) | (c.isBlink() ? 4 : 0) | (c.isInverse() ? 8 : 0) | (c.isInvisible() ? 16 : 0) | (c.isDim() ? 32 : 0) | (c.isItalic() ? 64 : 0) | (c.isStrikethrough() ? 128 : 0) };
}
export function terminalFrame(session: SessionRef): Frame {
  const terminal = terminals.get(key(session)); if (!terminal) throw new Error('原终端已关闭');
  const b = terminal.buffer.active; const fontSize = terminal.options.fontSize ?? 13;
  const lines = Array.from({ length: terminal.rows }, (_, row) => ({ mode: 0, cells: Array.from({ length: terminal.cols }, (_, col) => cell(b.getLine(b.baseY + row)?.getCell(col))) }));
  return { screen: { columns: terminal.cols, rows: terminal.rows, lines, cursorColumn: b.cursorX, cursorRow: b.cursorY, cursorVisible: true,
    cursorStyle: terminal.options.cursorStyle ?? 'block', foreground: 0xd4dde8, background: 0x101419, hasImages: false },
    appearance: { fontName: terminal.options.fontFamily ?? 'monospace', fontSize, cellWidth: fontSize * 0.6, cellHeight: fontSize * 1.25 } };
}

const color = (n: number) => `#${n.toString(16).padStart(6, '0')}`;
/** A read-only renderer. Text is drawn as glyphs; no escape parser or terminal is used. */
export function drawRecording(canvas: HTMLCanvasElement, frame: Frame) {
  const { screen: s, appearance: a } = frame;
  const scale = Math.min(1, 4096 / (s.columns * a.cellWidth), 4096 / (s.rows * a.cellHeight));
  canvas.width = Math.ceil(s.columns * a.cellWidth * scale); canvas.height = Math.ceil(s.rows * a.cellHeight * scale);
  const context = canvas.getContext('2d'); if (!context) return;
  context.scale(scale, scale); context.textBaseline = 'top'; context.fillStyle = color(s.background); context.fillRect(0, 0, canvas.width / scale, canvas.height / scale);
  for (let row = 0; row < s.rows; row++) for (let col = 0; col < s.columns; col++) {
    const c = s.lines[row].cells[col]; const inverse = c.style & 8;
    const x = col * a.cellWidth, y = row * a.cellHeight;
    context.fillStyle = color(inverse ? c.foreground : c.background); context.fillRect(x, y, a.cellWidth * Math.max(c.width, 1), a.cellHeight);
  }
  for (let row = 0; row < s.rows; row++) for (let col = 0; col < s.columns; col++) {
    const c = s.lines[row].cells[col]; const inverse = c.style & 8;
    const x = col * a.cellWidth, y = row * a.cellHeight;
    if (!c.width || (c.style & 16)) continue;
    context.globalAlpha = c.style & 32 ? 0.55 : 1;
    context.fillStyle = color(inverse ? c.background : c.foreground);
    context.font = `${c.style & 64 ? 'italic ' : ''}${c.style & 1 ? 'bold ' : ''}${a.fontSize}px ${a.fontName}`;
    context.fillText(c.text.replace(/[\x00-\x1f\x7f-\x9f]/g, ''), x, y, a.cellWidth * c.width);
    if (c.style & 2) context.fillRect(x, y + a.cellHeight - 2, a.cellWidth * c.width, 1);
    if (c.style & 128) context.fillRect(x, y + a.cellHeight / 2, a.cellWidth * c.width, 1);
    context.globalAlpha = 1;
  }
  if (s.cursorVisible && s.cursorColumn < s.columns && s.cursorRow >= 0 && s.cursorRow < s.rows) {
    context.strokeStyle = color(s.foreground); context.strokeRect(s.cursorColumn * a.cellWidth, s.cursorRow * a.cellHeight, a.cellWidth, a.cellHeight);
  }
}
