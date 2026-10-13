import type { Attachment, WireAttachment } from "./ipc";

/**
 * What one user turn looks like when it reaches TBD's agent, with or without files.
 *
 * @remarks
 * Kept out of the main process so it can be tested without a window or a live
 * agent: the ordering rule below is the kind of thing that is obvious while
 * writing it and invisible the day someone reorders the array.
 *
 * The output is the Anthropic Messages content the Claude Agent SDK passes on
 * unchanged (a user `MessageParam`), so nothing between here and the model
 * re-shapes the files.
 */

/** A text segment of a user turn. */
export interface TextBlock {
  type: "text";
  text: string;
}

/** A picture the model can see. */
export interface ImageBlock {
  type: "image";
  source: { type: "base64"; media_type: "image/png" | "image/jpeg" | "image/gif" | "image/webp"; data: string };
}

/** A document the model reads: a PDF (base64) or plain text. */
export interface DocumentBlock {
  type: "document";
  title?: string;
  source: { type: "base64"; media_type: "application/pdf"; data: string } | { type: "text"; media_type: "text/plain"; data: string };
}

export type ContentBlock = TextBlock | ImageBlock | DocumentBlock;
export type MessageContent = string | ContentBlock[];

const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
const TEXT_TYPES = new Set(["application/json", "application/xml", "image/svg+xml", "application/x-yaml", "application/yaml"]);

/** Base64 without Node's Buffer, so this stays usable from the renderer too. */
export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

function fromBase64(data: string): Uint8Array {
  const binary = atob(data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/**
 * The renderer → helper wire shape: bytes as base64. A typed array does not survive the
 * WebKit message bridge as bytes, which is how attachments used to arrive as "[object Object]".
 */
export function toWire(file: Attachment): WireAttachment {
  return { name: file.name, mediaType: file.mediaType, size: file.size, data: toBase64(file.bytes) };
}

/** Back from the wire. Refuses anything that is not a named file with base64 bytes. */
export function fromWire(raw: unknown): Attachment {
  const f = raw as Partial<WireAttachment> | null;
  if (!f || typeof f.name !== "string" || typeof f.mediaType !== "string" || typeof f.data !== "string") {
    throw new Error("An attached file could not be read. Attach it again.");
  }
  const bytes = fromBase64(f.data);
  return { name: f.name, mediaType: f.mediaType, size: bytes.length, bytes };
}

/** Whether the model reads this type inline (picture, PDF or text). */
export function readsInline(mediaType: string): boolean {
  return IMAGE_TYPES.has(mediaType) || mediaType === "application/pdf" || mediaType.startsWith("text/") || TEXT_TYPES.has(mediaType);
}

/**
 * Build the content for a turn.
 *
 * @remarks
 * A plain string when nothing is attached: the overwhelming case, and the shape
 * every turn used before attachments existed.
 *
 * The text block comes FIRST, deliberately. A model reads the turn in order, and
 * a file arriving ahead of its instruction is a document dropped on a desk with
 * no note attached. An empty text block is left out (the API refuses it); the
 * files alone mean "look at this".
 *
 * Pictures, PDFs and text files are inlined, so the model receives the bytes with
 * the turn. Other types (Word, spreadsheets, archives) cannot be read inline: the
 * caller's `save` puts them in the agent's own working folder, where its file
 * tools may read them without asking, and the turn names where they are. Without
 * `save`, the turn says the file could not be passed on.
 */
export function buildMessage(
  text: string,
  attachments?: readonly Attachment[],
  save?: (file: Attachment) => string,
): MessageContent {
  if (!attachments || attachments.length === 0) return text;
  const notes: string[] = [];
  const files: ContentBlock[] = [];
  for (const file of attachments) {
    if (IMAGE_TYPES.has(file.mediaType)) {
      files.push({ type: "image", source: { type: "base64", media_type: file.mediaType as ImageBlock["source"]["media_type"], data: toBase64(file.bytes) } });
    } else if (file.mediaType === "application/pdf") {
      files.push({ type: "document", title: file.name, source: { type: "base64", media_type: "application/pdf", data: toBase64(file.bytes) } });
    } else if (readsInline(file.mediaType)) {
      files.push({ type: "document", title: file.name, source: { type: "text", media_type: "text/plain", data: new TextDecoder().decode(file.bytes) } });
    } else if (save) {
      notes.push(`Attached file "${file.name}" (${file.mediaType}) is saved at ${save(file)}`);
    } else {
      notes.push(`Attached file "${file.name}" (${file.mediaType}) could not be passed on.`);
    }
  }
  const lead = [text, ...notes].filter((part) => part.length > 0).join("\n\n");
  return lead ? [{ type: "text", text: lead }, ...files] : files;
}
