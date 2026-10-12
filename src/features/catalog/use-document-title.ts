import { useEffect } from "react";

import { storeConfig } from "@/lib/env";

/**
 * Sets the tab title from loaded data (the route's `head` can only see the URL slug). Pass null
 * while loading to leave the route's own title alone.
 */
export function useDocumentTitle(title: string | null) {
  useEffect(() => {
    if (title) document.title = `${title} — ${storeConfig.name}`;
  }, [title]);
}
