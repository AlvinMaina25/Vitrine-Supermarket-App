/**
 * Admin navigation structure. Pure data, so the shell and the tests share one list.
 *
 * An item with a `to` is a live route. An item without one is a placeholder: it is rendered
 * disabled ("Soon") rather than linking to a route that does not exist yet. When a later phase
 * builds a section, give its entry a `to` and delete nothing else.
 */
export type AdminNavTo =
  | "/admin"
  | "/admin/orders"
  | "/admin/products"
  | "/admin/categories"
  | "/admin/inventory"
  | "/admin/customers"
  | "/admin/customers/$customerId"
  | "/admin/delivery"
  | "/admin/promotions"
  | "/admin/payments"
  | "/admin/reports"
  | "/admin/audit-log";

export interface AdminNavItem {
  key: string;
  label: string;
  /** Live route. Absent while the section is not built. */
  to?: AdminNavTo;
  /** Highlight only on an exact match. Sections with sub-pages (e.g. order details) leave it off. */
  exact?: boolean;
  /**
   * Phase 15: the route exists but only to say the section is not available yet (no backend read
   * to show). It stays a link, so keyboard and screen-reader users can reach the explanation, and
   * is marked "Soon".
   */
  soon?: boolean;
}

export interface AdminNavGroup {
  label: string;
  items: AdminNavItem[];
}

export const ADMIN_NAV: AdminNavGroup[] = [
  {
    label: "Operations",
    items: [
      { key: "dashboard", label: "Dashboard", to: "/admin", exact: true },
      { key: "orders", label: "Orders", to: "/admin/orders" },
      { key: "products", label: "Products", to: "/admin/products" },
      { key: "categories", label: "Categories", to: "/admin/categories" },
      { key: "inventory", label: "Inventory", to: "/admin/inventory" },
      { key: "customers", label: "Customers", to: "/admin/customers" },
      { key: "delivery", label: "Delivery", to: "/admin/delivery" },
      { key: "promotions", label: "Promotions", to: "/admin/promotions" },
      { key: "payments", label: "Payments", to: "/admin/payments" },
      { key: "audit-log", label: "Audit log", to: "/admin/audit-log" },
    ],
  },
  {
    label: "Coming later",
    items: [
      { key: "reports", label: "Reports", to: "/admin/reports", soon: true },
    ],
  },
];

/**
 * What the admin UI may tell a person about a failed load. Raw database messages are never
 * shown; the detail goes to the console for whoever is debugging.
 */
export function adminLoadErrorMessage(): string {
  return "Something went wrong while loading this page. Please try again in a moment.";
}
