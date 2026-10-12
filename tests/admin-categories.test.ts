import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  AdminCategoryActionError,
  buildCategoryChanges,
  buildCreateCategoryArgs,
  categoryFieldFromMessage,
  categoryHasChanges,
  categoryToFormValues,
  CATEGORY_REASON_MESSAGES,
  describeCategorySaveError,
  emptyCategoryFormValues,
  parsePosition,
  toAdminCategoryActionError,
  toAdminCategoryMutationResult,
  type CategoryFormValues,
} from "../src/features/admin/categories-result.ts";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";
import type { CategoryRow } from "../src/lib/supabase/types.ts";

const form = (o: Partial<CategoryFormValues> = {}): CategoryFormValues => ({
  ...emptyCategoryFormValues(),
  name: "Fresh Fruit",
  slug: "fresh-fruit",
  ...o,
});

const row: CategoryRow = {
  id: "11111111-1111-4111-8111-111111111111",
  slug: "fresh-fruit",
  name: "Fresh Fruit",
  tagline: null,
  description: null,
  image_url: null,
  parent_id: null,
  position: 2,
  is_active: true,
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
};

describe("buildCreateCategoryArgs", () => {
  it("builds the RPC arguments, trimming text and turning blanks into null", () => {
    const r = buildCreateCategoryArgs(
      form({
        name: "  Fresh Fruit ",
        tagline: "  ",
        description: "",
        position: " 3 ",
      }),
    );
    assert.deepEqual(r.errors, {});
    assert.deepEqual(r.args, {
      p_name: "Fresh Fruit",
      p_slug: "fresh-fruit",
      p_tagline: null,
      p_description: null,
      p_position: 3,
      p_is_active: true,
    });
  });

  it("sends is_active false when the switch is off", () => {
    assert.equal(
      buildCreateCategoryArgs(form({ isActive: false })).args?.p_is_active,
      false,
    );
  });

  it("rejects each field the database would reject", () => {
    const bad = buildCreateCategoryArgs(
      form({
        name: "A",
        slug: "Bad Slug",
        tagline: "t".repeat(121),
        description: "d".repeat(501),
        position: "-1",
      }),
    );
    assert.equal(bad.args, null);
    assert.deepEqual(Object.keys(bad.errors).sort(), [
      "description",
      "name",
      "position",
      "slug",
      "tagline",
    ]);
  });

  it("accepts the limits exactly", () => {
    const ok = buildCreateCategoryArgs(
      form({
        name: "ab",
        slug: "a".repeat(80),
        tagline: "t".repeat(120),
        description: "d".repeat(500),
        position: "0",
      }),
    );
    assert.deepEqual(ok.errors, {});
    assert.notEqual(ok.args, null);
  });

  it("refuses names of 81 characters, control characters and slugs with double hyphens", () => {
    assert.ok(
      buildCreateCategoryArgs(form({ name: "n".repeat(81) })).errors.name,
    );
    assert.ok(
      buildCreateCategoryArgs(form({ name: "Fresh\u0007Fruit" })).errors.name,
    );
    assert.ok(buildCreateCategoryArgs(form({ slug: "a--b" })).errors.slug);
    assert.ok(buildCreateCategoryArgs(form({ slug: "-a" })).errors.slug);
    assert.ok(
      buildCreateCategoryArgs(form({ slug: "a".repeat(81) })).errors.slug,
    );
  });
});

describe("parsePosition", () => {
  it("accepts whole numbers only", () => {
    assert.equal(parsePosition("0"), 0);
    assert.equal(parsePosition(" 07 "), 7);
    assert.equal(parsePosition("2147483647"), 2147483647);
    for (const t of ["", "-1", "1.5", "1e3", "abc", "2147483648", "+1"]) {
      assert.equal(parsePosition(t), null, t);
    }
  });
});

describe("buildCategoryChanges", () => {
  const initial = categoryToFormValues(row);

  it("sends nothing when nothing changed", () => {
    const r = buildCategoryChanges(initial, { ...initial });
    assert.deepEqual(r.changes, {});
    assert.equal(categoryHasChanges(r.changes), false);
  });

  it("sends only the fields that changed", () => {
    const r = buildCategoryChanges(initial, {
      ...initial,
      name: "Fruit",
      position: "5",
      isActive: false,
    });
    assert.deepEqual(r.changes, {
      name: "Fruit",
      position: 5,
      is_active: false,
    });
  });

  it("clears tagline and description with null", () => {
    const withText = { ...initial, tagline: "Sweet", description: "Long text" };
    const r = buildCategoryChanges(withText, {
      ...withText,
      tagline: " ",
      description: "",
    });
    assert.deepEqual(r.changes, { tagline: null, description: null });
  });

  it("does not validate an untouched legacy value", () => {
    const legacy = { ...initial, name: "x" };
    const r = buildCategoryChanges(legacy, { ...legacy, position: "9" });
    assert.deepEqual(r.errors, {});
    assert.deepEqual(r.changes, { position: 9 });
  });

  it("reports an invalid changed field and sends no patch", () => {
    const r = buildCategoryChanges(initial, {
      ...initial,
      slug: "NOPE",
      position: "1",
    });
    assert.ok(r.errors.slug);
    assert.deepEqual(r.changes, {});
  });
});

describe("error mapping and plain-words messages", () => {
  it("maps not-authorised to AdminAccessError", () => {
    const e = toAdminCategoryActionError({
      message: "x",
      code: "42501",
      details: "not_authorised",
    });
    assert.ok(e instanceof AdminAccessError);
    assert.equal(
      describeCategorySaveError(e),
      "Your account is not permitted to change categories.",
    );
  });

  it("maps slug_taken onto the slug field", () => {
    const e = toAdminCategoryActionError({
      message: "dup",
      details: "slug_taken",
    });
    assert.ok(e instanceof AdminCategoryActionError);
    assert.equal((e as AdminCategoryActionError).field, "slug");
    assert.equal(
      describeCategorySaveError(e),
      CATEGORY_REASON_MESSAGES.slug_taken,
    );
  });

  it("finds the field named by an invalid_arguments message", () => {
    assert.equal(
      categoryFieldFromMessage(
        "Invalid category position (a whole number >= 0).",
      ),
      "position",
    );
    assert.equal(
      categoryFieldFromMessage(
        "Invalid category tagline (max 120 characters).",
      ),
      "tagline",
    );
    assert.equal(categoryFieldFromMessage("something else"), null);
    const e = toAdminCategoryActionError({
      message: "Invalid category slug (1-80 characters)",
      details: "invalid_arguments",
    });
    assert.equal(
      describeCategorySaveError(e),
      "The URL slug was not accepted. Check it and try again.",
    );
  });

  it("never shows raw database text", () => {
    const raw = toAdminCategoryActionError({
      message: "duplicate key value violates constraint foo",
      details: null,
    });
    const text = describeCategorySaveError(raw);
    assert.ok(!text.includes("duplicate key"));
    assert.equal(
      text,
      "We couldn't save this category. Please try again in a moment.",
    );
    for (const message of Object.values(CATEGORY_REASON_MESSAGES)) {
      assert.ok(!/P0001|23505|constraint|violates/i.test(message));
    }
  });
});

describe("toAdminCategoryMutationResult", () => {
  it("returns the stored row", () => {
    assert.equal(
      toAdminCategoryMutationResult({ category: row }).category.slug,
      "fresh-fruit",
    );
  });
  it("throws on anything else", () => {
    assert.throws(() => toAdminCategoryMutationResult(null));
    assert.throws(() => toAdminCategoryMutationResult({ category: { id: 1 } }));
    assert.throws(() => toAdminCategoryMutationResult({ product: row }));
  });
});
