import Image from "next/image";
import Link from "next/link";
import logo from "@/public/brand/strzelajtu/logo-horizontal.png";

/** Presentation only: platform identity never supplies tenant or auth authority. */
export default function PlatformBrand({ compact = false }: { compact?: boolean }) {
  return (
    <Link href="/" aria-label="StrzelajTu.pl — strona główna" className="platform-brand">
      <Image src={logo} alt="StrzelajTu.pl" priority sizes={compact ? "240px" : "(max-width: 430px) 280px, 400px"}
        className={compact ? "platform-logo platform-logo-compact" : "platform-logo"} />
    </Link>
  );
}
