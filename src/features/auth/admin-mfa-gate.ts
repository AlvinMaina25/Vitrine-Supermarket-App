/**
 * Phase 6L.1 - the one decision the /admin layout makes about two-factor sign-in.
 *
 * Pure on purpose (no imports) so it runs under `node --test`. It only decides what to RENDER.
 * The database is the real gate: with enforcement on, every admin RPC refuses an aal1 session
 * (SQLSTATE 42501, DETAIL `mfa_required`), whatever this returns.
 *
 * The browser cannot read the enforcement flag, so this applies to every admin whether or not
 * the database is enforcing yet: an admin on an aal1 session is asked to enrol or to verify.
 */

export type AssuranceLevel = "aal1" | "aal2";

export type AdminMfaGateState =
  | "loading" //          still asking Supabase Auth / the database
  | "not_admin" //        signed in, but not an administrator
  | "needs_enrol" //      admin, aal1, no verified authenticator yet
  | "needs_challenge" //  admin, aal1, has a verified authenticator: ask for a code
  | "ok"; //              admin on an aal2 session

export interface AdminMfaGateInput {
  /** True until both the admin check and the MFA status have answered. */
  loading: boolean;
  isAdmin: boolean;
  /** From getAuthenticatorAssuranceLevel().currentLevel; null when unknown. */
  currentLevel: AssuranceLevel | null;
  /** At least one TOTP factor with status "verified". */
  hasVerifiedFactor: boolean;
}

export function adminMfaGate(input: AdminMfaGateInput): AdminMfaGateState {
  if (input.loading) return "loading";
  if (!input.isAdmin) return "not_admin";
  if (input.currentLevel === "aal2") return "ok";
  return input.hasVerifiedFactor ? "needs_challenge" : "needs_enrol";
}

/** A TOTP code is exactly six digits. Anything else is never sent to Supabase Auth. */
export function isTotpCode(value: string): boolean {
  return /^[0-9]{6}$/.test(value);
}
