import { createBrowserClient } from "@supabase/ssr";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

if (!supabaseUrl) {
  throw new Error("Brak NEXT_PUBLIC_SUPABASE_URL w pliku .env.local");
}

if (!supabaseAnonKey) {
  throw new Error("Brak NEXT_PUBLIC_SUPABASE_ANON_KEY w pliku .env.local");
}

export const supabase = createBrowserClient(
  supabaseUrl,
  supabaseAnonKey
);