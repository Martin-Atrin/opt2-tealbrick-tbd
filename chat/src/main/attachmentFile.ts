import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

/**
 * Keep a file the person attached that the model cannot read inline (Word, spreadsheets,
 * archives) in `dir` (the agent's own working folder, Attachments/), where its file tools may
 * read it without asking. The name is reduced to one safe path segment; an existing file is
 * never overwritten: a second file with the same name gets a numbered name.
 */
export function saveAttachmentIn(dir: string, file: { name: string; bytes: Uint8Array }): string {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const safe = basename(file.name).replace(/[^\w.\- ]+/g, "_").replace(/^\.+/, "") || "attachment";
  const dot = safe.lastIndexOf(".");
  const [stem, ext] = dot > 0 ? [safe.slice(0, dot), safe.slice(dot)] : [safe, ""];
  let path = join(dir, safe);
  for (let n = 2; existsSync(path); n += 1) path = join(dir, `${stem} ${n}${ext}`);
  writeFileSync(path, file.bytes, { mode: 0o600, flag: "wx" });
  return path;
}
