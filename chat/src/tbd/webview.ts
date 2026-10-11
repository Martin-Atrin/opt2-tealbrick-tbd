/** The WKWebView side of the host bridge: renderer <-> native via webkit message handlers. */
let nextId = 0;
const pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
const listeners = new Map<string, Set<(...args: any[]) => void>>();
export const ipcRenderer = {
  invoke(channel: string, ...args: unknown[]): Promise<any> {
    return new Promise((resolve, reject) => { const id = ++nextId; pending.set(id, { resolve, reject }); (window as any).webkit.messageHandlers.tbd.postMessage({ id, channel, args }); });
  },
  send(channel: string, ...args: unknown[]) { void this.invoke(channel, ...args).catch(console.error); },
  on(channel: string, handler: (...args: any[]) => void) { if (!listeners.has(channel)) listeners.set(channel, new Set()); listeners.get(channel)!.add(handler); },
  off(channel: string, handler: (...args: any[]) => void) { listeners.get(channel)?.delete(handler); },
};
(window as any).__tbdReceive = (message: any) => {
  if (message.type === 'event') { listeners.get(message.channel)?.forEach(fn => fn(null, message.payload)); return; }
  const p = pending.get(message.id); if (!p) return; pending.delete(message.id);
  message.error ? p.reject(Error(message.error)) : p.resolve(message.value);
};
(window as any).tbdAudio = { invoke: (method: string) => ipcRenderer.invoke('tbd:audio', method) };
