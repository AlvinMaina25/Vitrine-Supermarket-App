import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";

import { AdminQueryError } from "@/components/admin/admin-states";
import { AdminPageHeader } from "@/components/admin/admin-shell";
import { CategoryForm } from "@/components/admin/category-form";
import { ProductActiveBadge } from "@/components/admin/product-badges";
import { ConfigNotice, EmptyState } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { adminCategoriesQuery } from "@/features/admin/categories";
import { SupabaseNotConfiguredError } from "@/lib/supabase/client";
import type { CategoryRow } from "@/lib/supabase/types";

export const Route = createFileRoute("/_authenticated/admin/categories/")({
  head: () => ({
    meta: [
      { title: "Categories — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: CategoriesPage,
});

/** The form is either closed, creating a new category, or editing one row. */
type Panel =
  { mode: "closed" } | { mode: "new" } | { mode: "edit"; id: string };

/**
 * Sits under /_authenticated/admin, so it inherits the existing gate (signed-out visitors go to
 * /auth, signed-in non-admins see "Admin access required"). Writes are refused by the database
 * for anyone who is not an admin with 2FA (require_admin()).
 */
function CategoriesPage() {
  const categories = useQuery(adminCategoriesQuery());
  const [panel, setPanel] = useState<Panel>({ mode: "closed" });

  const editing =
    panel.mode === "edit"
      ? ((categories.data ?? []).find((c) => c.id === panel.id) ?? null)
      : null;

  return (
    <>
      <AdminPageHeader
        title="Categories"
        description="Create and edit categories. A category is hidden, never deleted."
        actions={
          <Button
            size="sm"
            disabled={panel.mode !== "closed"}
            onClick={() => setPanel({ mode: "new" })}
          >
            New category
          </Button>
        }
      />

      {panel.mode !== "closed" ? (
        <section
          aria-labelledby="category-form-title"
          className="glass-panel mb-4 rounded-(--radius-panel) p-5 sm:p-6"
        >
          <h2
            id="category-form-title"
            className="mb-4 font-display text-xl font-semibold"
          >
            {panel.mode === "new"
              ? "New category"
              : `Edit “${editing?.name ?? "category"}”`}
          </h2>
          {panel.mode === "edit" && !editing ? (
            <p role="alert" className="text-sm text-danger">
              This category is no longer in the list. Close this panel and
              refresh.
            </p>
          ) : (
            <CategoryForm
              // A fresh form per category, so no values leak from one to another.
              key={panel.mode === "edit" ? panel.id : "new"}
              category={editing}
              onDone={() => setPanel({ mode: "closed" })}
            />
          )}
        </section>
      ) : null}

      {categories.isPending ? (
        <div
          className="space-y-2"
          role="status"
          aria-label="Loading categories"
        >
          {Array.from({ length: 5 }, (_, i) => (
            <div key={i} className="skeleton h-12 rounded-lg" />
          ))}
        </div>
      ) : categories.isError ? (
        categories.error instanceof SupabaseNotConfiguredError ? (
          <ConfigNotice />
        ) : (
          <AdminQueryError
            error={categories.error}
            noun="categories"
            action="view categories"
            onRetry={() => void categories.refetch()}
          />
        )
      ) : categories.data.length === 0 ? (
        <EmptyState
          eyebrow="No categories"
          title="No categories yet"
          message="Create the first category to group products in the storefront."
        />
      ) : (
        <div className="glass-panel rounded-(--radius-panel) p-2 sm:p-4">
          <CategoriesTable
            rows={categories.data}
            activeId={panel.mode === "edit" ? panel.id : null}
            onEdit={(id) => setPanel({ mode: "edit", id })}
          />
        </div>
      )}
    </>
  );
}

function CategoriesTable({
  rows,
  activeId,
  onEdit,
}: {
  rows: CategoryRow[];
  activeId: string | null;
  onEdit: (id: string) => void;
}) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Category</TableHead>
          <TableHead>Slug</TableHead>
          <TableHead className="text-right">Position</TableHead>
          <TableHead>Status</TableHead>
          <TableHead className="text-right">
            <span className="sr-only">Actions</span>
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((category) => (
          <TableRow
            key={category.id}
            data-state={category.id === activeId ? "selected" : undefined}
          >
            <TableCell>
              <div className="font-medium">{category.name}</div>
              {category.tagline ? (
                <div className="text-xs text-muted-foreground">
                  {category.tagline}
                </div>
              ) : null}
            </TableCell>
            <TableCell className="font-mono text-xs">{category.slug}</TableCell>
            <TableCell className="text-right tabular-nums">
              {category.position}
            </TableCell>
            <TableCell>
              <ProductActiveBadge active={category.is_active} />
            </TableCell>
            <TableCell className="text-right">
              <Button
                variant="outline"
                size="sm"
                onClick={() => onEdit(category.id)}
                aria-label={`Edit ${category.name}`}
              >
                Edit
              </Button>
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
