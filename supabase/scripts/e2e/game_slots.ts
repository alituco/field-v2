const HOUR = 60 * 60 * 1000;
const MINUTE = 60 * 1000;

// Leave time for builds/mobile automation, while keeping the played fixture
// inside S0's real +/-24h window. Cancellation remains >48h away for refunds.
export function selectJourneySlots(
  now: Date,
  existing: ReadonlyArray<{ starts_at: string; status: string }>,
): [Date, Date] {
  const nowMs = now.getTime();
  if (!Number.isFinite(nowMs)) throw new Error("Invalid E2E setup time.");
  const active = existing.filter((row) => row.status !== "CANCELLED");
  const occupied = new Set(
    active.map((row) => new Date(row.starts_at).getTime()),
  );
  const selected: Date[] = [];
  for (const [earliestHours, latestHours] of [[12, 23], [72, 96]]) {
    let selectedSlot: Date | undefined;
    const first = Math.ceil((nowMs + earliestHours * HOUR) / MINUTE) * MINUTE;
    for (
      let start = first;
      start <= nowMs + latestHours * HOUR;
      start += MINUTE
    ) {
      if (occupied.has(start)) continue;
      const earlierVisible = active.filter((row) =>
        ["OPEN", "FULL"].includes(row.status) &&
        new Date(row.starts_at).getTime() < start
      ).length;
      if (earlierVisible + selected.length + 1 > 40) {
        throw new Error(
          "No discoverable E2E slot without touching normal staging fixtures.",
        );
      }
      selectedSlot = new Date(start);
      break;
    }
    if (!selectedSlot) {
      throw new Error("No unoccupied E2E slot in the required kickoff window.");
    }
    selected.push(selectedSlot);
    occupied.add(selectedSlot.getTime());
  }
  return [selected[0], selected[1]];
}

export function assertJourneyKickoffWindow(startsAt: string, now: Date) {
  const delta = new Date(startsAt).getTime() - now.getTime();
  if (!Number.isFinite(delta) || Math.abs(delta) > 24 * HOUR) {
    throw new Error(
      "E2E match is outside the real +/-24h check-in/start window. Create fresh isolated fixtures.",
    );
  }
}
