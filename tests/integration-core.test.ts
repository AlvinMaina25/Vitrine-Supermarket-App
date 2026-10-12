import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  Recorder,
  SkipCheck,
  assertSafeTarget,
  base32Decode,
  errorInfo,
  expectDenied,
  expectNoRows,
  expectOk,
  findId,
  formatReport,
  projectRefFromUrl,
  totpCode,
} from "../scripts/integration/live/core.ts";

// RFC 6238 appendix B (SHA-1), secret "12345678901234567890", last 6 digits of the 8-digit codes.
const RFC_SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

describe("totpCode", () => {
  it("matches the RFC 6238 SHA-1 test vectors", () => {
    const vectors: Array<[number, string]> = [
      [59, "287082"],
      [1111111109, "081804"],
      [1111111111, "050471"],
      [1234567890, "005924"],
      [2000000000, "279037"],
      [20000000000, "353130"],
    ];
    for (const [seconds, code] of vectors) {
      assert.equal(totpCode(RFC_SECRET, seconds * 1000), code, `t=${seconds}`);
    }
  });

  it("stepOffset moves by whole 30-second steps", () => {
    assert.equal(totpCode(RFC_SECRET, 59_000, 1), totpCode(RFC_SECRET, 89_000));
    assert.equal(
      totpCode(RFC_SECRET, 89_000, -1),
      totpCode(RFC_SECRET, 59_000),
    );
  });

  it("base32Decode ignores case, spaces and padding, and rejects junk", () => {
    assert.equal(Buffer.from(base32Decode("mzxw 6===")).toString(), "foo");
    assert.throws(() => base32Decode("not-base32!"));
  });
});

describe("assertSafeTarget", () => {
  it("extracts the project ref", () => {
    assert.equal(
      projectRefFromUrl("https://abcdefghijklmnopqrst.supabase.co"),
      "abcdefghijklmnopqrst",
    );
    assert.equal(projectRefFromUrl("http://localhost:54321"), null);
    assert.equal(projectRefFromUrl("not a url"), null);
  });

  it("refuses a missing or mismatched confirmation", () => {
    const url = "https://abcdefghijklmnopqrst.supabase.co";
    assert.throws(
      () => assertSafeTarget(url, undefined),
      /IT_ALLOW_PROJECT_REF=abcdefghijklmnopqrst/,
    );
    assert.throws(
      () => assertSafeTarget(url, "otherprojectref12345"),
      /does not match/,
    );
    assert.throws(
      () => assertSafeTarget("http://localhost:54321", "x"),
      /project-ref/,
    );
    assert.equal(
      assertSafeTarget(url, "abcdefghijklmnopqrst"),
      "abcdefghijklmnopqrst",
    );
  });
});

describe("error expectations", () => {
  const refused = {
    data: null,
    error: { code: "42501", details: "not_authorised", message: "no" },
  };

  it("errorInfo normalises PostgREST errors and null", () => {
    assert.equal(errorInfo(null), null);
    assert.deepEqual(errorInfo(refused.error), {
      code: "42501",
      detail: "not_authorised",
      message: "no",
    });
  });

  it("expectDenied pins code and detail", () => {
    assert.doesNotThrow(() =>
      expectDenied(refused, { code: "42501", detail: "not_authorised" }),
    );
    assert.throws(
      () => expectDenied(refused, { detail: "mfa_required" }),
      /expected detail mfa_required/,
    );
    assert.throws(() => expectDenied({ data: [], error: null }), /succeeded/);
  });

  it("expectOk returns data or throws", () => {
    assert.deepEqual(expectOk({ data: { a: 1 }, error: null }), { a: 1 });
    assert.throws(() => expectOk(refused, "x"), /x failed: 42501/);
  });

  it("expectNoRows accepts an error or an empty result only", () => {
    assert.doesNotThrow(() => expectNoRows(refused));
    assert.doesNotThrow(() => expectNoRows({ data: [], error: null }));
    assert.throws(
      () => expectNoRows({ data: [{ id: 1 }], error: null }),
      /1 row/,
    );
  });
});

describe("Recorder and report", () => {
  it("records PASS, FAIL and SKIP and prints totals", async () => {
    const rec = new Recorder();
    await rec.check("A", "passes", () => undefined);
    await rec.check("A", "fails", () => {
      throw new Error("boom");
    });
    await rec.check("B", "skips", () => {
      throw new SkipCheck("no APP_URL");
    });
    assert.deepEqual(rec.counts(), { PASS: 1, FAIL: 1, SKIP: 1 });
    const text = formatReport(rec.results);
    assert.match(text, /FAIL\s+fails {2}-> boom/);
    assert.match(text, /SKIP\s+skips {2}-> no APP_URL/);
    assert.match(text, /TOTAL 3: 1 passed, 1 failed, 1 skipped/);
  });
});

describe("findId", () => {
  const id = "00000000-0000-4000-8000-000000000001";
  it("finds the shallowest id", () => {
    assert.equal(findId({ product: { id } }), id);
    assert.equal(
      findId({ id, nested: { id: "00000000-0000-4000-8000-000000000002" } }),
      id,
    );
    assert.equal(findId([{ x: 1 }, { variant: { id } }]), id);
  });
  it("returns null when there is none", () => {
    assert.equal(findId({ id: "not-a-uuid" }), null);
    assert.equal(findId(null), null);
  });
});
