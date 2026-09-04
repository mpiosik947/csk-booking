export const PASSWORD_MIN_LENGTH = 12;
export const PASSWORD_MAX_LENGTH = 72;

export const PASSWORD_MIN_LENGTH_MESSAGE =
  `Hasło musi mieć minimum ${PASSWORD_MIN_LENGTH} znaków.`;
export const PASSWORD_MAX_LENGTH_MESSAGE =
  `Hasło może mieć maksymalnie ${PASSWORD_MAX_LENGTH} znaki.`;

export function getPasswordLengthError(password: string): string | null {
  if (password.length < PASSWORD_MIN_LENGTH) {
    return PASSWORD_MIN_LENGTH_MESSAGE;
  }

  if (password.length > PASSWORD_MAX_LENGTH) {
    return PASSWORD_MAX_LENGTH_MESSAGE;
  }

  return null;
}
