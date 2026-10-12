import {
  toAdminListAuditLogArgs,
  type AdminListAuditLogArgs,
} from "./audit-log-result.ts";

/**
 * Pure helpers for the admin audit log screen (Phase 6J). No runtime imports beyond sibling pure
 * modules, so they run under `node --test`. The URL is the single source of truth for the filters.
 * Nothing here decides who may read the log: the database does inside admin_list_audit_log().
 */

export const AUDIT_LOG_PAGE_SIZE = 25;
export const AUDIT_LOG_MAX_PAGE = 100_000;
export const AUDIT_LOG_MAX_TEXT_LENGTH = 100;

export interface AuditLogParams {
  action?: string;
  targetId?: string;
  actorId?: string;
  /** Local calendar day, YYYY-MM-DD, inclusive. */
  from?: string;
  /** Local calendar day, YYYY-MM-DD, inclusive. */
  to?: string;
  /** 1-based; omitted means page 1. */
  page?: number;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAY = /^(\d{4})-(\d{2})-(\d{2})$/;

function cleanText(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = Array.from(value.trim())
    .slice(0, AUDIT_LOG_MAX_TEXT_LENGTH)
    .join("")
    .trim();
  return text === "" ? undefined : text;
}

function cleanDay(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const match = DAY.exec(value);
  if (!match) return undefined;
  const [, y, m, d] = match;
  const date = new Date(Number(y), Number(m) - 1, Number(d));
  const real =
    date.getFullYear() === Number(y) &&
    date.getMonth() === Number(m) - 1 &&
    date.getDate() === Number(d);
  return real ? value : undefined;
}

/** Invalid or unknown values are dropped rather than sent to the database. */
export function parseAuditLogParams(
  search: Record<string, unknown>,
): AuditLogParams {
  const params: AuditLogParams = {};

  const action = cleanText(search["action"]);
  if (action) params.action = action;

  const target = search["targetId"];
  if (typeof target === "string" && UUID.test(target.trim()))
    params.targetId = target.trim();

  const actor = search["actorId"];
  if (typeof actor === "string" && UUID.test(actor.trim()))
    params.actorId = actor.trim();

  const from = cleanDay(search["from"]);
  if (from) params.from = from;
  const to = cleanDay(search["to"]);
  // An end day before the start day can match nothing; drop it.
  if (to && !(from && to < from)) params.to = to;

  const page = Number(search["page"]);
  if (Number.isInteger(page) && page > 1 && page <= AUDIT_LOG_MAX_PAGE)
    params.page = page;

  return params;
}

export function activeAuditLogPage(params: AuditLogParams): number {
  return params.page ?? 1;
}

export function hasAuditLogFilter(params: AuditLogParams): boolean {
  return (
    params.action !== undefined ||
    params.targetId !== undefined ||
    params.actorId !== undefined ||
    params.from !== undefined ||
    params.to !== undefined
  );
}

/** A changed filter returns to page 1. Pass null to clear one filter. */
export function withAuditLogFilter(
  params: AuditLogParams,
  change: Partial<
    Record<"action" | "targetId" | "actorId" | "from" | "to", string | null>
  >,
): AuditLogParams {
  const pick = (key: "action" | "targetId" | "actorId" | "from" | "to") =>
    change[key] === undefined ? params[key] : change[key];
  return parseAuditLogParams({
    action: pick("action"),
    targetId: pick("targetId"),
    actorId: pick("actorId"),
    from: pick("from"),
    to: pick("to"),
  });
}

export function withAuditLogPage(
  params: AuditLogParams,
  page: number,
): AuditLogParams {
  return parseAuditLogParams({ ...params, page });
}

function localDayStartIso(day: string, addDays: number): string {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(y ?? 0, (m ?? 1) - 1, (d ?? 1) + addDays).toISOString();
}

/** Named arguments for admin_list_audit_log(). `from` is the start of the day, `to` the start of the next day (exclusive). */
export function toAuditLogArgs(params: AuditLogParams): AdminListAuditLogArgs {
  return toAdminListAuditLogArgs({
    action: params.action ?? null,
    targetId: params.targetId ?? null,
    actorId: params.actorId ?? null,
    from: params.from ? localDayStartIso(params.from, 0) : null,
    to: params.to ? localDayStartIso(params.to, 1) : null,
    limit: AUDIT_LOG_PAGE_SIZE,
    offset: (activeAuditLogPage(params) - 1) * AUDIT_LOG_PAGE_SIZE,
  });
}

/** First 8 characters of an id, for display; the full value goes in the title. */
export function shortId(id: string): string {
  return id.length > 8 ? `${id.slice(0, 8)}…` : id;
}
