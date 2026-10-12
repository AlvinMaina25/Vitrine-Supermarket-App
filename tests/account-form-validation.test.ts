import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  ADDRESS_FIELD_ORDER,
  cleanPhone,
  firstErrorField,
  PROFILE_FIELD_ORDER,
  validateAddress,
  validateProfile,
} from "../src/features/account/form-validation.ts";

const goodAddress = {
  label: "Home",
  fullName: "Amina Otieno",
  phone: "0712 345 678",
  county: "Nairobi",
  line1: "Riverside Drive",
  line2: "",
  city: "Nairobi",
  postalCode: "",
  instructions: "",
};

describe("validateProfile", () => {
  it("accepts a blank phone and a valid one", () => {
    assert.deepEqual(validateProfile({ fullName: "A", phone: "" }), {});
    assert.deepEqual(
      validateProfile({ fullName: "A", phone: "+254 712 345 678" }),
      {},
    );
  });
  it("flags a bad phone and an over-long name next to their own fields", () => {
    const errors = validateProfile({ fullName: "x".repeat(121), phone: "abc" });
    assert.ok(errors.fullName);
    assert.ok(errors.phone);
    assert.equal(firstErrorField(errors, PROFILE_FIELD_ORDER), "fullName");
  });
});

describe("validateAddress", () => {
  it("accepts a complete address", () => {
    assert.deepEqual(validateAddress(goodAddress), {});
  });
  it("requires name, phone, street and city, each with its own message", () => {
    const errors = validateAddress({
      ...goodAddress,
      fullName: " ",
      phone: "",
      line1: "",
      city: "",
    });
    assert.deepEqual(Object.keys(errors).sort(), [
      "city",
      "fullName",
      "line1",
      "phone",
    ]);
  });
  it("focuses the first error in on-screen order", () => {
    const errors = validateAddress({ ...goodAddress, city: "", phone: "12" });
    assert.equal(firstErrorField(errors, ADDRESS_FIELD_ORDER), "phone");
  });
  it("enforces the input length limits", () => {
    assert.ok(validateAddress({ ...goodAddress, label: "x".repeat(41) }).label);
    assert.ok(
      validateAddress({ ...goodAddress, instructions: "x".repeat(501) })
        .instructions,
    );
    assert.ok(
      validateAddress({ ...goodAddress, postalCode: "x".repeat(11) })
        .postalCode,
    );
  });
});

describe("firstErrorField / cleanPhone", () => {
  it("returns null with no errors", () => {
    assert.equal(firstErrorField({}, PROFILE_FIELD_ORDER), null);
  });
  it("strips spaces from a phone number", () => {
    assert.equal(cleanPhone("0712 345 678"), "0712345678");
  });
});
