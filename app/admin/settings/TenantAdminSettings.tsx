"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import AdminShell from "../_components/AdminShell";
import { supabase } from "../../../lib/supabase";
import { reportClientError } from "../../../lib/safe-client-error";

type PricingItem = { id: string | null; title: string; price: number; currency: string; unit: string; short_description: string | null; display_order: number; is_active: boolean };

type Settings = {
  about_offer: string | null; about_audience: string | null; public_map_url: string | null; pricing_items: PricingItem[];
  display_name: string; city: string; logo_path: string | null; hero_image_path: string | null;
  description: string | null; regulations_path: string | null; public_address: string | null;
  public_phone: string | null; public_email: string | null; opening_hours: string | null;
  social_links: Record<string, string>; show_booking: boolean; show_pricing: boolean;
  show_instructor: boolean; show_events: boolean; show_about: boolean; show_contact: boolean;
  show_regulations: boolean; updated_at: string;
  feature_access: { booking: boolean; events: boolean; instructors: boolean };
};

const BOOLEAN_FIELDS = ["show_booking","show_pricing","show_instructor","show_events","show_about","show_contact","show_regulations"] as const;
const TEXT_FIELDS = ["display_name","city","logo_path","hero_image_path","description","regulations_path","public_address","public_phone","public_email","opening_hours","about_offer","about_audience","public_map_url"] as const;

function isSettings(value: unknown): value is Settings {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  return Array.isArray(row.pricing_items) && TEXT_FIELDS.every((key) => typeof row[key] === "string" || row[key] === null) &&
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

export default function AdminSettingsPage({ tenantSlug }: Readonly<{ tenantSlug: string }>) {
  const [settings,setSettings]=useState<Settings|null>(null);
  const [loading,setLoading]=useState(true); const [saving,setSaving]=useState(false);
  const [message,setMessage]=useState(""); const [error,setError]=useState("");

  const load=useCallback(async()=>{
    setLoading(true); setError("");
    const {data,error:rpcError}=await supabase.rpc("admin_get_tenant_content_v1",{p_tenant_slug:tenantSlug});
    if(rpcError||!isSettings(data)){ reportClientError("Tenant public settings read failed",rpcError); setError("Nie udało się pobrać ustawień publicznych."); }
    else setSettings(data);
    setLoading(false);
  },[tenantSlug]);
  useEffect(()=>{
    const task=window.setTimeout(()=>void load(),0);
    return ()=>window.clearTimeout(task);
  },[load]);

  function setText(key:typeof TEXT_FIELDS[number],value:string){setSettings(current=>current?{...current,[key]:value}:current);}
  function setFlag(key:typeof BOOLEAN_FIELDS[number],value:boolean){setSettings(current=>current?{...current,[key]:value}:current);}
  function setSocial(key:"facebook"|"instagram"|"youtube",value:string){setSettings(current=>current?{...current,social_links:{...current.social_links,[key]:value}}:current);}

  async function save(event:FormEvent){
    event.preventDefault(); if(!settings||saving)return; setSaving(true); setError(""); setMessage("");
    const social_links=Object.fromEntries(Object.entries(settings.social_links).map(([key,value])=>[key,value.trim()]).filter(([,value])=>value));
    const payload={
      display_name:settings.display_name.trim(),city:settings.city.trim(),logo_path:nullable(settings.logo_path??""),
      hero_image_path:nullable(settings.hero_image_path??""),description:nullable(settings.description??""),
      regulations_path:nullable(settings.regulations_path??""),public_address:nullable(settings.public_address??""),
      public_phone:nullable(settings.public_phone??""),public_email:nullable(settings.public_email??""),
      opening_hours:nullable(settings.opening_hours??""),social_links,
      ...Object.fromEntries(BOOLEAN_FIELDS.map(key=>[key,settings[key]])),
    };
    const {data,error:rpcError}=await supabase.rpc("admin_update_tenant_content_v1",{p_tenant_slug:tenantSlug,p_settings:payload,p_content:{about_offer:nullable(settings.about_offer??""),about_audience:nullable(settings.about_audience??""),public_map_url:nullable(settings.public_map_url??""),pricing_items:settings.pricing_items},p_expected_updated_at:settings.updated_at});
    if(rpcError||!isSettings(data)){
      reportClientError("Tenant public settings update failed",rpcError);
      setError(rpcError?.message?.includes("settings_conflict")?"Ustawienia zmieniły się w innej sesji. Odśwież dane i spróbuj ponownie.":"Nie udało się zapisać ustawień. Sprawdź format pól.");
    } else { setSettings(data); setMessage("Ustawienia publiczne zostały zapisane."); }
    setSaving(false);
  }

  return <AdminShell eyebrow="Administracja" title="Ustawienia publiczne" description="Edytujesz wyłącznie publiczny profil bieżącego obiektu. Przełączniki sterują prezentacją strony i nie zmieniają uprawnień ani dostępności tras rezerwacji.">
    <div className="mx-auto w-full max-w-5xl text-[#f2efe4]">
      {loading&&<p role="status" className="mt-8">Ładowanie ustawień…</p>}
      {error&&<div role="alert" className="mt-6 rounded-xl border border-[#7a4545] bg-[#2a1b1b] p-4 text-[#efb2b2]">{error} <button type="button" onClick={()=>void load()} className="ml-2 underline">Spróbuj ponownie</button></div>}
      {message&&<div role="status" className="mt-6 rounded-xl border border-[#496348] bg-[#172419] p-4 text-[#b7d2ad]">{message}</div>}
      {settings&&<form onSubmit={save} className="mt-8 space-y-6">
        <section className="grid gap-4 rounded-2xl border border-[#30372c] bg-[#141814] p-5 sm:grid-cols-2">
          <h2 className="sm:col-span-2 text-xl font-bold">Profil obiektu</h2>
          <Field label="Nazwa publiczna" value={settings.display_name} required onChange={value=>setText("display_name",value)}/>
          <Field label="Miejscowość" value={settings.city} required onChange={value=>setText("city",value)}/>
          <Field label="Ścieżka logo" value={settings.logo_path??""} placeholder="/logo.png" onChange={value=>setText("logo_path",value)}/>
          <Field label="Ścieżka hero" value={settings.hero_image_path??""} placeholder="/hero.jpg" onChange={value=>setText("hero_image_path",value)}/>
          <Field label="Ścieżka regulaminu" value={settings.regulations_path??""} placeholder="/terms" onChange={value=>setText("regulations_path",value)}/>
          <p className="self-end text-xs leading-5 text-[#858c7f]">Obsługa uploadu logo/hero nie jest częścią PRODUCT-10C. Akceptowane są bezpieczne ścieżki same-origin.</p>
        </section>
        <section className="grid gap-4 rounded-2xl border border-[#30372c] bg-[#141814] p-5 sm:grid-cols-2">
          <h2 className="sm:col-span-2 text-xl font-bold">Kontakt i lokalizacja</h2>
          <Field label="Link do mapy (HTTPS)" type="url" value={settings.public_map_url??""} onChange={value=>setText("public_map_url",value)}/>
          <Field label="Adres" value={settings.public_address??""} onChange={value=>setText("public_address",value)}/>
          <Field label="Telefon" value={settings.public_phone??""} onChange={value=>setText("public_phone",value)}/>
          <Field label="E-mail" type="email" value={settings.public_email??""} onChange={value=>setText("public_email",value)}/>
          <Field label="Godziny otwarcia" value={settings.opening_hours??""} onChange={value=>setText("opening_hours",value)}/>
          {(["facebook","instagram","youtube"] as const).map(key=><Field key={key} label={`${key[0].toUpperCase()}${key.slice(1)} URL`} type="url" value={settings.social_links[key]??""} placeholder="https://" onChange={value=>setSocial(key,value)}/>) }
        </section>
        <section className="space-y-4 rounded-2xl border border-[#30372c] bg-[#141814] p-5">
          <h2 className="text-xl font-bold">O obiekcie</h2>
          {([["description","Główny opis"],["about_offer","Co oferujemy"],["about_audience","Dla kogo"]] as const).map(([key,label])=><label key={key} className="block text-sm font-semibold">{label}<textarea value={settings[key]??""} maxLength={1200} onChange={e=>setText(key,e.target.value)} className="mt-2 min-h-28 w-full rounded-xl border border-[#3d4638] bg-[#0e110e] p-3 font-normal"/></label>)}
        </section>
        <section className="space-y-4 rounded-2xl border border-[#30372c] bg-[#141814] p-5">
          <h2 className="text-xl font-bold">Cennik</h2>
          <p className="text-sm text-[#a9ada4]">Publiczna oferta informacyjna. Nie zmienia cen booking ani historycznych rezerwacji. Ceny rezerwacji edytuje się w konfiguracji osi.</p>
          {settings.pricing_items.length===0&&<p className="text-sm">Brak pozycji cennika.</p>}
          {settings.pricing_items.map((item,index)=>{
            const update=(patch:Partial<PricingItem>)=>setSettings(current=>current?{...current,pricing_items:current.pricing_items.map((row,i)=>i===index?{...row,...patch}:row)}:current);
            return <fieldset key={item.id??`new-${index}`} className="grid min-w-0 gap-3 rounded-xl border border-[#343a31] p-4 sm:grid-cols-2">
              <legend className="px-2 text-sm">Pozycja {index+1}</legend>
              <Field label="Nazwa pozycji" value={item.title} required onChange={title=>update({title})}/>
              <label className="text-sm font-semibold">Cena<input aria-label="Cena" type="number" min="0" max="9999999.99" step="0.01" required value={item.price} onChange={e=>update({price:e.target.valueAsNumber})} className="mt-2 min-h-12 w-full rounded-xl border border-[#3d4638] bg-[#0e110e] px-3"/></label>
              <Field label="Waluta (ISO, np. PLN lub EUR)" value={item.currency} required onChange={currency=>update({currency:currency.toUpperCase()})}/>
              <Field label="Jednostka (np. godzina)" value={item.unit} required onChange={unit=>update({unit})}/>
              <Field label="Krótki opis" value={item.short_description??""} onChange={short_description=>update({short_description:nullable(short_description)})}/>
              <label className="text-sm font-semibold">Kolejność<input aria-label="Kolejność" type="number" min="0" max="9999" step="1" required value={item.display_order} onChange={e=>update({display_order:e.target.valueAsNumber})} className="mt-2 min-h-12 w-full rounded-xl border border-[#3d4638] bg-[#0e110e] px-3"/></label>
              <label className="flex min-h-11 items-center gap-3 text-sm"><input type="checkbox" checked={item.is_active} onChange={e=>update({is_active:e.target.checked})}/>Aktywna pozycja</label>
              {item.id===null&&<button type="button" className="min-h-11 text-sm underline" onClick={()=>setSettings(current=>current?{...current,pricing_items:current.pricing_items.filter((_,i)=>i!==index)}:current)}>Usuń niezapisaną pozycję</button>}
            </fieldset>;
          })}
          <button type="button" disabled={settings.pricing_items.length>=100} className="min-h-11 rounded-xl border border-[#536143] px-4 disabled:opacity-50" onClick={()=>setSettings(current=>current?{...current,pricing_items:[...current.pricing_items,{id:null,title:"",price:0,currency:"",unit:"",short_description:null,display_order:Math.min(current.pricing_items.length*10,9999),is_active:true}]}:current)}>Dodaj pozycję</button>
        </section>
        <section className="rounded-2xl border border-[#30372c] bg-[#141814] p-5">
          <h2 className="text-xl font-bold">Widoczność sekcji</h2>
          <p className="mt-2 text-sm text-[#a9ada4]">Widoczność nie przyznaje funkcji. Moduły niedostępne w planie są zablokowane.</p>
          <div className="mt-4 grid gap-3 sm:grid-cols-2">{([
            ["show_booking","Rezerwacja"],["show_pricing","Cennik"],["show_instructor","Instruktor"],["show_events","Eventy"],["show_about","O obiekcie"],["show_contact","Kontakt"],["show_regulations","Regulamin"],
          ] as const).map(([key,label])=>{const entitled=entitlementForFlag(settings,key); return <label key={key} className="flex min-h-12 items-center gap-3 rounded-xl border border-[#343a31] p-3"><input type="checkbox" checked={settings[key]} disabled={!entitled} onChange={e=>setFlag(key,e.target.checked)} className="h-5 w-5 accent-[#8b7b48] disabled:opacity-50"/><span className="font-semibold">{label}{!entitled&&<span className="ml-2 text-xs font-normal text-[#e1c477]">Niedostępne w obecnym planie</span>}</span></label>;})}</div>
        </section>
        <button disabled={saving} className="min-h-12 rounded-xl border border-[#c5a861] bg-[#3a301d] px-6 py-3 font-bold text-[#f0d17b] disabled:opacity-50">{saving?"Zapisywanie…":"Zapisz ustawienia"}</button>
      </form>}
    </div>
  </AdminShell>;
}

function Field({label,value,onChange,type="text",placeholder,required=false}:{label:string;value:string;onChange:(value:string)=>void;type?:string;placeholder?:string;required?:boolean}){
  return <label className="text-sm font-semibold">{label}<input type={type} value={value} required={required} placeholder={placeholder} onChange={e=>onChange(e.target.value)} className="mt-2 min-h-12 w-full rounded-xl border border-[#3d4638] bg-[#0e110e] px-3 font-normal"/></label>;
}
