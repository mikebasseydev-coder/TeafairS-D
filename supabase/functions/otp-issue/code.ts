// Uniform 6-digit codes: rejection sampling avoids the modulo bias of
// `random % 1_000_000` on a 32-bit draw.
const RANGE = 1_000_000;
const LIMIT = 2 ** 32 - (2 ** 32 % RANGE);

export function generateOtpCode(): string {
  const draw = new Uint32Array(1);
  do crypto.getRandomValues(draw); while (draw[0] >= LIMIT);
  return String(draw[0] % RANGE).padStart(6, "0");
}

// "+2348012345678" → "+234******5678"
export function maskPhone(phone: string): string {
  return phone.slice(0, 4) + "*".repeat(Math.max(phone.length - 8, 0)) + phone.slice(-4);
}
