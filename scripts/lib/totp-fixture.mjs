import { createHmac } from "node:crypto";

// Synthetic test authenticator only. Never import this into the app/API or use
// it as a production factor verifier. Secrets and generated codes stay in memory.
// RFC 6238 (SHA-1) and RFC 4648 base32; no provider behavior is simulated here.
const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const paddingByRemainder = new Map([
  [0, 0],
  [2, 6],
  [4, 4],
  [5, 3],
  [7, 1],
]);

function decodeBase32(secret) {
  if (
    typeof secret !== "string" ||
    secret.length === 0 ||
    secret.length > 1024 ||
    !/^[A-Za-z2-7]+={0,6}$/.test(secret)
  ) {
    throw new Error("Invalid synthetic base32 secret.");
  }
  const encoded = secret.toUpperCase().replace(/=+$/, "");
  const padding = secret.length - encoded.length;
  const expectedPadding = paddingByRemainder.get(encoded.length % 8);
  if (
    expectedPadding === undefined ||
    (padding !== 0 && padding !== expectedPadding)
  ) {
    throw new Error("Invalid synthetic base32 secret.");
  }
  const bytes = [];
  let bits = 0;
  let remainder = 0;
  for (const character of encoded) {
    remainder = (remainder << 5) | alphabet.indexOf(character);
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.push(remainder >>> bits);
      remainder &= (1 << bits) - 1;
    }
  }
  if (remainder !== 0) throw new Error("Invalid synthetic base32 secret.");
  return Buffer.from(bytes);
}

export function generateTotp(
  secret,
  {
    timestampSeconds = Math.floor(Date.now() / 1000),
    digits = 6,
    stepSeconds = 30,
  } = {},
) {
  if (
    !Number.isSafeInteger(timestampSeconds) ||
    timestampSeconds < 0 ||
    !Number.isSafeInteger(stepSeconds) ||
    stepSeconds <= 0 ||
    ![6, 8].includes(digits)
  ) {
    throw new Error("Invalid synthetic TOTP parameters.");
  }
  const key = decodeBase32(secret);
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(timestampSeconds) / BigInt(stepSeconds));
  try {
    const digest = createHmac("sha1", key).update(counter).digest();
    const offset = digest[digest.length - 1] & 0x0f;
    const number = digest.readUInt32BE(offset) & 0x7fffffff;
    return String(number % 10 ** digits).padStart(digits, "0");
  } finally {
    key.fill(0);
  }
}
