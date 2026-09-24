import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "StrzelajTu.pl | Rezerwacje strzelnic online",
  description:
    "Znajdź strzelnicę, sprawdź dostępność i zarezerwuj termin online w StrzelajTu.pl.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="pl" className="h-full antialiased">
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
