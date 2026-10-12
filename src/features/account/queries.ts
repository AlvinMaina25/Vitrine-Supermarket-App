import { queryOptions } from "@tanstack/react-query";

import { requireSupabase } from "@/lib/supabase/client";
import type {
  AddressInsert,
  AddressRow,
  ProfileRow,
  ProfileUpdate,
} from "@/lib/supabase/types";

/**
 * Account data access. Every call relies on the signed-in session: the user id
 * is read from Supabase Auth (never from props/input) and RLS scopes rows to
 * auth.uid() on the database side.
 */

const PROFILE_COLUMNS =
  "id, full_name, phone, email, avatar_url, status, created_at, updated_at";
const ADDRESS_COLUMNS =
  "id, user_id, label, full_name, phone, address_line_1, address_line_2, city, county, postal_code, delivery_instructions, latitude, longitude, is_default, created_at, updated_at";

async function currentUserId(): Promise<string> {
  const { data, error } = await requireSupabase().auth.getUser();
  if (error || !data.user)
    throw new Error("Your session has expired. Please sign in again.");
  return data.user.id;
}

export const profileQuery = () =>
  queryOptions({
    queryKey: ["account", "profile"],
    queryFn: async (): Promise<ProfileRow | null> => {
      const userId = await currentUserId();
      const { data, error } = await requireSupabase()
        .from("profiles")
        .select(PROFILE_COLUMNS)
        .eq("id", userId)
        .maybeSingle();
      if (error) throw new Error(error.message);
      return (data as ProfileRow | null) ?? null;
    },
  });

export async function updateProfile(values: ProfileUpdate): Promise<void> {
  const userId = await currentUserId();
  const { error } = await requireSupabase()
    .from("profiles")
    .update(values)
    .eq("id", userId);
  if (error) throw new Error(error.message);
}

export const addressesQuery = () =>
  queryOptions({
    queryKey: ["account", "addresses"],
    queryFn: async (): Promise<AddressRow[]> => {
      await currentUserId();
      const { data, error } = await requireSupabase()
        .from("addresses")
        .select(ADDRESS_COLUMNS)
        .order("is_default", { ascending: false })
        .order("created_at", { ascending: true });
      if (error) throw new Error(error.message);
      return (data ?? []) as AddressRow[];
    },
  });

export async function createAddress(values: AddressInsert): Promise<void> {
  await currentUserId();
  const { error } = await requireSupabase().from("addresses").insert(values);
  if (error) throw new Error(error.message);
}

export async function updateAddress(
  id: string,
  values: Partial<AddressInsert>,
): Promise<void> {
  await currentUserId();
  const { error } = await requireSupabase()
    .from("addresses")
    .update(values)
    .eq("id", id);
  if (error) throw new Error(error.message);
}

export async function deleteAddress(id: string): Promise<void> {
  await currentUserId();
  const { error } = await requireSupabase()
    .from("addresses")
    .delete()
    .eq("id", id);
  if (error) throw new Error(error.message);
}

export const KENYAN_COUNTIES = [
  "Baringo",
  "Bomet",
  "Bungoma",
  "Busia",
  "Elgeyo-Marakwet",
  "Embu",
  "Garissa",
  "Homa Bay",
  "Isiolo",
  "Kajiado",
  "Kakamega",
  "Kericho",
  "Kiambu",
  "Kilifi",
  "Kirinyaga",
  "Kisii",
  "Kisumu",
  "Kitui",
  "Kwale",
  "Laikipia",
  "Lamu",
  "Machakos",
  "Makueni",
  "Mandera",
  "Marsabit",
  "Meru",
  "Migori",
  "Mombasa",
  "Murang'a",
  "Nairobi",
  "Nakuru",
  "Nandi",
  "Narok",
  "Nyamira",
  "Nyandarua",
  "Nyeri",
  "Samburu",
  "Siaya",
  "Taita-Taveta",
  "Tana River",
  "Tharaka-Nithi",
  "Trans Nzoia",
  "Turkana",
  "Uasin Gishu",
  "Vihiga",
  "Wajir",
  "West Pokot",
] as const;
