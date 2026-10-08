export const tenantId = 'a0000000-0000-4000-8000-000000000001';
export const actorId = 'b0000000-0000-4000-8000-000000000001';
export const userId = 'c0000000-0000-4000-8000-000000000001';
export const email = 'candidate@example.invalid';
export const readerNames = ['platform_get_tenant_onboarding_detail_v1','platform_list_active_plans_v1','platform_get_tenant_admin_management_v1','platform_get_tenant_archive_preview_v1','platform_get_tenant_delete_eligibility_v1'];
export function fixture() {
  const tenant = {tenant_id:tenantId,name:'Strzelnica testowa',status:'active'};
  return {
    detail:{tenant:{...tenant,technical_slug:'local-range'},public_profile:{display_name:'Strzelnica testowa',city:'Testowo',public_slug:'public-range',is_public:true},plan:{plan_key:'current_full_v1',status:'active',assignment_status:'active',enabled_feature_keys:['booking','events']},admins:[{user_id:userId,email}],readiness:{create_ready:true,activation_ready:true,public_ready:false,booking_ready:true,booking_required:true,publication_gate_enforced:false,checks:{admin_ready:true}}},
    plans:[{plan_key:'booking_only_v1',display_name:'Minimum',status:'active',features:[{feature_key:'booking',description:'Booking'}]},{plan_key:'current_full_v1',display_name:'Full',status:'active',features:[{feature_key:'booking',description:'Booking'},{feature_key:'events',description:'Events'}]}],
    admins:{tenant:{...tenant},active_admin_count:1,admins:[{user_id:userId,email,membership_role:'admin',membership_status:'active',updated_at:'2026-10-07T10:00:00Z'}]},
    lifecycle:{tenant:{...tenant,is_public:true},current_plan:{plan_key:'current_full_v1',status:'active',plan_status:'active'},admin_summary:{active_admin_count:1},operational_counts:{future_reservations:2,future_events:1,open_registrations:3,active_lane_blocks:0,active_custom_domains:0,settlement_records:0,pending_deliveries:0,in_flight_positive_deliveries:0},warnings:['HISTORY_RETAINED','CLOSURE_CONTINUITY_ONLY','RESTORE_REQUIRES_SEPARATE_PUBLICATION'],blockers:[],can_archive:true,revision:17},
    eligibility:{tenant:{...tenant},lifecycle:{is_archived:false,is_public:true},eligibility:{can_hard_delete:false,blocker_count:2},blockers:[{code:'HARD_DELETE_POLICY_DEFERRED',category:'policy',count:1,hard_blocker:true},{code:'AUDIT_LOGS_EXIST',category:'history',count:3,hard_blocker:true}],warnings:['SNAPSHOT_ONLY_NOT_DELETE_AUTHORIZATION'],dependency_summary:{audit_logs:3}},
    preview:{tenant:{...tenant},current_plan:{plan_key:'current_full_v1',assignment_status:'active',enabled_feature_keys:['booking','events']},target_plan:{plan_key:'booking_only_v1',enabled_feature_keys:['booking']},features_added:[],features_removed:['events'],blockers:[],warnings:[{code:'CAPABILITY_REMOVED',feature_key:'events'}],can_apply:true,revision:'9007199254740993'},
    candidate:{user_id:userId,email,membership:{exists:false,role:null,status:null}},
  };
}
export function response(f, name, args) {
  const map = Object.fromEntries(readerNames.map((name,i)=>[name,['detail','plans','admins','lifecycle','eligibility'][i]]));
  if(map[name])return f[map[name]];
  if(name==='platform_get_tenant_plan_change_preview_v1')return {...f.preview,target_plan:{...f.preview.target_plan,plan_key:args.p_target_plan_key}};
  if(name==='platform_lookup_tenant_admin_candidate_v1')return f.candidate;
  if(name==='platform_change_tenant_plan_v2'){f.detail.plan.plan_key=args.p_target_plan_key;return {code:'changed',plan_key:args.p_target_plan_key,revision:'9007199254740994'};}
  if(['platform_archive_tenant_v1','platform_restore_archived_tenant_v1'].includes(name)){
    const status=name==='platform_archive_tenant_v1'?'archived':'dormant';
    for(const k of ['detail','admins','lifecycle','eligibility'])f[k].tenant.status=status;
    f.lifecycle.tenant.is_public=false;f.detail.public_profile.is_public=false;f.lifecycle.revision++;
    return {tenant_id:tenantId,status,is_public:false,revision:f.lifecycle.revision};
  }
  const operations={platform_add_tenant_admin_v1:'add',platform_reactivate_tenant_admin_v1:'reactivate',platform_demote_tenant_admin_v1:'demote',platform_suspend_tenant_admin_v1:'suspend'};
  if(operations[name]){
    if(operations[name]==='demote'&&(f.candidate.membership.role!=='admin'||f.candidate.membership.status!=='active')){
      throw Object.assign(new Error('NOT_ACTIVE_TENANT_ADMIN'),{code:'55000'});
    }
    const role=operations[name]==='demote'?'user':'admin',status=operations[name]==='suspend'?'suspended':'active';
    if(operations[name]==='reactivate'){
      const admin=f.admins.admins.find(a=>a.user_id===args.p_user_id);
      if(admin)admin.membership_status='active';
      f.admins.active_admin_count=f.admins.admins.filter(a=>a.membership_status==='active').length;
    }
    f.candidate.membership={exists:true,role,status};return {code:'changed',user_id:args.p_user_id,role,status};
  }
  throw Error(`Unexpected RPC ${name}`);
}

export function rpcResponse(f,name,args){
  try{return {data:response(f,name,args),error:null};}
  catch(error){if(!error.code)throw error;return {data:null,error:{code:error.code,message:error.message}};}
}
