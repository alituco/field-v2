import { NextResponse } from "next/server";

export function cleanReliabilityText(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

export function validReliabilityIso(value: unknown) {
  if (typeof value !== "string") return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : null;
}

export function validReliabilityBahrainDateStart(value: unknown) {
  const iso = validReliabilityIso(value);
  if (!iso) return null;
  const timestamp = Date.parse(iso);
  const bahrainOffsetMilliseconds = 3 * 60 * 60 * 1_000;
  return (timestamp + bahrainOffsetMilliseconds) % (24 * 60 * 60 * 1_000) === 0
    ? iso
    : null;
}

export function optionalReliabilityUuid(
  value: unknown,
  label: string,
): string | null | NextResponse {
  if (value == null || value === "") return null;
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    return NextResponse.json({ error: `Choose a valid ${label}.` }, { status: 400 });
  }
  return value;
}

export function reliabilityMutationStatus(message: string) {
  const lower = message.toLowerCase();
  return lower.includes("changed") || lower.includes("stale") || lower.includes("already")
    ? 409
    : 400;
}
