import fs from "node:fs";
import path from "node:path";

export type LocalSupabaseTestEnvironment = {
  supabaseUrl: string;
  anonKey: string;
  serviceRoleKey: string;
};

function parseEnvFile(filePath: string) {
  const values = new Map<string, string>();
  const source = fs.readFileSync(filePath, "utf8");

  for (const rawLine of source.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator < 1) continue;
    const key = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    values.set(key, value);
  }

  return values;
}

function requireValue(values: Map<string, string>, key: string) {
  const value = process.env[key]?.trim() || values.get(key)?.trim();
  if (!value) throw new Error(`Missing required local E2E setting: ${key}`);
  return value;
}

export function assertLocalSupabaseUrl(value: string) {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL is not a valid URL.");
  }

  const hostname = url.hostname.toLowerCase();
  if (
    !["localhost", "127.0.0.1", "::1"].includes(hostname) ||
    hostname.endsWith(".supabase.co")
  ) {
    throw new Error(
      `Refusing to run local E2E against non-local Supabase host: ${hostname}`
    );
  }
  return url.toString().replace(/\/$/u, "");
}

export function getLocalSupabaseTestEnvironment(): LocalSupabaseTestEnvironment {
  const values = parseEnvFile(path.join(process.cwd(), ".env.local"));
  const fileUrl = values.get("NEXT_PUBLIC_SUPABASE_URL")?.trim();
  const processUrl = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();

  if (fileUrl) assertLocalSupabaseUrl(fileUrl);
  if (processUrl) assertLocalSupabaseUrl(processUrl);

  return {
    supabaseUrl: assertLocalSupabaseUrl(
      processUrl || requireValue(values, "NEXT_PUBLIC_SUPABASE_URL")
    ),
    anonKey: requireValue(values, "NEXT_PUBLIC_SUPABASE_ANON_KEY"),
    serviceRoleKey: requireValue(values, "SUPABASE_SERVICE_ROLE_KEY"),
  };
}
