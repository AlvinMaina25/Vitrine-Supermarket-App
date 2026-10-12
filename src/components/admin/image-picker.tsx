import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useEffect, useId, useRef, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui-kit/button";
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import {
  adminSetCategoryImage,
  adminSetProductImage,
  uploadCatalogImage,
} from "@/features/admin/catalog-images-api";
import {
  describeImageError,
  IMAGE_ACCEPT,
  IMAGE_FILE_MESSAGES,
  validateImageFile,
  type ImageKind,
} from "@/features/admin/catalog-images";

type Staged = { file: File; url: string };

/**
 * Choose, preview, replace or remove one picture (product or category). It saves on its own,
 * separately from the text fields of the form around it:
 *   choose a file -> checked in the browser (type, 2 MB) -> preview -> "Use this picture"
 *   -> upload under a random name -> admin_set_*_image() -> refresh the admin lists.
 * A failed upload or link leaves the stored picture untouched and shows a plain sentence; the raw
 * error goes to the console. Old files are never deleted. The database and Storage re-check
 * everything and refuse anyone who is not an admin with 2FA.
 *
 * `currentUrl` is what the database holds; the parent updates it from `onSaved`.
 */
export function ImagePicker({
  kind,
  targetId,
  currentUrl,
  invalidateKeys,
  onSaved,
  onBusyChange,
  disabled = false,
}: {
  kind: ImageKind;
  targetId: string;
  currentUrl: string | null;
  /** Existing admin query keys for this screen, refreshed after a successful change. */
  invalidateKeys: readonly (readonly unknown[])[];
  onSaved?: (saved: { image_url: string | null; updated_at: string }) => void;
  onBusyChange?: (busy: boolean) => void;
  disabled?: boolean;
}) {
  const queryClient = useQueryClient();
  const headingId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const stagedRef = useRef<Staged | null>(null);
  // A second click can land before React re-renders the disabled button; this closes that gap.
  const inFlight = useRef(false);

  const [staged, setStaged] = useState<Staged | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [confirmRemove, setConfirmRemove] = useState(false);

  const mutation = useMutation({
    mutationFn: async (file: File | null) => {
      const imageUrl = file ? await uploadCatalogImage(kind, file) : null;
      return kind === "product"
        ? (await adminSetProductImage({ productId: targetId, imageUrl }))
            .product
        : (await adminSetCategoryImage({ categoryId: targetId, imageUrl }))
            .category;
    },
    onSuccess: (row, file) => {
      clearStaged();
      setMessage(null);
      onSaved?.({ image_url: row.image_url, updated_at: row.updated_at });
      toast.success(file ? "Picture saved." : "Picture removed.");
    },
    onError: (cause) => {
      console.error("Picture change failed", cause);
      setMessage(describeImageError(cause));
    },
    onSettled: async () => {
      inFlight.current = false;
      await Promise.all(
        invalidateKeys.map((queryKey) =>
          queryClient.invalidateQueries({ queryKey: [...queryKey] }),
        ),
      );
    },
  });

  const pending = mutation.isPending;
  useEffect(() => {
    onBusyChange?.(pending);
  }, [pending, onBusyChange]);

  // Release the preview address when the picker goes away.
  useEffect(
    () => () => {
      if (stagedRef.current) URL.revokeObjectURL(stagedRef.current.url);
    },
    [],
  );

  function clearStaged() {
    if (stagedRef.current) URL.revokeObjectURL(stagedRef.current.url);
    stagedRef.current = null;
    setStaged(null);
  }

  function onFileChosen(event: React.ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    // Reset so choosing the same file again still fires a change.
    event.target.value = "";
    if (!file) return;
    const problem = validateImageFile(file);
    if (problem) {
      clearStaged();
      setMessage(IMAGE_FILE_MESSAGES[problem]);
      return;
    }
    if (stagedRef.current) URL.revokeObjectURL(stagedRef.current.url);
    const next = { file, url: URL.createObjectURL(file) };
    stagedRef.current = next;
    setStaged(next);
    setMessage(null);
  }

  function upload() {
    if (!staged || inFlight.current || pending) return;
    inFlight.current = true;
    setMessage(null);
    mutation.mutate(staged.file);
  }

  function remove() {
    if (inFlight.current || pending) return;
    inFlight.current = true;
    setMessage(null);
    mutation.mutate(null);
  }

  const shown = staged ? staged.url : currentUrl;
  const locked = disabled || pending;

  return (
    <div
      role="group"
      aria-labelledby={headingId}
      aria-busy={pending}
      className="space-y-3"
    >
      <p id={headingId} className="eyebrow text-muted-foreground">
        Picture
      </p>
      <div className="flex flex-wrap items-start gap-4">
        <div className="h-32 w-32 shrink-0 overflow-hidden rounded-lg border border-border bg-surface-strong">
          {shown ? (
            <img
              src={shown}
              alt="Preview of the chosen picture"
              className="h-full w-full object-cover"
            />
          ) : (
            <div className="flex h-full w-full items-center justify-center p-2 text-center text-xs text-muted-foreground">
              No picture
            </div>
          )}
        </div>
        <div className="min-w-0 space-y-2">
          <input
            ref={inputRef}
            type="file"
            accept={IMAGE_ACCEPT}
            className="sr-only"
            tabIndex={-1}
            aria-label="Picture file"
            disabled={locked}
            onChange={onFileChosen}
          />
          <div className="flex flex-wrap items-center gap-2">
            {staged ? (
              <>
                <Button
                  type="button"
                  size="sm"
                  disabled={locked}
                  onClick={upload}
                >
                  {pending ? "Saving…" : "Use this picture"}
                </Button>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={locked}
                  onClick={() => {
                    clearStaged();
                    setMessage(null);
                  }}
                >
                  Cancel
                </Button>
              </>
            ) : (
              <>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={locked}
                  onClick={() => inputRef.current?.click()}
                >
                  {currentUrl ? "Replace picture" : "Choose picture"}
                </Button>
                {currentUrl ? (
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={locked}
                    onClick={() => setConfirmRemove(true)}
                  >
                    {pending ? "Removing…" : "Remove picture"}
                  </Button>
                ) : null}
              </>
            )}
          </div>
          <p className="text-xs text-muted-foreground">
            JPG, PNG or WebP, up to 2 MB.
          </p>
          {staged && !pending ? (
            <p className="text-xs text-muted-foreground">
              Not saved yet. Your current picture stays until you use this one.
            </p>
          ) : null}
          {pending ? (
            <p role="status" className="text-xs text-muted-foreground">
              Saving the picture…
            </p>
          ) : null}
        </div>
      </div>

      {message ? (
        <p
          role="alert"
          className="rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-danger"
        >
          {message}
        </p>
      ) : null}

      <AlertDialog
        open={confirmRemove}
        onOpenChange={(next) => {
          if (!pending) setConfirmRemove(next);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Remove this picture?</AlertDialogTitle>
            <AlertDialogDescription>
              The picture will no longer be shown. Nothing else changes, and you
              can add a new picture at any time.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={pending}
              onClick={() => setConfirmRemove(false)}
            >
              Cancel
            </Button>
            <Button
              type="button"
              variant="danger"
              disabled={pending}
              onClick={() => {
                setConfirmRemove(false);
                remove();
              }}
            >
              Remove picture
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
