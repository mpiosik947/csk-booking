const HTML_ENTITIES: Readonly<Record<string, string>> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

export function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, (character) => HTML_ENTITIES[character]);
}

export function escapeEmailHref(value: string) {
  let url: URL;

  try {
    url = new URL(value);
  } catch {
    throw new Error("Invalid email URL.");
  }

  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error("Invalid email URL protocol.");
  }

  return escapeHtml(url.toString());
}
