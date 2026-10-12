import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";

import { isTotpCode, type AssuranceLevel } from "./admin-mfa-gate";

/**
 * Phase 6L.1 - TOTP two-factor sign-in through Supabase Auth's own MFA API. No custom crypto.
 *
 * Secrets and codes: the enrolment QR/secret exist only in the object returned by startTotpEnrol()
 * and are held by the enrol screen until it finishes or is cancelled. Nothing here logs, stores or
 * caches a secret or a code, and error messages shown to people are fixed text, never the server's.
 */

export interface MfaFactor {
  id: string;
  friendlyName: string | null;
  verified: boolean;
  createdAt: string;
}

export interface MfaStatus {
  currentLevel: AssuranceLevel | null;
  /** Every TOTP factor, verified or not. */
  factors: MfaFactor[];
}

export interface TotpEnrolment {
  factorId: string;
  /** SVG data URL from Supabase, used as an <img> source. */
  qrCode: string;
  /** Manual-entry key for apps that cannot scan the QR. */
  secret: string;
}

export class MfaError extends Error {
  override readonly name = "MfaError";
}

export const MFA_STATUS_KEY = ["auth", "mfa"] as const;

export const mfaStatusQuery = () =>
  queryOptions({
    queryKey: MFA_STATUS_KEY,
    staleTime: 0,
    retry: false,
    queryFn: async (): Promise<MfaStatus> => {
      const client = requireSupabase();
      const [level, list] = await Promise.all([
        client.auth.mfa.getAuthenticatorAssuranceLevel(),
        client.auth.mfa.listFactors(),
      ]);
      if (level.error || list.error)
        throw new MfaError("Could not read your sign-in security.");
      const raw = level.data.currentLevel;
      return {
        currentLevel: raw === "aal2" ? "aal2" : raw === "aal1" ? "aal1" : null,
        factors: list.data.all
          .filter((factor) => factor.factor_type === "totp")
          .map((factor) => ({
            id: factor.id,
            friendlyName: factor.friendly_name ?? null,
            verified: factor.status === "verified",
            createdAt: factor.created_at,
          })),
      };
    },
  });

/**
 * Starts a new TOTP enrolment. Half-finished enrolments of this account (status "unverified") are
 * removed first so abandoned attempts do not pile up.
 */
export async function startTotpEnrol(
  staleFactorIds: string[],
): Promise<TotpEnrolment> {
  const client = requireSupabase();
  for (const factorId of staleFactorIds) {
    await client.auth.mfa.unenroll({ factorId });
  }
  const { data, error } = await client.auth.mfa.enroll({ factorType: "totp" });
  if (error)
    throw new MfaError(
      "Could not start setting up two-factor sign-in. Please try again.",
    );
  return {
    factorId: data.id,
    qrCode: data.totp.qr_code,
    secret: data.totp.secret,
  };
}

/** challenge + verify, then refresh the session so the new token carries aal2. */
export async function verifyTotp(
  factorId: string,
  code: string,
): Promise<void> {
  if (!isTotpCode(code))
    throw new MfaError("Enter the 6-digit code from your authenticator app.");
  const client = requireSupabase();
  const challenge = await client.auth.mfa.challenge({ factorId });
  if (challenge.error)
    throw new MfaError("Could not check your code. Please try again.");
  const verified = await client.auth.mfa.verify({
    factorId,
    challengeId: challenge.data.id,
    code,
  });
  if (verified.error) {
    throw new MfaError(
      "That code didn't work. Check your authenticator app and try again.",
    );
  }
  const refreshed = await client.auth.refreshSession();
  if (refreshed.error) {
    throw new MfaError(
      "Your code was accepted, but the session could not be refreshed. Reload the page.",
    );
  }
}

/** Removing a verified factor needs an aal2 session; Supabase Auth enforces that. */
export async function removeFactor(factorId: string): Promise<void> {
  const { error } = await requireSupabase().auth.mfa.unenroll({ factorId });
  if (error) {
    throw new MfaError(
      "Could not remove that authenticator. Confirm a code first, then try again.",
    );
  }
}

/** Throws away an enrolment that was never verified (the person cancelled). */
export async function cancelTotpEnrol(factorId: string): Promise<void> {
  await requireSupabase().auth.mfa.unenroll({ factorId });
}
