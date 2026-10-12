import { useQuery, useQueryClient } from "@tanstack/react-query";
import { isNetworkFailure } from "@/components/states/error-kind";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useRef, useState, type FormEvent } from "react";
import { toast } from "sonner";

import {
  EmptyState,
  ErrorState,
  StorefrontErrorState,
} from "@/components/states/states";
import { Button } from "@/components/ui-kit/button";
import { Field, TextInput } from "@/components/ui-kit/field";
import { AddressForm } from "@/features/account/address-form";
import {
  addressesQuery,
  createAddress,
  deleteAddress,
  profileQuery,
  updateAddress,
  updateProfile,
} from "@/features/account/queries";
import {
  cleanPhone,
  firstErrorField,
  PROFILE_FIELD_ORDER,
  validateProfile,
  type ProfileErrors,
  type ProfileField,
} from "@/features/account/form-validation";
import { useAuth } from "@/features/auth/auth-provider";
import { storeConfig } from "@/lib/env";
import type { AddressRow, ProfileRow } from "@/lib/supabase/types";

export const Route = createFileRoute("/_authenticated/account/")({
  head: () => ({
    meta: [
      { title: `Your account — ${storeConfig.name}` },
      {
        name: "description",
        content: `Manage your ${storeConfig.name} profile and delivery addresses.`,
      },
      { property: "og:title", content: `Your account — ${storeConfig.name}` },
      {
        property: "og:description",
        content: "Manage your profile and delivery addresses.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: AccountPage,
});

function AccountPage() {
  const { signOut } = useAuth();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  return (
    <section className="mx-auto max-w-3xl space-y-6 px-5 pt-10 pb-16">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <div className="eyebrow text-muted-foreground">Account</div>
          <h1 className="mt-2 font-display text-3xl font-semibold">
            Your account
          </h1>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button asChild variant="outline">
            <Link to="/account/orders">Your orders</Link>
          </Button>
          <Button
            variant="outline"
            onClick={async () => {
              await queryClient.cancelQueries();
              queryClient.clear();
              await signOut();
              void navigate({ to: "/auth", search: {}, replace: true });
            }}
          >
            Sign out
          </Button>
        </div>
      </div>
      <ProfileSection />
      <AddressesSection />
    </section>
  );
}

const PROFILE_FIELD_IDS: Record<ProfileField, string> = {
  fullName: "profile-name",
  phone: "profile-phone",
};

function PanelSkeleton() {
  return (
    <div
      aria-busy="true"
      role="status"
      aria-label="Loading"
      className="space-y-3"
    >
      <div className="skeleton h-5 w-40 rounded" />
      <div className="skeleton h-10 w-full rounded-lg" />
      <div className="skeleton h-10 w-full rounded-lg" />
    </div>
  );
}

function ProfileSection() {
  const profile = useQuery(profileQuery());
  const { user } = useAuth();
  const [editing, setEditing] = useState(false);

  return (
    <div className="glass-panel rounded-(--radius-panel) p-6 sm:p-8">
      <div className="flex items-center justify-between gap-3">
        <h2 className="font-display text-xl font-semibold">Profile</h2>
        {profile.data && !editing ? (
          <Button
            variant="outline"
            size="touch"
            onClick={() => setEditing(true)}
          >
            Edit profile
          </Button>
        ) : null}
      </div>
      <div className="mt-5">
        {profile.isPending ? (
          <PanelSkeleton />
        ) : profile.isError ? (
          <StorefrontErrorState
            error={profile.error}
            onRetry={() => void profile.refetch()}
          />
        ) : !profile.data ? (
          <ErrorState
            title="Profile not found"
            message="Your profile record hasn't been created yet. Make sure the database foundation script has been applied, then refresh."
          />
        ) : editing ? (
          <ProfileForm
            profile={profile.data}
            onDone={() => setEditing(false)}
          />
        ) : (
          <dl className="grid grid-cols-1 gap-4 text-sm sm:grid-cols-3">
            <ProfileItem label="Full name" value={profile.data.full_name} />
            <ProfileItem
              label="Email"
              value={profile.data.email ?? user?.email ?? null}
              mono
            />
            <ProfileItem label="Phone" value={profile.data.phone} mono />
          </dl>
        )}
      </div>
    </div>
  );
}

function ProfileItem({
  label,
  value,
  mono,
}: {
  label: string;
  value: string | null;
  mono?: boolean;
}) {
  return (
    <div>
      <dt className="eyebrow text-muted-foreground">{label}</dt>
      <dd
        className={`mt-1 break-words ${mono ? "font-mono" : ""} ${value ? "" : "text-muted-foreground"}`}
      >
        {value || "Not set"}
      </dd>
    </div>
  );
}

function ProfileForm({
  profile,
  onDone,
}: {
  profile: ProfileRow;
  onDone: () => void;
}) {
  const queryClient = useQueryClient();
  const [fullName, setFullName] = useState(profile.full_name ?? "");
  const [phone, setPhone] = useState(profile.phone ?? "");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [errors, setErrors] = useState<ProfileErrors>({});
  const submitting = useRef(false);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (submitting.current) return; // no double submit
    setError(null);
    const found = validateProfile({ fullName, phone });
    setErrors(found);
    const first = firstErrorField(found, PROFILE_FIELD_ORDER);
    if (first) {
      document.getElementById(PROFILE_FIELD_IDS[first])?.focus();
      return;
    }
    submitting.current = true;
    setPending(true);
    try {
      await updateProfile({
        full_name: fullName.trim() || null,
        phone: cleanPhone(phone) || null,
      });
      await queryClient.invalidateQueries({ queryKey: ["account", "profile"] });
      toast.success("Profile saved");
      onDone();
    } catch (cause) {
      console.error("Profile save failed", cause);
      setError(
        isNetworkFailure(
          cause,
          typeof navigator === "undefined" ? undefined : navigator.onLine,
        )
          ? "We couldn't reach the shop. Check your connection and try again."
          : "We couldn't save your profile. Please try again.",
      );
    } finally {
      submitting.current = false;
      setPending(false);
    }
  }

  return (
    <form onSubmit={onSubmit} noValidate className="space-y-4">
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label="Full name" htmlFor="profile-name" error={errors.fullName}>
          <TextInput
            id="profile-name"
            className="min-h-11"
            aria-invalid={errors.fullName ? true : undefined}
            aria-describedby={
              errors.fullName ? "profile-name-error" : undefined
            }
            maxLength={120}
            autoComplete="name"
            value={fullName}
            onChange={(e) => setFullName(e.target.value)}
          />
        </Field>
        <Field label="Phone" htmlFor="profile-phone" error={errors.phone}>
          <TextInput
            id="profile-phone"
            className="min-h-11"
            aria-invalid={errors.phone ? true : undefined}
            aria-describedby={errors.phone ? "profile-phone-error" : undefined}
            type="tel"
            autoComplete="tel"
            placeholder="0712 345 678"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
          />
        </Field>
        <div className="sm:col-span-2">
          <Field
            label="Email"
            htmlFor="profile-email"
            hint="Email is tied to your sign-in and can't be changed here."
          >
            <TextInput
              id="profile-email"
              className="min-h-11"
              value={profile.email ?? ""}
              disabled
              readOnly
            />
          </Field>
        </div>
      </div>
      {error ? (
        <div role="alert">
          <ErrorState title="Couldn't save profile" message={error} />
        </div>
      ) : null}
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="touch" disabled={pending}>
          {pending ? "Saving…" : "Save changes"}
        </Button>
        <Button
          type="button"
          size="touch"
          variant="outline"
          onClick={onDone}
          disabled={pending}
        >
          Cancel
        </Button>
      </div>
    </form>
  );
}

function AddressesSection() {
  const queryClient = useQueryClient();
  const addresses = useQuery(addressesQuery());
  const profile = useQuery(profileQuery());
  const [mode, setMode] = useState<
    { kind: "idle" } | { kind: "new" } | { kind: "edit"; address: AddressRow }
  >({ kind: "idle" });
  const [busyId, setBusyId] = useState<string | null>(null);
  // Phase 14: the address whose delete is waiting for an explicit "Yes, delete".
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);
  const busyRef = useRef(false);

  const refresh = () =>
    queryClient.invalidateQueries({ queryKey: ["account", "addresses"] });

  async function run(id: string, action: () => Promise<void>, success: string) {
    if (busyRef.current) return; // one change at a time: no double submit
    busyRef.current = true;
    setBusyId(id);
    try {
      await action();
      await refresh();
      toast.success(success);
    } catch (cause) {
      // Raw database text never reaches the screen; it goes to the console.
      console.error("Address change failed", cause);
      toast.error(
        isNetworkFailure(
          cause,
          typeof navigator === "undefined" ? undefined : navigator.onLine,
        )
          ? "We couldn't reach the shop. Check your connection and try again."
          : "We couldn't save that change. Please try again.",
      );
    } finally {
      busyRef.current = false;
      setBusyId(null);
    }
  }

  return (
    <div className="glass-panel rounded-(--radius-panel) p-6 sm:p-8">
      <div className="flex items-center justify-between gap-3">
        <h2 className="font-display text-xl font-semibold">
          Delivery addresses
        </h2>
        {mode.kind === "idle" && addresses.data ? (
          <Button size="touch" onClick={() => setMode({ kind: "new" })}>
            Add address
          </Button>
        ) : null}
      </div>

      <div className="mt-5 space-y-4">
        {mode.kind !== "idle" ? (
          <div className="rounded-(--radius-card) border border-border bg-surface-strong p-5">
            <h3 className="mb-4 font-display text-base font-semibold">
              {mode.kind === "new" ? "New address" : "Edit address"}
            </h3>
            <AddressForm
              initial={mode.kind === "edit" ? mode.address : undefined}
              defaultName={profile.data?.full_name}
              defaultPhone={profile.data?.phone}
              onCancel={() => setMode({ kind: "idle" })}
              onSubmit={async (values) => {
                if (mode.kind === "edit")
                  await updateAddress(mode.address.id, values);
                else
                  await createAddress({
                    ...values,
                    is_default:
                      values.is_default || (addresses.data?.length ?? 0) === 0,
                  });
                await refresh();
                toast.success(
                  mode.kind === "edit" ? "Address updated" : "Address added",
                );
                setMode({ kind: "idle" });
              }}
            />
          </div>
        ) : null}

        {addresses.isPending ? (
          <PanelSkeleton />
        ) : addresses.isError ? (
          <StorefrontErrorState
            error={addresses.error}
            onRetry={() => void addresses.refetch()}
          />
        ) : addresses.data.length === 0 && mode.kind === "idle" ? (
          <EmptyState
            eyebrow="No addresses"
            title="Add where we should deliver"
            message="Save a delivery address to speed through checkout."
            action={
              <Button size="touch" onClick={() => setMode({ kind: "new" })}>
                Add address
              </Button>
            }
          />
        ) : (
          <ul className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            {addresses.data.map((address) => (
              <li
                key={address.id}
                className="flex flex-col rounded-(--radius-card) border border-border bg-surface-strong p-4"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="font-medium">
                    {address.label || "Address"}
                  </span>
                  {address.is_default ? (
                    <span className="eyebrow rounded-full bg-primary/10 px-2 py-0.5 text-primary">
                      Default
                    </span>
                  ) : null}
                </div>
                <address className="mt-2 flex-1 text-sm not-italic text-muted-foreground">
                  {address.full_name} ·{" "}
                  <span className="font-mono">{address.phone}</span>
                  <br />
                  {address.address_line_1}
                  {address.address_line_2 ? (
                    <>, {address.address_line_2}</>
                  ) : null}
                  <br />
                  {address.city}, {address.county}
                  {address.postal_code ? ` ${address.postal_code}` : ""}
                  {address.delivery_instructions ? (
                    <span className="mt-2 block text-xs">
                      Note: {address.delivery_instructions}
                    </span>
                  ) : null}
                </address>
                {confirmDeleteId === address.id ? (
                  <div
                    role="alertdialog"
                    aria-label="Confirm delete address"
                    className="mt-3 space-y-2 rounded-lg border border-danger/25 bg-danger/5 p-3"
                  >
                    <p className="text-sm">
                      Delete {address.label || "this address"}? This can't be
                      undone. Orders you've already placed keep their own copy
                      of the address.
                    </p>
                    <div className="flex flex-wrap gap-2">
                      <Button
                        size="touch"
                        variant="danger"
                        disabled={busyId === address.id}
                        onClick={() => {
                          setConfirmDeleteId(null);
                          void run(
                            address.id,
                            () => deleteAddress(address.id),
                            "Address deleted",
                          );
                        }}
                      >
                        Yes, delete
                      </Button>
                      <Button
                        size="touch"
                        variant="outline"
                        autoFocus
                        onClick={() => setConfirmDeleteId(null)}
                      >
                        Keep it
                      </Button>
                    </div>
                  </div>
                ) : (
                  <div className="mt-3 flex flex-wrap gap-2">
                    <Button
                      size="touch"
                      variant="outline"
                      disabled={busyId !== null}
                      onClick={() => setMode({ kind: "edit", address })}
                    >
                      Edit
                    </Button>
                    {!address.is_default ? (
                      <Button
                        size="touch"
                        variant="outline"
                        disabled={busyId !== null}
                        onClick={() =>
                          void run(
                            address.id,
                            () =>
                              updateAddress(address.id, { is_default: true }),
                            "Default address updated",
                          )
                        }
                      >
                        {busyId === address.id ? "Saving…" : "Set as default"}
                      </Button>
                    ) : null}
                    <Button
                      size="touch"
                      variant="ghost"
                      className="text-danger"
                      disabled={busyId !== null}
                      onClick={() => setConfirmDeleteId(address.id)}
                    >
                      Delete
                    </Button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
