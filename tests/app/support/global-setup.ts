// Before the app run: boot the local Auth hooks (Auth waits only 5 s for a
// hook, and a cold worker can take longer). Without a local stack this is a
// no-op, so the B1 gallery run still works on its own.
import { warmAuthHooks } from "./stack";

export default async function globalSetup(): Promise<void> {
  try {
    await warmAuthHooks();
  } catch {
    // no local stack: the B2 spec will say so when it runs
  }
}
