"use client";
import SetupChecklist from "./SetupChecklist";

import { FormEvent, useCallback, useEffect, useRef, useState } from "react";
import AdminShell from "@/app/admin/_components/AdminShell";
import { supabase } from "@/lib/supabase";
import { reportClientError } from "@/lib/safe-client-error";

import { parseHours, serializeHours, validateSettings, mapSettingsError, type FieldErrors, type Hours } from "./settings-validation";

type Settings = {
  display_name: string; city: string; logo_path: string | null; hero_image_path: string | null;
  description: string | null; regulations_path: string | null; public_address: string | null;
  public_phone: string | null; public_email: string | null; opening_hours: string | null;
  social_links: Record<string, string>; show_booking: boolean; show_pricing: boolean;
  show_instructor: boolean; show_events: boolean; show_about: boolean; show_contact: boolean;
  show_regulations: boolean; updated_at: string;
  feature_access: { booking: boolean; events: boolean; instructors: boolean };
};

const BOOLEAN_FIELDS = ["show_booking","show_pricing","show_instructor","show_events","show_about","show_contact","show_regulations"] as const;
const TEXT_FIELDS = ["display_name","city","logo_path","hero_image_path","description","regulations_path","public_address","public_phone","public_email","opening_hours"] as const;

function isSettings(value: unknown): value is Settings {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  return TEXT_FIELDS.every((key) => typeof row[key] === "string" || row[key] === null) &&
    BOOLEAN_FIELDS.every((key) => typeof row[key] === "boolean") && typeof row.updated_at === "string" &&
    !!row.social_links && typeof row.social_links === "object" && !Array.isArray(row.social_links) &&
    !!row.feature_access && typeof row.feature_access === "object" && !Array.isArray(row.feature_access) &&
    ["booking","events","instructors"].every(key => typeof (row.feature_access as Record<string, unknown>)[key] === "boolean");
}

function entitlementForFlag(settings: Settings, key: typeof BOOLEAN_FIELDS[number]) {
  if (key === "show_booking" || key === "show_pricing") return settings.feature_access.booking;
  if (key === "show_events") return settings.feature_access.events;
  if (key === "show_instructor") return settings.feature_access.instructors;
  return true;
}

function nullable(value: string) { return value.trim() || null; }

export default function TenantOnboardingSettings({ tenantSlug, tenantId = null, dormant = false }: Readonly<{ tenantSlug: string; tenantId?: string | null; dormant?: boolean }>) {
  const [settings,setSettings]=useState<Settings|null>(null);
  const [loading,setLoading]=useState(true); const [saving,setSaving]=useState(false);
  const formRef=useRef<HTMLFormElement>(null);
  const [fields,setFields]=useState<FieldErrors>({});
  const [conflict,setConflict]=useState(false);
  const [hours,setHours]=useState<Hours>(parseHours(null));
  const [saved,setSaved]=useState<Settings|null>(null);
  const [message,setMessage]=useState(""); const [error,setError]=useState("");

  const load=useCallback(async()=>{
    setLoading(true); setError("");
    const {data,error:rpcError}=await supabase.rpc("admin_get_tenant_public_settings_v1",{p_tenant_slug:tenantSlug});
    if(rpcError||!isSettings(data)){ reportClientError("Tenant public settings read failed",rpcError); setError("Nie udało się pobrać ustawień publicznych."); }
    else { setSettings(data); setSaved(data); setHours(parseHours(data.opening_hours)); setFields({}); setConflict(false); }
    setLoading(false);
  },[tenantSlug]);
  useEffect(()=>{
    const task=window.setTimeout(()=>void load(),0);
    return ()=>window.clearTimeout(task);
  },[load]);

  function setText(key:typeof TEXT_FIELDS[number],value:string){setSettings(current=>current?{...current,[key]:value}:current);}
  function setFlag(key:typeof BOOLEAN_FIELDS[number],value:boolean){setSettings(current=>current?{...current,[key]:value}:current);}
  function setSocial(key:"facebook"|"instagram"|"youtube",value:string){setSettings(current=>current?{...current,social_links:{...current.social_links,[key]:value}}:current);}

  function focusInvalid(errors:FieldErrors){
    window.requestAnimationFrame(()=>{
      const controls=formRef.current?.querySelectorAll<HTMLElement>("[data-field]");
      for(const control of controls??[]) if(errors[control.dataset.field??""]){control.focus();break;}
    });
  }
  async function save(event:FormEvent){
    event.preventDefault(); if(!settings||saving)return; setError(""); setMessage(""); setConflict(false);
    const validation=validateSettings(settings,hours); setFields(validation);
    if(Object.keys(validation).length){setError("Popraw zaznaczone pola.");focusInvalid(validation);return;}
    setSaving(true);
    const social_links=Object.fromEntries(Object.entries(settings.social_links).map(([key,value])=>[key,value.trim()]).filter(([,value])=>value));
    const payload={
      display_name:settings.display_name.trim(),city:settings.city.trim(),logo_path:nullable(settings.logo_path??""),
      hero_image_path:nullable(settings.hero_image_path??""),description:nullable(settings.description??""),
      regulations_path:nullable(settings.regulations_path??""),public_address:nullable(settings.public_address??""),
      public_phone:nullable(settings.public_phone??""),public_email:nullable(settings.public_email??""),
      opening_hours:serializeHours(hours),social_links,
      ...Object.fromEntries(BOOLEAN_FIELDS.map(key=>[key,settings[key]])),
    };
    const {data,error:rpcError}=await supabase.rpc("admin_update_tenant_public_settings_v1",{p_tenant_slug:tenantSlug,p_settings:payload,p_expected_updated_at:settings.updated_at});
    if(rpcError||!isSettings(data)){
      reportClientError("Tenant public settings update failed",rpcError);
      const mapped=mapSettingsError(rpcError??{},settings,hours); setFields(mapped.fields); setError(mapped.summary); setConflict(mapped.conflict); focusInvalid(mapped.fields);
    } else { setSettings(data); setSaved(data); setHours(parseHours(data.opening_hours)); setMessage("Ustawienia zapisane."); }
    setSaving(false);
  }

  return <AdminShell eyebrow="Administracja" title={saved?.display_name??"Ustawienia publiczne"} description="Edytujesz wyłącznie publiczny profil bieżącego obiektu. Przełączniki sterują prezentacją strony i nie zmieniają uprawnień ani dostępności tras rezerwacji.">
    <div className="mx-auto w-full max-w-5xl text-[#f2efe4]">
      {saved&&<header className="mt-6"><p>{saved.city}</p>{dormant&&<><p className="mt-2 font-semibold text-[#e1c477]">W przygotowaniu</p><p className="mt-2">Dokończ konfigurację przed aktywacją obiektu.</p></>}</header>}
      {loading&&<p role="status" className="mt-8">Ładowanie ustawień…</p>}
      {error&&<div role="alert" aria-live="assertive" className="mt-6 rounded-xl border border-[#7a4545] bg-[#2a1b1b] p-4 text-[#efb2b2]">{error} {(conflict||!settings)&&<button type="button" onClick={()=>void load()} className="ml-2 underline">Odśwież dane (zastąpi wpisane wartości)</button>}</div>}
      {message&&<div role="status" aria-live="polite" className="mt-6 rounded-xl border border-[#496348] bg-[#172419] p-4 text-[#b7d2ad]">{message} <a href="#public-profile" className="ml-2 underline">Przejdź do profilu publicznego</a></div>}
      {saved&&<SetupChecklist tenantId={tenantId} tenantSlug={tenantSlug} dormant={dormant} booking={saved.feature_access.booking} basic={!!saved.display_name&&!!saved.city} contact={!!(saved.public_address||saved.public_phone||saved.public_email)}/>}
      {settings&&<form ref={formRef} noValidate onSubmit={save} className="mt-8 space-y-6">
        <section id="public-profile" className="grid gap-4 rounded-2xl border border-[#30372c] bg-[#141814] p-5 sm:grid-cols-2">
          <h2 className="sm:col-span-2 text-xl font-bold">Profil obiektu</h2>
          <Field field="display_name" error={fields.display_name} label="Nazwa publiczna" value={settings.display_name} required onChange={value=>setText("display_name",value)}/>
          <Field field="city" error={fields.city} label="Miejscowość" value={settings.city} required onChange={value=>setText("city",value)}/>
          <Field field="logo_path" error={fields.logo_path} label="Ścieżka logo" help="Lokalna ścieżka, np. /brand/logo.png; bez .. i //." value={settings.logo_path??""} placeholder="/logo.png" onChange={value=>setText("logo_path",value)}/>
          <Field field="hero_image_path" error={fields.hero_image_path} label="Ścieżka hero" help="Lokalna ścieżka, np. /brand/logo.png; bez .. i //." value={settings.hero_image_path??""} placeholder="/hero.jpg" onChange={value=>setText("hero_image_path",value)}/>
          <label className="sm:col-span-2 text-sm font-semibold">Opis (opcjonalne)<textarea data-field="description" aria-invalid={!!fields.description} aria-describedby={fields.description?"description-error":undefined} value={settings.description??""} maxLength={1200} onChange={e=>setText("description",e.target.value)} className="mt-2 min-h-28 w-full rounded-xl border border-[#3d4638] bg-[#0e110e] p-3 font-normal"/>{fields.description&&<span id="description-error" className="mt-2 block text-[#efb2b2]">{fields.description}</span>}</label>
          <Field field="regulations_path" error={fields.regulations_path} label="Ścieżka regulaminu" help="Lokalna ścieżka, np. /brand/logo.png; bez .. i //." value={settings.regulations_path??""} placeholder="/terms" onChange={value=>setText("regulations_path",value)}/>
          <p className="self-end text-xs leading-5 text-[#858c7f]">Wpisz ścieżkę do pliku dostępnego w tej witrynie. Formularz nie przesyła plików.</p>
        </section>
        <section className="grid gap-4 rounded-2xl border border-[#30372c] bg-[#141814] p-5 sm:grid-cols-2">
          <h2 className="sm:col-span-2 text-xl font-bold">Kontakt publiczny</h2>
          <Field field="public_address" error={fields.public_address} label="Adres" value={settings.public_address??""} onChange={value=>setText("public_address",value)}/>
          <Field field="public_phone" error={fields.public_phone} label="Telefon" value={settings.public_phone??""} onChange={value=>setText("public_phone",value)}/>
          <Field field="public_email" error={fields.public_email} label="E-mail" type="email" value={settings.public_email??""} onChange={value=>setText("public_email",value)}/>
          <div className="sm:col-span-2">
            <p className="mb-2 text-sm">Publiczna informacja o godzinach; nie zmienia godzin rezerwacji.</p>
            {hours.legacy!==null?<div>
              <p>Dotychczasowa wartość: <span className="break-words">{hours.legacy}</span></p>
              {fields.legacyHours&&<p role="alert">{fields.legacyHours}</p>}
              <button data-field="legacyHours" type="button" className="mt-2 underline" onClick={()=>setHours(parseHours(null))}>Zastąp dotychczasowy zapis godzin</button>
            </div>:<div className="grid gap-4 sm:grid-cols-2">
              <Field field="openingTime" label="Godzina otwarcia" type="time" error={fields.openingTime} value={hours.openingTime} onChange={openingTime=>setHours(current=>({...current,openingTime}))}/>
              <Field field="closingTime" label="Godzina zamknięcia" type="time" error={fields.closingTime} value={hours.closingTime} onChange={closingTime=>setHours(current=>({...current,closingTime}))}/>
            </div>}
          </div>
          {(["facebook","instagram","youtube"] as const).map(key=><Field key={key} field={key} error={fields[key]} label={`${key[0].toUpperCase()}${key.slice(1)} URL`} type="url" value={settings.social_links[key]??""} placeholder="https://" onChange={value=>setSocial(key,value)}/>) }
        </section>
        <section className="rounded-2xl border border-[#30372c] bg-[#141814] p-5">
          <h2 className="text-xl font-bold">Widoczność sekcji</h2>
          <p className="mt-2 text-sm text-[#a9ada4]">Widoczność nie przyznaje funkcji. Moduły niedostępne w planie są zablokowane.</p>
          <div className="mt-4 grid gap-3 sm:grid-cols-2">{([
            ["show_booking","Rezerwacja"],["show_pricing","Cennik"],["show_instructor","Instruktor"],["show_events","Eventy"],["show_about","O obiekcie"],["show_contact","Kontakt"],["show_regulations","Regulamin"],
          ] as const).map(([key,label])=>{const entitled=entitlementForFlag(settings,key); return <label key={key} className="flex min-h-12 items-center gap-3 rounded-xl border border-[#343a31] p-3"><input type="checkbox" checked={settings[key]} disabled={!entitled} onChange={e=>setFlag(key,e.target.checked)} className="h-5 w-5 accent-[#8b7b48] disabled:opacity-50"/><span className="font-semibold">{label}{!entitled&&<span className="ml-2 text-xs font-normal text-[#e1c477]">Niedostępne w obecnym planie</span>}</span></label>;})}</div>
        </section>
        <button disabled={saving} className="min-h-12 rounded-xl border border-[#c5a861] bg-[#3a301d] px-6 py-3 font-bold text-[#f0d17b] disabled:opacity-50">{saving?"Zapisywanie…":"Zapisz i zostań"}</button>
      </form>}
    </div>
  </AdminShell>;
}

function Field({field,label,value,onChange,type="text",placeholder,required=false,error,help}:{field:string;label:string;value:string;onChange:(value:string)=>void;type?:string;placeholder?:string;required?:boolean;error?:string;help?:string}){
  const description=[help?`${field}-help`:null,error?`${field}-error`:null].filter(Boolean).join(" ")||undefined;
  return <label className="min-w-0 text-sm font-semibold">{label} ({required?"wymagane":"opcjonalne"})<input data-field={field} type={type} value={value} required={required} aria-invalid={!!error} aria-describedby={description} placeholder={placeholder} onChange={e=>onChange(e.target.value)} className="mt-2 min-h-12 w-full rounded-xl border border-[#3d4638] bg-[#0e110e] px-3 font-normal"/>{help&&<span id={`${field}-help`} className="mt-2 block text-xs font-normal text-[#a9ada4]">{help}</span>}{error&&<span id={`${field}-error`} className="mt-2 block text-sm font-normal text-[#efb2b2]">{error}</span>}</label>;
}
