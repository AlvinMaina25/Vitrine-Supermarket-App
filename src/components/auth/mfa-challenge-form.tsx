import { useQueryClient } from "@tanstack/react-query";
import { REGEXP_ONLY_DIGITS } from "input-otp";
import { useState } from "react";

import { Button } from "@/components/ui-kit/button";
import {
  InputOTP,
  InputOTPGroup,
  InputOTPSlot,
} from "@/components/ui/input-otp";
import { isTotpCode } from "@/features/auth/admin-mfa-gate";
import { MFA_STATUS_KEY, MfaError, verifyTotp } from "@/features/auth/mfa";

/**
 * Asks for the 6-digit code of one verified authenticator and, on success, upgrades the session
 * to aal2. The code lives only in this component's state and is cleared after every attempt.
 */
export function MfaChallengeForm({
  factorId,
  submitLabel = "Verify",
  onVerified,
}: {
  factorId: string;
  submitLabel?: string;
  onVerified?: () => void;
}) {
  const queryClient = useQueryClient();
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function submit(value: string) {
    if (busy || !isTotpCode(value)) return;
    setBusy(true);
    setMessage(null);
    try {
      await verifyTotp(factorId, value);
      await queryClient.invalidateQueries({ queryKey: MFA_STATUS_KEY });
      onVerified?.();
    } catch (error) {
      setMessage(
        error instanceof MfaError
          ? error.message
          : "Something went wrong. Please try again.",
      );
    } finally {
      setCode("");
      setBusy(false);
    }
  }

  return (
    <form
      className="space-y-4"
      onSubmit={(event) => {
        event.preventDefault();
        void submit(code);
      }}
    >
      <div className="flex justify-center">
        <InputOTP
          maxLength={6}
          pattern={REGEXP_ONLY_DIGITS}
          inputMode="numeric"
          autoComplete="one-time-code"
          value={code}
          onChange={setCode}
          onComplete={(value) => void submit(value)}
          disabled={busy}
          aria-label="6-digit authenticator code"
        >
          <InputOTPGroup>
            {[0, 1, 2, 3, 4, 5].map((index) => (
              <InputOTPSlot key={index} index={index} />
            ))}
          </InputOTPGroup>
        </InputOTP>
      </div>
      {message && (
        <p role="alert" className="text-center text-sm text-danger">
          {message}
        </p>
      )}
      <Button type="submit" size="block" disabled={busy || !isTotpCode(code)}>
        {busy ? "Checking…" : submitLabel}
      </Button>
    </form>
  );
}
