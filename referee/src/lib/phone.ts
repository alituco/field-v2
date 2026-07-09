export function normalizePhoneNumber(input: string) {
  const value = input.trim();
  if (value.startsWith("+")) return `+${value.replace(/\D/g, "")}`;

  const digits = value.replace(/\D/g, "");

  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  if (digits.length >= 8) return `+${digits}`;

  throw new Error("Enter a valid phone number.");
}
