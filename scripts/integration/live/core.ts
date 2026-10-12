/**
 * Phase 6M - pure helpers for the live Supabase integration run. No network, no Supabase imports,
 * so they are unit-tested under `npm test` (tests/integration-core.test.ts).
 *
 * TOTP here exists ONLY so the test runner can complete a real enrolment against Supabase Auth.
 * The application itself never computes codes.
 */
import { createHmac } from "node:crypto";

// ------------------------------------------------------------------------- TOTP (RFC 6238)

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function base32Decode(input: string): Uint8Array {
  const clean = input.replace(/[\s=-]/g, "").toUpperCase();
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    const idx = B32.indexOf(ch);
    if (idx < 0) throw new Error("Not a base32 string.");
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Uint8Array.from(out);
}

/** HMAC-SHA1 TOTP, 30 s step. `stepOffset` shifts by whole steps (0, +1, -1). */
export function totpCode(
  secretBase32: string,
  nowMs: number,
  stepOffset = 0,
  digits = 6,
): string {
  const counter = Math.floor(nowMs / 1000 / 30) + stepOffset;
  const msg = Buffer.alloc(8);
  msg.writeBigUInt64BE(BigInt(counter));
  const hmac = createHmac("sha1", base32Decode(secretBase32))
    .update(msg)
    .digest();
  const offset = (hmac[hmac.length - 1] ?? 0) & 0x0f;
  const bin =
    (((hmac[offset] ?? 0) & 0x7f) << 24) |
    (((hmac[offset + 1] ?? 0) & 0xff) << 16) |
    (((hmac[offset + 2] ?? 0) & 0xff) << 8) |
    ((hmac[offset + 3] ?? 0) & 0xff);
  return String(bin % 10 ** digits).padStart(digits, "0");
}

// --------------------------------------------------------------------------- safety guard

export function projectRefFromUrl(url: string): string | null {
  try {
    const host = new URL(url).hostname;
    const match = /^([a-z0-9]{10,40})\.supabase\.(co|in|net)$/.exec(host);
    return match?.[1] ?? null;
  } catch {
    return null;
  }
}

/**
 * The run creates and deletes users and writes data. It refuses to start unless the operator
 * names the project ref they mean to hit, and that ref matches SUPABASE_URL.
 */
export function assertSafeTarget(
  url: string,
  allowedRef: string | undefined,
): string {
  const ref = projectRefFromUrl(url);
  if (!ref)
    throw new Error(
      "SUPABASE_URL must look like https://<project-ref>.supabase.co",
    );
  if (!allowedRef) {
    throw new Error(
      `Set IT_ALLOW_PROJECT_REF=${ref} to confirm this is the project to test.`,
    );
  }
  if (allowedRef !== ref) {
    throw new Error(
      `IT_ALLOW_PROJECT_REF (${allowedRef}) does not match SUPABASE_URL (${ref}).`,
    );
  }
  return ref;
}

// ------------------------------------------------------------------------ error handling

export interface ErrorInfo {
  code: string | null;
  detail: string | null;
  message: string;
}

/** Normalises PostgREST / Auth errors. Returns null when there is no error. */
export function errorInfo(error: unknown): ErrorInfo | null {
  if (error === null || error === undefined) return null;
  if (typeof error !== "object")
    return { code: null, detail: null, message: String(error) };
  const e = error as Record<string, unknown>;
  const str = (v: unknown): string | null =>
    typeof v === "string" && v !== "" ? v : null;
  return {
    code: str(e["code"]),
    detail: str(e["details"]) ?? str(e["detail"]),
    message: str(e["message"]) ?? "(no message)",
  };
}

export interface CallResult {
  data: unknown;
  error: unknown;
}

export class SkipCheck extends Error {
  override readonly name = "SkipCheck";
}

export function expect(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

/** The call must fail. Optionally pin the SQLSTATE and/or DETAIL code. */
export function expectDenied(
  res: CallResult,
  want: { code?: string; detail?: string } = {},
): ErrorInfo {
  const info = errorInfo(res.error);
  if (!info)
    throw new Error("expected the call to be refused, but it succeeded");
  if (want.code !== undefined && info.code !== want.code) {
    throw new Error(
      `expected SQLSTATE ${want.code}, got ${info.code ?? "none"} (${info.message})`,
    );
  }
  if (want.detail !== undefined && info.detail !== want.detail) {
    throw new Error(
      `expected detail ${want.detail}, got ${info.detail ?? "none"} (${info.message})`,
    );
  }
  return info;
}

/** The call must succeed; returns its data. */
export function expectOk(res: CallResult, label = "call"): unknown {
  const info = errorInfo(res.error);
  if (info)
    throw new Error(`${label} failed: ${info.code ?? "?"} ${info.message}`);
  return res.data;
}

/** Row-level security may either hide every row or refuse outright; both are a pass. */
export function expectNoRows(res: CallResult, label = "read"): void {
  if (errorInfo(res.error)) return;
  const rows = Array.isArray(res.data)
    ? res.data
    : res.data == null
      ? []
      : [res.data];
  if (rows.length > 0)
    throw new Error(`${label} returned ${rows.length} row(s); expected none`);
}

// ------------------------------------------------------------------------------- results

export type Outcome = "PASS" | "FAIL" | "SKIP";

export interface CheckResult {
  section: string;
  name: string;
  outcome: Outcome;
  note: string;
}

export class Recorder {
  readonly results: CheckResult[] = [];

  async check(
    section: string,
    name: string,
    fn: () => Promise<void> | void,
  ): Promise<void> {
    try {
      await fn();
      this.results.push({ section, name, outcome: "PASS", note: "" });
    } catch (error) {
      if (error instanceof SkipCheck) {
        this.results.push({
          section,
          name,
          outcome: "SKIP",
          note: error.message,
        });
      } else {
        const note = error instanceof Error ? error.message : String(error);
        this.results.push({ section, name, outcome: "FAIL", note });
      }
    }
  }

  counts(): Record<Outcome, number> {
    const c: Record<Outcome, number> = { PASS: 0, FAIL: 0, SKIP: 0 };
    for (const r of this.results) c[r.outcome] += 1;
    return c;
  }
}

export function formatReport(results: CheckResult[]): string {
  const lines: string[] = [];
  let section = "";
  for (const r of results) {
    if (r.section !== section) {
      section = r.section;
      lines.push("", `== ${section}`);
    }
    lines.push(
      `${r.outcome.padEnd(4)}  ${r.name}${r.note ? `  -> ${r.note}` : ""}`,
    );
  }
  const c = { PASS: 0, FAIL: 0, SKIP: 0 };
  for (const r of results) c[r.outcome] += 1;
  lines.push(
    "",
    `TOTAL ${results.length}: ${c.PASS} passed, ${c.FAIL} failed, ${c.SKIP} skipped`,
  );
  return lines.join("\n");
}

// --------------------------------------------------------------------------- id helpers

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** First string value under a key named "id" (breadth-first), or null. */
export function findId(data: unknown, key = "id"): string | null {
  const queue: unknown[] = [data];
  while (queue.length > 0) {
    const item = queue.shift();
    if (Array.isArray(item)) {
      queue.push(...item);
    } else if (item !== null && typeof item === "object") {
      const rec = item as Record<string, unknown>;
      const v = rec[key];
      if (typeof v === "string" && UUID.test(v)) return v;
      queue.push(...Object.values(rec));
    }
  }
  return null;
}

/** Reads rec[key] as an object field; null when absent. */
export function field(data: unknown, key: string): unknown {
  if (data === null || typeof data !== "object" || Array.isArray(data))
    return null;
  return (data as Record<string, unknown>)[key] ?? null;
}
