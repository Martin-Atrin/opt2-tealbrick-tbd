import { ipcMain, type BrowserWindow } from "electron";
import type { UpdateState } from "@shared/ipc";

/** Teal Brick has no approved release channel yet. Never install an upstream
 * KYBER build over this fork. Keep the existing IPC contract for callers. */
export function registerUpdater(_window: () => BrowserWindow | null): void {
  const state: UpdateState = { status: "idle", version: null };
  const unavailable = () => ({ ok: false, error: "Teal Brick updates are not configured for this preview." });
  ipcMain.handle("studio:updaterState", () => state);
  ipcMain.handle("studio:updaterCheck", unavailable);
  ipcMain.handle("studio:updaterDownload", unavailable);
  ipcMain.handle("studio:updaterInstall", unavailable);
}
