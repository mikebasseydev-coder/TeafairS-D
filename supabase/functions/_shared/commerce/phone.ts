// Addendum A1 §5.3 step 2 — buyers type numbers the way Nigerians write them.
// The result must satisfy orders.customer_phone's E.164 check.
export function normalizePhone(input: string): string | null {
  const plus = input.trim().replace(/[()]/g, "").startsWith("+");
  const digits = input.replace(/[^0-9]/g, "");
  if (!plus && /^0[789][01][0-9]{8}$/.test(digits)) return `+234${digits.slice(1)}`;
  if (!plus && /^234[0-9]{10}$/.test(digits)) return `+${digits}`;
  if (plus && /^[1-9][0-9]{7,14}$/.test(digits)) return `+${digits}`;
  return null;
}
