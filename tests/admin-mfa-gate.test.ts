import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  adminMfaGate,
  isTotpCode,
} from "../src/features/auth/admin-mfa-gate.ts";

describe("adminMfaGate", () => {
  it("loading wins over everything else", () => {
    assert.equal(
      adminMfaGate({
        loading: true,
        isAdmin: true,
        currentLevel: "aal2",
        hasVerifiedFactor: true,
      }),
      "loading",
    );
    assert.equal(
      adminMfaGate({
        loading: true,
        isAdmin: false,
        currentLevel: null,
        hasVerifiedFactor: false,
      }),
      "loading",
    );
  });

  it("a non-admin is never offered enrolment or a challenge", () => {
    for (const currentLevel of ["aal1", "aal2", null] as const) {
      for (const hasVerifiedFactor of [true, false]) {
        assert.equal(
          adminMfaGate({
            loading: false,
            isAdmin: false,
            currentLevel,
            hasVerifiedFactor,
          }),
          "not_admin",
        );
      }
    }
  });

  it("an admin on aal1 with no verified factor must enrol", () => {
    assert.equal(
      adminMfaGate({
        loading: false,
        isAdmin: true,
        currentLevel: "aal1",
        hasVerifiedFactor: false,
      }),
      "needs_enrol",
    );
  });

  it("an admin on aal1 with a verified factor must pass a challenge", () => {
    assert.equal(
      adminMfaGate({
        loading: false,
        isAdmin: true,
        currentLevel: "aal1",
        hasVerifiedFactor: true,
      }),
      "needs_challenge",
    );
  });

  it("an admin on aal2 is ok, with or without the factor list having loaded a factor", () => {
    assert.equal(
      adminMfaGate({
        loading: false,
        isAdmin: true,
        currentLevel: "aal2",
        hasVerifiedFactor: true,
      }),
      "ok",
    );
    assert.equal(
      adminMfaGate({
        loading: false,
        isAdmin: true,
        currentLevel: "aal2",
        hasVerifiedFactor: false,
      }),
      "ok",
    );
  });

  it("an unknown assurance level is treated like aal1 (never ok)", () => {
    assert.equal(
      adminMfaGate({
        loading: false,
        isAdmin: true,
        currentLevel: null,
        hasVerifiedFactor: true,
      }),
      "needs_challenge",
    );
    assert.equal(
      adminMfaGate({
        loading: false,
        isAdmin: true,
        currentLevel: null,
        hasVerifiedFactor: false,
      }),
      "needs_enrol",
    );
  });
});

describe("isTotpCode", () => {
  it("accepts exactly six digits", () => {
    assert.equal(isTotpCode("123456"), true);
    assert.equal(isTotpCode("000000"), true);
  });

  it("rejects everything else", () => {
    for (const value of [
      "",
      "12345",
      "1234567",
      "12345a",
      " 123456",
      "123 456",
      "123456\n",
      "١٢٣٤٥٦",
    ]) {
      assert.equal(isTotpCode(value), false, JSON.stringify(value));
    }
  });
});
