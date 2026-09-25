import { notFound } from "next/navigation";

// Settings require the authenticated /t/[slug]/admin/settings route.
// A global URL supplies no trusted tenant context.
export default function AdminSettingsPage() {
  notFound();
}
