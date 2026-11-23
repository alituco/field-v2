import { scannedWindow } from "./scanned-window.ts";
Deno.test("use the media clock and clamp either end of the 30s/5s window", () => {
  for (
    const [goal, duration, start, end] of [[630, 1156, 600, 635], [
      2,
      100,
      0,
      7,
    ], [98, 100, 68, 100]]
  ) {
    const w = scannedWindow(goal, duration);
    if (w?.goal !== goal || w.start !== start || w.end !== end) {
      throw new Error("Incorrect window");
    }
  }
  for (const value of [-1, 100, Infinity, NaN]) {
    if (scannedWindow(value, 100) !== null) throw new Error("Invalid offset");
  }
});
