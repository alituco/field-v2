import { assertSafeDevDataTarget } from "./environment_guard.ts";

/** Only disposable loopback seed data may temporarily create paused games.
 * No application RPC, environment override, or hosted bypass is introduced.
 */
export async function withLocalClanSeedCheckout<T>(
  settings: {
    url: string;
    readEnabled: () => Promise<boolean>;
    writeEnabled: (enabled: boolean) => Promise<void>;
  },
  seed: () => Promise<T>,
): Promise<T> {
  if (
    assertSafeDevDataTarget(settings.url, "historical clan fixture seed")
      .environment !== "local"
  ) {
    throw new Error("Temporarily enabling clan fixture seeds is local-only.");
  }
  const enabledBefore = await settings.readEnabled();
  try {
    if (!enabledBefore) await settings.writeEnabled(true);
    return await seed();
  } finally {
    if (!enabledBefore) await settings.writeEnabled(false);
  }
}
