import { expect, type Locator, type Page } from "@playwright/test";

/** Match only the selected game's finalization, not a goal or another action. */
export function isSoloFinishAction(
  method: string,
  pathname: string,
  body: unknown,
  gameId: string,
): boolean {
  return method === "POST" &&
    pathname === `/api/referee/open-queue-games/${gameId}/action` &&
    isRecord(body) && body.action === "finish";
}

/** Never include response metadata, request headers or the complete payload. */
export function finishFailureMessage(status: number, payload: unknown): string {
  const error = isRecord(payload) && typeof payload.error === "string"
    ? payload.error
    : "The API did not return a successful finalization acknowledgement.";
  const safeError = error
    .replace(/\bBearer\s+\S+/gi, "Bearer [redacted]")
    .replace(/\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9_]+\b/g, "[redacted]")
    .replace(/\bsb_(?:secret|publishable)_[A-Za-z0-9_-]+\b/g, "[redacted]")
    .replace(/\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "[redacted]")
    .replace(/\b(?:authorization|(?:access|refresh)[_-]?token|api[_-]?key|service[_-]?role[_-]?key)\s*[:=]\s*["']?[^\s,}"']+/gi, "[redacted credential]")
    .replace(/\b[a-z][a-z0-9+.-]*:\/\/[^\s/]*@/gi, "[redacted connection]@")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 600);
  return `Solo match finalization failed (HTTP ${status}): ${safeError}`;
}

export async function finishSoloMatch(
  page: Page,
  gameId: string,
  finishButton: Locator,
): Promise<void> {
  // Arm the response listener before the click. Retain Playwright's existing
  // timeout and make exactly one attempt; this does not bypass the finalizer.
  const [response] = await Promise.all([
    page.waitForResponse((candidate) => {
      const request = candidate.request();
      let body: unknown;
      try {
        body = request.postDataJSON();
      } catch {
        return false;
      }
      return isSoloFinishAction(
        request.method(),
        new URL(candidate.url()).pathname,
        body,
        gameId,
      );
    }),
    finishButton.click(),
  ]);
  const payload: unknown = await response.json().catch(() => null);
  const succeeded = response.ok() && isRecord(payload) && payload.ok === true;
  expect(succeeded, finishFailureMessage(response.status(), payload)).toBe(true);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
