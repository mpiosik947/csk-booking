-- NEW-TENANT-2C: local candidate; server-authoritative readiness, no handover/publication.
create table app_private.draft_configuration_epochs (
 tenant_id uuid primary key references public.tenants(id) on delete cascade,
 epoch bigint not null default 0 check(epoch>=0)
);
create table app_private.draft_readiness_validations (
 tenant_id uuid primary key references public.tenants(id) on delete cascade,
 configuration_revision text not null check(configuration_revision ~ '^[a-f0-9]{64}$'),
 validated_by uuid references auth.users(id) on delete set null,
 validated_at timestamptz not null default transaction_timestamp(),
 validation_version integer not null check(validation_version=1),
 checks jsonb not null check(jsonb_typeof(checks)='array')
);
alter table app_private.draft_configuration_epochs enable row level security;
alter table app_private.draft_readiness_validations enable row level security;
revoke all on app_private.draft_configuration_epochs,app_private.draft_readiness_validations from public,anon,authenticated,service_role;

create function app_private.bump_draft_config_epoch_v1(tid uuid) returns void
language plpgsql set search_path=pg_catalog,public,pg_temp as $$
begin
 if app_private.is_platform_draft_v1(tid) and exists(select 1 from public.tenants where id=tid) then
  insert into app_private.draft_configuration_epochs(tenant_id,epoch) values(tid,1)
  on conflict(tenant_id) do update set epoch=draft_configuration_epochs.epoch+1;
 end if;
end;$$;

create function app_private.track_draft_configuration_v1() returns trigger
language plpgsql set search_path=pg_catalog,public,pg_temp as $$
declare previous jsonb; next_value jsonb; row_value jsonb; tid uuid; previous_tid uuid;
 ignored constant text[]:=array['created_at','updated_at','assigned_at','revision','configuration_version'];
begin
 if tg_op<>'INSERT' then previous:=to_jsonb(old)-ignored; end if;
 if tg_op<>'DELETE' then next_value:=to_jsonb(new)-ignored; end if;
 if tg_table_name='saas_features' then previous:=previous-'description';next_value:=next_value-'description'; end if;
 if previous is not distinct from next_value then return null; end if;
 if tg_table_name in ('saas_plans','saas_plan_features','saas_features') then
  for tid in select distinct a.tenant_id from public.tenant_plan_assignments a
   where (tg_table_name='saas_plans' and a.plan_id::text in(previous->>'id',next_value->>'id'))
   or (tg_table_name='saas_plan_features' and a.plan_id::text in(previous->>'plan_id',next_value->>'plan_id'))
   or (tg_table_name='saas_features' and exists(select 1 from public.saas_plan_features f where f.plan_id=a.plan_id and f.feature_key in(previous->>'feature_key',next_value->>'feature_key')))
   order by a.tenant_id loop perform app_private.bump_draft_config_epoch_v1(tid); end loop;
 else
  for row_value in select value from jsonb_array_elements(jsonb_build_array(previous,next_value)) where value<>'null'::jsonb loop
   tid:=case when tg_table_name='tenants' then (row_value->>'id')::uuid
    when tg_table_name in ('lane_booking_rules','lane_booking_durations','lane_pricing_rules') then
     (select tenant_id from public.shooting_lanes where id=(row_value->>'lane_id')::uuid)
    else (row_value->>'tenant_id')::uuid end;
   if tid is not null and tid is distinct from previous_tid then perform app_private.bump_draft_config_epoch_v1(tid); previous_tid:=tid; end if;
  end loop;
 end if;
 return null;
end;$$;

create function app_private.draft_configuration_revision_v1(tid uuid) returns text
language sql stable set search_path=pg_catalog,public,pg_temp as $$
 with snapshot as(select app_private.draft_configuration_snapshot_v1(tid) value)
 select encode(sha256(convert_to(jsonb_build_object('configuration',jsonb_set(value,'{profile}',(value->'profile')-'updated_at'),
 'epoch',coalesce((select epoch from app_private.draft_configuration_epochs where tenant_id=tid),0))::text,'UTF8')),'hex')
 from snapshot;
$$;

create function app_private.lock_draft_readiness_v1(tid uuid) returns void
language plpgsql set search_path=pg_catalog,public,pg_temp as $$
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501';end if;
 perform 1 from public.platform_admins where user_id=auth.uid() and status='active' for share nowait;
 if not found then raise exception 'Not authorized' using errcode='42501';end if;
 perform 1 from public.tenants where id=tid for no key update nowait;
 if not found or not app_private.is_platform_draft_v1(tid) then raise exception 'Not authorized' using errcode='42501';end if;
 perform 1 from public.tenant_public_profiles where tenant_id=tid for update nowait;
 perform 1 from public.tenant_public_access_controls where tenant_id=tid for share nowait;
 perform 1 from public.tenant_plan_assignments where tenant_id=tid for share nowait;
 perform 1 from public.saas_plans order by id for share nowait;
 perform 1 from public.saas_plan_features order by plan_id,feature_key for share nowait;
 perform 1 from public.saas_features order by feature_key for share nowait;
 insert into app_private.draft_configuration_epochs(tenant_id,epoch) values(tid,0) on conflict do nothing;
 perform 1 from app_private.draft_configuration_epochs where tenant_id=tid for update nowait;
end;$$;

create function app_private.draft_readiness_checks_v1(tid uuid) returns jsonb
language sql stable set search_path=pg_catalog,public,pg_temp as $$
 with identity_flags as(select public.platform_tenant_readiness_core_v1(tid) flags),
 booking as(select * from public.get_public_booking_configuration_v1__saas9d4e_core(tid)),
 facts as(select t.*,p.display_name,p.city,p.is_public,p.logo_path,p.hero_image_path,p.public_address,p.public_email,p.public_phone,p.description,p.opening_hours,c.public_access_state,
 public.tenant_setup_has_feature_core_v1(tid,'booking') booking_required from public.tenants t
 left join public.tenant_public_profiles p on p.tenant_id=t.id left join public.tenant_public_access_controls c on c.tenant_id=t.id where t.id=tid),
 checks(ord,key,label,severity,passed,explanation) as (
 select 1,'identity','Dane obiektu i adresy','BLOCKER',coalesce((flags->>'identity_ready')::boolean and (flags->>'slug_ready')::boolean and (flags->>'settings_ready')::boolean,false)
 and not exists(select 1 from public.tenants a join public.tenants b on a.slug=b.slug and a.id<>b.id where a.id=tid)
 and not exists(select 1 from public.tenant_public_profiles a join public.tenant_public_profiles b on a.public_slug=b.public_slug and a.tenant_id<>b.tenant_id where a.tenant_id=tid),
 'Wymagane są poprawne, unikalne adresy oraz nazwa publiczna i miejscowość.' from identity_flags
 union all select 2,'safe_state','Bezpieczny stan draftu','BLOCKER',coalesce(status='dormant' and public_access_state='coming_soon' and not is_public,false),'Draft musi pozostać w konfiguracji, nieopublikowany i dostępny wkrótce.' from facts
 union all select 3,'plan','Aktywny plan','BLOCKER',coalesce((flags->>'plan_ready')::boolean,false),'Przed przekazaniem wymagany jest aktywny plan, zgodnie z istniejącym kontraktem gotowości.' from identity_flags
 union all select 4,'membership','Brak lokalnych członkostw','BLOCKER',not exists(select 1 from public.tenant_memberships where tenant_id=tid),'Ten etap wymaga 0 lokalnych członkostw; administrator zostanie przypisany później.'
 union all select 5,'resources','Struktura osi i stanowisk','BLOCKER',not exists(
  select 1 from public.shooting_lanes r left join public.shooting_lanes parent on parent.id=r.parent_lane_id and parent.tenant_id=r.tenant_id
  left join public.lane_booking_rules b on b.lane_id=r.id where r.tenant_id=tid and
   (length(btrim(r.name))=0 or b.lane_id is null or b.max_people_online>r.max_shooters or r.max_shooters<1
    or (r.resource_kind='lane' and r.parent_lane_id is not null)
    or (r.resource_kind='position' and (parent.id is null or parent.resource_kind<>'lane' or parent.parent_lane_id is not null or r.whole_lane_bookable or r.positions_bookable or (r.is_active and not parent.is_active)))
    or (r.resource_kind='lane' and r.positions_bookable and not exists(select 1 from booking child where child.parent_lane_id=r.id and child.effective_online_bookable))
    or (r.resource_kind='lane' and (select coalesce(sum(ch.max_shooters),0) from public.shooting_lanes ch where ch.parent_lane_id=r.id and ch.is_active)>r.max_shooters))),
 'Hierarchia, pojemności i tryby muszą spełniać obecne reguły konfiguracji osi.'
 union all select 6,'booking','Dostępna konfiguracja rezerwacji','BLOCKER',
  (not booking_required or exists(select 1 from booking where effective_online_bookable))
  and not exists(select 1 from public.shooting_lanes r join public.lane_booking_rules b on b.lane_id=r.id where r.tenant_id=tid and b.online_bookable and not exists(select 1 from booking c where c.lane_id=r.id and c.effective_online_bookable)),
 'Plan z rezerwacjami wymaga co najmniej jednego zasobu z kompletnymi czasami i cennikiem. Obowiązują istniejące reguły rezerwacji i anulowania.' from facts
 union all select 7,'prices','Poprawność cen','BLOCKER',not exists(select 1 from public.lane_pricing_rules p join public.shooting_lanes r on r.id=p.lane_id where r.tenant_id=tid and (p.hourly_price<0 or p.hourly_price::text in('NaN','Infinity','-Infinity')))
 and not exists(select 1 from public.tenant_public_pricing_items where tenant_id=tid and (price<0 or price::text in('NaN','Infinity','-Infinity'))),
 'Ceny muszą być nieujemne; pokrycie progów zasobów sprzedawanych online sprawdza istniejący silnik rezerwacji.'
 union all select 8,'durations','Kroki i czasy rezerwacji','BLOCKER',not exists(select 1 from public.shooting_lanes r left join public.lane_booking_durations d on d.lane_id=r.id and d.is_active where r.tenant_id=tid and
  (r.booking_step_minutes not between 1 and 1440 or (d.id is not null and (d.duration_minutes not between 1 and 1440 or d.duration_minutes % r.booking_step_minutes<>0)))),
 'Czasy muszą być dodatnimi wielokrotnościami kroku. Godziny publiczne są informacyjne; nie zmieniają obecnego okna 08:00–20:00.'
 union all select 9,'references','Integralność konfiguracji','BLOCKER',not exists(select 1 from public.shooting_lanes r where r.tenant_id=tid and r.resource_kind='lane' and not exists(select 1 from public.lane_booking_family_configuration_versions v where v.root_lane_id=r.id))
 and not exists(select 1 from public.shooting_lanes r where r.tenant_id=tid and r.resource_kind='position' and not exists(select 1 from public.shooting_lanes p where p.id=r.parent_lane_id and p.tenant_id=tid and p.resource_kind='lane')),
 'Osie i stanowiska muszą należeć do tego samego obiektu. Ich powiązania oraz zakresy cen muszą być spójne.'
 union all select 10,'branding','Logo i obraz główny','WARNING',logo_path is not null and hero_image_path is not null,'Opcjonalne obrazy można uzupełnić później.' from facts
 union all select 11,'contact','Publiczne dane kontaktowe','WARNING',public_address is not null and (public_email is not null or public_phone is not null),'Adres i kanał kontaktu są przydatne, ale obecny model nie wymaga opcjonalnych danych osobowych.' from facts
 union all select 12,'content','Opis publiczny','WARNING',description is not null,'Brak opcjonalnego opisu nie blokuje walidacji.' from facts
 union all select 13,'hours','Godziny informacyjne','WARNING',opening_hours is not null,'Godziny są informacyjne i nie sterują dostępnością rezerwacji.' from facts
 union all select 14,'partners','Partnerzy','WARNING',exists(select 1 from public.tenant_partners where tenant_id=tid and archived_at is null),'Partnerzy są opcjonalni; nie trzeba tworzyć danych partnera podczas wdrożenia.'
 ) select jsonb_agg(jsonb_build_object('key',key,'label',label,'severity',severity,'result',case when coalesce(passed,false) then 'PASS' else 'FAIL' end,'explanation',explanation) order by ord) from checks;
$$;

create function app_private.draft_readiness_result_v1(tid uuid) returns jsonb
language plpgsql stable set search_path=pg_catalog,public,pg_temp as $$
declare checks jsonb; revision text; proof app_private.draft_readiness_validations; passed boolean; current_proof boolean;
begin
 checks:=app_private.draft_readiness_checks_v1(tid);
 begin revision:=app_private.draft_configuration_revision_v1(tid);
 exception when others then revision:=null; checks:=checks||jsonb_build_array(jsonb_build_object('key','configuration_snapshot','label','Odczyt spójnej konfiguracji','severity','BLOCKER','result','FAIL','explanation','Konfiguracja nie spełnia bezpiecznego kontraktu odczytu.'));
 end;
 select * into proof from app_private.draft_readiness_validations where tenant_id=tid;
 passed:=revision is not null and not exists(select 1 from jsonb_array_elements(checks) c where c->>'severity'='BLOCKER' and c->>'result'='FAIL');
 current_proof:=passed and coalesce(proof.configuration_revision=revision and proof.validation_version=1,false);
 return jsonb_build_object('tenant_id',tid,'validation_version',1,'overall',case when passed then 'PASS' else 'FAIL' end,
 'state',case when current_proof then 'VALIDATED' when passed then 'READY' else 'NOT_READY' end,
 'current_revision',revision,'last_validated_revision',proof.configuration_revision,'validated_at',proof.validated_at,'validated_by',proof.validated_by,
 'validation_current',current_proof,'stale',proof.tenant_id is not null and not current_proof,
 'checks',checks,'warnings',coalesce((select jsonb_agg(c) from jsonb_array_elements(checks) c where c->>'severity'='WARNING' and c->>'result'='FAIL'),'[]'),
 'blockers',coalesce((select jsonb_agg(c) from jsonb_array_elements(checks) c where c->>'severity'='BLOCKER' and c->>'result'='FAIL'),'[]'));
end;$$;

create function public.platform_get_draft_readiness_v1(p_tenant_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp as $$
begin
 if not public.is_platform_admin_v1() or not app_private.is_platform_draft_v1(p_tenant_id) then raise exception 'Not authorized' using errcode='42501';end if;
 return app_private.draft_readiness_result_v1(p_tenant_id);
end;$$;

create function public.platform_validate_draft_readiness_v1(p_tenant_id uuid,p_expected_revision text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare actor uuid:=auth.uid(); result jsonb; summary jsonb;
begin
 perform app_private.lock_draft_readiness_v1(p_tenant_id);
 if not exists(select 1 from public.tenants where id=p_tenant_id and status='dormant') then raise exception 'Draft not editable' using errcode='42501';end if;
 if p_expected_revision is null or p_expected_revision !~ '^[a-f0-9]{64}$' then raise exception 'Invalid readiness revision' using errcode='22023';end if;
 result:=app_private.draft_readiness_result_v1(p_tenant_id);
 if result->>'current_revision' is not null and result->>'current_revision'<>p_expected_revision then raise exception 'READINESS_STALE' using errcode='PT409';end if;
 if (result->>'validation_current')::boolean then return result;end if;
 select jsonb_agg(jsonb_build_object('key',c->>'key','severity',c->>'severity','result',c->>'result')) into summary from jsonb_array_elements(result->'checks') c;
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details) values(actor,p_tenant_id,'readiness_validation_attempted',jsonb_build_object('revision',result->>'current_revision','validation_version',1));
 if result->>'overall'='PASS' then
  insert into app_private.draft_readiness_validations(tenant_id,configuration_revision,validated_by,validation_version,checks)
  values(p_tenant_id,result->>'current_revision',actor,1,summary)
  on conflict(tenant_id) do update set configuration_revision=excluded.configuration_revision,validated_by=excluded.validated_by,validated_at=transaction_timestamp(),validation_version=excluded.validation_version,checks=excluded.checks;
 end if;
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details) values(actor,p_tenant_id,case when result->>'overall'='PASS' then 'readiness_validation_passed' else 'readiness_validation_failed' end,
 jsonb_build_object('revision',result->>'current_revision','validation_version',1,'checks',summary));
 return app_private.draft_readiness_result_v1(p_tenant_id);
end;$$;

-- Invoke inside the future handover transaction. Locks persist until that transaction ends.
create function app_private.is_tenant_ready_for_handover_v1(tid uuid) returns boolean
language plpgsql set search_path=pg_catalog,public,pg_temp as $$
begin
 if not public.is_platform_admin_v1() or not app_private.recoverable_platform_draft_v1(tid)
 or not exists(select 1 from public.tenants where id=tid and status='dormant') then return false;end if;
 perform app_private.lock_draft_readiness_v1(tid);
 return coalesce((app_private.draft_readiness_result_v1(tid)->>'validation_current')::boolean,false);
end;$$;

revoke all on function public.platform_get_draft_readiness_v1(uuid),public.platform_validate_draft_readiness_v1(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.platform_get_draft_readiness_v1(uuid),public.platform_validate_draft_readiness_v1(uuid,text) to authenticated;
revoke all on function app_private.bump_draft_config_epoch_v1(uuid),app_private.track_draft_configuration_v1(),app_private.draft_configuration_revision_v1(uuid),app_private.lock_draft_readiness_v1(uuid),app_private.draft_readiness_checks_v1(uuid),app_private.draft_readiness_result_v1(uuid),app_private.is_tenant_ready_for_handover_v1(uuid) from public,anon,authenticated,service_role;

create trigger new_tenant_2c_revision after insert or update or delete on public.tenants for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.tenant_public_profiles for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.shooting_lanes for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.lane_booking_rules for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.lane_booking_durations for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.lane_pricing_rules for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.tenant_public_pricing_items for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.tenant_plan_assignments for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.tenant_public_access_controls for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.tenant_memberships for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.tenant_partners for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.saas_plans for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.saas_features for each row execute function app_private.track_draft_configuration_v1();

create trigger new_tenant_2c_revision after insert or update or delete on public.saas_plan_features for each row execute function app_private.track_draft_configuration_v1();

CREATE OR REPLACE FUNCTION public.platform_get_draft_configuration_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare result jsonb;
begin
 if not app_private.pa_draft_config_scope_v1(p_tenant_id) then raise exception 'Not authorized' using errcode='42501'; end if;
 result:=app_private.draft_configuration_snapshot_v1(p_tenant_id);
 return result||jsonb_build_object('revision',app_private.draft_configuration_revision_v1(p_tenant_id));
end;$function$
;

alter table public.platform_audit_logs drop constraint platform_audit_logs_action_check;
alter table public.platform_audit_logs add constraint platform_audit_logs_action_check CHECK ((action = ANY (ARRAY['tenant_created'::text, 'plan_assigned'::text, 'plan_changed'::text, 'tenant_admin_assigned'::text, 'tenant_activated'::text, 'tenant_suspended'::text, 'tenant_published'::text, 'tenant_unpublished'::text, 'platform_admin_bootstrapped'::text, 'domain_added'::text, 'domain_verification_started'::text, 'domain_verified'::text, 'domain_activated'::text, 'domain_disabled'::text, 'primary_domain_changed'::text, 'tenant_admin_add'::text, 'tenant_admin_reactivate'::text, 'tenant_admin_demote'::text, 'tenant_admin_suspend'::text, 'tenant_archived'::text, 'tenant_restored'::text, 'tenant_draft_configuration_updated'::text, 'readiness_validation_attempted'::text, 'readiness_validation_passed'::text, 'readiness_validation_failed'::text])));

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
 'tables',(select jsonb_agg(n.nspname||'.'||c.relname order by n.nspname,c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes','draft_configuration_requests','draft_configuration_epochs','draft_readiness_validations'))) and c.relkind in('r','p')),
 'columns',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||a.attname||':'||format_type(a.atttypid,a.atttypmod) order by n.nspname,c.relname,a.attnum) from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes','draft_configuration_requests','draft_configuration_epochs','draft_readiness_validations'))) and c.relkind in('r','p') and a.attnum>0 and not a.attisdropped),
 'foreign_keys',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||k.conname||':'||pg_get_constraintdef(k.oid) order by n.nspname,c.relname,k.conname) from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace join pg_class parent on parent.oid=k.confrelid join pg_namespace pn on pn.oid=parent.relnamespace where k.contype='f' and (n.nspname='public' or pn.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes','draft_configuration_requests','draft_configuration_epochs','draft_readiness_validations'))))
) into catalog;

 catalog_matches:=md5(catalog::text)='325df711391e9ae3e984a287ac132c8d';
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
 'draft_configuration_requests',(select count(*) from app_private.draft_configuration_requests where tenant_id=p_tenant_id),
 'draft_configuration_epochs',(select count(*) from app_private.draft_configuration_epochs where tenant_id=p_tenant_id),
 'draft_readiness_validations',(select count(*) from app_private.draft_readiness_validations where tenant_id=p_tenant_id),
 'tenant_partners',(select count(*) from public.tenant_partners where tenant_id=p_tenant_id),
 'tenant_partner_media',(select count(*) from app_private.tenant_partner_media where tenant_id=p_tenant_id),
 'tenant_partner_changes',(select count(*) from app_private.tenant_partner_changes where tenant_id=p_tenant_id),
 'tenant_public_access_controls',(select count(*) from public.tenant_public_access_controls where tenant_id=p_tenant_id),
 'tenant_public_access_changes',(select count(*) from app_private.tenant_public_access_changes where tenant_id=p_tenant_id),
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
 from (values ('draft_configuration_epochs','DRAFT_CONFIGURATION_HISTORY_EXISTS','lineage'),('draft_readiness_validations','DRAFT_READINESS_PROOF_EXISTS','lineage'),('draft_configuration_requests','DRAFT_CONFIGURATION_REQUESTS_EXIST','lineage'),('tenant_partners','TENANT_PARTNERS_EXIST','configuration'),('tenant_partner_media','PARTNER_MEDIA_EXISTS','configuration'),('tenant_partner_changes','PARTNER_AUDIT_EXISTS','history'),('tenant_public_access_controls','PUBLIC_ACCESS_CONFIGURATION_EXISTS','configuration'),('tenant_public_access_changes','PUBLIC_ACCESS_AUDIT_EXISTS','history'),('legal_documents','LEGAL_DOCUMENTS_EXIST','history'),('legal_document_versions','LEGAL_VERSIONS_EXIST','history'),('legal_actions','LEGAL_ACTIONS_EXIST','history'),('legal_acceptances','LEGAL_ACCEPTANCES_EXIST','history'),('audit_logs','AUDIT_LOGS_EXIST','history'),
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
$function$
;
