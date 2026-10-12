-- LEGAL-IMPL-3C1: additive foundation. No publication seed or runtime cutover.
-- Existing signup, booking, event and promotion callers/grants are unchanged.
-- Referenced-table FK/trigger metadata locks are bounded; a busy database must
-- reject this atomic migration for retry rather than build an unbounded queue.
-- Session SET also works with the official CLI's implicit transaction batch;
-- SET LOCAL would warn and be ignored. Reset both settings at the end.
SET lock_timeout = '500ms';
SET statement_timeout = '15s';

-- Tenant ownership is fixed at creation, including before legal evidence exists.
-- No role bypass and no evidence lookup: this is safe under every isolation level.
CREATE FUNCTION app_private.legal_resource_tenant_immutable_v1() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $fn$
BEGIN
 IF OLD.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
  RAISE EXCEPTION 'TENANT_OWNERSHIP_IMMUTABLE'
   USING ERRCODE='23514', CONSTRAINT='legal_resource_tenant_immutable';
 END IF;
 RETURN NEW;
END;$fn$;
REVOKE ALL ON FUNCTION app_private.legal_resource_tenant_immutable_v1() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER aa_legal_resource_tenant_immutable BEFORE UPDATE ON public.reservations
 FOR EACH ROW EXECUTE FUNCTION app_private.legal_resource_tenant_immutable_v1();
CREATE TRIGGER aa_legal_resource_tenant_immutable BEFORE UPDATE ON public.event_registrations
 FOR EACH ROW EXECUTE FUNCTION app_private.legal_resource_tenant_immutable_v1();
CREATE TABLE public.legal_documents (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 document_type text NOT NULL CHECK (document_type IN ('platform_terms','platform_privacy_notice','platform_cookie_storage_notice','adult_self_declaration','tenant_regulations','tenant_privacy_notice')),
 scope_type text NOT NULL CHECK (scope_type IN ('platform','tenant')),
 tenant_id uuid REFERENCES public.tenants(id) ON DELETE RESTRICT,
 current_version_id uuid,
 CHECK ((scope_type='platform' AND tenant_id IS NULL AND document_type IN ('platform_terms','platform_privacy_notice','platform_cookie_storage_notice','adult_self_declaration')) OR
        (scope_type='tenant' AND tenant_id IS NOT NULL AND document_type IN ('tenant_regulations','tenant_privacy_notice')))
);
CREATE UNIQUE INDEX legal_documents_platform_key ON public.legal_documents(document_type) WHERE tenant_id IS NULL;
CREATE UNIQUE INDEX legal_documents_tenant_key ON public.legal_documents(tenant_id,document_type) WHERE tenant_id IS NOT NULL;

CREATE TABLE public.legal_document_versions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 document_id uuid NOT NULL REFERENCES public.legal_documents(id) ON DELETE RESTRICT,
 version text NOT NULL CHECK (version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
 status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','retired')),
 content_canonical text NOT NULL CHECK (octet_length(content_canonical) BETWEEN 2 AND 262144),
 content_hash bytea GENERATED ALWAYS AS (extensions.digest(content_canonical,'sha256')) STORED,
 evidence_kind text NOT NULL CHECK (evidence_kind IN ('none','acceptance','acknowledgement','self_declaration')),
 requires_reacceptance boolean NOT NULL DEFAULT true,
 acceptance_anchor_version_id uuid,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 published_at timestamptz,
 effective_at timestamptz,
 retired_at timestamptz,
 UNIQUE(document_id,version), UNIQUE(document_id,id),
 FOREIGN KEY(document_id,acceptance_anchor_version_id) REFERENCES public.legal_document_versions(document_id,id) ON DELETE RESTRICT,
 CHECK ((status='draft' AND published_at IS NULL AND effective_at IS NULL AND retired_at IS NULL AND acceptance_anchor_version_id IS NULL) OR
        (status='published' AND published_at IS NOT NULL AND effective_at IS NOT NULL AND effective_at>=published_at AND retired_at IS NULL AND acceptance_anchor_version_id IS NOT NULL) OR
        (status='retired' AND published_at IS NOT NULL AND effective_at IS NOT NULL AND retired_at IS NOT NULL AND effective_at>=published_at AND retired_at>=published_at AND acceptance_anchor_version_id IS NOT NULL))
);
CREATE INDEX legal_versions_history_idx ON public.legal_document_versions(document_id,published_at,id);
ALTER TABLE public.legal_documents ADD CONSTRAINT legal_documents_current_version_fkey
 FOREIGN KEY(id,current_version_id) REFERENCES public.legal_document_versions(document_id,id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE app_private.legal_subjects (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX legal_subject_user_key ON app_private.legal_subjects(user_id) WHERE user_id IS NOT NULL;

CREATE TABLE app_private.legal_actions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subject_id uuid NOT NULL REFERENCES app_private.legal_subjects(id) ON DELETE RESTRICT,
 tenant_id uuid REFERENCES public.tenants(id) ON DELETE RESTRICT,
 context_type text NOT NULL CHECK (context_type IN ('registration','account_reacceptance','booking','event_registration','event_promotion')),
 reservation_id uuid,
 event_registration_id uuid,
 request_id uuid NOT NULL,
 request_hash bytea NOT NULL CHECK (octet_length(request_hash)=32),
 accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 outcome text NOT NULL CHECK (outcome IN ('account_completed','account_reaccepted','created','registered','reserve','confirmed')),
 offer_snapshot jsonb,
 -- A frozen, bounded manifest makes deferred completeness independent of later publication.
 required_document_version_ids uuid[] NOT NULL CHECK (cardinality(required_document_version_ids) BETWEEN 1 AND 8 AND array_position(required_document_version_ids,NULL) IS NULL),
 UNIQUE(subject_id,request_id),
 -- Existing PKs preserve resource lifetime; universal parent ownership guards
 -- and the evidence guard preserve the tenant snapshot without hot-table indexes.
 FOREIGN KEY(reservation_id) REFERENCES public.reservations(id) ON DELETE RESTRICT,
 FOREIGN KEY(event_registration_id) REFERENCES public.event_registrations(id) ON DELETE RESTRICT,
 CHECK ((context_type IN ('registration','account_reacceptance') AND tenant_id IS NULL AND reservation_id IS NULL AND event_registration_id IS NULL AND offer_snapshot IS NULL AND
         ((context_type='registration' AND outcome='account_completed') OR (context_type='account_reacceptance' AND outcome='account_reaccepted'))) OR
        (context_type='booking' AND tenant_id IS NOT NULL AND reservation_id IS NOT NULL AND event_registration_id IS NULL AND offer_snapshot IS NOT NULL AND outcome='created') OR
        (context_type IN ('event_registration','event_promotion') AND tenant_id IS NOT NULL AND reservation_id IS NULL AND event_registration_id IS NOT NULL AND offer_snapshot IS NOT NULL AND
          ((context_type='event_registration' AND outcome IN ('registered','reserve')) OR (context_type='event_promotion' AND outcome='confirmed'))))
);
CREATE UNIQUE INDEX legal_action_booking_key ON app_private.legal_actions(reservation_id) WHERE context_type='booking';
CREATE UNIQUE INDEX legal_action_event_key ON app_private.legal_actions(event_registration_id,context_type) WHERE event_registration_id IS NOT NULL;
CREATE UNIQUE INDEX legal_action_account_bundle_key ON app_private.legal_actions(subject_id,request_hash) WHERE context_type IN ('registration','account_reacceptance');
CREATE INDEX legal_action_subject_history_idx ON app_private.legal_actions(subject_id,accepted_at DESC,id DESC);
CREATE INDEX legal_action_tenant_history_idx ON app_private.legal_actions(tenant_id,accepted_at,id);

CREATE TABLE app_private.legal_acceptances (
 action_id uuid NOT NULL REFERENCES app_private.legal_actions(id) ON DELETE RESTRICT,
 document_version_id uuid NOT NULL REFERENCES public.legal_document_versions(id) ON DELETE RESTRICT,
 acceptance_kind text NOT NULL CHECK (acceptance_kind IN ('acceptance','acknowledgement','self_declaration')),
 PRIMARY KEY(action_id,document_version_id)
);
CREATE INDEX legal_acceptance_version_idx ON app_private.legal_acceptances(document_version_id,action_id);

-- Restricted JCS subset: ASCII object keys, Unicode NFC strings, no numeric content.
-- The authoring utility normalizes before review; DB rejects noncanonical input.
CREATE FUNCTION app_private.legal_canonical_content_v1(p_value jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE result text; item record; part text;
BEGIN
 IF p_value IS NULL THEN RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023'; END IF;
 CASE jsonb_typeof(p_value)
 WHEN 'object' THEN
  result:='';
  FOR item IN SELECT key,value FROM jsonb_each(p_value) ORDER BY key COLLATE "C" LOOP
   IF item.key !~ '^[a-z_]+$' THEN RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023'; END IF;
   part:=to_jsonb(item.key)::text||':'||app_private.legal_canonical_content_v1(item.value);
   result:=result||CASE WHEN result='' THEN '' ELSE ',' END||part;
  END LOOP;
  RETURN '{'||result||'}';
 WHEN 'array' THEN
  SELECT string_agg(app_private.legal_canonical_content_v1(value),',' ORDER BY ord) INTO result FROM jsonb_array_elements(p_value) WITH ORDINALITY a(value,ord);
  RETURN '['||coalesce(result,'')||']';
 WHEN 'string' THEN
  part:=p_value#>>'{}';
  IF position(chr(13) IN part)>0 OR normalize(part,NFC)<>part OR part ~ '[\x00-\x08\x0B\x0C\x0E-\x1F]' THEN
   RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023';
  END IF;
  RETURN p_value::text;
 WHEN 'boolean','null' THEN RETURN p_value::text;
 ELSE RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023';
 END CASE;
END;$fn$;

CREATE FUNCTION app_private.legal_registry_guard_v1() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE doc public.legal_documents; body jsonb; block jsonb; expected_kind text; keys text[];
BEGIN
 IF TG_OP IN ('DELETE','TRUNCATE') THEN RAISE EXCEPTION 'LEGAL_REGISTRY_IMMUTABLE' USING ERRCODE='42501'; END IF;
 IF TG_TABLE_NAME='legal_documents' THEN
  IF TG_OP='UPDATE' AND (to_jsonb(NEW)-'current_version_id') IS DISTINCT FROM (to_jsonb(OLD)-'current_version_id') THEN
   RAISE EXCEPTION 'LEGAL_DOCUMENT_IDENTITY_IMMUTABLE' USING ERRCODE='42501';
  END IF;
  IF NEW.current_version_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.legal_document_versions v WHERE v.id=NEW.current_version_id AND v.document_id=NEW.id AND v.status='published' AND v.effective_at<=clock_timestamp()) THEN
   RAISE EXCEPTION 'LEGAL_VERSION_NOT_ACTIVE' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
 END IF;
 IF TG_OP='INSERT' AND NEW.status<>'draft' THEN RAISE EXCEPTION 'LEGAL_DRAFT_REQUIRED' USING ERRCODE='23514'; END IF;
 IF TG_OP='UPDATE' AND OLD.status<>'draft' THEN
  IF (to_jsonb(NEW)-ARRAY['status','retired_at','content_hash']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','retired_at','content_hash']) OR
     NOT (OLD.status='published' AND NEW.status='retired' AND NEW.retired_at IS NOT NULL) THEN
   RAISE EXCEPTION 'LEGAL_VERSION_IMMUTABLE' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
 END IF;
 SELECT * INTO STRICT doc FROM public.legal_documents WHERE id=NEW.document_id;
 expected_kind:=CASE doc.document_type WHEN 'platform_cookie_storage_notice' THEN 'none' WHEN 'adult_self_declaration' THEN 'self_declaration'
   WHEN 'platform_privacy_notice' THEN 'acknowledgement' WHEN 'tenant_privacy_notice' THEN 'acknowledgement' ELSE 'acceptance' END;
 IF NEW.evidence_kind<>expected_kind THEN RAISE EXCEPTION 'LEGAL_KIND_INVALID' USING ERRCODE='23514'; END IF;
 body:=NEW.content_canonical::jsonb;
 SELECT array_agg(k ORDER BY k) INTO keys FROM jsonb_object_keys(body) k;
 IF keys IS DISTINCT FROM ARRAY['blocks','document_id','document_type','evidence_kind','format','locale','requires_reacceptance','scope_type','tenant_id','title','version'] OR
    body->>'format' IS DISTINCT FROM 'legal-content-v1' OR body->>'locale' IS DISTINCT FROM 'pl-PL' OR
    body->>'document_id' IS DISTINCT FROM doc.id::text OR body->>'document_type' IS DISTINCT FROM doc.document_type OR
    body->>'scope_type' IS DISTINCT FROM doc.scope_type OR body->'tenant_id' IS DISTINCT FROM coalesce(to_jsonb(doc.tenant_id),'null'::jsonb) OR
    body->>'version' IS DISTINCT FROM NEW.version OR body->>'evidence_kind' IS DISTINCT FROM NEW.evidence_kind OR
    body->'requires_reacceptance' IS DISTINCT FROM to_jsonb(NEW.requires_reacceptance) OR
    jsonb_typeof(body->'title') IS DISTINCT FROM 'string' OR length(btrim(body->>'title')) NOT BETWEEN 1 AND 200 OR
    jsonb_typeof(body->'blocks') IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023';
 END IF;
 IF jsonb_array_length(body->'blocks') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023'; END IF;
 FOR block IN SELECT value FROM jsonb_array_elements(body->'blocks') LOOP
  IF jsonb_typeof(block) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023'; END IF;
  SELECT array_agg(k ORDER BY k) INTO keys FROM jsonb_object_keys(block) k;
  IF block->>'type' IN ('heading','paragraph') THEN
   IF keys<>ARRAY['text','type'] OR jsonb_typeof(block->'text') IS DISTINCT FROM 'string' OR length(btrim(block->>'text')) NOT BETWEEN 1 AND 12000 THEN RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023'; END IF;
  ELSIF block->>'type'='link' THEN
   IF keys<>ARRAY['href','text','type'] OR jsonb_typeof(block->'text') IS DISTINCT FROM 'string' OR length(btrim(block->>'text')) NOT BETWEEN 1 AND 500 OR
      jsonb_typeof(block->'href') IS DISTINCT FROM 'string' OR length(block->>'href')>2048 OR (block->>'href') !~ '^(https://[^[:space:]]+|/[A-Za-z0-9][A-Za-z0-9._/#-]*)$' OR position('..' IN block->>'href')>0 THEN RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023'; END IF;
  ELSIF block->>'type'='list' THEN
   IF keys<>ARRAY['items','type'] OR jsonb_typeof(block->'items') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023'; END IF;
   IF jsonb_array_length(block->'items') NOT BETWEEN 1 AND 100 OR EXISTS(SELECT 1 FROM jsonb_array_elements(block->'items') x WHERE jsonb_typeof(x)<>'string' OR length(btrim(x#>>'{}')) NOT BETWEEN 1 AND 12000) THEN RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023'; END IF;
  ELSE RAISE EXCEPTION 'LEGAL_CONTENT_INVALID' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF NEW.content_canonical<>app_private.legal_canonical_content_v1(body) THEN RAISE EXCEPTION 'LEGAL_CONTENT_NOT_CANONICAL' USING ERRCODE='22023'; END IF;
 IF TG_OP='INSERT' THEN NEW.created_at:=clock_timestamp(); END IF;
 RETURN NEW;
END;$fn$;

CREATE FUNCTION app_private.legal_resolve_bundle_core_v1(p_context text,p_resource_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE actor uuid:=auth.uid(); tenant uuid; owner_id uuid; required_types text[]; documents jsonb; wanted bigint; complete boolean;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE user_id=actor) THEN RAISE EXCEPTION 'LEGAL_AUTH_REQUIRED' USING ERRCODE='42501'; END IF;
 IF p_context IS NULL OR p_context NOT IN ('account','booking','event_registration','event_promotion') THEN RAISE EXCEPTION 'LEGAL_CONTEXT_INVALID' USING ERRCODE='22023'; END IF;
 IF p_context='account' THEN
  IF p_resource_id IS NOT NULL THEN RAISE EXCEPTION 'LEGAL_CONTEXT_INVALID' USING ERRCODE='22023'; END IF;
  required_types:=ARRAY['platform_terms','platform_privacy_notice','adult_self_declaration'];
 ELSE
  IF p_context='booking' THEN
   SELECT tenant_id INTO tenant FROM public.shooting_lanes WHERE id=p_resource_id;
   IF tenant IS NULL OR public.get_my_tenant_role_v1(tenant) IS DISTINCT FROM 'user' THEN RAISE EXCEPTION 'LEGAL_RESOURCE_UNAVAILABLE' USING ERRCODE='42501'; END IF;
  ELSIF p_context='event_registration' THEN SELECT tenant_id INTO tenant FROM public.events WHERE id=p_resource_id;
  ELSE SELECT tenant_id,user_id INTO tenant,owner_id FROM public.event_registrations WHERE id=p_resource_id;
   IF owner_id IS DISTINCT FROM actor THEN RAISE EXCEPTION 'LEGAL_RESOURCE_UNAVAILABLE' USING ERRCODE='42501'; END IF;
  END IF;
  IF tenant IS NULL OR public.is_tenant_member_v1(tenant) IS NOT TRUE THEN RAISE EXCEPTION 'LEGAL_RESOURCE_UNAVAILABLE' USING ERRCODE='42501'; END IF;
  required_types:=ARRAY['platform_terms','platform_privacy_notice','tenant_regulations'];
  IF EXISTS(SELECT 1 FROM public.legal_documents WHERE tenant_id=tenant AND document_type='tenant_privacy_notice') THEN required_types:=required_types||'tenant_privacy_notice'::text; END IF;
 END IF;
 SELECT count(*) INTO wanted FROM public.legal_documents d JOIN public.legal_document_versions v ON v.id=d.current_version_id AND v.document_id=d.id
 WHERE d.document_type=ANY(required_types) AND (d.scope_type='platform' OR d.tenant_id=tenant) AND v.status='published' AND v.effective_at<=clock_timestamp();
 IF wanted<>cardinality(required_types) THEN RAISE EXCEPTION 'LEGAL_DOCUMENTS_UNAVAILABLE' USING ERRCODE='PT503'; END IF;
 SELECT jsonb_agg(jsonb_build_object('document_version_id',v.id,'document_type',d.document_type,'content_hash',encode(v.content_hash,'hex'),
  'kind',v.evidence_kind,'version',v.version,'canonical_path','/legal/documents/'||v.id::text,'requires_reacceptance',v.requires_reacceptance,
  'accepted_version_id',accepted.document_version_id,'acceptance_satisfied',accepted.document_version_id IS NOT NULL) ORDER BY v.id) INTO documents
 FROM public.legal_documents d JOIN public.legal_document_versions v ON v.id=d.current_version_id
 LEFT JOIN LATERAL (
  SELECT receipt.document_version_id FROM app_private.legal_acceptances receipt JOIN app_private.legal_actions a ON a.id=receipt.action_id
  JOIN app_private.legal_subjects s ON s.id=a.subject_id JOIN public.legal_document_versions accepted_v ON accepted_v.id=receipt.document_version_id
  WHERE s.user_id=actor AND accepted_v.document_id=d.id AND accepted_v.acceptance_anchor_version_id=v.acceptance_anchor_version_id AND receipt.acceptance_kind=v.evidence_kind
   AND (d.scope_type='platform' OR a.tenant_id=tenant)
   AND (p_context<>'event_promotion' OR a.event_registration_id=p_resource_id)
  ORDER BY a.accepted_at DESC,a.id DESC LIMIT 1
 ) accepted ON true
 WHERE d.document_type=ANY(required_types) AND (d.scope_type='platform' OR d.tenant_id=tenant);
 SELECT coalesce(bool_and((x->>'acceptance_satisfied')::boolean),false) INTO complete FROM jsonb_array_elements(documents) x;
 RETURN jsonb_build_object('context',p_context,'tenant_id',tenant,'required_documents',documents,'needs_reacceptance',NOT complete,
  'pre_registry_no_evidence',NOT EXISTS(SELECT 1 FROM app_private.legal_actions a JOIN app_private.legal_subjects s ON s.id=a.subject_id WHERE s.user_id=actor),
  'promotion_reacceptance_required',CASE WHEN p_context='event_promotion' THEN NOT complete ELSE NULL END);
END;$fn$;

CREATE FUNCTION app_private.legal_assert_bundle_core_v1(p_context text,p_resource_id uuid,p_presented jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE result jsonb; expected jsonb;
BEGIN
 IF p_presented IS NULL OR jsonb_typeof(p_presented)<>'array' THEN RAISE EXCEPTION 'LEGAL_BUNDLE_INVALID' USING ERRCODE='22023'; END IF;
 IF jsonb_array_length(p_presented) NOT BETWEEN 1 AND 8 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_presented) x WHERE jsonb_typeof(x)<>'object') THEN RAISE EXCEPTION 'LEGAL_BUNDLE_INVALID' USING ERRCODE='22023'; END IF;
 result:=app_private.legal_resolve_bundle_core_v1(p_context,p_resource_id);
 -- The current descriptor is re-read only after all logical documents are locked.
 PERFORM 1 FROM public.legal_documents d WHERE d.id IN (SELECT v.document_id FROM public.legal_document_versions v WHERE v.id IN (SELECT (x->>'document_version_id')::uuid FROM jsonb_array_elements(result->'required_documents') x)) ORDER BY d.id FOR SHARE;
 result:=app_private.legal_resolve_bundle_core_v1(p_context,p_resource_id);
 SELECT jsonb_agg(jsonb_build_object('document_version_id',x->'document_version_id','content_hash',x->'content_hash','kind',x->'kind') ORDER BY x->>'document_version_id') INTO expected FROM jsonb_array_elements(result->'required_documents') x;
 SELECT jsonb_agg(x ORDER BY x->>'document_version_id') INTO p_presented FROM jsonb_array_elements(p_presented) x;
 IF p_presented IS DISTINCT FROM expected THEN RAISE EXCEPTION 'LEGAL_VERSION_CHANGED' USING ERRCODE='PT409'; END IF;
 RETURN result;
END;$fn$;

CREATE FUNCTION app_private.legal_evidence_guard_v1() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE action app_private.legal_actions; ver public.legal_document_versions; doc public.legal_documents; actor uuid:=auth.uid(); expected uuid[]; actual uuid[]; target uuid; bundle jsonb;
BEGIN
 IF TG_WHEN='AFTER' THEN
  IF TG_TABLE_NAME='legal_actions' THEN target:=NEW.id; ELSE target:=NEW.action_id; END IF;
  SELECT * INTO STRICT action FROM app_private.legal_actions WHERE id=target;
  SELECT array_agg(document_version_id ORDER BY document_version_id) INTO actual FROM app_private.legal_acceptances WHERE action_id=target;
  IF actual IS DISTINCT FROM action.required_document_version_ids THEN RAISE EXCEPTION 'LEGAL_EVIDENCE_INCOMPLETE' USING ERRCODE='23514'; END IF;
  RETURN NULL;
 END IF;
 IF TG_TABLE_NAME='legal_subjects' THEN
  IF TG_OP='UPDATE' AND NEW.id=OLD.id AND OLD.user_id IS NOT NULL AND NEW.user_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP='INSERT' AND NEW.user_id=actor AND EXISTS(SELECT 1 FROM public.profiles WHERE user_id=actor) THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'LEGAL_SUBJECT_IMMUTABLE' USING ERRCODE='42501';
 END IF;
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'LEGAL_EVIDENCE_IMMUTABLE' USING ERRCODE='42501'; END IF;
 IF TG_TABLE_NAME='legal_actions' THEN
  IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM app_private.legal_subjects s JOIN public.profiles p ON p.user_id=s.user_id WHERE s.id=NEW.subject_id AND s.user_id=actor) THEN RAISE EXCEPTION 'LEGAL_ACTOR_INVALID' USING ERRCODE='42501'; END IF;
  IF NEW.context_type IN ('registration','account_reacceptance') THEN bundle:=app_private.legal_resolve_bundle_core_v1('account',NULL);
  ELSIF NEW.context_type='booking' THEN
   SELECT r.lane_id INTO target FROM public.reservations r
    JOIN public.shooting_lanes l ON l.id=r.lane_id AND l.tenant_id=r.tenant_id
    WHERE r.id=NEW.reservation_id AND r.tenant_id=NEW.tenant_id AND r.user_id=actor
    FOR SHARE OF r,l;
   IF target IS NULL THEN RAISE EXCEPTION 'LEGAL_RESOURCE_UNAVAILABLE' USING ERRCODE='42501'; END IF;
   bundle:=app_private.legal_resolve_bundle_core_v1('booking',target);
  ELSE
   SELECT r.event_id INTO target FROM public.event_registrations r
    JOIN public.events e ON e.id=r.event_id AND e.tenant_id=r.tenant_id
    WHERE r.id=NEW.event_registration_id AND r.tenant_id=NEW.tenant_id AND r.user_id=actor
    FOR SHARE OF r,e;
   IF target IS NULL THEN RAISE EXCEPTION 'LEGAL_RESOURCE_UNAVAILABLE' USING ERRCODE='42501'; END IF;
   bundle:=app_private.legal_resolve_bundle_core_v1('event_registration',target);
  END IF;
  SELECT array_agg((x->>'document_version_id')::uuid ORDER BY (x->>'document_version_id')::uuid) INTO expected FROM jsonb_array_elements(bundle->'required_documents') x;
  IF NEW.required_document_version_ids IS DISTINCT FROM expected OR NEW.tenant_id IS DISTINCT FROM (bundle->>'tenant_id')::uuid THEN RAISE EXCEPTION 'LEGAL_BUNDLE_INVALID' USING ERRCODE='23514'; END IF;
  PERFORM 1 FROM public.legal_documents d JOIN public.legal_document_versions v ON v.document_id=d.id WHERE v.id=ANY(expected) ORDER BY d.id FOR SHARE OF d;
  IF EXISTS(SELECT 1 FROM public.legal_document_versions v JOIN public.legal_documents d ON d.id=v.document_id WHERE v.id=ANY(expected) AND (d.current_version_id IS DISTINCT FROM v.id OR v.status<>'published' OR v.effective_at>clock_timestamp())) THEN
   RAISE EXCEPTION 'LEGAL_VERSION_CHANGED' USING ERRCODE='PT409';
  END IF;
  -- No public business evidence writer in this phase; future wrappers must validate offers atomically.
  IF NEW.offer_snapshot IS NOT NULL THEN
   IF jsonb_typeof(NEW.offer_snapshot)<>'object' OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(NEW.offer_snapshot) k) IS DISTINCT FROM ARRAY['amount_minor','cancellation_hours','currency','payment'] OR
    jsonb_typeof(NEW.offer_snapshot->'amount_minor') IS DISTINCT FROM 'number' OR (NEW.offer_snapshot->>'amount_minor') !~ '^[0-9]{1,12}$' OR
    NEW.offer_snapshot->>'currency' IS DISTINCT FROM 'PLN' OR NEW.offer_snapshot->>'payment' IS DISTINCT FROM 'pay_on_site' OR
    NEW.offer_snapshot->>'cancellation_hours' IS DISTINCT FROM (CASE WHEN NEW.context_type='booking' THEN '12' ELSE '72' END) THEN RAISE EXCEPTION 'LEGAL_OFFER_INVALID' USING ERRCODE='23514'; END IF;
  END IF;
  NEW.accepted_at:=clock_timestamp();
  RETURN NEW;
 END IF;
 SELECT * INTO STRICT action FROM app_private.legal_actions WHERE id=NEW.action_id;
 SELECT * INTO STRICT ver FROM public.legal_document_versions WHERE id=NEW.document_version_id;
 SELECT * INTO STRICT doc FROM public.legal_documents WHERE id=ver.document_id;
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM app_private.legal_subjects WHERE id=action.subject_id AND user_id=actor) OR
  NOT(NEW.document_version_id=ANY(action.required_document_version_ids)) OR NEW.acceptance_kind<>ver.evidence_kind OR ver.status<>'published' OR
  ver.effective_at>action.accepted_at OR doc.current_version_id IS DISTINCT FROM ver.id OR (doc.scope_type='tenant' AND doc.tenant_id IS DISTINCT FROM action.tenant_id) THEN
  RAISE EXCEPTION 'LEGAL_EVIDENCE_INVALID' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END;$fn$;

CREATE FUNCTION app_private.legal_finish_action_core_v1(p_request_id uuid,p_presented jsonb,p_confirmations jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE actor uuid:=auth.uid(); subject uuid; action app_private.legal_actions; hash bytea; bundle jsonb; ids uuid[]; item jsonb; context text;
BEGIN
 IF actor IS NULL THEN RAISE EXCEPTION 'LEGAL_AUTH_REQUIRED' USING ERRCODE='42501'; END IF;
 IF p_request_id IS NULL OR p_confirmations IS DISTINCT FROM '{"acceptance":true,"acknowledgement":true,"self_declaration":true}'::jsonb OR p_presented IS NULL OR jsonb_typeof(p_presented)<>'array' THEN RAISE EXCEPTION 'LEGAL_CONFIRMATION_REQUIRED' USING ERRCODE='22023'; END IF;
 IF jsonb_array_length(p_presented) NOT BETWEEN 1 AND 8 OR octet_length(p_presented::text)>4096 OR
    EXISTS(SELECT 1 FROM jsonb_array_elements(p_presented) x WHERE jsonb_typeof(x)<>'object') THEN RAISE EXCEPTION 'LEGAL_BUNDLE_INVALID' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(actor::text,0));
 PERFORM 1 FROM public.profiles WHERE user_id=actor FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'LEGAL_AUTH_REQUIRED' USING ERRCODE='42501'; END IF;
 SELECT jsonb_agg(x ORDER BY x->>'document_version_id') INTO p_presented FROM jsonb_array_elements(p_presented) x;
 hash:=extensions.digest(app_private.legal_canonical_content_v1(jsonb_build_object('operation','account_acceptance_v1','presented',p_presented,'confirmations',p_confirmations)),'sha256');
 SELECT id INTO subject FROM app_private.legal_subjects WHERE user_id=actor;
 SELECT * INTO action FROM app_private.legal_actions WHERE subject_id=subject AND request_id=p_request_id;
 IF FOUND THEN
  IF action.request_hash<>hash THEN RAISE EXCEPTION 'LEGAL_IDEMPOTENCY_CONFLICT' USING ERRCODE='PT409'; END IF;
  RETURN jsonb_build_object('ok',true,'changed',false,'action_id',action.id,'accepted_at',action.accepted_at);
 END IF;
 SELECT * INTO action FROM app_private.legal_actions WHERE subject_id=subject AND request_hash=hash AND context_type IN ('registration','account_reacceptance');
 IF FOUND THEN RETURN jsonb_build_object('ok',true,'changed',false,'action_id',action.id,'accepted_at',action.accepted_at); END IF;
 bundle:=app_private.legal_assert_bundle_core_v1('account',NULL,p_presented);
 IF subject IS NULL THEN INSERT INTO app_private.legal_subjects(user_id) VALUES(actor) RETURNING id INTO subject; END IF;
 context:=CASE WHEN EXISTS(SELECT 1 FROM app_private.legal_actions WHERE subject_id=subject) THEN 'account_reacceptance' ELSE 'registration' END;
 SELECT array_agg((x->>'document_version_id')::uuid ORDER BY (x->>'document_version_id')::uuid) INTO ids FROM jsonb_array_elements(bundle->'required_documents') x;
 -- The RPC is complete before it returns, including when its caller selected IMMEDIATE.
 SET CONSTRAINTS app_private.legal_action_complete,app_private.legal_acceptance_complete DEFERRED;
 INSERT INTO app_private.legal_actions(subject_id,context_type,request_id,request_hash,outcome,required_document_version_ids)
 VALUES(subject,context,p_request_id,hash,CASE WHEN context='registration' THEN 'account_completed' ELSE 'account_reaccepted' END,ids) RETURNING * INTO action;
 FOR item IN SELECT value FROM jsonb_array_elements(bundle->'required_documents') LOOP
  INSERT INTO app_private.legal_acceptances(action_id,document_version_id,acceptance_kind) VALUES(action.id,(item->>'document_version_id')::uuid,item->>'kind');
 END LOOP;
 IF (SELECT count(*) FROM app_private.legal_acceptances WHERE action_id=action.id)<>cardinality(ids) THEN RAISE EXCEPTION 'LEGAL_EVIDENCE_INCOMPLETE' USING ERRCODE='23514'; END IF;
 SET CONSTRAINTS app_private.legal_action_complete,app_private.legal_acceptance_complete IMMEDIATE;
 RETURN jsonb_build_object('ok',true,'changed',true,'action_id',action.id,'accepted_at',action.accepted_at);
END;$fn$;

CREATE FUNCTION app_private.legal_detach_subject_core_v1() RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $fn$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'LEGAL_AUTH_REQUIRED' USING ERRCODE='42501'; END IF;
 UPDATE app_private.legal_subjects SET user_id=NULL WHERE user_id=auth.uid();
END;$fn$;

CREATE FUNCTION app_private.legal_publish_version_core_v1(p_version_id uuid,p_expected_current uuid,p_effective_at timestamptz DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE ver public.legal_document_versions; doc public.legal_documents; previous public.legal_document_versions; stamp timestamptz:=clock_timestamp();
BEGIN
 SELECT * INTO ver FROM public.legal_document_versions WHERE id=p_version_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'LEGAL_VERSION_UNAVAILABLE' USING ERRCODE='22023'; END IF;
 SELECT * INTO STRICT doc FROM public.legal_documents WHERE id=ver.document_id FOR UPDATE;
 SELECT * INTO STRICT ver FROM public.legal_document_versions WHERE id=p_version_id FOR UPDATE;
 stamp:=clock_timestamp();
 IF doc.current_version_id IS DISTINCT FROM p_expected_current THEN RAISE EXCEPTION 'LEGAL_PUBLICATION_CONFLICT' USING ERRCODE='PT409'; END IF;
 IF ver.status='retired' OR doc.current_version_id=ver.id THEN RAISE EXCEPTION 'LEGAL_VERSION_IMMUTABLE' USING ERRCODE='42501'; END IF;
 SELECT * INTO previous FROM public.legal_document_versions WHERE id=doc.current_version_id;
 IF NOT ver.requires_reacceptance AND (previous.id IS NULL OR previous.evidence_kind<>ver.evidence_kind) THEN RAISE EXCEPTION 'LEGAL_REACCEPTANCE_POLICY_INVALID' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM public.legal_document_versions WHERE document_id=doc.id AND status='published' AND effective_at>stamp AND id<>ver.id) THEN RAISE EXCEPTION 'LEGAL_FUTURE_VERSION_EXISTS' USING ERRCODE='23514'; END IF;
 IF ver.status='draft' THEN
  IF p_effective_at IS NOT NULL AND p_effective_at<stamp THEN RAISE EXCEPTION 'LEGAL_EFFECTIVE_DATE_INVALID' USING ERRCODE='22023'; END IF;
  UPDATE public.legal_document_versions SET status='published',published_at=stamp,effective_at=coalesce(p_effective_at,stamp),
   acceptance_anchor_version_id=CASE WHEN requires_reacceptance THEN id ELSE previous.acceptance_anchor_version_id END WHERE id=ver.id RETURNING * INTO ver;
 ELSE
  IF p_effective_at IS NOT NULL OR (NOT ver.requires_reacceptance AND ver.acceptance_anchor_version_id IS DISTINCT FROM previous.acceptance_anchor_version_id) THEN RAISE EXCEPTION 'LEGAL_PUBLICATION_CONFLICT' USING ERRCODE='PT409'; END IF;
 END IF;
 IF ver.effective_at<=stamp THEN
  UPDATE public.legal_documents SET current_version_id=ver.id WHERE id=doc.id;
  IF previous.id IS NOT NULL THEN UPDATE public.legal_document_versions SET status='retired',retired_at=clock_timestamp() WHERE id=previous.id; END IF;
 END IF;
 RETURN jsonb_build_object('version_id',ver.id,'published',true,'active',ver.effective_at<=stamp,'content_hash',encode(ver.content_hash,'hex'));
END;$fn$;

CREATE FUNCTION public.get_published_legal_document_v1(p_document_type text DEFAULT NULL,p_tenant_id uuid DEFAULT NULL,p_version_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE result jsonb;
BEGIN
 IF (p_version_id IS NOT NULL AND (p_document_type IS NOT NULL OR p_tenant_id IS NOT NULL)) OR (p_version_id IS NULL AND p_document_type IS NULL) THEN RAISE EXCEPTION 'LEGAL_SELECTOR_INVALID' USING ERRCODE='22023'; END IF;
 SELECT jsonb_build_object('document_version_id',v.id,'document_type',d.document_type,'scope_type',d.scope_type,'tenant_id',d.tenant_id,'version',v.version,
  'status',v.status,'published_at',v.published_at,'effective_at',v.effective_at,'content_canonical',v.content_canonical,'content_hash',encode(v.content_hash,'hex'),
  'kind',v.evidence_kind,'requires_reacceptance',v.requires_reacceptance,'canonical_path','/legal/documents/'||v.id::text) INTO result
 FROM public.legal_documents d JOIN public.legal_document_versions v ON v.document_id=d.id
 WHERE v.published_at IS NOT NULL AND v.status IN ('published','retired') AND
  ((p_version_id IS NOT NULL AND v.id=p_version_id) OR (p_version_id IS NULL AND d.document_type=p_document_type AND d.tenant_id IS NOT DISTINCT FROM p_tenant_id AND d.current_version_id=v.id AND v.status='published' AND v.effective_at<=statement_timestamp()));
 RETURN result;
END;$fn$;

CREATE FUNCTION public.get_my_legal_requirements_v1(p_context text DEFAULT 'account',p_resource_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $fn$
BEGIN RETURN app_private.legal_resolve_bundle_core_v1(p_context,p_resource_id); END;$fn$;

CREATE FUNCTION public.accept_my_account_legal_v1(p_request_id uuid,p_presented jsonb,p_confirmations jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $fn$
BEGIN RETURN app_private.legal_finish_action_core_v1(p_request_id,p_presented,p_confirmations); END;$fn$;

CREATE FUNCTION public.get_my_legal_acceptances_v1(p_before_time timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL,p_limit integer DEFAULT 50) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $fn$
DECLARE result jsonb; actor uuid:=auth.uid();
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE user_id=actor) THEN RAISE EXCEPTION 'LEGAL_AUTH_REQUIRED' USING ERRCODE='42501'; END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR (p_before_time IS NULL)<>(p_before_id IS NULL) THEN RAISE EXCEPTION 'LEGAL_CURSOR_INVALID' USING ERRCODE='22023'; END IF;
 SELECT coalesce(jsonb_agg(x.row ORDER BY x.accepted_at DESC,x.id DESC),'[]'::jsonb) INTO result FROM (
  SELECT a.id,a.accepted_at,jsonb_build_object('action_id',a.id,'context_type',a.context_type,'tenant_id',a.tenant_id,'reservation_id',a.reservation_id,
    'event_registration_id',a.event_registration_id,'accepted_at',a.accepted_at,'outcome',a.outcome,'offer_snapshot',a.offer_snapshot,
    'documents',(SELECT jsonb_agg(jsonb_build_object('document_version_id',v.id,'document_type',d.document_type,'version',v.version,'content_hash',encode(v.content_hash,'hex'),'kind',r.acceptance_kind,'canonical_path','/legal/documents/'||v.id::text) ORDER BY v.id)
     FROM app_private.legal_acceptances r JOIN public.legal_document_versions v ON v.id=r.document_version_id JOIN public.legal_documents d ON d.id=v.document_id WHERE r.action_id=a.id)) row
  FROM app_private.legal_actions a JOIN app_private.legal_subjects s ON s.id=a.subject_id WHERE s.user_id=actor AND
    (p_before_time IS NULL OR (a.accepted_at,a.id)<(p_before_time,p_before_id)) ORDER BY a.accepted_at DESC,a.id DESC LIMIT p_limit
 ) x;
 RETURN result;
END;$fn$;

DO $guards$
DECLARE tab text;
BEGIN
 FOREACH tab IN ARRAY ARRAY['legal_documents','legal_document_versions'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',tab);
  EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated,service_role',tab);
  EXECUTE format('CREATE TRIGGER legal_registry_guard BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION app_private.legal_registry_guard_v1()',tab);
  EXECUTE format('CREATE TRIGGER legal_registry_truncate_guard BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION app_private.legal_registry_guard_v1()',tab);
 END LOOP;
 FOREACH tab IN ARRAY ARRAY['legal_subjects','legal_actions','legal_acceptances'] LOOP
  EXECUTE format('ALTER TABLE app_private.%I ENABLE ROW LEVEL SECURITY',tab);
  EXECUTE format('REVOKE ALL ON app_private.%I FROM PUBLIC,anon,authenticated,service_role',tab);
  EXECUTE format('CREATE TRIGGER legal_evidence_guard BEFORE INSERT OR UPDATE OR DELETE ON app_private.%I FOR EACH ROW EXECUTE FUNCTION app_private.legal_evidence_guard_v1()',tab);
  EXECUTE format('CREATE TRIGGER legal_evidence_truncate_guard BEFORE TRUNCATE ON app_private.%I FOR EACH STATEMENT EXECUTE FUNCTION app_private.legal_evidence_guard_v1()',tab);
 END LOOP;
END;$guards$;
CREATE CONSTRAINT TRIGGER legal_action_complete AFTER INSERT ON app_private.legal_actions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION app_private.legal_evidence_guard_v1();
CREATE CONSTRAINT TRIGGER legal_acceptance_complete AFTER INSERT ON app_private.legal_acceptances DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION app_private.legal_evidence_guard_v1();

REVOKE ALL ON FUNCTION public.get_published_legal_document_v1(text,uuid,uuid),public.get_my_legal_requirements_v1(text,uuid),public.accept_my_account_legal_v1(uuid,jsonb,jsonb),public.get_my_legal_acceptances_v1(timestamptz,uuid,integer) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_published_legal_document_v1(text,uuid,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_legal_requirements_v1(text,uuid),public.accept_my_account_legal_v1(uuid,jsonb,jsonb),public.get_my_legal_acceptances_v1(timestamptz,uuid,integer) TO authenticated;
REVOKE ALL ON FUNCTION app_private.legal_canonical_content_v1(jsonb),app_private.legal_registry_guard_v1(),app_private.legal_evidence_guard_v1(),app_private.legal_resolve_bundle_core_v1(text,uuid),app_private.legal_assert_bundle_core_v1(text,uuid,jsonb),app_private.legal_finish_action_core_v1(uuid,jsonb,jsonb),app_private.legal_detach_subject_core_v1(),app_private.legal_publish_version_core_v1(uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated,service_role;

-- Lifecycle and dependency integration follows below. No changes to business writers.

-- Detach only: existing lifecycle authority and transaction are preserved.
CREATE OR REPLACE FUNCTION public.anonymize_my_account_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_user_id uuid:=auth.uid();
  v_now timestamptz:=pg_catalog.transaction_timestamp();
  v_pseudonym_hash text;
  v_pseudonym_id uuid;
  v_pseudonym text;
  v_pseudonym_email text;
  v_profile public.profiles%rowtype;
  v_direct_values text[]:='{}'::text[];
  v_reservation_ids uuid[]:='{}'::uuid[];
  v_registration_ids uuid[]:='{}'::uuid[];
  v_reservation_count integer:=0;
  v_registration_count integer:=0;
  v_delivery_count integer:=0;
  v_rate_limit_count integer:=0;
  v_membership_count integer:=0;
  v_verification_count integer:=0;
  v_note_count integer:=0;
  v_audit_count integer:=0;
  v_membership public.tenant_memberships%rowtype;
  v_active_admin_count bigint;
begin
  if v_user_id is null then
    raise exception 'Authentication is required.' using errcode='42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text,0));

  v_pseudonym_hash:=pg_catalog.md5(v_user_id::text||':csk-sec009-v1');
  v_pseudonym_id:=(
    pg_catalog.substr(v_pseudonym_hash,1,8)||'-'||
    pg_catalog.substr(v_pseudonym_hash,9,4)||'-'||
    pg_catalog.substr(v_pseudonym_hash,13,4)||'-'||
    pg_catalog.substr(v_pseudonym_hash,17,4)||'-'||
    pg_catalog.substr(v_pseudonym_hash,21,12)
  )::uuid;
  v_pseudonym:='deleted-user-'||pg_catalog.substr(v_pseudonym_hash,1,16);
  v_pseudonym_email:=v_pseudonym||'@invalid.local';

  select pg_catalog.count(*) into v_audit_count
  from public.audit_logs audit
  where audit.action='account_anonymized'
    and audit.actor_user_id=v_pseudonym_id
    and audit.target_type='account'
    and audit.target_id=v_pseudonym_id;
  if v_audit_count>1 then
    raise exception 'Account lifecycle state is ambiguous.' using errcode='P0001';
  end if;
  if v_audit_count=1 then
    return pg_catalog.jsonb_build_object('ok',true,'changed',false,'code','already_anonymized');
  end if;

  select profile.* into v_profile
  from public.profiles profile
  where profile.user_id=v_user_id
  for update;

  for v_membership in
    select membership.*
    from public.tenant_memberships membership
    where membership.user_id=v_user_id
    order by membership.tenant_id
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(v_membership.tenant_id::text,9401)
    );
    perform 1 from public.tenant_memberships membership
    where membership.tenant_id=v_membership.tenant_id
    order by membership.user_id
    for update;
    if v_membership.status='active' and v_membership.role='admin' then
      perform public.tenant_assert_admin_loss_core_v1(v_membership.tenant_id,v_user_id);
    end if;
  end loop;

  select coalesce(pg_catalog.array_agg(reservation.id order by reservation.id),'{}'::uuid[])
  into v_reservation_ids from public.reservations reservation where reservation.user_id=v_user_id;
  select coalesce(pg_catalog.array_agg(registration.id order by registration.id),'{}'::uuid[])
  into v_registration_ids from public.event_registrations registration where registration.user_id=v_user_id;

  select coalesce(pg_catalog.array_agg(distinct source.value) filter(where source.value is not null and source.value<>''),'{}'::text[])
  into v_direct_values
  from(
    select value from pg_catalog.unnest(array[
      v_profile.id::text,v_profile.first_name,v_profile.last_name,v_profile.full_name,
      v_profile.email,v_profile.phone,v_profile.postal_code,v_profile.city,
      v_profile.street,v_profile.house_number,v_profile.apartment_number,
      v_profile.weapon_permit_number,v_profile.weapon_permit_type,
      v_profile.weapon_permit_issuer,v_profile.range_officer_number,
      v_profile.instructor_number,v_profile.admin_note,v_profile.verification_note,
      v_profile.permissions_verification_note
    ]::text[]) value
    union all select reservation.customer_name from public.reservations reservation where reservation.user_id=v_user_id
    union all select reservation.customer_email from public.reservations reservation where reservation.user_id=v_user_id
    union all select reservation.customer_phone from public.reservations reservation where reservation.user_id=v_user_id
    union all select reservation.reservation_note from public.reservations reservation where reservation.user_id=v_user_id
    union all select reservation.admin_note from public.reservations reservation where reservation.user_id=v_user_id
    union all select registration.customer_name from public.event_registrations registration where registration.user_id=v_user_id
    union all select registration.customer_email from public.event_registrations registration where registration.user_id=v_user_id
    union all select registration.customer_phone from public.event_registrations registration where registration.user_id=v_user_id
    union all select note.admin_note from public.tenant_user_admin_notes note where note.user_id=v_user_id
    union all select verification.permissions_verification_note from public.tenant_user_verifications verification where verification.user_id=v_user_id
  ) source;

  update public.reservations reservation set
    user_id=null,customer_name=v_pseudonym,customer_email=v_pseudonym_email,
    customer_phone='[redacted]',admin_note=null,reservation_note=null,
    check_in_token=null,pii_anonymized_at=v_now
  where reservation.user_id=v_user_id;
  get diagnostics v_reservation_count=row_count;

  update public.event_registrations registration set
    user_id=null,customer_name=v_pseudonym,customer_email=v_pseudonym_email,
    customer_phone='[redacted]',promotion_token=null,
    promotion_token_expires_at=null,promotion_claim_id=null,
    promotion_claim_expires_at=null,promotion_attempt_count=0,
    promotion_last_attempt_at=null,promotion_last_error_code=null,
    pii_anonymized_at=v_now
  where registration.user_id=v_user_id;
  get diagnostics v_registration_count=row_count;

  update public.audit_logs audit set
    actor_user_id=case when audit.actor_user_id=v_user_id then v_pseudonym_id else audit.actor_user_id end,
    actor_name=case when audit.actor_user_id=v_user_id then v_pseudonym else audit.actor_name end,
    target_id=case when audit.target_type in('profile','account') and audit.target_id=v_user_id then v_pseudonym_id else audit.target_id end,
    target_name=case when audit.target_id=v_user_id then v_pseudonym else audit.target_name end,
    details=public.redact_account_audit_details_v1(audit.details,v_user_id,v_pseudonym,v_direct_values)
  where audit.actor_user_id=v_user_id
     or (audit.target_type in('profile','account','tenant_user_admin_note','tenant_user_verification','tenant_user_role','tenant_user_identity','tenant_user_contact') and audit.target_id=v_user_id)
     or audit.target_id=any(v_reservation_ids)
     or audit.target_id=any(v_registration_ids);

  delete from public.email_deliveries delivery where delivery.recipient_user_id=v_user_id;
  get diagnostics v_delivery_count=row_count;
  delete from public.confirmation_email_rate_limits rate_limit
  where rate_limit.scope_type='user' and rate_limit.scope_key=v_user_id::text;
  get diagnostics v_rate_limit_count=row_count;
  delete from public.tenant_user_admin_notes note where note.user_id=v_user_id;
  get diagnostics v_note_count=row_count;
  delete from public.tenant_user_verifications verification where verification.user_id=v_user_id;
  get diagnostics v_verification_count=row_count;
  delete from public.tenant_memberships membership where membership.user_id=v_user_id;
  get diagnostics v_membership_count=row_count;

  update public.platform_audit_logs entry set
    actor_user_id=case when entry.actor_user_id=v_user_id then v_pseudonym_id else entry.actor_user_id end,
    details=public.redact_account_audit_details_v1(entry.details,v_user_id,v_pseudonym,v_direct_values)
  where entry.actor_user_id=v_user_id or entry.details->>'user_id'=v_user_id::text;
  update public.external_settlement_records entry set
    actor_user_id=case when entry.actor_user_id=v_user_id then v_pseudonym_id else entry.actor_user_id end,
    external_reference='[redacted]'
  where entry.actor_user_id=v_user_id or entry.reservation_id=any(v_reservation_ids) or entry.registration_id=any(v_registration_ids);
  delete from public.platform_admins where user_id=v_user_id;
  perform app_private.legal_detach_subject_core_v1();
  delete from public.profiles profile where profile.user_id=v_user_id;


  insert into public.audit_logs(
    tenant_id,actor_user_id,actor_name,actor_role,action,
    target_type,target_id,target_name,details
  ) values(
    null,v_pseudonym_id,v_pseudonym,'user','account_anonymized',
    'account',v_pseudonym_id,v_pseudonym,
    pg_catalog.jsonb_build_object(
      'anonymization_version',2,
      'reservation_count',v_reservation_count,
      'event_registration_count',v_registration_count,
      'email_delivery_count',v_delivery_count,
      'user_rate_limit_count',v_rate_limit_count,
      'tenant_membership_count',v_membership_count,
      'tenant_verification_count',v_verification_count,
      'tenant_admin_note_count',v_note_count,
      'anonymized_at',v_now
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok',true,'changed',true,'code','anonymized',
    'reservation_count',v_reservation_count,
    'event_registration_count',v_registration_count
  );
end;
$function$
;

-- Account-neutral aggregate dependency counts; hard delete remains prohibited.
CREATE OR REPLACE FUNCTION public.platform_get_tenant_delete_eligibility_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
 t public.tenants; catalog jsonb; summary jsonb:='{}'; blockers jsonb;
 is_public_value boolean; catalog_matches boolean;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 select * into t from public.tenants where id=p_tenant_id;
 if not found then raise exception 'TENANT_UNAVAILABLE' using errcode='22023'; end if;
 -- Deliberate policy blocker even for a physically empty synthetic tenant.
 -- This read is not a lock, deletion token, or authorization for future deletion.
 blockers:=jsonb_build_array(jsonb_build_object('code','HARD_DELETE_POLICY_DEFERRED','category','policy','count',1,'hard_blocker',true));
 if t.status<>'archived' then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','TENANT_NOT_ARCHIVED','category','lifecycle','count',1,'hard_blocker',true)); end if;
 select jsonb_build_object(
 'tables',(select jsonb_agg(n.nspname||'.'||c.relname order by n.nspname,c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances'))) and c.relkind in('r','p')),
 'columns',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||a.attname||':'||format_type(a.atttypid,a.atttypmod) order by n.nspname,c.relname,a.attnum) from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances'))) and c.relkind in('r','p') and a.attnum>0 and not a.attisdropped),
 'foreign_keys',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||k.conname||':'||pg_get_constraintdef(k.oid) order by n.nspname,c.relname,k.conname) from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace join pg_class parent on parent.oid=k.confrelid join pg_namespace pn on pn.oid=parent.relnamespace where k.contype='f' and (n.nspname='public' or pn.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances'))))
) into catalog;

 catalog_matches:=md5(catalog::text)='4fcf3efba37ae79bc2186d109d83872b';
 if not catalog_matches then
  -- Do not execute stale table/column queries if the catalog contract has changed.
  return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
   'lifecycle',jsonb_build_object('is_archived',t.status='archived','is_public',null),
   'eligibility',jsonb_build_object('can_hard_delete',false,'blocker_count',jsonb_array_length(blockers)+1),
   'blockers',blockers||jsonb_build_array(jsonb_build_object('code','UNKNOWN_DEPENDENCY','category','schema','count',1,'hard_blocker',true)),
   'warnings',jsonb_build_array('DEPENDENCY_COUNTS_UNAVAILABLE'),'dependency_summary',summary);
 end if;
 select coalesce(bool_or(p.is_public),false) into is_public_value from public.tenant_public_profiles p where p.tenant_id=t.id;
 if is_public_value then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','TENANT_PUBLIC','category','lifecycle','count',1,'hard_blocker',true)); end if;
 select jsonb_build_object(
 'legal_documents',(select count(*) from public.legal_documents d where d.tenant_id=p_tenant_id),
 'legal_document_versions',(select count(*) from public.legal_document_versions v join public.legal_documents d on d.id=v.document_id where d.tenant_id=p_tenant_id),
 'legal_actions',(select count(*) from app_private.legal_actions a where a.tenant_id=p_tenant_id),
 'legal_acceptances',(select count(*) from app_private.legal_acceptances r join app_private.legal_actions a on a.id=r.action_id where a.tenant_id=p_tenant_id),
 'audit_logs',(select count(*) from public.audit_logs x where x.tenant_id=p_tenant_id or x.target_id=p_tenant_id or exists(select 1 from public.reservations r where r.id=x.target_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.target_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.target_id and e.tenant_id=p_tenant_id) or exists(select 1 from public.shooting_lanes l where l.id=x.target_id and l.tenant_id=p_tenant_id)),
 'email_deliveries',(select count(*) from public.email_deliveries x where x.tenant_id=p_tenant_id or exists(select 1 from public.reservations r where r.id=x.record_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.record_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.record_id and e.tenant_id=p_tenant_id) or exists(select 1 from public.event_instructors i where i.id=x.record_id and i.tenant_id=p_tenant_id) or exists(select 1 from public.reminder_occurrences o join public.reminder_schedules s on s.id=o.schedule_id where o.id=x.record_id and (exists(select 1 from public.reservations r where r.id=s.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=s.event_id and e.tenant_id=p_tenant_id)))),
 'event_instructors',(select count(*) from public.event_instructors x where x.tenant_id=p_tenant_id),
 'event_lanes',(select count(*) from public.event_lanes x where x.tenant_id=p_tenant_id),
 'event_registrations',(select count(*) from public.event_registrations x where x.tenant_id=p_tenant_id),
 'events',(select count(*) from public.events x where x.tenant_id=p_tenant_id),
 'external_settlement_records',(select count(*) from public.external_settlement_records x where x.tenant_id=p_tenant_id),
 'lane_blocks',(select count(*) from public.lane_blocks x where x.tenant_id=p_tenant_id),
 'platform_admin_management_requests',(select count(*) from public.platform_admin_management_requests x where x.tenant_id=p_tenant_id),
 'platform_audit_logs',(select count(*) from public.platform_audit_logs x where x.tenant_id=p_tenant_id),
 'platform_plan_change_requests',(select count(*) from public.platform_plan_change_requests x where x.tenant_id=p_tenant_id),
 'platform_tenant_creation_requests',(select count(*) from public.platform_tenant_creation_requests x where x.tenant_id=p_tenant_id),
 'platform_tenant_lifecycle_requests',(select count(*) from public.platform_tenant_lifecycle_requests x where x.tenant_id=p_tenant_id),
 'reservations',(select count(*) from public.reservations x where x.tenant_id=p_tenant_id),
 'shooting_lanes',(select count(*) from public.shooting_lanes x where x.tenant_id=p_tenant_id),
 'tenant_domains',(select count(*) from public.tenant_domains x where x.tenant_id=p_tenant_id),
 'tenant_memberships',(select count(*) from public.tenant_memberships x where x.tenant_id=p_tenant_id),
 'tenant_plan_assignments',(select count(*) from public.tenant_plan_assignments x where x.tenant_id=p_tenant_id),
 'tenant_public_pricing_items',(select count(*) from public.tenant_public_pricing_items x where x.tenant_id=p_tenant_id),
 'tenant_public_profiles',(select count(*) from public.tenant_public_profiles x where x.tenant_id=p_tenant_id),
 'tenant_user_admin_notes',(select count(*) from public.tenant_user_admin_notes x where x.tenant_id=p_tenant_id),
 'tenant_user_verifications',(select count(*) from public.tenant_user_verifications x where x.tenant_id=p_tenant_id),
 'lane_booking_durations',(select count(*) from public.lane_booking_durations x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'lane_booking_family_configuration_versions',(select count(*) from public.lane_booking_family_configuration_versions x where exists(select 1 from public.shooting_lanes l where l.id=x.root_lane_id and l.tenant_id=p_tenant_id)),
 'lane_booking_rules',(select count(*) from public.lane_booking_rules x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'lane_pricing_rules',(select count(*) from public.lane_pricing_rules x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'reminder_schedules',(select count(*) from public.reminder_schedules x where exists(select 1 from public.reservations r where r.id=x.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.event_id and e.tenant_id=p_tenant_id)),
 'reminder_occurrences',(select count(*) from public.reminder_occurrences x where exists(select 1 from public.reservations r where r.id=x.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.registration_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.reminder_schedules s where s.id=x.schedule_id and (exists(select 1 from public.reservations r where r.id=s.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=s.event_id and e.tenant_id=p_tenant_id))))
 ) into summary;
 -- A global profile is not owned by a tenant. Only count related user links.
 summary:=summary||jsonb_build_object('profile_links',(select count(*) from (
  select user_id from public.tenant_memberships where tenant_id=t.id
  union select user_id from public.tenant_user_verifications where tenant_id=t.id
  union select user_id from public.tenant_user_admin_notes where tenant_id=t.id
  union select user_id from public.reservations where tenant_id=t.id
  union select user_id from public.event_registrations where tenant_id=t.id
  union select instructor_user_id from public.event_instructors where tenant_id=t.id
 ) links where user_id is not null));
 select blockers||coalesce(jsonb_agg(jsonb_build_object('code',code,'category',category,'count',(summary->>tab)::bigint,'hard_blocker',true) order by code),'[]'::jsonb) into blockers
 from (values ('legal_documents','LEGAL_DOCUMENTS_EXIST','history'),('legal_document_versions','LEGAL_VERSIONS_EXIST','history'),('legal_actions','LEGAL_ACTIONS_EXIST','history'),('legal_acceptances','LEGAL_ACCEPTANCES_EXIST','history'),('audit_logs','AUDIT_LOGS_EXIST','history'),
   ('email_deliveries','EMAIL_HISTORY_EXISTS','history'),
   ('event_instructors','EVENT_INSTRUCTORS_EXIST','business'),
   ('event_lanes','EVENT_LANES_EXIST','business'),
   ('event_registrations','EVENT_REGISTRATIONS_EXIST','business'),
   ('events','EVENTS_EXIST','business'),
   ('external_settlement_records','SETTLEMENTS_EXIST','history'),
   ('lane_blocks','LANE_BLOCKS_EXIST','business'),
   ('platform_admin_management_requests','PLATFORM_ADMIN_MANAGEMENT_REQUESTS_EXIST','lineage'),
   ('platform_audit_logs','PLATFORM_AUDIT_EXISTS','history'),
   ('platform_plan_change_requests','PLATFORM_PLAN_CHANGE_REQUESTS_EXIST','lineage'),
   ('platform_tenant_creation_requests','CREATION_LEDGER_EXISTS','lineage'),
   ('platform_tenant_lifecycle_requests','PLATFORM_TENANT_LIFECYCLE_REQUESTS_EXIST','lineage'),
   ('reservations','RESERVATIONS_EXIST','business'),
   ('shooting_lanes','SHOOTING_LANES_EXIST','configuration'),
   ('tenant_domains','CUSTOM_DOMAIN_EXISTS','configuration'),
   ('tenant_memberships','TENANT_MEMBERSHIPS_EXIST','lineage'),
   ('tenant_plan_assignments','PLAN_ASSIGNMENT_EXISTS','lineage'),
   ('tenant_public_pricing_items','TENANT_PUBLIC_PRICING_ITEMS_EXIST','configuration'),
   ('tenant_public_profiles','TENANT_PUBLIC_PROFILES_EXIST','configuration'),
   ('tenant_user_admin_notes','TENANT_USER_ADMIN_NOTES_EXIST','lineage'),
   ('tenant_user_verifications','TENANT_USER_VERIFICATIONS_EXIST','lineage'),
   ('lane_booking_durations','LANE_BOOKING_DURATIONS_EXIST','configuration'),
   ('lane_booking_family_configuration_versions','LANE_BOOKING_FAMILY_CONFIGURATION_VERSIONS_EXIST','configuration'),
   ('lane_booking_rules','LANE_BOOKING_RULES_EXIST','configuration'),
   ('lane_pricing_rules','LANE_PRICING_RULES_EXIST','configuration'),
   ('reminder_schedules','REMINDER_SCHEDULES_EXIST','history'),
   ('reminder_occurrences','REMINDER_HISTORY_EXISTS','history'),('profile_links','TENANT_PROFILE_LINKS_EXIST','lineage')) c(tab,code,category)
 where (summary->>tab)::bigint>0;
 return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
  'lifecycle',jsonb_build_object('is_archived',t.status='archived','is_public',is_public_value),
  'eligibility',jsonb_build_object('can_hard_delete',false,'blocker_count',jsonb_array_length(blockers)),
  'blockers',blockers,'warnings',jsonb_build_array('GLOBAL_ACCOUNTS_NOT_TENANT_OWNED','SNAPSHOT_ONLY_NOT_DELETE_AUTHORIZATION'),
  'dependency_summary',summary);
end;
$function$;

RESET lock_timeout;
RESET statement_timeout;
