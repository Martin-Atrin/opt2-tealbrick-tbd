import { AsyncLocalStorage } from 'node:async_hooks';
import { createInterface } from 'node:readline';
import { configure, handlers, sender, nativeReply, app } from './platform';
const send = (message: unknown) => process.stdout.write(JSON.stringify(message) + '\n');
console.log = console.info = console.debug = (...args) => console.error(...args);
// One failed background promise or callback must not take every chat down with it:
// Node exits 1 on either by default. Log the error (no payloads) and keep serving;
// per-request failures are already answered as error replies below.
const report = (kind: string, error: unknown) => {
  const text = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
  const frames = error instanceof Error ? (error.stack ?? '').split('\n').slice(1, 4).map((f) => f.trim().replace(/\/[^\s():]*\//g, '')) : [];
  console.error(`[helper:error] ${kind}: ${text}${frames.length ? ` (${frames.join(' | ')})` : ''}`);
};
process.on('unhandledRejection', (reason) => report('unhandled rejection', reason));
process.on('uncaughtException', (error) => report('uncaught exception', error));
let initialized = false;
let resetting = false;
let resetOwner: number | undefined;
const requests = new AsyncLocalStorage<number>();
let stop = () => {};
let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true; resetting = true; stop();
  setTimeout(() => process.exit(0), 400);
}
app.on('tbd:reset-session', () => { resetting = true; resetOwner = requests.getStore(); });
const lines = createInterface({ input: process.stdin });
lines.on('line', async (line) => {
  let message: any;
  try {
    message = JSON.parse(line);
    if (message.type === 'init' && !initialized) {
      configure(message.key, send);
      await import('../main/controlPlanes');
      const { registerIpc } = await import('../main/ipc');
      const { startLocalExec, stopLocalExec, setLocalExecWindow } = await import('../main/localExec');
      const { stopAll } = await import('../main/localMcp');
      registerIpc();
      setLocalExecWindow(sender as any);
      stop = () => { sender.emit('destroyed'); stopLocalExec(); stopAll(); };
      startLocalExec(); initialized = true; send({ type: 'ready' }); return;
    }
    if (message.type === 'nativeReply') { nativeReply(message); return; }
    if (message.type === 'shutdown') { shutdown(); return; }
    if (!initialized || resetting) throw Error('Chat session is changing. Retry when ready.');
    const handler = handlers.get(message.channel);
    if (!handler) throw Error(`Unsupported bridge method: ${message.channel}`);
    const value = await requests.run(message.id, () => handler({ sender }, ...(message.args ?? [])));
    if (resetting && resetOwner === message.id) { stop(); send({ type: 'reset', id: message.id }); }
    else if (resetting) send({ type: 'reply', id: message.id, error: 'Chat workspace changed' });
    else send({ type: 'reply', id: message.id, value: value ?? null });
  } catch (error) {
    send({ type: message?.type === 'init' ? 'fatal' : 'reply', id: message?.id, error: error instanceof Error ? error.message : String(error) }); }
});
lines.on('close', shutdown);
process.on('SIGTERM', shutdown);
