import { useQuery, useQueryClient } from "@tanstack/react-query";
import { REGEXP_ONLY_DIGITS } from "input-otp";
import { useState } from "react";
import { toast } from "sonner";

import { MfaChallengeForm } from "@/components/auth/mfa-challenge-form";
import { QueryErrorState } from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import {
  InputOTP,
  InputOTPGroup,
  InputOTPSlot,
} from "@/components/ui/input-otp";
import { isTotpCode } from "@/features/auth/admin-mfa-gate";
import { formatDateTime } from "@/lib/format";
import {
  MFA_STATUS_KEY,
  MfaError,
  cancelTotpEnrol,
  mfaStatusQuery,
  removeFactor,
  startTotpEnrol,
  verifyTotp,
  type MfaFactor,
  type TotpEnrolment,
} from "@/features/auth/mfa";

const CARD = "rounded-2xl border border-border bg-surface-strong p-5";

function errorText(error: unknown): string {
  return error instanceof MfaError
    ? error.message
    : "Something went wrong. Please try again.";
}

/** List, add and remove authenticator-app (TOTP) factors for the signed-in account. */
export function MfaFactorsPanel() {
  const queryClient = useQueryClient();
  const status = useQuery(mfaStatusQuery());
  const [enrolment, setEnrolment] = useState<TotpEnrolment | null>(null);
  const [starting, setStarting] = useState(false);
  const [removing, setRemoving] = useState<string | null>(null);
  const [confirmId, setConfirmId] = useState<string | null>(null);

  if (status.isPending)
    return <p className="text-sm text-muted-foreground">Loading…</p>;
  if (status.isError) {
    return (
      <QueryErrorState
        error={status.error}
        onRetry={() => void status.refetch()}
      />
    );
  }

  const { currentLevel, factors } = status.data;
  const verified = factors.filter((factor) => factor.verified);
  const unverified = factors.filter((factor) => !factor.verified);
  const needsCodeFirst = verified.length > 0 && currentLevel !== "aal2";

  const refresh = () =>
    queryClient.invalidateQueries({ queryKey: MFA_STATUS_KEY });

  async function begin() {
    if (starting) return;
    setStarting(true);
    try {
      setEnrolment(await startTotpEnrol(unverified.map((factor) => factor.id)));
    } catch (error) {
      toast.error(errorText(error));
    } finally {
      setStarting(false);
      void refresh();
    }
  }

  async function cancel() {
    const current = enrolment;
    setEnrolment(null);
    if (current) await cancelTotpEnrol(current.factorId);
    void refresh();
  }

  async function remove(factor: MfaFactor) {
    if (removing) return;
    setRemoving(factor.id);
    try {
      await removeFactor(factor.id);
      toast.success("Authenticator removed.");
      setConfirmId(null);
    } catch (error) {
      toast.error(errorText(error));
    } finally {
      setRemoving(null);
      void refresh();
    }
  }

  return (
    <div className="space-y-5">
      <section className={CARD} aria-labelledby="mfa-factors-title">
        <h2
          id="mfa-factors-title"
          className="font-display text-lg font-semibold"
        >
          Authenticator apps
        </h2>
        {verified.length === 0 ? (
          <p className="mt-2 text-sm text-muted-foreground">
            No authenticator app is set up. Add one to protect this account with
            a 6-digit code at sign-in.
          </p>
        ) : (
          <ul className="mt-3 divide-y divide-border">
            {verified.map((factor) => (
              <li
                key={factor.id}
                className="flex flex-wrap items-center justify-between gap-3 py-3"
              >
                <div>
                  <div className="text-sm font-medium">
                    {factor.friendlyName ?? "Authenticator app"}
                  </div>
                  <div className="text-xs text-muted-foreground">
                    Added {formatDateTime(factor.createdAt)}
                  </div>
                </div>
                {confirmId === factor.id ? (
                  <div className="flex gap-2">
                    <Button
                      variant="danger"
                      size="sm"
                      disabled={removing !== null || needsCodeFirst}
                      onClick={() => void remove(factor)}
                    >
                      {removing === factor.id ? "Removing…" : "Confirm remove"}
                    </Button>
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => setConfirmId(null)}
                    >
                      Keep
                    </Button>
                  </div>
                ) : (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setConfirmId(factor.id)}
                  >
                    Remove
                  </Button>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      {needsCodeFirst && verified[0] && (
        <section className={CARD} aria-labelledby="mfa-confirm-title">
          <h2
            id="mfa-confirm-title"
            className="font-display text-lg font-semibold"
          >
            Confirm it&apos;s you
          </h2>
          <p className="mt-2 mb-4 text-sm text-muted-foreground">
            Removing an authenticator needs a fresh code from your authenticator
            app.
          </p>
          <MfaChallengeForm
            factorId={verified[0].id}
            submitLabel="Confirm code"
          />
        </section>
      )}

      {enrolment ? (
        <EnrolCard
          enrolment={enrolment}
          onCancel={() => void cancel()}
          onDone={() => {
            setEnrolment(null);
            void refresh();
          }}
        />
      ) : (
        <div>
          <Button onClick={() => void begin()} disabled={starting}>
            {starting
              ? "Starting…"
              : verified.length === 0
                ? "Set up authenticator app"
                : "Add another authenticator app"}
          </Button>
        </div>
      )}
    </div>
  );
}

function EnrolCard({
  enrolment,
  onCancel,
  onDone,
}: {
  enrolment: TotpEnrolment;
  onCancel: () => void;
  onDone: () => void;
}) {
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function submit(value: string) {
    if (busy || !isTotpCode(value)) return;
    setBusy(true);
    setMessage(null);
    try {
      await verifyTotp(enrolment.factorId, value);
      toast.success("Two-factor sign-in is on.");
      onDone();
    } catch (error) {
      setMessage(errorText(error));
    } finally {
      setCode("");
      setBusy(false);
    }
  }

  return (
    <section className={CARD} aria-labelledby="mfa-enrol-title">
      <h2 id="mfa-enrol-title" className="font-display text-lg font-semibold">
        Scan, then confirm
      </h2>
      <ol className="mt-2 list-decimal space-y-1 pl-5 text-sm text-muted-foreground">
        <li>
          Open an authenticator app (Google Authenticator, Authy, 1Password, …).
        </li>
        <li>Scan this QR code, or type the key below into the app.</li>
        <li>Enter the 6-digit code the app shows.</li>
      </ol>
      <div className="mt-4 flex flex-col items-center gap-3">
        <img
          src={enrolment.qrCode}
          alt="QR code for your authenticator app"
          className="h-44 w-44 rounded-lg bg-white p-2"
        />
        <div className="text-center">
          <div className="text-xs text-muted-foreground">
            Can&apos;t scan? Enter this key manually
          </div>
          <code className="mt-1 block rounded bg-background px-2 py-1 text-sm break-all select-all">
            {enrolment.secret}
          </code>
        </div>
      </div>
      <form
        className="mt-5 space-y-4"
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
        <div className="flex gap-2">
          <Button
            type="submit"
            className="flex-1"
            disabled={busy || !isTotpCode(code)}
          >
            {busy ? "Checking…" : "Turn on two-factor"}
          </Button>
          <Button
            type="button"
            variant="ghost"
            onClick={onCancel}
            disabled={busy}
          >
            Cancel
          </Button>
        </div>
      </form>
    </section>
  );
}
