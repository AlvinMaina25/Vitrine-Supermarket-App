import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  MAX_IMAGE_SIDE,
  scaleToFit,
} from "../src/features/admin/image-optimise.ts";

describe("scaleToFit", () => {
  it("leaves a picture that already fits unchanged", () => {
    assert.deepEqual(scaleToFit(800, 600), { width: 800, height: 600 });
    assert.deepEqual(scaleToFit(MAX_IMAGE_SIDE, MAX_IMAGE_SIDE), {
      width: MAX_IMAGE_SIDE,
      height: MAX_IMAGE_SIDE,
    });
  });

  it("shrinks a large landscape picture and keeps its shape", () => {
    assert.deepEqual(scaleToFit(4000, 3000), { width: 1000, height: 750 });
  });

  it("shrinks a large portrait picture and keeps its shape", () => {
    assert.deepEqual(scaleToFit(3000, 4000), { width: 750, height: 1000 });
  });

  it("never enlarges and never returns zero", () => {
    assert.deepEqual(scaleToFit(100, 50), { width: 100, height: 50 });
    const thin = scaleToFit(20000, 1);
    assert.equal(thin.width, 1000);
    assert.equal(thin.height, 1);
  });

  it("passes odd input through instead of throwing", () => {
    assert.deepEqual(scaleToFit(0, 100), { width: 0, height: 100 });
    assert.deepEqual(scaleToFit(Number.NaN, 100).height, 100);
  });

  it("honours a custom limit", () => {
    assert.deepEqual(scaleToFit(2000, 1000, 500), { width: 500, height: 250 });
  });
});
