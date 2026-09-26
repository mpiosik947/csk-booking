-- Global auth infrastructure, not tenant authority. Minting trusts ONLY the
-- server's immediately preceding recovery verification, never browser claims.
CREATE TABLE public.recovery_grants (
  grant_hash text PRIMARY KEY CHECK (grant_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id uuid NOT NULL REFERENCES auth.sessions(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  CHECK (expires_at > created_at)
);
ALTER TABLE public.recovery_grants OWNER TO postgres;
ALTER TABLE public.recovery_grants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.recovery_grants FROM PUBLIC, anon, authenticated, service_role;
CREATE INDEX recovery_grants_expiry_idx ON public.recovery_grants(expires_at);
CREATE INDEX recovery_grants_session_idx ON public.recovery_grants(session_id);

CREATE FUNCTION public.create_recovery_grant_v1(p_session_id uuid, p_grant_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_user_id uuid; v_now timestamptz := clock_timestamp();
BEGIN
  IF p_grant_hash IS NULL OR p_grant_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Recovery unavailable' USING ERRCODE = '22023';
  END IF;
  SELECT s.user_id INTO v_user_id FROM auth.sessions s JOIN auth.users u ON u.id=s.user_id
  WHERE s.id=p_session_id AND (s.not_after IS NULL OR s.not_after > v_now)
    AND u.deleted_at IS NULL AND (u.banned_until IS NULL OR u.banned_until <= v_now)
    AND NOT coalesce(u.is_anonymous,false);
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Recovery unavailable' USING ERRCODE = '28000';
  END IF;
  -- Bounded opportunistic retention: up to 1000 rows older than expiry + 24h
  -- per mint. Session/user deletion also cascades. No external scheduler added.
  DELETE FROM public.recovery_grants WHERE grant_hash IN (
    SELECT g.grant_hash FROM public.recovery_grants g
    WHERE g.expires_at < v_now - interval '24 hours'
    ORDER BY g.expires_at LIMIT 1000 FOR UPDATE SKIP LOCKED
  );
  INSERT INTO public.recovery_grants(grant_hash,user_id,session_id,created_at,expires_at)
  VALUES(p_grant_hash,v_user_id,p_session_id,v_now,v_now + interval '10 minutes');
  RETURN true;
END;
$$;

CREATE FUNCTION public.check_recovery_grant_v1(p_grant_hash text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.recovery_grants g
    JOIN auth.sessions s ON s.id=g.session_id AND s.user_id=g.user_id
    JOIN auth.users u ON u.id=g.user_id
    WHERE g.grant_hash=p_grant_hash AND g.user_id=auth.uid()
      AND g.session_id::text=auth.jwt()->>'session_id'
      AND g.expires_at > statement_timestamp() AND g.consumed_at IS NULL
      AND (s.not_after IS NULL OR s.not_after > statement_timestamp())
      AND u.deleted_at IS NULL AND (u.banned_until IS NULL OR u.banned_until <= statement_timestamp())
      AND NOT coalesce(u.is_anonymous,false)
  );
$$;

CREATE FUNCTION public.consume_recovery_grant_v1(p_grant_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_hash text;
BEGIN
  UPDATE public.recovery_grants g SET consumed_at=clock_timestamp()
  WHERE g.grant_hash=p_grant_hash AND g.user_id=auth.uid()
    AND g.session_id::text=auth.jwt()->>'session_id'
    AND g.expires_at > clock_timestamp() AND g.consumed_at IS NULL
    AND EXISTS (
      SELECT 1 FROM auth.sessions s JOIN auth.users u ON u.id=s.user_id
      WHERE s.id=g.session_id AND s.user_id=g.user_id
        AND (s.not_after IS NULL OR s.not_after > clock_timestamp())
        AND u.deleted_at IS NULL AND (u.banned_until IS NULL OR u.banned_until <= clock_timestamp())
        AND NOT coalesce(u.is_anonymous,false)
    )
  RETURNING g.grant_hash INTO v_hash;
  RETURN v_hash IS NOT NULL;
END;
$$;

ALTER FUNCTION public.create_recovery_grant_v1(uuid,text) OWNER TO postgres;
ALTER FUNCTION public.check_recovery_grant_v1(text) OWNER TO postgres;
ALTER FUNCTION public.consume_recovery_grant_v1(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.create_recovery_grant_v1(uuid,text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.check_recovery_grant_v1(text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.consume_recovery_grant_v1(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_recovery_grant_v1(uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.check_recovery_grant_v1(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.consume_recovery_grant_v1(text) TO authenticated;
