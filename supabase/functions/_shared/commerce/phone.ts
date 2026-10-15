// Addendum A1 §5.3 step 2 — buyers type numbers the way Nigerians write them.
// The result must satisfy orders.customer_phone's E.164 check.
export function normalizePhone(input: string): string | null {
  const plus = input.trim().replace(/[()]/g, "").startsWith("+");
  let digits = input.replace(/[^0-9]/g, "");
  if (!plus && /^0[789][01][0-9]{8}$/.test(digits)) return `+234${digits.slice(1)}`;
  if (digits.startsWith("234")) {
    // A trunk 0 written after the country code (+234 0803…) is not part of E.164.
    if (/^2340[789][01][0-9]{8}$/.test(digits)) digits = `234${digits.slice(4)}`;
    return /^234[789][01][0-9]{8}$/.test(digits) ? `+${digits}` : null;
  }
  if (plus && /^[1-9][0-9]{7,14}$/.test(digits)) return `+${digits}`;
  return null;
}
