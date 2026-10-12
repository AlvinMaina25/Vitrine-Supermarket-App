import { Button } from "@/components/ui-kit/button";
import { getPageInfo } from "@/features/admin/order-management";

/** Previous / Next with a "Showing a–b of n" line. Pure display; the caller owns the page number. */
export function InventoryPagination({
  label,
  total,
  limit,
  offset,
  rows,
  disabled,
  onPage,
}: {
  label: string;
  total: number;
  limit: number;
  offset: number;
  rows: number;
  disabled: boolean;
  onPage: (page: number) => void;
}) {
  const info = getPageInfo(total, limit, offset, rows);
  return (
    <nav
      aria-label={label}
      className="mt-3 flex flex-wrap items-center justify-between gap-3 border-t border-border px-2 pt-3"
    >
      <p className="text-xs text-muted-foreground">
        Showing {info.from}–{info.to} of {total.toLocaleString("en-US")} · Page{" "}
        {info.page} of {info.pageCount}
      </p>
      <div className="flex gap-2">
        <Button
          variant="outline"
          size="sm"
          disabled={disabled || !info.hasPrevious}
          onClick={() => onPage(info.page - 1)}
        >
          Previous
        </Button>
        <Button
          variant="outline"
          size="sm"
          disabled={disabled || !info.hasNext}
          onClick={() => onPage(info.page + 1)}
        >
          Next
        </Button>
      </div>
    </nav>
  );
}
