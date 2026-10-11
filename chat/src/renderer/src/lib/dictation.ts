/**
 * Recording speech, and only while somebody is holding the control.
 *
 * No audio is captured unless the user started dictation; the native host
 * (TBD Listening) owns the shared microphone and the local speech-to-text.
 */

export interface Recorder {
  /** Stop and return the transcript (or an error). */
  finishText(): Promise<{ text?: string; error?: string }>;
  /** Stop and discard. For Escape, and for anything that goes wrong. */
  cancel(): void;
  /** 0–1, for showing that the microphone is genuinely hearing something. */
  level(): number;
}

type NativeAudio = { invoke(method: string): Promise<any> };

/**
 * Open the microphone through the native host and start recording.
 *
 * @throws When the host refuses (permission, busy), so the caller can say so.
 */
export async function record(): Promise<Recorder> {
  const native = (window as unknown as { tbdAudio?: NativeAudio }).tbdAudio;
  if (!native) throw new Error("Dictation needs the TBD host.");
  await native.invoke("start");
  let level = 0;
  const meter = setInterval(() => { void native.invoke("level").then(value => { level = Number(value); }).catch(() => {}); }, 100);
  return {
    level: () => level,
    cancel: () => { clearInterval(meter); void native.invoke("cancel").catch(() => {}); },
    finishText: async () => {
      clearInterval(meter);
      try { return await native.invoke("stop"); }
      catch (error) { return { error: error instanceof Error ? error.message : String(error) }; }
    },
  };
}
