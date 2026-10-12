// Offline authoring only. No database connection and no publication side effect.
import { createHash } from "node:crypto";

export function canonicalize(value) {
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "string") {
    const text = value.replace(/\r\n?/g, "\n").normalize("NFC");
    if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(text) || !text.isWellFormed()) {
      throw new TypeError("Invalid legal text");
    }
    return JSON.stringify(text);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(",")}]`;
  if (value && Object.getPrototypeOf(value) === Object.prototype) {
    const keys = Object.keys(value).sort();
    if (keys.some((key) => !/^[a-z_]+$/.test(key))) throw new TypeError("Invalid field name");
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalize(value[key])}`).join(",")}}`;
  }
  throw new TypeError("Unsupported legal content value");
}

export function contentSnapshot(source) {
  const canonical = canonicalize(source);
  if (Buffer.byteLength(canonical, "utf8") > 262144) throw new RangeError("Legal content too large");
  return { canonical, sha256: createHash("sha256").update(canonical, "utf8").digest("hex") };
}
