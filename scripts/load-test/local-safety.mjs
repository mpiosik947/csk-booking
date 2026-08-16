import fs from "node:fs";
import path from "node:path";

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

function readEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return {};
  const result = {};
  for (const rawLine of fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/u, "").split(/\r?\n/u)) {
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
    result[key] = value;
  }
  return result;
}

export function assertLocalUrl(value, label) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`${label} is not a valid URL.`);
  }
  const host = parsed.hostname.toLowerCase();
  if (!LOCAL_HOSTS.has(host) || host.endsWith(".supabase.co")) {
    throw new Error(`${label} must target localhost; blocked host: ${host}`);
  }
  return parsed.origin;
}

export function getLocalLoadTestEnvironment() {
  const fileEnvironment = readEnvFile(path.resolve(process.cwd(), ".env.local"));
  const fileSupabaseUrl = fileEnvironment.NEXT_PUBLIC_SUPABASE_URL;
  const processSupabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;

  if (!fileSupabaseUrl) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL is missing from .env.local.");
  }
  const supabaseUrl = assertLocalUrl(fileSupabaseUrl, ".env.local Supabase URL");
  if (processSupabaseUrl) {
    const processUrl = assertLocalUrl(processSupabaseUrl, "process Supabase URL");
    if (processUrl !== supabaseUrl) {
      throw new Error("Process and .env.local Supabase URLs differ.");
    }
  }

  const appUrl = assertLocalUrl(
    process.env.LOADTEST_TARGET_URL ?? "http://127.0.0.1:3000",
    "load-test target"
  );
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? fileEnvironment.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY ?? fileEnvironment.SUPABASE_SERVICE_ROLE_KEY;
  if (!anonKey || !serviceRoleKey) {
    throw new Error("Local Supabase anon/service credentials are missing.");
  }

  return { supabaseUrl, appUrl, anonKey, serviceRoleKey };
}
