/**
 * Shrinks a picture in the browser before it is uploaded (admin product / category pictures).
 *
 * Phone and camera photos are often 2-5 MB. Storing them as they are made every shop page that
 * shows them slow, on mobile data especially. Here a picture is scaled down so its longer side is at
 * most 1000 px (never enlarged, never cropped) and saved as WebP. If anything is not supported or
 * goes wrong, or the result is not smaller, the original file is returned unchanged, so an upload
 * never fails because of this step.
 */

export const MAX_IMAGE_SIDE = 1000;
const WEBP_QUALITY = 0.82;

/** Largest size that fits inside maxSide x maxSide, same shape, never bigger than the original. */
export function scaleToFit(
  width: number,
  height: number,
  maxSide: number = MAX_IMAGE_SIDE,
): { width: number; height: number } {
  if (
    !Number.isFinite(width) ||
    !Number.isFinite(height) ||
    width <= 0 ||
    height <= 0
  ) {
    return { width, height };
  }
  const longest = Math.max(width, height);
  if (longest <= maxSide) return { width, height };
  const factor = maxSide / longest;
  return {
    width: Math.max(1, Math.round(width * factor)),
    height: Math.max(1, Math.round(height * factor)),
  };
}

export async function optimiseImage(file: File): Promise<File> {
  try {
    if (
      typeof createImageBitmap !== "function" ||
      typeof document === "undefined"
    ) {
      return file;
    }
    const bitmap = await createImageBitmap(file);
    const size = scaleToFit(bitmap.width, bitmap.height);
    const canvas = document.createElement("canvas");
    canvas.width = size.width;
    canvas.height = size.height;
    const context = canvas.getContext("2d");
    if (!context) {
      bitmap.close();
      return file;
    }
    context.drawImage(bitmap, 0, 0, size.width, size.height);
    bitmap.close();
    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, "image/webp", WEBP_QUALITY),
    );
    if (!blob || blob.type !== "image/webp" || blob.size >= file.size)
      return file;
    return new File([blob], "picture.webp", { type: "image/webp" });
  } catch {
    return file;
  }
}
