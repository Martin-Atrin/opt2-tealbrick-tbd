/**
 * The typed host protocol of the TBD Chat helper: the native app (Swift) on the
 * other side of stdio provides storage keys, dialogs, notifications and URLs.
 * This is the only module the helper's main code uses for host services.
 */
import { EventEmitter } from 'node:events';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

export const handlers = new Map<string, (...args: any[]) => any>();
export const events = new EventEmitter();
let key: Buffer;
let output: (message: unknown) => void;
let nextId = 0;
const pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
export function configure(secret: string, send: typeof output) { key = Buffer.from(secret, 'base64'); if (key.length !== 32) throw Error('Invalid host key'); output = send; }
export function nativeReply(message: any) { const p = pending.get(message.id); if (!p) return; pending.delete(message.id); message.error ? p.reject(Error(message.error)) : p.resolve(message.value); }
export function nativeCall(method: string, ...args: unknown[]): Promise<any> {
  return new Promise((resolve, reject) => { const id = ++nextId; pending.set(id, { resolve, reject }); output({ type: 'native', id, method, args }); });
}
let userData = process.env.TBD_CHAT_DATA!;
/** A native call nobody awaits: log a failure instead of leaving an unhandled rejection. */
export function fireAndForget(method: string, ...args: unknown[]): void {
  nativeCall(method, ...args).catch((error) => console.error(`[helper:error] native ${method} failed: ${error instanceof Error ? error.message : String(error)}`));
}
export const app = Object.assign(new EventEmitter(), {
  commandLine: { getSwitchValue: (_name: string) => process.env.TBD_CHAT_DATA! },
  getPath: (name: string) => name === 'userData' ? userData : name === 'home' ? homedir() : name === 'temp' ? '/tmp' : join(homedir(), 'Library/Application Support'),
  setPath: (_name: string, path: string) => { userData = path; },
  getAppPath: () => process.cwd(), isPackaged: true,
});
export const safeStorage = {
  isEncryptionAvailable: () => key?.length === 32,
  encryptString(value: string) { const nonce = randomBytes(12); const c = createCipheriv('aes-256-gcm', key, nonce); const encrypted = Buffer.concat([c.update(value, 'utf8'), c.final()]); return Buffer.concat([nonce, c.getAuthTag(), encrypted]); },
  decryptString(value: Buffer) { const d = createDecipheriv('aes-256-gcm', key, value.subarray(0,12)); d.setAuthTag(value.subarray(12,28)); return Buffer.concat([d.update(value.subarray(28)),d.final()]).toString('utf8'); },
};
export const sender = Object.assign(new EventEmitter(), {
  isDestroyed: () => false,
  send: (channel: string, payload: unknown) => output({ type: 'event', channel, payload }),
});
export const ipcMain = {
  handle: (channel: string, handler: (...args: any[]) => any) => { handlers.set(channel, handler); },
  on: (channel: string, handler: (...args: any[]) => any) => { handlers.set(channel, handler); },
};
export const shell = {
  openExternal: (url: string) => nativeCall('openExternal', url),
  openPath: (path: string) => nativeCall('openPath', path),
  showItemInFolder: (path: string) => { fireAndForget('reveal', path); },
};
export const dialog = {
  showOpenDialog: (options: unknown) => nativeCall('openDialog', options),
  showSaveDialog: (options: unknown) => nativeCall('saveDialog', options),
};
export class Notification extends EventEmitter {
  constructor(private options: unknown) { super(); }
  static isSupported() { return true; }
  // Electron's show() never throws; a denied or failed notification must not either.
  show() { fireAndForget('notify', this.options); }
}
export class BrowserWindow {
  static fromWebContents(_contents?: unknown) { return { show: () => nativeCall('activate'), focus: () => nativeCall('activate'), isMinimized: () => false, restore() {} }; }
}

export type WebContents = typeof sender;
