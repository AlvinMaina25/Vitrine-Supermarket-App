import { Link } from "@tanstack/react-router";
import { Fragment } from "react";

import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator,
} from "@/components/ui/breadcrumb";

export type Crumb =
  | { label: string; to: "home" }
  | { label: string; to: "category"; slug: string }
  | { label: string; to?: undefined };

/** Home › Category › Product. The last crumb (no `to`) is the current page. */
export function Breadcrumbs({ items }: { items: readonly Crumb[] }) {
  return (
    <Breadcrumb className="mb-4">
      <BreadcrumbList className="text-sm text-muted-foreground">
        {items.map((item, index) => (
          <Fragment key={`${item.label}-${index}`}>
            {index > 0 ? <BreadcrumbSeparator /> : null}
            <BreadcrumbItem>
              {item.to === "home" ? (
                <BreadcrumbLink
                  asChild
                  className="inline-flex min-h-11 min-w-11 items-center justify-center"
                >
                  <Link to="/" search={{}}>
                    {item.label}
                  </Link>
                </BreadcrumbLink>
              ) : item.to === "category" ? (
                <BreadcrumbLink
                  asChild
                  className="inline-flex min-h-11 min-w-11 items-center justify-center"
                >
                  <Link to="/category/$slug" params={{ slug: item.slug }}>
                    {item.label}
                  </Link>
                </BreadcrumbLink>
              ) : (
                <BreadcrumbPage className="line-clamp-1">
                  {item.label}
                </BreadcrumbPage>
              )}
            </BreadcrumbItem>
          </Fragment>
        ))}
      </BreadcrumbList>
    </Breadcrumb>
  );
}
