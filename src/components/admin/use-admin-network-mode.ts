import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef } from "react";

/**
 * By default TanStack Query PAUSES a request while the browser is offline: a screen then sits on
 * its loading skeleton for ever, and an admin action would be queued and sent later without the
 * person knowing. In the admin area both are wrong. While the admin shell is mounted, admin reads
 * and every mutation are attempted straight away and fail fast, so the screen can say "you appear
 * to be offline" and an action can say "nothing was changed". The previous defaults are restored
 * when the shell unmounts, so nothing outside the admin area changes behaviour.
 *
 * Applied during the first render as well as in an effect: child queries build their options
 * before a parent effect would run.
 */
export function useAdminNetworkMode(): void {
  const queryClient = useQueryClient();
  const applied = useRef(false);

  const apply = () => {
    queryClient.setQueryDefaults(["admin"], { networkMode: "always" });
    const current = queryClient.getDefaultOptions();
    queryClient.setDefaultOptions({
      ...current,
      mutations: { ...current.mutations, networkMode: "always" },
    });
  };

  if (!applied.current) {
    applied.current = true;
    apply();
  }

  useEffect(() => {
    apply();
    return () => {
      queryClient.setQueryDefaults(["admin"], { networkMode: "online" });
      const current = queryClient.getDefaultOptions();
      queryClient.setDefaultOptions({
        ...current,
        mutations: { ...current.mutations, networkMode: "online" },
      });
    };
    // apply is stable for a given client.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queryClient]);
}
