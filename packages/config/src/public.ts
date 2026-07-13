export function isProductionEnvironment(value: string | undefined): boolean {
  return value === "production";
}

export function publicOrigin(value: string): URL {
  const origin = new URL(value);
  if (
    !["http:", "https:"].includes(origin.protocol) ||
    origin.username ||
    origin.password
  ) {
    throw new Error(
      "public origin must be an HTTP(S) origin without credentials",
    );
  }
  return origin;
}
