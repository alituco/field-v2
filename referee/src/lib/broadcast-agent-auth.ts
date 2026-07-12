import { timingSafeEqual } from "node:crypto";

export function isBroadcastAgentRequest(request: Request) {
  const expected = process.env.BROADCAST_AGENT_TOKEN?.trim();
  const provided = request.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "")
    .trim();

  if (!expected || !provided) return false;

  const expectedBytes = Buffer.from(expected);
  const providedBytes = Buffer.from(provided);
  return expectedBytes.length === providedBytes.length &&
    timingSafeEqual(expectedBytes, providedBytes);
}

export function broadcastDeviceKey() {
  return process.env.BROADCAST_DEVICE_KEY?.trim() || "main-pitch";
}

export function broadcastDeviceName() {
  return process.env.BROADCAST_DEVICE_NAME?.trim() || "Main Pitch Camera";
}

export function broadcastOverlayToken() {
  const value = process.env.BROADCAST_OVERLAY_TOKEN?.trim();
  if (!value) throw new Error("BROADCAST_OVERLAY_TOKEN is not configured.");
  return value;
}

export function isValidOverlayToken(value: string | null) {
  const expected = process.env.BROADCAST_OVERLAY_TOKEN?.trim();
  if (!expected || !value) return false;

  const expectedBytes = Buffer.from(expected);
  const providedBytes = Buffer.from(value);
  return expectedBytes.length === providedBytes.length &&
    timingSafeEqual(expectedBytes, providedBytes);
}
