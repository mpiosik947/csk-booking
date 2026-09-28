import { escapeEmailHref, escapeHtml } from "./email-html.ts";

export type OperationalEmailLayoutInput = {
  tenantDisplayName: string;
  title: string;
  intro: string;
  details: ReadonlyArray<{ label: string; value: string }>;
  actions: ReadonlyArray<{ label: string; url: string; description?: string }>;
  notes?: ReadonlyArray<string>;
};

/** Pure presentation only: callers retain authority, subjects, routing and delivery. */
export function operationalEmailLayout(message: OperationalEmailLayoutInput): string {
  const paragraph = (text: string) => `<p style="margin:0 0 16px;color:#A6ADA5;font-size:16px;line-height:1.6;overflow-wrap:anywhere;word-break:break-word;">${escapeHtml(text)}</p>`;
  const details = message.details.map(({ label, value }) => `<tr><td style="padding:12px 16px;border-bottom:1px solid #303B27;overflow-wrap:anywhere;word-break:break-word;"><span style="font-size:14px;line-height:1.5;color:#A6ADA5;">${escapeHtml(label)}</span><br><strong style="font-size:16px;line-height:1.6;font-weight:600;color:#F4F3EE;">${escapeHtml(value)}</strong></td></tr>`).join("");
  const actions = message.actions.map(({ label, url, description }) => `${description ? paragraph(description) : ""}<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%;table-layout:fixed;margin:0 0 20px;"><tr><td align="center" bgcolor="#F5A900" style="background:#F5A900;border-radius:8px;mso-padding-alt:16px 20px;"><a href="${escapeEmailHref(url)}" style="display:block;padding:16px 20px;color:#080B09;text-decoration:none;font-size:16px;line-height:1.5;font-weight:bold;text-align:center;overflow-wrap:anywhere;word-break:break-word;">${escapeHtml(label)}</a></td></tr></table>`).join("");
  return `<!doctype html>
<html lang="pl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>${escapeHtml(message.title)}</title></head>
<body style="margin:0;padding:0;background:#080B09;color:#F4F3EE;font-family:Arial,Helvetica,sans-serif;-webkit-text-size-adjust:100%;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#080B09" style="width:100%;table-layout:fixed;background:#080B09;"><tr><td align="center" style="padding:24px 12px;">
<!--[if mso]><table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0"><tr><td><![endif]-->
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" data-operational-email="strzelajtu" style="width:100%;max-width:600px;table-layout:fixed;margin:0 auto;">
<tr><td align="center" style="padding:8px 16px 24px;overflow-wrap:anywhere;word-break:break-word;">
<img src="https://strzelajtu.pl/brand/strzelajtu/logo-horizontal.png" width="240" alt="StrzelajTu.pl" style="display:block;width:240px;max-width:100%;height:auto;border:0;color:#F4F3EE;font-size:24px;">
<p style="margin:16px 0 0;color:#A6ADA5;font-size:16px;line-height:1.5;">${escapeHtml(message.tenantDisplayName)}</p></td></tr>
<tr><td bgcolor="#111712" style="padding:24px 20px;background:#111712;border:1px solid #697A2F;border-radius:14px;overflow-wrap:anywhere;word-break:break-word;">
<h1 style="margin:0 0 16px;color:#F4F3EE;font-size:26px;line-height:1.3;font-weight:700;">${escapeHtml(message.title)}</h1>
${paragraph(message.intro)}
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#182019" style="width:100%;table-layout:fixed;background:#182019;margin:24px 0;border-radius:8px;">${details}</table>
${actions}${(message.notes ?? []).map(paragraph).join("")}
</td></tr>
<tr><td align="center" style="padding:24px 16px 8px;color:#A6ADA5;font-size:14px;line-height:1.7;"><strong style="color:#F4F3EE;font-weight:600;">StrzelajTu.pl</strong><br>System rezerwacji strzelnic</td></tr>
</table>
<!--[if mso]></td></tr></table><![endif]-->
</td></tr></table></body></html>`;
}
