import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";

import { toAuditLogArgs, type AuditLogParams } from "./audit-log-params";
import { toAuditLogList, toAuditLogReadError } from "./audit-log-result";

/**
 * Admin audit log (Phase 6J, read only). The only call is the admin-only admin_list_audit_log()
 * function through the signed-in session; the table itself is never queried. Query keys start
 * with ["admin", "audit-log"].
 */
export const adminAuditLogQuery = (params: AuditLogParams = {}) =>
  queryOptions({
    queryKey: ["admin", "audit-log", "list", toAuditLogArgs(params)],
    staleTime: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await requireSupabase().rpc(
        "admin_list_audit_log",
        toAuditLogArgs(params),
      );
      if (error) throw toAuditLogReadError(error);
      return toAuditLogList(data);
    },
  });
