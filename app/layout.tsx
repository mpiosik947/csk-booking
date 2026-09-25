import type { Metadata } from "next";
import "./globals.css";
import "./platform-brand.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://strzelajtu.pl"),
  title: "StrzelajTu.pl — znajdź strzelnicę i zarezerwuj termin",
  icons: { icon: "/brand/strzelajtu/logo-symbol.png", apple: "/brand/strzelajtu/logo-symbol.png" },
  openGraph: {
    title: "StrzelajTu.pl — znajdź strzelnicę i zarezerwuj termin",
    description: "Jedno konto do rezerwacji na wszystkich strzelnicach.",
    images: ["/brand/strzelajtu/logo-horizontal.png"],
  },
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
