import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "CSK Booking | Centrum Szkolenia Krutla",
  description:
    "Rezerwacje strzelnicy, szkolenia strzeleckie, wydarzenia i obsluga klientow Centrum Szkolenia Krutla.",
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
