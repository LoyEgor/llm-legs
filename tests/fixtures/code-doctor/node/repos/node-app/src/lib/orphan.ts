export function legacyBanner(name: string): string {
  const stamp = new Date().toISOString();
  return `== ${name} (${stamp}) ==`;
}
