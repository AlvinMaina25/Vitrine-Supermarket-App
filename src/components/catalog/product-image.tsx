import { ImageOff } from "lucide-react";
import { useState } from "react";

import { cn } from "@/lib/utils";

/**
 * Fixed-ratio product image. The box reserves its space before the image arrives (no layout
 * shift), the image loads lazily by default, and a missing or broken URL falls back to a quiet
 * placeholder instead of a broken-image icon.
 */
export function ProductImage({
  src,
  alt,
  priority = false,
  ratio = "square",
  className,
  sizes,
}: {
  src: string | null;
  alt: string;
  /** Above-the-fold images load eagerly; everything else is lazy. */
  priority?: boolean;
  ratio?: "square" | "wide";
  className?: string;
  sizes?: string;
}) {
  const [failedSrc, setFailedSrc] = useState<string | null>(null);
  const broken = !src || failedSrc === src;
  return (
    <div
      className={cn(
        "relative w-full overflow-hidden bg-surface-strong",
        ratio === "square" ? "aspect-square" : "aspect-[16/9]",
        className,
      )}
    >
      {broken ? (
        <div
          role="img"
          aria-label={`No photo available for ${alt}`}
          className="grid size-full place-items-center text-muted-foreground"
        >
          <ImageOff aria-hidden className="size-7" />
        </div>
      ) : (
        <img
          src={src}
          alt={alt}
          loading={priority ? "eager" : "lazy"}
          decoding="async"
          fetchPriority={priority ? "high" : "auto"}
          {...(sizes ? { sizes } : {})}
          onError={() => setFailedSrc(src)}
          className="absolute inset-0 size-full object-cover"
        />
      )}
    </div>
  );
}
