import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import {
  ALLOWED_IMAGE_TYPES,
  AdminImageActionError,
  buildImagePath,
  describeImageError,
  IMAGE_ACCEPT,
  IMAGE_FILE_MESSAGES,
  IMAGE_GENERIC_MESSAGE,
  IMAGE_REASON_MESSAGES,
  IMAGE_UPLOAD_FAILED_MESSAGE,
  ImageUploadError,
  MAX_IMAGE_BYTES,
  toAdminImageActionError,
  validateImageFile,
} from "../src/features/admin/catalog-images.ts";
import { AdminAccessError } from "../src/features/admin/dashboard-result.ts";

const UUID = "0b5f3c1e-7a2d-4e8b-9c64-1f2a3b4c5d6e";

describe("validateImageFile", () => {
  it("accepts jpeg, png and webp up to exactly 2 MB", () => {
    for (const type of ALLOWED_IMAGE_TYPES) {
      assert.equal(validateImageFile({ type, size: 1 }), null);
      assert.equal(validateImageFile({ type, size: MAX_IMAGE_BYTES }), null);
    }
  });

  it("rejects a file one byte over 2 MB", () => {
    assert.equal(
      validateImageFile({ type: "image/png", size: MAX_IMAGE_BYTES + 1 }),
      "size",
    );
  });

  it("rejects other types (gif, svg, pdf, empty type)", () => {
    for (const type of ["image/gif", "image/svg+xml", "application/pdf", ""]) {
      assert.equal(validateImageFile({ type, size: 1000 }), "type");
    }
  });

  it("rejects an empty or nonsense size", () => {
    assert.equal(validateImageFile({ type: "image/jpeg", size: 0 }), "empty");
    assert.equal(validateImageFile({ type: "image/jpeg", size: -5 }), "empty");
    assert.equal(
      validateImageFile({ type: "image/jpeg", size: Number.NaN }),
      "empty",
    );
  });

  it("checks the type before the size", () => {
    assert.equal(
      validateImageFile({ type: "image/gif", size: MAX_IMAGE_BYTES * 2 }),
      "type",
    );
  });

  it("has a plain sentence for every problem and the 2 MB limit is 2097152", () => {
    assert.equal(MAX_IMAGE_BYTES, 2097152);
    assert.match(IMAGE_FILE_MESSAGES.size, /2 MB/);
    assert.match(IMAGE_FILE_MESSAGES.type, /JPG, PNG or WebP/);
    assert.ok(IMAGE_FILE_MESSAGES.empty.length > 0);
    assert.equal(IMAGE_ACCEPT, "image/jpeg,image/png,image/webp");
  });
});

describe("buildImagePath", () => {
  it("builds products/<uuid>.<ext> and categories/<uuid>.<ext>", () => {
    assert.equal(
      buildImagePath("product", UUID, "image/jpeg"),
      `products/${UUID}.jpg`,
    );
    assert.equal(
      buildImagePath("product", UUID, "image/png"),
      `products/${UUID}.png`,
    );
    assert.equal(
      buildImagePath("category", UUID, "image/webp"),
      `categories/${UUID}.webp`,
    );
  });

  it("refuses a type or id that is not acceptable", () => {
    assert.equal(buildImagePath("product", UUID, "image/gif"), null);
    assert.equal(buildImagePath("product", "holiday photo", "image/png"), null);
    assert.equal(
      buildImagePath("product", UUID.toUpperCase(), "image/png"),
      null,
    );
    assert.equal(buildImagePath("product", `../${UUID}`, "image/png"), null);
    assert.equal(buildImagePath("product", "", "image/png"), null);
  });

  it("only ever produces names the migration's storage policy accepts", () => {
    const policy =
      /^(products|categories)\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$/;
    for (const kind of ["product", "category"] as const) {
      for (const type of ALLOWED_IMAGE_TYPES) {
        const path = buildImagePath(kind, UUID, type);
        assert.ok(path !== null && policy.test(path), String(path));
      }
    }
    // The pattern in the SQL file is the one used above.
    const sql = readFileSync(
      new URL(
        "../db/migrations/20261011020000_phase20b_catalog_images.sql",
        import.meta.url,
      ),
      "utf8",
    );
    assert.ok(
      sql.includes(
        "^(products|categories)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(jpg|png|webp)$",
      ),
    );
  });
});

describe("error mapping", () => {
  it("maps database refusals to reasons and plain words", () => {
    for (const reason of Object.keys(IMAGE_REASON_MESSAGES)) {
      const err = toAdminImageActionError({
        message: "raw database text",
        details: reason,
      });
      assert.ok(err instanceof AdminImageActionError);
      assert.equal(
        describeImageError(err),
        IMAGE_REASON_MESSAGES[(err as AdminImageActionError).reason],
      );
      assert.ok(!describeImageError(err).includes("raw database text"));
    }
  });

  it("maps a permission refusal to an access error", () => {
    const a = toAdminImageActionError({ message: "x", code: "42501" });
    const b = toAdminImageActionError({
      message: "x",
      details: "not_authorised",
    });
    assert.ok(a instanceof AdminAccessError && b instanceof AdminAccessError);
    assert.match(describeImageError(a), /not permitted/);
  });

  it("never shows raw text for an unknown failure or a storage failure", () => {
    const unknown = toAdminImageActionError({ message: "pg: secret detail" });
    assert.equal(describeImageError(unknown), IMAGE_GENERIC_MESSAGE);
    assert.equal(
      describeImageError(new ImageUploadError("StorageApiError: bucket x")),
      IMAGE_UPLOAD_FAILED_MESSAGE,
    );
    assert.equal(describeImageError("weird"), IMAGE_GENERIC_MESSAGE);
    for (const text of [IMAGE_GENERIC_MESSAGE, IMAGE_UPLOAD_FAILED_MESSAGE]) {
      assert.match(text, /current picture was not changed/);
    }
  });
});
