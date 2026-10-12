/**
 * Phase 14: inline validation for the profile and address forms.
 *
 * These are the same rules the forms already applied (phone shape, required address parts, the
 * field length limits set on the inputs), moved into pure functions so each problem can be shown
 * next to its own field and focus can go to the first one. The database remains the authority: this
 * only catches typing mistakes before a request is sent.
 */

export const PHONE_PATTERN = /^\+?\d{7,15}$/;
export const PHONE_ERROR =
  "Enter a valid phone number, e.g. 0712345678 or +254712345678.";

/** "0712 345 678" -> "0712345678". */
export function cleanPhone(value: string): string {
  return value.replace(/\s+/g, "");
}

export type ProfileField = "fullName" | "phone";
export type ProfileErrors = Partial<Record<ProfileField, string>>;

/** Order the fields appear on screen: the first error in this order gets focus. */
export const PROFILE_FIELD_ORDER: readonly ProfileField[] = [
  "fullName",
  "phone",
];

export function validateProfile(input: {
  fullName: string;
  phone: string;
}): ProfileErrors {
  const errors: ProfileErrors = {};
  if (input.fullName.trim().length > 120) {
    errors.fullName = "Use 120 characters or fewer for your name.";
  }
  const phone = cleanPhone(input.phone);
  if (phone !== "" && !PHONE_PATTERN.test(phone)) {
    errors.phone = PHONE_ERROR;
  }
  return errors;
}

export type AddressField =
  | "label"
  | "fullName"
  | "phone"
  | "county"
  | "line1"
  | "line2"
  | "city"
  | "postalCode"
  | "instructions";
export type AddressErrors = Partial<Record<AddressField, string>>;

/** Visual order of the address form (label, name, phone, county, street, estate, city, ...). */
export const ADDRESS_FIELD_ORDER: readonly AddressField[] = [
  "label",
  "fullName",
  "phone",
  "county",
  "line1",
  "line2",
  "city",
  "postalCode",
  "instructions",
];

export function validateAddress(input: {
  label: string;
  fullName: string;
  phone: string;
  county: string;
  line1: string;
  line2: string;
  city: string;
  postalCode: string;
  instructions: string;
}): AddressErrors {
  const errors: AddressErrors = {};
  const tooLong = (value: string, max: number) => value.trim().length > max;

  if (tooLong(input.label, 40)) errors.label = "Use 40 characters or fewer.";

  if (input.fullName.trim() === "") {
    errors.fullName = "Enter the recipient's name.";
  } else if (tooLong(input.fullName, 120)) {
    errors.fullName = "Use 120 characters or fewer.";
  }

  const phone = cleanPhone(input.phone);
  if (phone === "") {
    errors.phone = "Enter a phone number for the delivery.";
  } else if (!PHONE_PATTERN.test(phone)) {
    errors.phone = PHONE_ERROR;
  }

  if (input.county.trim() === "") errors.county = "Choose a county.";

  if (input.line1.trim() === "") {
    errors.line1 = "Enter the street or building.";
  } else if (tooLong(input.line1, 200)) {
    errors.line1 = "Use 200 characters or fewer.";
  }

  if (tooLong(input.line2, 200)) errors.line2 = "Use 200 characters or fewer.";

  if (input.city.trim() === "") {
    errors.city = "Enter the town or city.";
  } else if (tooLong(input.city, 80)) {
    errors.city = "Use 80 characters or fewer.";
  }

  if (tooLong(input.postalCode, 10)) {
    errors.postalCode = "Use 10 characters or fewer.";
  }
  if (tooLong(input.instructions, 500)) {
    errors.instructions = "Use 500 characters or fewer.";
  }
  return errors;
}

/** The first field with an error, in on-screen order; null when there is none. */
export function firstErrorField<F extends string>(
  errors: Partial<Record<F, string>>,
  order: readonly F[],
): F | null {
  for (const field of order) {
    if (errors[field]) return field;
  }
  return null;
}
