import { useEffect, useState } from "react";

/** Becomes true when `active` has stayed true for `afterMs` (a slow connection hint). */
export function useSlowFlag(active: boolean, afterMs = 6000): boolean {
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    if (!active) {
      setSlow(false);
      return;
    }
    const timer = setTimeout(() => setSlow(true), afterMs);
    return () => clearTimeout(timer);
  }, [active, afterMs]);
  return slow;
}
