import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import { AdminCustomerNotesError } from "../src/features/admin/customer-notes-result.ts";
import { AdminCustomerStatusError } from "../src/features/admin/customer-status-result.ts";
import {
  asOrderStatus,
  asPaymentStatus,
  describeNotesError,
  describeStatusChangeError,
  formatAddressLines,
  notesChanged,
  oppositeStatus,
  orderReference,
  statusActionLabel,
  statusConfirmLabel,
} from "../src/features/admin/customer-detail-management.ts";

describe("status helpers", () => {
  it("offers the opposite status and matching labels", () => {
    assert.equal(oppositeStatus("active"), "suspended");
    assert.equal(oppositeStatus("suspended"), "active");
    assert.equal(statusActionLabel("suspended"), "Suspend customer");
    assert.equal(statusActionLabel("active"), "Reactivate customer");
    assert.equal(statusConfirmLabel("suspended"), "Suspend");
    assert.equal(statusConfirmLabel("active"), "Reactivate");
  });
});

describe("describeStatusChangeError", () => {
  it("words every refusal and never leaks raw text", () => {
    const codes = [
      "invalid_arguments",
      "invalid_status",
      "reason_required",
      "reason_too_long",
      "cannot_target_self",
      "customer_not_found",
      "cannot_target_staff",
      "status_unchanged",
    ] as const;
    for (const code of codes) {
      const text = describeStatusChangeError(
        new AdminCustomerStatusError(code),
      );
      assert.ok(text.length > 10, code);
      assert.doesNotMatch(text, /_/);
    }
  });

  it("names the self, staff and missing-reason cases", () => {
    assert.match(
      describeStatusChangeError(
        new AdminCustomerStatusError("cannot_target_self"),
      ),
      /own/,
    );
    assert.match(
      describeStatusChangeError(
        new AdminCustomerStatusError("cannot_target_staff"),
      ),
      /Staff and admin/,
    );
    assert.match(
      describeStatusChangeError(
        new AdminCustomerStatusError("reason_required"),
      ),
      /reason is required/i,
    );
  });

  it("handles access errors and unknown failures", () => {
    assert.match(
      describeStatusChangeError(new AdminAccessError("x")),
      /not permitted/,
    );
    assert.match(
      describeStatusChangeError(new Error("network down")),
      /couldn't confirm/,
    );
    assert.doesNotMatch(
      describeStatusChangeError(new Error("network down")),
      /network down/,
    );
  });
});

describe("describeNotesError", () => {
  it("words every refusal", () => {
    for (const code of [
      "invalid_arguments",
      "notes_too_long",
      "customer_not_found",
      "cannot_target_staff",
    ] as const) {
      const text = describeNotesError(new AdminCustomerNotesError(code));
      assert.ok(text.length > 10, code);
      assert.doesNotMatch(text, /_/);
    }
  });

  it("handles access errors and unknown failures", () => {
    assert.match(
      describeNotesError(new AdminAccessError("x")),
      /not permitted/,
    );
    assert.match(describeNotesError("weird"), /couldn't confirm/);
  });
});

describe("notesChanged", () => {
  it("compares trimmed text, treating null as empty", () => {
    assert.equal(notesChanged(null, ""), false);
    assert.equal(notesChanged(null, "   "), false);
    assert.equal(notesChanged("hi", " hi "), false);
    assert.equal(notesChanged("hi", "hello"), true);
    assert.equal(notesChanged("hi", ""), true);
    assert.equal(notesChanged(null, "x"), true);
  });
});

describe("order helpers", () => {
  it("builds a short upper-case reference", () => {
    assert.equal(
      orderReference("abcdef12-3456-7890-abcd-ef1234567890"),
      "ABCDEF12",
    );
  });

  it("narrows known statuses and rejects unknown ones", () => {
    assert.equal(asOrderStatus("cancelled"), "cancelled");
    assert.equal(asOrderStatus("mystery"), null);
    assert.equal(asPaymentStatus("paid"), "paid");
    assert.equal(asPaymentStatus("mystery"), null);
  });
});

describe("formatAddressLines", () => {
  it("skips blanks and joins the town line", () => {
    assert.deepEqual(
      formatAddressLines({
        address_line_1: "1 Road",
        address_line_2: null,
        city: "Nairobi",
        county: " ",
        postal_code: "00100",
      }),
      ["1 Road", "Nairobi, 00100"],
    );
    assert.deepEqual(
      formatAddressLines({
        address_line_1: null,
        address_line_2: null,
        city: null,
        county: null,
        postal_code: null,
      }),
      [],
    );
  });
});
