import type { NextConfig } from "next";

type ContentSecurityPolicyOptions = {
  nodeEnv?: string;
  supabaseUrl?: string;
};

const PRIVATE_NO_STORE_HEADERS = [
  {
    key: "Cache-Control",
    value: "private, no-store, max-age=0, must-revalidate",
  },
];

function getSupabaseConnectSources(rawUrl?: string) {
  if (!rawUrl) {
    return [];
  }

  try {
    const url = new URL(rawUrl);

    if (url.protocol !== "https:" && url.protocol !== "http:") {
      return [];
    }

    const websocketProtocol = url.protocol === "https:" ? "wss:" : "ws:";
    const websocketOrigin = `${websocketProtocol}//${url.host}`;

    return [url.origin, websocketOrigin];
  } catch {
    return [];
  }
}

export function buildContentSecurityPolicy({
  nodeEnv = process.env.NODE_ENV,
  supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL,
}: ContentSecurityPolicyOptions = {}) {
  const scriptSources = ["'self'", "'unsafe-inline'"];

  if (nodeEnv !== "production") {
    scriptSources.push("'unsafe-eval'");
  }

  const connectSources = [
    "'self'",
    ...getSupabaseConnectSources(supabaseUrl),
  ];

  return [
    "default-src 'self'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'",
    `script-src ${scriptSources.join(" ")}`,
    "script-src-attr 'none'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    `connect-src ${connectSources.join(" ")}`,
    "frame-src 'none'",
    "manifest-src 'self'",
    "worker-src 'self' blob:",
  ].join("; ");
}

export function getApplicationSecurityHeaders() {
  return [
    {
      key: "Content-Security-Policy",
      value: buildContentSecurityPolicy(),
    },
    { key: "X-Content-Type-Options", value: "nosniff" },
    {
      key: "Referrer-Policy",
      value: "strict-origin-when-cross-origin",
    },
    { key: "X-Frame-Options", value: "DENY" },
    {
      key: "Permissions-Policy",
      value:
        "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()",
    },
    { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
  ];
}

const nextConfig: NextConfig = {
  async headers() {
    const securityHeaders = getApplicationSecurityHeaders();

    return [
      {
        source: "/:path*",
        headers: securityHeaders,
      },
      {
        source: "/api/:path*",
        headers: PRIVATE_NO_STORE_HEADERS,
      },
      {
        source:
          "/:path(account|dashboard|my-events|my-reservations|reset-password)",
        headers: PRIVATE_NO_STORE_HEADERS,
      },
      {
        source: "/admin/:path*",
        headers: PRIVATE_NO_STORE_HEADERS,
      },
      {
        source: "/check-in/:path*",
        headers: [
          ...PRIVATE_NO_STORE_HEADERS,
          { key: "Referrer-Policy", value: "no-referrer" },
        ],
      },
      {
        source: "/events/confirm/:path*",
        headers: [
          ...PRIVATE_NO_STORE_HEADERS,
          { key: "Referrer-Policy", value: "no-referrer" },
        ],
      },
    ];
  },
};

export default nextConfig;
