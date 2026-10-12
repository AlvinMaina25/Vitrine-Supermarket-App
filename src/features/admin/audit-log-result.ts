import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";
import {
  nullableString,
  requireArray,
  requireRecord,
  requireString,
  requireWholeNumber,
  type JsonRecord,
} from "./customer-parse.ts";

/**
 * Pure parser, error mapper and argument builder for the Phase 6I.1 read function
 * admin_list_audit_log() (admin only). The browser has no direct table read, so this RPC is the
 * only path. Entries are built field by field: anything else the server sends is dropped.
 */

const WHAT = "The audit log";

// ---------------------------------------------------------------- shapes

export interface AuditLogEntry {
  id: string;
  actor_id: string | null;
  action: string;
  target_id: string | null;
  reason: string | null;
  created_at: string;
}

export interface AuditLogList {
  total_count: number;
  limit: number;
  offset: number;
  entries: AuditLogEntry[];
}

// ---------------------------------------------------------------- parsers

function toEntry(value: unknown): AuditLogEntry {
  const r: JsonRecord = requireRecord(value, WHAT);
  return {
    id: requireString(r, "id", WHAT),
    actor_id: nullableString(r, "actor_id", WHAT),
    action: requireString(r, "action", WHAT),
    target_id: nullableString(r, "target_id", WHAT),
    reason: nullableString(r, "reason", WHAT),
    created_at: requireString(r, "created_at", WHAT),
  };
}

export function toAuditLogList(data: unknown): AuditLogList {
  const r = requireRecord(data, WHAT);
  return {
    total_count: requireWholeNumber(r, "total_count", WHAT),
    limit: requireWholeNumber(r, "limit", WHAT),
    offset: requireWholeNumber(r, "offset", WHAT),
    entries: requireArray(r["entries"], WHAT).map(toEntry),
  };
}

// ---------------------------------------------------------------- error mapping

function isNotAuthorised(error: RpcErrorLike): boolean {
  return error.code === "42501" || error.details === "not_authorised";
}

/** Not-an-admin -> AdminAccessError; bad arguments -> a plain Error. Never echoes the database message. */
export function toAuditLogReadError(error: RpcErrorLike): Error {
  if (isNotAuthorised(error)) {
    return new AdminAccessError(
      "You do not have permission to view the audit log.",
    );
  }
  if (error.details === "invalid_arguments")
    return new Error("The audit log request was not valid.");
  return new Error("The audit log could not be loaded.");
}

// ---------------------------------------------------------------- arguments

export interface AuditLogQuery {
  actorId?: string | null;
  action?: string | null;
  targetId?: string | null;
  /** Inclusive lower bound, ISO timestamp. */
  from?: string | null;
  /** Exclusive upper bound, ISO timestamp. */
  to?: string | null;
  limit?: number;
  offset?: number;
}

export interface AdminListAuditLogArgs {
  p_actor: string | null;
  p_action: string | null;
  p_target_id: string | null;
  p_from: string | null;
  p_to: string | null;
  p_limit: number;
  p_offset: number;
}

/** Named arguments for admin_list_audit_log(). Blank action becomes null; defaults 25/0. */
export function toAdminListAuditLogArgs(
  query: AuditLogQuery = {},
): AdminListAuditLogArgs {
  const action = query.action?.trim();
  return {
    p_actor: query.actorId ?? null,
    p_action: action ? action : null,
    p_target_id: query.targetId ?? null,
    p_from: query.from ?? null,
    p_to: query.to ?? null,
    p_limit: query.limit ?? 25,
    p_offset: query.offset ?? 0,
  };
}
