// Spec A §3.6 check 2. Paystack's signature carries no timestamp, so the window
// is measured against the event's own time: paid_at, else created_at. No
// usable time fails closed (treated as stale; the reconcile sweep settles it).
export const REPLAY_WINDOW_MS = 300_000;

export function eventTime(data: { paid_at?: string | null; created_at?: string | null }): Date | null {
  const raw = data.paid_at ?? data.created_at;
  if (!raw) return null;
  const at = new Date(raw);
  return Number.isNaN(at.getTime()) ? null : at;
}

export function withinReplayWindow(at: Date | null, now: Date): boolean {
  return at !== null && Math.abs(now.getTime() - at.getTime()) <= REPLAY_WINDOW_MS;
}
