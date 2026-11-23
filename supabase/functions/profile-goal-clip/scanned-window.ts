// The scoreboard changes after the referee confirms a goal. Preserve the buildup.
export function scannedWindow(position: number, duration: number) {
  if (!Number.isFinite(position) || position < 0 || position >= duration) {
    return null;
  }
  return {
    start: Math.max(0, position - 30),
    end: Math.min(duration, position + 5),
    goal: position,
  };
}
