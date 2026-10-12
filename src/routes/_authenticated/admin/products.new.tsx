import { createFileRoute, Link } from "@tanstack/react-router";

import { AdminPageHeader } from "@/components/admin/admin-shell";
import { ProductCreateForm } from "@/components/admin/product-create-form";
import { Button } from "@/components/ui-kit/button";

export const Route = createFileRoute("/_authenticated/admin/products/new")({
  head: () => ({
    meta: [
      { title: "New product — Admin" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: NewProductPage,
});

/**
 * Sits under /_authenticated/admin, so it inherits the existing gate: signed-out visitors go to
 * /auth and signed-in non-admins see "Admin access required" and none of this form. The write
 * itself is refused by the database for anyone who is not an admin (admin_create_product()).
 */
function NewProductPage() {
  return (
    <>
      <AdminPageHeader
        title="New product"
        description="Add a product to the catalogue."
        actions={
          <Button asChild variant="outline" size="sm">
            <Link to="/admin/products" search={{}}>
              ← All products
            </Link>
          </Button>
        }
      />
      <section className="glass-panel rounded-(--radius-panel) p-5 sm:p-6">
        <ProductCreateForm />
      </section>
    </>
  );
}
