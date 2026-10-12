import { AdminAccessError, type RpcErrorLike } from "./dashboard-result.ts";
import {
  characterCount,
  requireArray,
  requireBoolean,
  requireRecord,
  requireString,
  unexpected,
  type JsonRecord,
} from "./customer-parse.ts";

/**
 * Pure types, parsers, error mapper and argument builders for the Phase 6L.2 role-management
 * functions admin_set_user_role() and admin_list_role_holders() (admin only, MFA applies).
 * No UI uses these yet. Results are built field by field: anything else the server sends is
 * dropped. The database stays authoritative; the argument builder only saves a round trip.
 */

export const MIN_ROLE_REASON_LENGTH = 3;
export const MAX_ROLE_REASON_LENGTH = 200;

export type ManagedRole = "staff" | "admin";
export type RoleAction = "grant" | "revoke";

const MANAGED_ROLES: readonly ManagedRole[] = ["staff", "admin"];
const ROLE_ACTIONS: readonly RoleAction[] = ["grant", "revoke"];

// ---------------------------------------------------------------- shapes

export interface RoleHolder {
  user_id: string;
  role: ManagedRole;
  granted_at: string;
}

export interface RoleHolderList {
  holders: RoleHolder[];
}

export interface AdminSetUserRoleResult {
  /** false = a no-op (role already held / not held): nothing changed, no audit row. */
  changed: boolean;
  user_id: string;
  role: ManagedRole;
  action: RoleAction;
}

// ---------------------------------------------------------------- parsers

function requireRole(
  record: JsonRecord,
  key: string,
  what: string,
): ManagedRole {
  const value = requireString(record, key, what);
  const role = MANAGED_ROLES.find((r) => r === value);
  return role ?? unexpected(what);
}

function requireAction(
  record: JsonRecord,
  key: string,
  what: string,
): RoleAction {
  const value = requireString(record, key, what);
  const action = ROLE_ACTIONS.find((a) => a === value);
  return action ?? unexpected(what);
}

function toHolder(value: unknown): RoleHolder {
  const what = "The role holders list";
  const r = requireRecord(value, what);
  return {
    user_id: requireString(r, "user_id", what),
    role: requireRole(r, "role", what),
    granted_at: requireString(r, "granted_at", what),
  };
}

export function toRoleHolderList(data: unknown): RoleHolderList {
  const what = "The role holders list";
  const r = requireRecord(data, what);
  return { holders: requireArray(r["holders"], what).map(toHolder) };
}

export function toAdminSetUserRoleResult(
  data: unknown,
): AdminSetUserRoleResult {
  const what = "The role change";
  const r = requireRecord(data, what);
  return {
    changed: requireBoolean(r, "changed", what),
    user_id: requireString(r, "user_id", what),
    role: requireRole(r, "role", what),
    action: requireAction(r, "action", what),
  };
}

// ---------------------------------------------------------------- error mapping

export type AdminRoleChangeReason =
  | "invalid_arguments"
  | "invalid_action"
  | "invalid_role"
  | "reason_required"
  | "reason_too_short"
  | "reason_too_long"
  | "cannot_change_own_role"
  | "user_not_found"
  | "last_admin";

const ROLE_CHANGE_REASONS: readonly AdminRoleChangeReason[] = [
  "invalid_arguments",
  "invalid_action",
  "invalid_role",
  "reason_required",
  "reason_too_short",
  "reason_too_long",
  "cannot_change_own_role",
  "user_not_found",
  "last_admin",
];

export type RoleChangeFieldKey = "reason";

/** A rule refused the change. `reason` is the database's own DETAIL code, not its message. */
export class AdminRoleChangeError extends Error {
  override readonly name = "AdminRoleChangeError";
  readonly reason: AdminRoleChangeReason;
  readonly field: RoleChangeFieldKey | null;

  constructor(reason: AdminRoleChangeReason) {
    super(`Role change refused: ${reason}`);
    this.reason = reason;
    this.field =
      reason === "reason_required" ||
      reason === "reason_too_short" ||
      reason === "reason_too_long"
        ? "reason"
        : null;
  }
}

function isNotAuthorised(error: RpcErrorLike): boolean {
  return error.code === "42501" || error.details === "not_authorised";
}

/**
 * Not-an-admin (or MFA required) -> AdminAccessError; a known rule -> AdminRoleChangeError;
 * anything else -> a plain Error. Never echoes the database message.
 */
export function toAdminRoleChangeError(error: RpcErrorLike): Error {
  if (isNotAuthorised(error)) {
    return new AdminAccessError("You do not have permission to change roles.");
  }
  const reason = ROLE_CHANGE_REASONS.find((r) => r === error.details);
  return reason
    ? new AdminRoleChangeError(reason)
    : new Error("The role could not be changed.");
}

/** Not-an-admin -> AdminAccessError; anything else -> a plain Error. Never echoes the database message. */
export function toRoleHoldersReadError(error: RpcErrorLike): Error {
  if (isNotAuthorised(error)) {
    return new AdminAccessError(
      "You do not have permission to view role holders.",
    );
  }
  return new Error("The role holders could not be loaded.");
}

/** A short, safe sentence for each refusal; never the database text. */
export function roleChangeErrorMessage(reason: AdminRoleChangeReason): string {
  switch (reason) {
    case "invalid_arguments":
      return "The role change request was not valid.";
    case "invalid_action":
      return "Choose whether to grant or revoke the role.";
    case "invalid_role":
      return "Choose staff or admin.";
    case "reason_required":
      return "A reason is required.";
    case "reason_too_short":
      return `The reason must be at least ${MIN_ROLE_REASON_LENGTH} characters.`;
    case "reason_too_long":
      return `Keep the reason to ${MAX_ROLE_REASON_LENGTH} characters or fewer.`;
    case "cannot_change_own_role":
      return "You cannot change your own role.";
    case "user_not_found":
      return "That user could not be found.";
    case "last_admin":
      return "The last remaining admin cannot be revoked.";
  }
}

// ---------------------------------------------------------------- arguments

export interface AdminSetUserRoleArgs {
  p_user: string;
  p_role: ManagedRole;
  p_action: RoleAction;
  p_reason: string;
}

export type RoleChangeBuild =
  | { ok: true; args: AdminSetUserRoleArgs }
  | { ok: false; errors: Partial<Record<RoleChangeFieldKey, string>> };

/** Turns the (future) form into admin_set_user_role() arguments; the database still decides. */
export function buildSetUserRoleArgs(
  userId: string,
  role: ManagedRole,
  action: RoleAction,
  rawReason: string,
): RoleChangeBuild {
  const reason = rawReason.trim();
  const length = characterCount(reason);
  if (length === 0)
    return {
      ok: false,
      errors: { reason: roleChangeErrorMessage("reason_required") },
    };
  if (length < MIN_ROLE_REASON_LENGTH) {
    return {
      ok: false,
      errors: { reason: roleChangeErrorMessage("reason_too_short") },
    };
  }
  if (length > MAX_ROLE_REASON_LENGTH) {
    return {
      ok: false,
      errors: { reason: roleChangeErrorMessage("reason_too_long") },
    };
  }
  return {
    ok: true,
    args: { p_user: userId, p_role: role, p_action: action, p_reason: reason },
  };
}
