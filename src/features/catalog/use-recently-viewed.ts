import { useCallback, useEffect, useState } from "react";

import {
  clearRecentlyViewed,
  readRecentlyViewed,
  recordRecentlyViewed,
  type StorageLike,
} from "@/features/catalog/recently-viewed";

/** localStorage, or null where it is missing or blocked (some private modes throw on access). */
function deviceStorage(): StorageLike | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    return null;
  }
}

/**
 * Device-only recently viewed ids. Reads after mount (so server and first client render agree),
 * and never talks to the server.
 */
export function useRecentlyViewed() {
  const [ids, setIds] = useState<string[]>([]);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    setIds(readRecentlyViewed(deviceStorage()));
    setReady(true);
  }, []);

  const record = useCallback((id: string) => {
    setIds(recordRecentlyViewed(deviceStorage(), id));
  }, []);

  const clear = useCallback(() => {
    clearRecentlyViewed(deviceStorage());
    setIds([]);
  }, []);

  return { ids, ready, record, clear };
}
