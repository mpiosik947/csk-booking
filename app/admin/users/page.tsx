"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { supabase } from "../../../lib/supabase";
import AdminShell from "../_components/AdminShell";

type UserRole = "admin" | "pracownik" | "instruktor" | "user";
type VerificationAction = "verify" | "mark_pending" | "reject";
type Feedback = { tone: "error" | "success" | "info"; text: string } | null;

type Profile = {
  user_id: string;
  email: string | null;
  first_name: string | null;
  last_name: string | null;
  full_name: string | null;
  phone: string | null;
  role: UserRole | string | null;
  verification_status: string | null;
  admin_note: string | null;
  created_at: string | null;
  updated_at: string | null;
  postal_code: string | null;
  city: string | null;
  street: string | null;
  house_number: string | null;
  apartment_number: string | null;
  permission_sport: boolean | null;
  permission_collector: boolean | null;
  permission_hunting: boolean | null;
  permission_training: boolean | null;
  permission_personal_protection: boolean | null;
  permission_other: boolean | null;
  qualification_instructor: boolean | null;
  qualification_range_officer: boolean | null;
  qualification_pzss_license: boolean | null;
  qualification_hunter: boolean | null;
  permissions_verified: boolean | null;
  permissions_verified_at: string | null;
  permissions_verification_note: string | null;
};

type AdminUserListRow = Profile & { total_count: number | string };

type VerificationRpcResult = {
  user_id: string;
  verification_status: string | null;
  permissions_verified: boolean | null;
  permissions_verified_at: string | null;
  permissions_verification_note: string | null;
  updated_at: string | null;
};

type AdminUserMutationResult = {
  ok: boolean;
  changed: boolean;
  code: string;
  role?: string;
  admin_note?: string | null;
  updated_at?: string | null;
};

type IdentityDraft = { first_name: string; last_name: string };
type IdentityRpcResult = IdentityDraft & {
  user_id: string;
  full_name: string;
  updated_at: string | null;
  changed_fields: string[];
};
type ContactDraft = {
  phone: string;
  postal_code: string;
  city: string;
  street: string;
  house_number: string;
  apartment_number: string;
};
type ContactRpcResult = {
  user_id: string;
  phone: string | null;
  postal_code: string | null;
  city: string | null;
  street: string | null;
  house_number: string | null;
  apartment_number: string | null;
  updated_at: string | null;
  changed_fields: string[];
};

const PAGE_SIZE = 25;
const roleOptions: Array<{ value: UserRole; label: string }> = [
  { value: "user", label: "Użytkownik" },
  { value: "instruktor", label: "Instruktor" },
  { value: "pracownik", label: "Pracownik" },
  { value: "admin", label: "Admin" },
];
const verificationFilters = [
  { value: "all", label: "Wszystkie statusy" },
  { value: "pending", label: "Oczekujący" },
  { value: "unverified", label: "Niezweryfikowani" },
  { value: "verified", label: "Zweryfikowani" },
  { value: "rejected", label: "Odrzuceni" },
];
const sortOptions = [
  { value: "newest", label: "Najnowsi" },
  { value: "oldest", label: "Najstarsi" },
  { value: "name", label: "Nazwa A–Z" },
  { value: "role", label: "Rola" },
];

const VERIFIED_NOTE =
  "Sprawdzono uprawnienia klienta podczas pierwszej wizyty. Dokumenty okazane do wglądu, bez kopiowania i zapisywania numerów. Klient zapoznany z regulaminem i zasadami bezpieczeństwa. Konto zweryfikowane.";
const INCOMPLETE_NOTE =
  "Nie zakończono pełnej weryfikacji uprawnień. Klient poinformowany o konieczności okazania wymaganych dokumentów przy kolejnej wizycie. Konto pozostaje niezweryfikowane.";
const contactFieldLimits: Array<{
  field: keyof ContactDraft;
  label: string;
  maxLength: number;
}> = [
  { field: "phone", label: "Numer telefonu", maxLength: 32 },
  { field: "postal_code", label: "Kod pocztowy", maxLength: 20 },
  { field: "city", label: "Miasto", maxLength: 120 },
  { field: "street", label: "Ulica", maxLength: 160 },
  { field: "house_number", label: "Numer domu", maxLength: 30 },
  { field: "apartment_number", label: "Numer mieszkania", maxLength: 30 },
];

function isNullableString(value: unknown): value is string | null {
  return typeof value === "string" || value === null;
}

function isAdminUserListRow(value: unknown): value is AdminUserListRow {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value as Partial<AdminUserListRow>;
  return (
    typeof row.user_id === "string" &&
    (row.role === null || typeof row.role === "string") &&
    (typeof row.total_count === "number" || typeof row.total_count === "string")
  );
}

function isVerificationRpcResult(value: unknown): value is VerificationRpcResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const result = value as Record<string, unknown>;
  return (
    typeof result.user_id === "string" &&
    isNullableString(result.verification_status) &&
    (typeof result.permissions_verified === "boolean" ||
      result.permissions_verified === null) &&
    isNullableString(result.permissions_verified_at) &&
    isNullableString(result.permissions_verification_note) &&
    isNullableString(result.updated_at)
  );
}

function isIdentityRpcResult(value: unknown): value is IdentityRpcResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const result = value as Record<string, unknown>;
  return (
    typeof result.user_id === "string" &&
    typeof result.first_name === "string" &&
    typeof result.last_name === "string" &&
    typeof result.full_name === "string" &&
    isNullableString(result.updated_at) &&
    Array.isArray(result.changed_fields) &&
    result.changed_fields.every((field) => typeof field === "string")
  );
}

function isContactRpcResult(value: unknown): value is ContactRpcResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const result = value as Record<string, unknown>;
  return (
    typeof result.user_id === "string" &&
    ["phone", "postal_code", "city", "street", "house_number", "apartment_number"].every(
      (field) => typeof result[field] === "string" || result[field] === null
    ) &&
    isNullableString(result.updated_at) &&
    Array.isArray(result.changed_fields) &&
    result.changed_fields.every((field) => typeof field === "string")
  );
}

function getMissingFields(profile: Profile) {
  const missing: string[] = [];
  if (!profile.first_name?.trim() || !profile.last_name?.trim()) missing.push("imię i nazwisko");
  if (!profile.phone?.trim()) missing.push("telefon");
  if (!profile.postal_code?.trim()) missing.push("kod pocztowy");
  if (!profile.city?.trim()) missing.push("miasto");
  if (!profile.street?.trim()) missing.push("ulica");
  if (!profile.house_number?.trim()) missing.push("numer domu");
  return missing;
}

function getDisplayName(profile: Profile) {
  const structured = [profile.first_name, profile.last_name]
    .map((value) => value?.trim() ?? "")
    .filter(Boolean)
    .join(" ");
  return structured || profile.full_name?.trim() || profile.email?.trim() || "Nieznany użytkownik";
}

function getRoleLabel(role: string | null) {
  return roleOptions.find((item) => item.value === role)?.label ?? "Brak roli";
}

function getVerificationLabel(profile: Profile) {
  if (profile.verification_status === "verified" && profile.permissions_verified) {
    return "Zweryfikowany";
  }
  if (profile.verification_status === "pending") return "Oczekuje";
  if (profile.verification_status === "rejected") return "Odrzucony";
  return "Niezweryfikowany";
}

function getRoleBadgeClass(role: string | null) {
  if (role === "admin") return "border-[#806a32] bg-[#2b2618] text-[#e1c477]";
  if (role === "pracownik") return "border-[#536143] bg-[#20271e] text-[#b9c9a5]";
  if (role === "instruktor") return "border-[#665d45] bg-[#242119] text-[#d7c895]";
  return "border-[#3d4638] bg-[#191e19] text-[#c7cbbf]";
}

function getVerificationBadgeClass(profile: Profile) {
  if (profile.verification_status === "verified" && profile.permissions_verified) {
    return "border-[#536143] bg-[#20271e] text-[#a9d4ad]";
  }
  if (profile.verification_status === "pending") {
    return "border-[#806a32] bg-[#2b2618] text-[#e1c477]";
  }
  if (profile.verification_status === "rejected") {
    return "border-[#744545] bg-[#2a1b1b] text-[#e0a0a0]";
  }
  return "border-[#484b43] bg-[#1a1d19] text-[#a9ada4]";
}

function formatDate(value: string | null) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? "—"
    : new Intl.DateTimeFormat("pl-PL", {
        day: "2-digit",
        month: "2-digit",
        year: "numeric",
      }).format(date);
}

function getQualifications(profile: Profile) {
  const result: string[] = [];
  if (profile.qualification_instructor) result.push("Instruktor");
  if (profile.qualification_range_officer) result.push("Prowadzący strzelanie");
  if (profile.qualification_pzss_license) result.push("Licencja PZSS");
  if (profile.qualification_hunter) result.push("Myśliwy");
  return result;
}

function getPermissions(profile: Profile) {
  const result: string[] = [];
  if (profile.permission_sport) result.push("Sportowe");
  if (profile.permission_collector) result.push("Kolekcjonerskie");
  if (profile.permission_hunting) result.push("Łowieckie");
  if (profile.permission_training) result.push("Szkoleniowe");
  if (profile.permission_personal_protection) result.push("Ochrona osobista");
  if (profile.permission_other) result.push("Inne");
  return result;
}

function getAddress(profile: Profile) {
  const street = [
    profile.street,
    profile.house_number,
    profile.apartment_number ? `/ ${profile.apartment_number}` : null,
  ]
    .filter(Boolean)
    .join(" ");
  const city = [profile.postal_code, profile.city].filter(Boolean).join(" ");
  return [street, city].filter(Boolean);
}

function Badge({ children, className }: { children: React.ReactNode; className: string }) {
  return (
    <span className={`inline-flex rounded-full border px-2.5 py-1 text-xs font-semibold ${className}`}>
      {children}
    </span>
  );
}

function DetailItem({ label, value }: { label: string; value: string | null }) {
  if (!value?.trim()) return null;
  return (
    <div>
      <dt className="text-xs uppercase tracking-[0.14em] text-[#7f8679]">{label}</dt>
      <dd className="mt-1 break-words text-sm text-[#e7e4da]">{value}</dd>
    </div>
  );
}

export default function AdminUsersPage() {
  const [currentRole, setCurrentRole] = useState<UserRole | null>(null);
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [totalCount, setTotalCount] = useState(0);
  const [page, setPage] = useState(0);
  const [search, setSearch] = useState("");
  const [roleFilter, setRoleFilter] = useState("all");
  const [verificationFilter, setVerificationFilter] = useState("all");
  const [sort, setSort] = useState("newest");
  const [loading, setLoading] = useState(true);
  const [savingUserId, setSavingUserId] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<Feedback>(null);
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null);
  const [roleDrafts, setRoleDrafts] = useState<Record<string, UserRole>>({});
  const [noteDrafts, setNoteDrafts] = useState<Record<string, string>>({});
  const [verificationDrafts, setVerificationDrafts] = useState<Record<string, string>>({});
  const [identityDrafts, setIdentityDrafts] = useState<Record<string, IdentityDraft>>({});
  const [contactDrafts, setContactDrafts] = useState<Record<string, ContactDraft>>({});
  const [editingIdentity, setEditingIdentity] = useState(false);
  const [editingContact, setEditingContact] = useState(false);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const detailsTriggerRef = useRef<HTMLButtonElement | null>(null);
  const requestRef = useRef(0);

  const selectedProfile = profiles.find((profile) => profile.user_id === selectedUserId) ?? null;
  const hasFilters =
    search.trim() !== "" || roleFilter !== "all" || verificationFilter !== "all" || sort !== "newest";
  const rangeStart = totalCount === 0 ? 0 : page * PAGE_SIZE + 1;
  const rangeEnd = Math.min((page + 1) * PAGE_SIZE, totalCount);
  const totalPages = Math.max(1, Math.ceil(totalCount / PAGE_SIZE));

  useEffect(() => {
    const timeoutId = window.setTimeout(async () => {
      const requestId = ++requestRef.current;
      setLoading(true);
      setFeedback(null);

      const { data: authData } = await supabase.auth.getUser();
      if (!authData.user) {
        if (requestId === requestRef.current) {
          setCurrentRole(null);
          setProfiles([]);
          setTotalCount(0);
          setFeedback({ tone: "error", text: "Brak dostępu do modułu użytkowników." });
          setLoading(false);
        }
        return;
      }

      const { data: roleData, error: roleError } = await supabase.rpc("get_my_role");
      if (roleError || roleData !== "admin") {
        if (requestId === requestRef.current) {
          setCurrentRole(typeof roleData === "string" ? (roleData as UserRole) : null);
          setProfiles([]);
          setTotalCount(0);
          setFeedback({
            tone: "error",
            text: "Brak dostępu. Ten moduł jest dostępny tylko dla administratora.",
          });
          setLoading(false);
        }
        return;
      }

      const { data, error } = await supabase.rpc("admin_list_users_v1", {
        p_limit: PAGE_SIZE,
        p_offset: page * PAGE_SIZE,
        p_search: search.trim() || null,
        p_role: roleFilter === "all" ? null : roleFilter,
        p_verification_filter: verificationFilter === "all" ? null : verificationFilter,
        p_sort: sort,
      });

      if (requestId !== requestRef.current) return;
      setCurrentRole("admin");
      setLoading(false);

      if (error) {
        console.error("Admin users read failed:", error);
        setProfiles([]);
        setTotalCount(0);
        setFeedback({ tone: "error", text: "Nie udało się pobrać użytkowników. Spróbuj ponownie." });
        return;
      }

      const rawRows: unknown[] = Array.isArray(data) ? data : [];
      const rows = rawRows.filter(isAdminUserListRow);
      if (rows.length !== rawRows.length) {
        console.error("Admin users RPC returned malformed data.");
        setProfiles([]);
        setTotalCount(0);
        setFeedback({ tone: "error", text: "Nie udało się poprawnie odczytać listy użytkowników." });
        return;
      }

      setProfiles(rows);
      setTotalCount(rows.length > 0 ? Number(rows[0].total_count) : 0);
      setRoleDrafts((drafts) => ({
        ...drafts,
        ...Object.fromEntries(
          rows.map((profile) => [
            profile.user_id,
            (profile.role as UserRole) || "user",
          ])
        ),
      }));
      setNoteDrafts((drafts) => ({
        ...drafts,
        ...Object.fromEntries(rows.map((profile) => [profile.user_id, profile.admin_note ?? ""])),
      }));
    }, 250);

    return () => window.clearTimeout(timeoutId);
  }, [page, roleFilter, search, sort, verificationFilter]);

  useEffect(() => {
    if (!selectedProfile) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    window.setTimeout(() => closeButtonRef.current?.focus(), 0);

    function closeAndRestoreFocus() {
      setSelectedUserId(null);
      window.setTimeout(() => detailsTriggerRef.current?.focus(), 0);
    }

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        closeAndRestoreFocus();
        return;
      }
      if (event.key !== "Tab") return;
      const dialog = closeButtonRef.current?.closest('[role="dialog"]');
      const focusable = dialog?.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href]'
      );
      if (!focusable?.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }

    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.body.style.overflow = previousOverflow;
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [selectedProfile]);

  function openDetails(profile: Profile, trigger: HTMLButtonElement) {
    detailsTriggerRef.current = trigger;
    setSelectedUserId(profile.user_id);
    setRoleDrafts((drafts) => ({
      ...drafts,
      [profile.user_id]: (profile.role as UserRole) || "user",
    }));
    setNoteDrafts((drafts) => ({ ...drafts, [profile.user_id]: profile.admin_note ?? "" }));
    setIdentityDrafts((drafts) => ({
      ...drafts,
      [profile.user_id]: {
        first_name: profile.first_name ?? "",
        last_name: profile.last_name ?? "",
      },
    }));
    setContactDrafts((drafts) => ({
      ...drafts,
      [profile.user_id]: {
        phone: profile.phone ?? "",
        postal_code: profile.postal_code ?? "",
        city: profile.city ?? "",
        street: profile.street ?? "",
        house_number: profile.house_number ?? "",
        apartment_number: profile.apartment_number ?? "",
      },
    }));
    setEditingIdentity(false);
    setEditingContact(false);
    setFeedback(null);
  }

  function closeDetails() {
    setSelectedUserId(null);
    window.setTimeout(() => detailsTriggerRef.current?.focus(), 0);
  }

  function resetFilters() {
    setSearch("");
    setRoleFilter("all");
    setVerificationFilter("all");
    setSort("newest");
    setPage(0);
  }

  async function saveRole(profile: Profile) {
    const nextRole = roleDrafts[profile.user_id] ?? (profile.role as UserRole) ?? "user";
    if (nextRole === profile.role) {
      setFeedback({ tone: "info", text: "Rola użytkownika nie została zmieniona." });
      return;
    }

    const confirmation =
      nextRole === "admin"
        ? `Nadać użytkownikowi ${getDisplayName(profile)} rolę administratora? Ta rola daje pełny dostęp administracyjny.`
        : `Zmienić rolę użytkownika ${getDisplayName(profile)} z „${getRoleLabel(profile.role)}” na „${getRoleLabel(nextRole)}”?`;
    if (!window.confirm(confirmation)) return;

    setSavingUserId(profile.user_id);
    setFeedback(null);
    const { data, error } = await supabase.rpc("admin_set_user_role_v1", {
      p_target_user_id: profile.user_id,
      p_new_role: nextRole,
    });
    setSavingUserId(null);

    if (error) {
      console.error("Admin role mutation failed:", error);
      setFeedback({ tone: "error", text: "Nie udało się zapisać zmiany roli." });
      return;
    }

    const result = data as AdminUserMutationResult | null;
    if (!result || typeof result.code !== "string") {
      setFeedback({ tone: "error", text: "Nie udało się potwierdzić wyniku zmiany roli." });
      return;
    }
    if (!result.ok) {
      const messages: Record<string, string> = {
        last_admin: "Nie można zmienić roli ostatniego administratora.",
        not_allowed: "Brak uprawnień do tej operacji.",
        invalid_target: "Nieprawidłowy użytkownik docelowy.",
        target_not_found: "Nie znaleziono użytkownika.",
        invalid_role: "Wybrano nieprawidłową rolę.",
      };
      setFeedback({ tone: "error", text: messages[result.code] ?? "Zmiana roli została odrzucona." });
      return;
    }

    setProfiles((items) =>
      items.map((item) =>
        item.user_id === profile.user_id
          ? { ...item, role: result.role ?? nextRole, updated_at: result.updated_at ?? item.updated_at }
          : item
      )
    );
    setFeedback({
      tone: "success",
      text: result.changed ? "Rola użytkownika została zapisana." : "Rola użytkownika jest aktualna.",
    });
  }

  async function saveAdminNote(profile: Profile) {
    const note = noteDrafts[profile.user_id] ?? "";
    if (note.length > 2000) {
      setFeedback({ tone: "error", text: "Notatka może mieć maksymalnie 2000 znaków." });
      return;
    }

    setSavingUserId(profile.user_id);
    setFeedback(null);
    const { data, error } = await supabase.rpc("admin_set_user_note_v1", {
      p_target_user_id: profile.user_id,
      p_admin_note: note.trim() || null,
    });
    setSavingUserId(null);

    if (error) {
      console.error("Admin note mutation failed:", error);
      setFeedback({ tone: "error", text: "Nie udało się zapisać notatki administratora." });
      return;
    }
    const result = data as AdminUserMutationResult | null;
    if (!result || typeof result.code !== "string") {
      setFeedback({ tone: "error", text: "Nie udało się potwierdzić zapisu notatki." });
      return;
    }
    if (!result.ok) {
      setFeedback({
        tone: "error",
        text: result.code === "note_too_long" ? "Notatka może mieć maksymalnie 2000 znaków." : "Zapis notatki został odrzucony.",
      });
      return;
    }

    setProfiles((items) =>
      items.map((item) =>
        item.user_id === profile.user_id
          ? { ...item, admin_note: result.admin_note ?? null, updated_at: result.updated_at ?? item.updated_at }
          : item
      )
    );
    setFeedback({ tone: "success", text: result.changed ? "Notatka administratora została zapisana." : "Notatka jest aktualna." });
  }

  async function updateVerification(profile: Profile, action: VerificationAction) {
    if (action === "verify") {
      const missingFields = getMissingFields(profile);
      if (
        missingFields.length > 0 &&
        !window.confirm(
          `Konto posiada braki: ${missingFields.join(", ")}. Czy mimo to oznaczyć konto jako zweryfikowane?`
        )
      ) {
        return;
      }
    }
    const note = verificationDrafts[profile.user_id] ?? "";
    setSavingUserId(profile.user_id);
    setFeedback(null);
    const { data, error } = await supabase.rpc("update_profile_verification", {
      p_target_user_id: profile.user_id,
      p_action: action,
      p_note: note.trim() || null,
    });
    setSavingUserId(null);

    if (error) {
      console.error("Profile verification RPC failed:", error);
      setFeedback({ tone: "error", text: "Nie udało się zaktualizować weryfikacji profilu." });
      return;
    }
    if (!isVerificationRpcResult(data) || data.user_id !== profile.user_id) {
      console.error("Profile verification RPC returned invalid data.");
      setFeedback({ tone: "error", text: "Nie udało się potwierdzić wyniku weryfikacji." });
      return;
    }

    setProfiles((items) =>
      items.map((item) =>
        item.user_id === data.user_id
          ? {
              ...item,
              verification_status: data.verification_status,
              permissions_verified: data.permissions_verified,
              permissions_verified_at: data.permissions_verified_at,
              permissions_verification_note: data.permissions_verification_note,
              updated_at: data.updated_at,
            }
          : item
      )
    );
    setVerificationDrafts((drafts) => ({ ...drafts, [profile.user_id]: "" }));
    setFeedback({ tone: "success", text: "Weryfikacja profilu została zaktualizowana." });
  }

  async function saveIdentity(profile: Profile) {
    const draft = identityDrafts[profile.user_id];
    const firstName = draft?.first_name.trim() ?? "";
    const lastName = draft?.last_name.trim() ?? "";
    if (!firstName || !lastName) {
      setFeedback({ tone: "error", text: "Imię i nazwisko są wymagane." });
      return;
    }
    if (firstName.length > 120 || lastName.length > 160) {
      setFeedback({ tone: "error", text: "Imię lub nazwisko przekracza dozwolony limit." });
      return;
    }

    setSavingUserId(profile.user_id);
    setFeedback(null);
    const { data, error } = await supabase.rpc("update_profile_identity", {
      p_target_user_id: profile.user_id,
      p_first_name: firstName,
      p_last_name: lastName,
    });
    setSavingUserId(null);
    if (error || !isIdentityRpcResult(data) || data.user_id !== profile.user_id) {
      if (error) console.error("Profile identity RPC failed:", error);
      setFeedback({ tone: "error", text: "Nie udało się zaktualizować imienia i nazwiska." });
      return;
    }
    setProfiles((items) =>
      items.map((item) =>
        item.user_id === data.user_id
          ? {
              ...item,
              first_name: data.first_name,
              last_name: data.last_name,
              full_name: data.full_name,
              updated_at: data.updated_at,
            }
          : item
      )
    );
    setEditingIdentity(false);
    setFeedback({
      tone: "success",
      text: data.changed_fields.length ? "Dane podstawowe zostały zaktualizowane." : "Dane podstawowe są aktualne.",
    });
  }

  async function saveContact(profile: Profile) {
    const draft = contactDrafts[profile.user_id];
    if (!draft) return;
    const invalidField = contactFieldLimits.find(
      ({ field, maxLength }) => draft[field].trim().length > maxLength
    );
    if (invalidField) {
      setFeedback({
        tone: "error",
        text: `${invalidField.label} przekracza limit ${invalidField.maxLength} znaków.`,
      });
      return;
    }

    setSavingUserId(profile.user_id);
    setFeedback(null);
    const { data, error } = await supabase.rpc("update_profile_contact_details", {
      p_target_user_id: profile.user_id,
      p_phone: draft.phone,
      p_postal_code: draft.postal_code,
      p_city: draft.city,
      p_street: draft.street,
      p_house_number: draft.house_number,
      p_apartment_number: draft.apartment_number,
    });
    setSavingUserId(null);
    if (error || !isContactRpcResult(data) || data.user_id !== profile.user_id) {
      if (error) console.error("Profile contact RPC failed:", error);
      setFeedback({ tone: "error", text: "Nie udało się zaktualizować danych kontaktowych." });
      return;
    }
    setProfiles((items) =>
      items.map((item) =>
        item.user_id === data.user_id
          ? {
              ...item,
              phone: data.phone || null,
              postal_code: data.postal_code || null,
              city: data.city || null,
              street: data.street || null,
              house_number: data.house_number || null,
              apartment_number: data.apartment_number || null,
              updated_at: data.updated_at,
            }
          : item
      )
    );
    setEditingContact(false);
    setFeedback({
      tone: "success",
      text: data.changed_fields.length ? "Dane kontaktowe zostały zaktualizowane." : "Dane kontaktowe są aktualne.",
    });
  }

  return (
    <AdminShell
      eyebrow="Panel administracyjny"
      title="Użytkownicy"
      description="Zarządzanie kontami, rolami i weryfikacją użytkowników."
      badge={
        <span className="rounded-full border border-[#536143] bg-[#20271e] px-3 py-1 text-sm text-[#b9c9a5]">
          {loading ? "Wczytywanie…" : `${totalCount} kont`}
        </span>
      }
      actions={
        <Link
          href="/admin"
          className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#46503f] px-4 py-2 text-sm font-semibold text-[#d7c895] transition hover:border-[#7a6a3c] hover:bg-[#1d211b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
        >
          ← Wróć do panelu
        </Link>
      }
    >
      <section aria-labelledby="users-filters" className="rounded-2xl border border-[#30372c] bg-[#101310] p-4 sm:p-5">
        <div className="mb-4 flex items-center justify-between gap-4">
          <div>
            <h2 id="users-filters" className="font-semibold text-[#f2efe4]">Filtry listy</h2>
            <p className="mt-1 text-sm text-[#858c7f]">Wyniki są wyszukiwane i filtrowane po stronie serwera.</p>
          </div>
          <button
            type="button"
            onClick={resetFilters}
            disabled={!hasFilters}
            className="min-h-11 shrink-0 rounded-xl border border-[#3d4638] px-3 py-2 text-sm text-[#c7cbbf] transition hover:bg-[#1d211b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:cursor-not-allowed disabled:opacity-40"
          >
            Resetuj
          </button>
        </div>
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-[minmax(16rem,2fr)_1fr_1fr_1fr]">
          <label className="text-sm text-[#c7cbbf]">
            <span className="mb-2 block">Wyszukiwanie</span>
            <input
              type="search"
              value={search}
              onChange={(event) => { setSearch(event.target.value); setPage(0); }}
              placeholder="Szukaj po imieniu, e-mailu lub telefonie"
              className="min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#171b17] px-3 text-[#f2efe4] outline-none placeholder:text-[#73796e] focus:border-[#7a6a3c] focus:ring-2 focus:ring-[#d7c895]/25"
            />
          </label>
          <label className="text-sm text-[#c7cbbf]">
            <span className="mb-2 block">Rola</span>
            <select
              value={roleFilter}
              onChange={(event) => { setRoleFilter(event.target.value); setPage(0); }}
              className="min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#171b17] px-3 text-[#f2efe4] outline-none focus:border-[#7a6a3c] focus:ring-2 focus:ring-[#d7c895]/25"
            >
              <option value="all">Wszystkie role</option>
              {roleOptions.map((item) => <option key={item.value} value={item.value}>{item.label}</option>)}
            </select>
          </label>
          <label className="text-sm text-[#c7cbbf]">
            <span className="mb-2 block">Weryfikacja</span>
            <select
              value={verificationFilter}
              onChange={(event) => { setVerificationFilter(event.target.value); setPage(0); }}
              className="min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#171b17] px-3 text-[#f2efe4] outline-none focus:border-[#7a6a3c] focus:ring-2 focus:ring-[#d7c895]/25"
            >
              {verificationFilters.map((item) => <option key={item.value} value={item.value}>{item.label}</option>)}
            </select>
          </label>
          <label className="text-sm text-[#c7cbbf]">
            <span className="mb-2 block">Sortowanie</span>
            <select
              value={sort}
              onChange={(event) => { setSort(event.target.value); setPage(0); }}
              className="min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#171b17] px-3 text-[#f2efe4] outline-none focus:border-[#7a6a3c] focus:ring-2 focus:ring-[#d7c895]/25"
            >
              {sortOptions.map((item) => <option key={item.value} value={item.value}>{item.label}</option>)}
            </select>
          </label>
        </div>
      </section>

      {feedback && (
        <div
          role={feedback.tone === "error" ? "alert" : "status"}
          className={`mt-5 rounded-xl border px-4 py-3 text-sm ${
            feedback.tone === "error"
              ? "border-[#744545] bg-[#2a1b1b] text-[#edb1b1]"
              : feedback.tone === "success"
                ? "border-[#536143] bg-[#20271e] text-[#b9d9b9]"
                : "border-[#665d45] bg-[#242119] text-[#d7c895]"
          }`}
        >
          {feedback.text}
        </div>
      )}

      <section aria-label="Lista użytkowników" aria-busy={loading} className="mt-5">
        {loading ? (
          <div className="space-y-3" aria-label="Wczytywanie użytkowników">
            {[0, 1, 2, 3].map((item) => (
              <div key={item} className="h-24 animate-pulse rounded-2xl border border-[#30372c] bg-[#171b17]" />
            ))}
          </div>
        ) : currentRole !== "admin" ? null : profiles.length === 0 ? (
          <div className="rounded-2xl border border-dashed border-[#46503f] bg-[#101310] px-5 py-12 text-center">
            <h2 className="text-lg font-semibold text-[#e7e4da]">{hasFilters ? "Brak wyników" : "Brak użytkowników"}</h2>
            <p className="mt-2 text-sm text-[#858c7f]">
              {hasFilters ? "Brak użytkowników spełniających wybrane kryteria." : "Lista użytkowników jest obecnie pusta."}
            </p>
          </div>
        ) : (
          <>
            <div className="hidden overflow-hidden rounded-2xl border border-[#30372c] md:block">
              <table className="w-full table-fixed text-left">
                <thead className="bg-[#1a1e1a] text-xs uppercase tracking-[0.12em] text-[#858c7f]">
                  <tr>
                    <th className="w-[25%] px-4 py-3 font-medium">Użytkownik</th>
                    <th className="w-[23%] px-4 py-3 font-medium">Kontakt</th>
                    <th className="w-[13%] px-4 py-3 font-medium">Rola</th>
                    <th className="w-[16%] px-4 py-3 font-medium">Weryfikacja</th>
                    <th className="w-[11%] px-4 py-3 font-medium">Utworzono</th>
                    <th className="w-[12%] px-4 py-3 text-right font-medium">Akcje</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-[#30372c] bg-[#111411]">
                  {profiles.map((profile) => (
                    <tr key={profile.user_id} className="align-top transition hover:bg-[#171b17]">
                      <td className="px-4 py-4">
                        <p className="truncate font-semibold text-[#f2efe4]">{getDisplayName(profile)}</p>
                        {getQualifications(profile).length > 0 && (
                          <p className="mt-1 truncate text-xs text-[#9fa590]">{getQualifications(profile).join(" • ")}</p>
                        )}
                      </td>
                      <td className="px-4 py-4 text-sm text-[#b9bdb4]">
                        {profile.email && <p className="truncate">{profile.email}</p>}
                        {profile.phone && <p className="mt-1 truncate text-[#858c7f]">{profile.phone}</p>}
                      </td>
                      <td className="px-4 py-4"><Badge className={getRoleBadgeClass(profile.role)}>{getRoleLabel(profile.role)}</Badge></td>
                      <td className="px-4 py-4"><Badge className={getVerificationBadgeClass(profile)}>{getVerificationLabel(profile)}</Badge></td>
                      <td className="px-4 py-4 text-sm text-[#a9ada4]">{formatDate(profile.created_at)}</td>
                      <td className="px-4 py-4 text-right">
                        <button
                          type="button"
                          onClick={(event) => openDetails(profile, event.currentTarget)}
                          className="min-h-11 rounded-xl border border-[#536143] px-3 py-2 text-sm font-semibold text-[#d7c895] transition hover:bg-[#20271e] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
                        >
                          Szczegóły
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <div className="grid gap-3 md:hidden">
              {profiles.map((profile) => (
                <article key={profile.user_id} className="min-w-0 rounded-2xl border border-[#30372c] bg-[#111411] p-4">
                  <h2 className="break-words font-semibold text-[#f2efe4]">{getDisplayName(profile)}</h2>
                  {profile.email && <p className="mt-1 break-all text-sm text-[#a9ada4]">{profile.email}</p>}
                  <div className="mt-3 flex flex-wrap gap-2">
                    <Badge className={getRoleBadgeClass(profile.role)}>{getRoleLabel(profile.role)}</Badge>
                    <Badge className={getVerificationBadgeClass(profile)}>{getVerificationLabel(profile)}</Badge>
                  </div>
                  <button
                    type="button"
                    onClick={(event) => openDetails(profile, event.currentTarget)}
                    className="mt-4 min-h-11 w-full rounded-xl border border-[#536143] px-4 py-2 text-sm font-semibold text-[#d7c895] transition hover:bg-[#20271e] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
                  >
                    Szczegóły
                  </button>
                </article>
              ))}
            </div>

            <nav aria-label="Stronicowanie użytkowników" className="mt-5 flex flex-col items-center justify-between gap-3 rounded-2xl border border-[#30372c] bg-[#101310] p-3 sm:flex-row">
              <p className="text-sm text-[#a9ada4]">{rangeStart}–{rangeEnd} z {totalCount}</p>
              <div className="flex w-full items-center gap-2 sm:w-auto">
                <button
                  type="button"
                  onClick={() => setPage((value) => Math.max(0, value - 1))}
                  disabled={page === 0}
                  className="min-h-11 flex-1 rounded-xl border border-[#3d4638] px-3 py-2 text-sm font-semibold text-[#c7cbbf] hover:bg-[#1d211b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-40 sm:flex-none"
                >
                  Poprzednia
                </button>
                <span aria-current="page" className="min-w-20 text-center text-sm text-[#e7e4da]">Strona {page + 1} z {totalPages}</span>
                <button
                  type="button"
                  onClick={() => setPage((value) => value + 1)}
                  disabled={page + 1 >= totalPages}
                  className="min-h-11 flex-1 rounded-xl border border-[#3d4638] px-3 py-2 text-sm font-semibold text-[#c7cbbf] hover:bg-[#1d211b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-40 sm:flex-none"
                >
                  Następna
                </button>
              </div>
            </nav>
          </>
        )}
      </section>

      {selectedProfile && (
        <div
          className="fixed inset-0 z-50 flex items-end justify-center bg-black/75 p-0 backdrop-blur-sm sm:items-center sm:p-5"
          onMouseDown={(event) => { if (event.target === event.currentTarget) closeDetails(); }}
        >
          <section
            role="dialog"
            aria-modal="true"
            aria-labelledby="user-details-title"
            className="max-h-[95dvh] w-full overflow-y-auto rounded-t-[1.75rem] border border-[#3d4638] bg-[#111411] shadow-2xl sm:max-w-3xl sm:rounded-[1.75rem]"
          >
            <header className="sticky top-0 z-10 flex items-start justify-between gap-4 border-b border-[#30372c] bg-[#111411]/95 p-5 backdrop-blur sm:p-6">
              <div className="min-w-0">
                <p className="text-xs uppercase tracking-[0.2em] text-[#d7c895]">Szczegóły użytkownika</p>
                <h2 id="user-details-title" className="mt-2 break-words text-xl font-bold text-[#f2efe4] sm:text-2xl">{getDisplayName(selectedProfile)}</h2>
                <div className="mt-3 flex flex-wrap gap-2">
                  <Badge className={getRoleBadgeClass(selectedProfile.role)}>{getRoleLabel(selectedProfile.role)}</Badge>
                  <Badge className={getVerificationBadgeClass(selectedProfile)}>{getVerificationLabel(selectedProfile)}</Badge>
                </div>
              </div>
              <button
                ref={closeButtonRef}
                type="button"
                onClick={closeDetails}
                aria-label="Zamknij szczegóły użytkownika"
                className="min-h-11 min-w-11 rounded-xl border border-[#3d4638] text-xl text-[#c7cbbf] transition hover:bg-[#20241f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
              >
                ×
              </button>
            </header>

            <div className="space-y-5 p-4 sm:p-6">
              <section className="rounded-2xl border border-[#30372c] bg-[#171b17] p-4">
                <div className="flex items-center justify-between gap-3">
                  <h3 className="font-semibold text-[#f2efe4]">Dane podstawowe</h3>
                  <button
                    type="button"
                    onClick={() => setEditingIdentity((value) => !value)}
                    className="min-h-11 rounded-xl border border-[#3d4638] px-3 text-sm text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
                  >
                    {editingIdentity ? "Anuluj" : "Edytuj"}
                  </button>
                </div>
                {editingIdentity ? (
                  <div className="mt-4 grid gap-4 sm:grid-cols-2">
                    {(["first_name", "last_name"] as const).map((field) => (
                      <label key={field} className="text-sm text-[#c7cbbf]">
                        <span className="mb-2 block">{field === "first_name" ? "Imię" : "Nazwisko"}</span>
                        <input
                          value={identityDrafts[selectedProfile.user_id]?.[field] ?? ""}
                          maxLength={field === "first_name" ? 120 : 160}
                          onChange={(event) => setIdentityDrafts((drafts) => ({
                            ...drafts,
                            [selectedProfile.user_id]: {
                              ...(drafts[selectedProfile.user_id] ?? { first_name: "", last_name: "" }),
                              [field]: event.target.value,
                            },
                          }))}
                          className="min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#101310] px-3 text-[#f2efe4] focus:border-[#7a6a3c] focus:outline-none focus:ring-2 focus:ring-[#d7c895]/25"
                        />
                      </label>
                    ))}
                    <button
                      type="button"
                      onClick={() => void saveIdentity(selectedProfile)}
                      disabled={savingUserId === selectedProfile.user_id}
                      className="min-h-11 rounded-xl bg-[#696f3d] px-4 text-sm font-bold text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-40 sm:col-span-2 sm:justify-self-end"
                    >
                      Zapisz dane podstawowe
                    </button>
                  </div>
                ) : (
                  <dl className="mt-4 grid gap-4 sm:grid-cols-2">
                    <DetailItem label="Imię" value={selectedProfile.first_name} />
                    <DetailItem label="Nazwisko" value={selectedProfile.last_name} />
                    <DetailItem label="E-mail" value={selectedProfile.email} />
                    <DetailItem label="Telefon" value={selectedProfile.phone} />
                  </dl>
                )}
              </section>

              {(getAddress(selectedProfile).length > 0 || editingContact) && (
                <section className="rounded-2xl border border-[#30372c] bg-[#171b17] p-4">
                  <div className="flex items-center justify-between gap-3">
                    <h3 className="font-semibold text-[#f2efe4]">Adres i kontakt</h3>
                    <button
                      type="button"
                      onClick={() => setEditingContact((value) => !value)}
                      className="min-h-11 rounded-xl border border-[#3d4638] px-3 text-sm text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
                    >
                      {editingContact ? "Anuluj" : "Edytuj"}
                    </button>
                  </div>
                  {editingContact ? (
                    <div className="mt-4 grid gap-4 sm:grid-cols-2">
                      {contactFieldLimits.map(({ field, label, maxLength }) => (
                        <label key={field} className="text-sm text-[#c7cbbf]">
                          <span className="mb-2 block">{label}</span>
                          <input
                            value={contactDrafts[selectedProfile.user_id]?.[field] ?? ""}
                            maxLength={maxLength}
                            onChange={(event) => setContactDrafts((drafts) => ({
                              ...drafts,
                              [selectedProfile.user_id]: {
                                ...(drafts[selectedProfile.user_id] ?? {
                                  phone: "", postal_code: "", city: "", street: "", house_number: "", apartment_number: "",
                                }),
                                [field]: event.target.value,
                              },
                            }))}
                            className="min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#101310] px-3 text-[#f2efe4] focus:border-[#7a6a3c] focus:outline-none focus:ring-2 focus:ring-[#d7c895]/25"
                          />
                        </label>
                      ))}
                      <button
                        type="button"
                        onClick={() => void saveContact(selectedProfile)}
                        disabled={savingUserId === selectedProfile.user_id}
                        className="min-h-11 rounded-xl bg-[#696f3d] px-4 text-sm font-bold text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-40 sm:col-span-2 sm:justify-self-end"
                      >
                        Zapisz dane kontaktowe
                      </button>
                    </div>
                  ) : (
                    <address className="mt-3 not-italic text-sm leading-6 text-[#c7cbbf]">{getAddress(selectedProfile).map((line) => <div key={line}>{line}</div>)}</address>
                  )}
                </section>
              )}

              {getAddress(selectedProfile).length === 0 && !editingContact && (
                <button
                  type="button"
                  onClick={() => setEditingContact(true)}
                  className="min-h-11 rounded-xl border border-[#3d4638] px-4 text-sm text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]"
                >
                  Dodaj dane kontaktowe i adres
                </button>
              )}

              <section className="rounded-2xl border border-[#536143] bg-[#171b17] p-4 sm:p-5">
                <div>
                  <p className="text-xs uppercase tracking-[0.16em] text-[#9fa590]">
                    Dane zadeklarowane przez użytkownika
                  </p>
                  <h3 className="mt-1 font-semibold text-[#f2efe4]">
                    Deklarowane uprawnienia i kwalifikacje
                  </h3>
                  <p className="mt-2 text-sm text-[#858c7f]">
                    Deklaracje nie są równoznaczne z ich weryfikacją przez administratora.
                  </p>
                </div>

                {getPermissions(selectedProfile).length === 0 &&
                getQualifications(selectedProfile).length === 0 ? (
                  <p className="mt-4 rounded-xl border border-[#30372c] bg-[#101310] px-4 py-3 text-sm text-[#a9ada4]">
                    Brak zadeklarowanych uprawnień i kwalifikacji.
                  </p>
                ) : (
                  <div className="mt-4 grid gap-4 sm:grid-cols-2">
                    <div className="rounded-xl border border-[#30372c] bg-[#101310] p-4">
                      <h4 className="text-sm font-semibold text-[#e7e4da]">Uprawnienia</h4>
                      {getPermissions(selectedProfile).length > 0 ? (
                        <ul className="mt-3 flex flex-wrap gap-2" aria-label="Zadeklarowane uprawnienia">
                          {getPermissions(selectedProfile).map((item) => (
                            <li key={item}>
                              <Badge className="border-[#665d45] bg-[#242119] text-[#d7c895]">
                                <span aria-hidden="true">✓</span> {item}
                              </Badge>
                            </li>
                          ))}
                        </ul>
                      ) : (
                        <p className="mt-3 text-sm text-[#73796e]">Brak aktywnych deklaracji.</p>
                      )}
                    </div>

                    <div className="rounded-xl border border-[#30372c] bg-[#101310] p-4">
                      <h4 className="text-sm font-semibold text-[#e7e4da]">Kwalifikacje</h4>
                      {getQualifications(selectedProfile).length > 0 ? (
                        <ul className="mt-3 flex flex-wrap gap-2" aria-label="Zadeklarowane kwalifikacje">
                          {getQualifications(selectedProfile).map((item) => (
                            <li key={item}>
                              <Badge className="border-[#536143] bg-[#20271e] text-[#b9c9a5]">
                                <span aria-hidden="true">✓</span> {item}
                              </Badge>
                            </li>
                          ))}
                        </ul>
                      ) : (
                        <p className="mt-3 text-sm text-[#73796e]">Brak aktywnych deklaracji.</p>
                      )}
                    </div>
                  </div>
                )}
              </section>

              <section className="rounded-2xl border border-[#30372c] bg-[#171b17] p-4">
                <h3 className="font-semibold text-[#f2efe4]">Rola</h3>
                <div className="mt-4 grid gap-4 sm:grid-cols-[1fr_auto] sm:items-end">
                  <label className="text-sm text-[#c7cbbf]">
                    <span className="mb-2 block">Nowa rola</span>
                    <select
                      value={roleDrafts[selectedProfile.user_id] ?? selectedProfile.role ?? "user"}
                      onChange={(event) => setRoleDrafts((drafts) => ({ ...drafts, [selectedProfile.user_id]: event.target.value as UserRole }))}
                      className="min-h-11 w-full rounded-xl border border-[#3d4638] bg-[#101310] px-3 text-[#f2efe4] focus:border-[#7a6a3c] focus:outline-none focus:ring-2 focus:ring-[#d7c895]/25"
                    >
                      {roleOptions.map((item) => <option key={item.value} value={item.value}>{item.label}</option>)}
                    </select>
                  </label>
                  <button
                    type="button"
                    onClick={() => void saveRole(selectedProfile)}
                    disabled={savingUserId === selectedProfile.user_id || (roleDrafts[selectedProfile.user_id] ?? selectedProfile.role) === selectedProfile.role}
                    className="min-h-11 rounded-xl bg-[#696f3d] px-4 py-2 text-sm font-bold text-white transition hover:bg-[#7a8147] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-40"
                  >
                    Zapisz zmianę roli
                  </button>
                </div>
                {(roleDrafts[selectedProfile.user_id] ?? selectedProfile.role) !== selectedProfile.role && (
                  <p className="mt-3 text-sm text-[#d7c895]">{getRoleLabel(selectedProfile.role)} → {getRoleLabel(roleDrafts[selectedProfile.user_id])}</p>
                )}
              </section>

              <section className="rounded-2xl border border-[#30372c] bg-[#171b17] p-4">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <h3 className="font-semibold text-[#f2efe4]">Weryfikacja</h3>
                  <Badge className={getVerificationBadgeClass(selectedProfile)}>{getVerificationLabel(selectedProfile)}</Badge>
                </div>
                {selectedProfile.permissions_verification_note && <p className="mt-3 rounded-xl bg-[#101310] p-3 text-sm text-[#b9bdb4]">{selectedProfile.permissions_verification_note}</p>}
                <label className="mt-4 block text-sm text-[#c7cbbf]">
                  <span className="mb-2 block">Notatka weryfikacyjna</span>
                  <textarea
                    rows={4}
                    value={verificationDrafts[selectedProfile.user_id] ?? ""}
                    onChange={(event) => setVerificationDrafts((drafts) => ({ ...drafts, [selectedProfile.user_id]: event.target.value }))}
                    className="w-full rounded-xl border border-[#3d4638] bg-[#101310] p-3 text-[#f2efe4] focus:border-[#7a6a3c] focus:outline-none focus:ring-2 focus:ring-[#d7c895]/25"
                  />
                </label>
                <div className="mt-3 flex flex-wrap gap-2">
                  <button type="button" onClick={() => setVerificationDrafts((drafts) => ({ ...drafts, [selectedProfile.user_id]: VERIFIED_NOTE }))} className="min-h-11 rounded-xl border border-[#3d4638] px-3 text-sm text-[#c7cbbf] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]">Szablon pozytywny</button>
                  <button type="button" onClick={() => setVerificationDrafts((drafts) => ({ ...drafts, [selectedProfile.user_id]: INCOMPLETE_NOTE }))} className="min-h-11 rounded-xl border border-[#3d4638] px-3 text-sm text-[#c7cbbf] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895]">Szablon braków</button>
                </div>
                <div className="mt-4 grid gap-2 sm:grid-cols-3">
                  <button type="button" disabled={savingUserId === selectedProfile.user_id} onClick={() => void updateVerification(selectedProfile, "verify")} className="min-h-11 rounded-xl bg-[#536143] px-3 text-sm font-semibold text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-40">Zweryfikuj</button>
                  <button type="button" disabled={savingUserId === selectedProfile.user_id} onClick={() => void updateVerification(selectedProfile, "mark_pending")} className="min-h-11 rounded-xl border border-[#806a32] px-3 text-sm font-semibold text-[#e1c477] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-40">Oznacz jako oczekujące</button>
                  <button type="button" disabled={savingUserId === selectedProfile.user_id} onClick={() => void updateVerification(selectedProfile, "reject")} className="min-h-11 rounded-xl border border-[#744545] px-3 text-sm font-semibold text-[#e0a0a0] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-40">Odrzuć</button>
                </div>
              </section>

              <section className="rounded-2xl border border-[#30372c] bg-[#171b17] p-4">
                <h3 className="font-semibold text-[#f2efe4]">Notatka administratora</h3>
                <label className="mt-4 block text-sm text-[#c7cbbf]">
                  <span className="sr-only">Treść notatki administratora</span>
                  <textarea
                    maxLength={2000}
                    rows={5}
                    value={noteDrafts[selectedProfile.user_id] ?? ""}
                    onChange={(event) => setNoteDrafts((drafts) => ({ ...drafts, [selectedProfile.user_id]: event.target.value }))}
                    className="w-full rounded-xl border border-[#3d4638] bg-[#101310] p-3 text-[#f2efe4] focus:border-[#7a6a3c] focus:outline-none focus:ring-2 focus:ring-[#d7c895]/25"
                  />
                </label>
                <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
                  <span className="text-xs text-[#858c7f]">{(noteDrafts[selectedProfile.user_id] ?? "").length} / 2000</span>
                  <button
                    type="button"
                    onClick={() => void saveAdminNote(selectedProfile)}
                    disabled={savingUserId === selectedProfile.user_id || (noteDrafts[selectedProfile.user_id] ?? "") === (selectedProfile.admin_note ?? "")}
                    className="min-h-11 rounded-xl bg-[#696f3d] px-4 py-2 text-sm font-bold text-white transition hover:bg-[#7a8147] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] disabled:opacity-40"
                  >
                    Zapisz notatkę
                  </button>
                </div>
              </section>

              <p className="text-xs text-[#73796e]">Konto utworzono {formatDate(selectedProfile.created_at)} · ostatnia aktualizacja {formatDate(selectedProfile.updated_at)}</p>
              {feedback && (
                <div role={feedback.tone === "error" ? "alert" : "status"} className={`rounded-xl border px-4 py-3 text-sm ${feedback.tone === "error" ? "border-[#744545] bg-[#2a1b1b] text-[#edb1b1]" : feedback.tone === "success" ? "border-[#536143] bg-[#20271e] text-[#b9d9b9]" : "border-[#665d45] bg-[#242119] text-[#d7c895]"}`}>{feedback.text}</div>
              )}
            </div>
          </section>
        </div>
      )}
    </AdminShell>
  );
}
