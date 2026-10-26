"use client";

import { useEffect, useState, type ReactNode } from "react";
import { supabase } from "@/lib/supabase";

/** Auth changes invalidate server-rendered navigation; this component never grants access. */
export default function PublicAccessSessionClient({ children, serverActorId }: { children: ReactNode; serverActorId: string | null }) {
  const [invalidated, setInvalidated] = useState(false);
  useEffect(() => {
    let actor: string | null = serverActorId;
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, session) => {
      const next = session?.user.id ?? null;
      if (actor !== next && (event === "INITIAL_SESSION" || event === "SIGNED_IN" || event === "SIGNED_OUT")) {
        setInvalidated(true);
        window.location.reload();
      }
      actor = next;
    });
    return () => subscription.unsubscribe();
  }, [serverActorId]);
  return invalidated ? <p role="status">Sprawdzanie dostępności…</p> : children;
}
