/**
 * A fresh key identifying one checkout attempt. create_order() returns the
 * original order when it sees a key again, so a replayed submit never creates
 * a second order.
 */
export function newIdempotencyKey(): string {
  const webCrypto = globalThis.crypto;

  if (typeof webCrypto.randomUUID === "function") return webCrypto.randomUUID();

  // Older browsers and non-secure contexts have getRandomValues but no randomUUID.
  const bytes = webCrypto.getRandomValues(new Uint8Array(16));
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40; // version 4
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80; // RFC 4122 variant
  const hex = Array.from(bytes, (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join("-");
}
