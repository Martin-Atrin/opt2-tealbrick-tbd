/** Observe the served manifest, never infer execution from Eve's hasRun flag. */
export async function observeSchedule(options: {
  read(): Promise<unknown>;
  current(): boolean;
  name: string;
  cron?: string;
  instruction?: string;
  removed?: boolean;
  handler?: boolean;
  attempts?: number;
  wait?: () => Promise<void>;
}): Promise<'loaded' | 'development' | 'pending' | 'cancelled'> {
  for (let i = 0; i < (options.attempts ?? 12); i++) {
    if (!options.current()) return 'cancelled';
    const raw = await options.read().catch(() => null) as {
      mode?: string;
      schedules?: { name: string; cron?: string; markdown?: string; hasRun?: boolean }[];
    } | null;
    if (!options.current()) return 'cancelled';
    if (Array.isArray(raw?.schedules)) {
      const found = raw.schedules.find(s => s.name === options.name);
      const matches = options.removed ? !found : found?.cron === options.cron
        && (options.handler ? found?.hasRun === true : found?.markdown?.trim() === options.instruction?.trim());
      if (matches && raw.mode === 'production') return 'loaded';
      if (matches && raw.mode === 'development') return 'development';
    }
    if (i + 1 < (options.attempts ?? 12)) {
      await (options.wait ?? (() => new Promise(resolve => setTimeout(resolve, 5000))))();
    }
  }
  return 'pending';
}
