// The client's copy of the server's PIN rule (pin_policy_refusal, migration
// 20261125130000), so a weak PIN is refused before anything is sent. The
// database still decides: its refusal is shown as written.
export function pinPolicyRefusal(pin: string): string | null {
  if (!/^\d{4}$/.test(pin)) return "a PIN is exactly four digits";
  const d = [...pin].map(Number);
  if (d.every((x) => x === d[0])) return "choose a PIN that is not one digit repeated";
  const up = d.every((x, i) => i === 0 || x === d[i - 1] + 1);
  const down = d.every((x, i) => i === 0 || x === d[i - 1] - 1);
  if (up || down) return "choose a PIN that is not a run of digits";
  return null;
}

/** Shown in the UI: the database copy with a capital first letter. */
export const sentence = (s: string) => s.charAt(0).toUpperCase() + s.slice(1) + (/[.!?]$/.test(s) ? "" : ".");
