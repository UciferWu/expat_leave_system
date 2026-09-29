// Supabase Edge Function: notify-leave
// 员工提交休假申请后，向审批人发送邮件（含申请信息和审批链接）
// Envoie un e-mail au valideur après une demande de congé (détails + lien de validation)
// Emails the approver when a leave request is submitted (details + approval link)
//
// 需要在 Edge Functions → Secrets 中设置 / Secrets à définir :
//   RESEND_API_KEY   Resend 的 API Key（re_ 开头）
//   MAIL_FROM        发件人，例如 "员工休假系统 <leave@你的域名>"（域名须在 Resend 验证）
//   APP_URL          （可选）平台网址，默认 https://uciferwu.github.io/expat_leave_system/

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// ---------------------------------------------------------------------
// 邮件文案 / Textes
// ---------------------------------------------------------------------
const TXT: Record<string, Record<string, string>> = {
  zh: {
    subject: "【休假审批】{name} · {type} · {period}（{days}）",
    title: "新的休假申请待你审批",
    intro: "{name} 提交了一份休假申请，请登录系统审批。",
    employee: "申请人", type: "假期类型", period: "休假时间", days: "天数", reason: "事由",
    destination: "休假期间所在地", contact: "紧急联系方式", ref: "编号", balance: "申请人{kind}余额",
    balanceVal: "剩余 {avail} 天（审批中 {pend} 天，含本次）", attachment: "附件", hasAttachment: "已上传，请在系统中查看",
    button: "查看并审批", fallback: "如果按钮无法点击，请复制以下链接到浏览器打开：",
    footer: "此邮件由员工休假系统自动发送，请勿直接回复。",
    am: "上午", pm: "下午", unit: "天", annual: "年假", sick: "病假",
  },
  fr: {
    subject: "[Congé à valider] {name} · {type} · {period} ({days})",
    title: "Nouvelle demande de congé à valider",
    intro: "{name} a soumis une demande de congé. Merci de vous connecter pour la traiter.",
    employee: "Demandeur", type: "Type de congé", period: "Période", days: "Durée", reason: "Motif",
    destination: "Lieu pendant le congé", contact: "Contact d'urgence", ref: "Référence", balance: "Solde {kind} du demandeur",
    balanceVal: "{avail} j restants ({pend} j en attente, cette demande comprise)", attachment: "Justificatif", hasAttachment: "Joint — à consulter dans la plateforme",
    button: "Voir et valider", fallback: "Si le bouton ne fonctionne pas, copiez ce lien dans votre navigateur :",
    footer: "E-mail envoyé automatiquement par la plateforme de gestion des congés. Merci de ne pas y répondre.",
    am: "matin", pm: "après-midi", unit: "j", annual: "congés annuels", sick: "congés maladie",
  },
  en: {
    subject: "[Leave approval] {name} · {type} · {period} ({days})",
    title: "New leave request awaiting your approval",
    intro: "{name} has submitted a leave request. Please sign in to review it.",
    employee: "Employee", type: "Leave type", period: "Period", days: "Duration", reason: "Reason",
    destination: "Location during leave", contact: "Emergency contact", ref: "Reference", balance: "Employee {kind} balance",
    balanceVal: "{avail} days left ({pend} pending, incl. this request)", attachment: "Supporting document", hasAttachment: "Attached — view it in the platform",
    button: "Review and approve", fallback: "If the button does not work, copy this link into your browser:",
    footer: "This email was sent automatically by the leave management system. Please do not reply.",
    am: "morning", pm: "afternoon", unit: "days", annual: "annual leave", sick: "sick leave",
  },
};

const esc = (v: unknown) => String(v ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" } as Record<string, string>)[c]);
const fill = (s: string, v: Record<string, string>) => s.replace(/\{(\w+)\}/g, (_, k) => v[k] ?? "");
const num = (n: unknown) => { const v = Number(n || 0); return Number.isInteger(v) ? String(v) : v.toFixed(1).replace(/\.0$/, ""); };

export function renderEmail(lang: string, d: {
  name: string; employeeNo?: string | null; department?: string | null; typeName: string; color?: string;
  start: string; end: string; startHalf: boolean; endHalf: boolean; days: number;
  reason?: string | null; destination?: string | null; contact?: string | null; ref?: string | null;
  hasAttachment?: boolean; balance?: { kind: string; available: number; pending: number } | null; link: string;
}) {
  const T = TXT[lang] || TXT.fr;
  const loc = lang === "zh" ? "zh-CN" : lang === "en" ? "en-GB" : "fr-FR";
  const fd = (iso: string, withYear = true) => new Intl.DateTimeFormat(loc,
    { weekday: "short", day: "numeric", month: "short", ...(withYear ? { year: "numeric" } : {}) })
    .format(new Date(iso + "T00:00:00Z"));
  const days = lang === "zh" ? `${num(d.days)} 天` : lang === "en" ? `${num(d.days)} ${Number(d.days) === 1 ? "day" : "days"}` : `${num(d.days)} j`;
  const a = fd(d.start) + (d.startHalf ? ` (${T.pm})` : "");
  const period = d.start === d.end
    ? fd(d.start) + (d.startHalf ? ` (${T.pm})` : d.endHalf ? ` (${T.am})` : "")
    : `${a} → ${fd(d.end)}${d.endHalf ? ` (${T.am})` : ""}`;
  const shortPeriod = d.start === d.end ? fd(d.start, false) : `${fd(d.start, false)} – ${fd(d.end, false)}`;
  const subject = fill(T.subject, { name: d.name, type: d.typeName, period: shortPeriod, days });

  const row = (k: string, v: string) =>
    `<tr><td style="padding:9px 0;color:#64748b;font-size:14px;vertical-align:top;width:42%">${esc(k)}</td>` +
    `<td style="padding:9px 0;color:#0f172a;font-size:14px;font-weight:600;text-align:right">${v}</td></tr>`;
  const who = esc(d.name) + (d.employeeNo ? ` · ${esc(d.employeeNo)}` : "") +
    (d.department ? `<br><span style="color:#64748b;font-weight:400">${esc(d.department)}</span>` : "");
  const rows = [
    row(T.employee, who),
    row(T.type, `<span style="display:inline-block;width:9px;height:9px;border-radius:5px;background:${esc(d.color || "#2563eb")};margin-right:6px"></span>${esc(d.typeName)}`),
    row(T.period, esc(period)),
    row(T.days, `<span style="font-size:16px">${esc(days)}</span>`),
    d.balance ? row(fill(T.balance, { kind: T[d.balance.kind] || "" }),
      esc(fill(T.balanceVal, { avail: num(d.balance.available), pend: num(d.balance.pending) }))) : "",
    d.reason ? row(T.reason, esc(d.reason)) : "",
    d.destination ? row(T.destination, esc(d.destination)) : "",
    d.contact ? row(T.contact, esc(d.contact)) : "",
    d.hasAttachment ? row(T.attachment, esc(T.hasAttachment)) : "",
    d.ref ? row(T.ref, esc(d.ref)) : "",
  ].join("");

  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f3f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'PingFang SC','Microsoft YaHei',Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f5f9;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e2e8f0">
  <tr><td style="background:#1e40af;padding:20px 24px">
    <div style="color:#c7d2fe;font-size:12px;font-weight:600;letter-spacing:.3px">Winning Consortium</div>
    <div style="color:#ffffff;font-size:19px;font-weight:700;margin-top:4px">${esc(T.title)}</div></td></tr>
  <tr><td style="padding:20px 24px 4px;color:#334155;font-size:15px;line-height:1.5">${esc(fill(T.intro, { name: d.name }))}</td></tr>
  <tr><td style="padding:4px 24px 8px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid #eef2f7">${rows}</table></td></tr>
  <tr><td align="center" style="padding:16px 24px 8px">
    <a href="${esc(d.link)}" style="display:inline-block;background:#1e40af;color:#ffffff;text-decoration:none;font-weight:700;font-size:15px;padding:13px 28px;border-radius:10px">${esc(T.button)}</a></td></tr>
  <tr><td style="padding:8px 24px 20px;color:#64748b;font-size:12px;line-height:1.5">${esc(T.fallback)}<br>
    <a href="${esc(d.link)}" style="color:#2563eb;word-break:break-all">${esc(d.link)}</a></td></tr>
  <tr><td style="padding:14px 24px;background:#f8fafc;color:#94a3b8;font-size:11px;border-top:1px solid #eef2f7">${esc(T.footer)}</td></tr>
</table></td></tr></table></body></html>`;

  const text = [T.title, "", fill(T.intro, { name: d.name }), "",
    `${T.employee}: ${d.name}${d.employeeNo ? " · " + d.employeeNo : ""}`,
    `${T.type}: ${d.typeName}`, `${T.period}: ${period}`, `${T.days}: ${days}`,
    d.reason ? `${T.reason}: ${d.reason}` : "", d.ref ? `${T.ref}: ${d.ref}` : "", "",
    `${T.button}: ${d.link}`].filter((x) => x !== null).join("\n");
  return { subject, html, text };
}

// ---------------------------------------------------------------------
// 处理请求 / Handler
// ---------------------------------------------------------------------
if (typeof Deno !== "undefined") Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "ERR_METHOD" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const mailFrom = Deno.env.get("MAIL_FROM");
  if (!resendKey || !mailFrom) return json({ error: "ERR_MAIL_NOT_CONFIGURED" }, 500);

  const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const { data: who } = await asCaller.auth.getUser();
  if (!who?.user) return json({ error: "ERR_UNAUTHENTICATED" }, 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "ERR_BAD_REQUEST" }, 400); }
  const id = String(body.request_id ?? "");

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: r } = await admin.from("leave_requests").select("*").eq("id", id).maybeSingle();
  if (!r) return json({ error: "ERR_NOT_FOUND" }, 404);
  if (r.user_id !== who.user.id) return json({ error: "ERR_FORBIDDEN" }, 403);   // 只能由申请人本人触发
  if (r.status !== "pending") return json({ ok: true, skipped: "not_pending" });
  if (r.notified_at) return json({ ok: true, skipped: "already_sent" });           // 防止重复发送

  const [{ data: emp }, { data: lt }] = await Promise.all([
    admin.from("profiles").select("full_name,employee_no,department").eq("id", r.user_id).single(),
    admin.from("leave_types").select("*").eq("code", r.type_code).single(),
  ]);

  // 收件人：审批人；未指定审批人时发给所有在职管理员
  // Destinataires : le valideur, sinon tous les administrateurs actifs
  let recipients: { email: string; lang: string }[] = [];
  if (r.approver_id) {
    const { data: ap } = await admin.from("profiles").select("email,lang,active").eq("id", r.approver_id).maybeSingle();
    if (ap?.active && ap.email) recipients = [{ email: ap.email, lang: ap.lang }];
  }
  if (!recipients.length) {
    const { data: admins } = await admin.from("profiles").select("email,lang").eq("role", "admin").eq("active", true);
    recipients = (admins || []).filter((a) => a.email && a.email !== undefined).map((a) => ({ email: a.email, lang: a.lang }));
  }
  if (!recipients.length) return json({ ok: true, skipped: "no_recipient" });

  let balance = null;
  if (lt?.balance_kind) {
    const { data: b } = await admin.rpc("_leave_balance",
      { p_user: r.user_id, p_year: Number(r.start_date.slice(0, 4)), p_kind: lt.balance_kind });
    const row = Array.isArray(b) ? b[0] : b;
    if (row) balance = { kind: lt.balance_kind, available: Number(row.available), pending: Number(row.pending) };
  }

  const appUrl = (Deno.env.get("APP_URL") || "https://uciferwu.github.io/expat_leave_system/").replace(/#.*$/, "");
  const link = `${appUrl}#req/${r.id}`;

  const errors: string[] = [];
  for (const to of recipients) {
    const lang = ["zh", "fr", "en"].includes(to.lang) ? to.lang : "fr";
    const typeName = lang === "zh" ? lt?.name_zh : lang === "en" ? (lt?.name_en || lt?.name_fr) : lt?.name_fr;
    const mail = renderEmail(lang, {
      name: emp?.full_name || "", employeeNo: emp?.employee_no, department: emp?.department,
      typeName: typeName || r.type_code, color: lt?.color,
      start: r.start_date, end: r.end_date, startHalf: r.start_half, endHalf: r.end_half, days: r.days,
      reason: r.reason, destination: r.destination, contact: r.contact, ref: r.ref_no,
      hasAttachment: !!r.attachment_path, balance, link,
    });
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: mailFrom, to: [to.email], subject: mail.subject, html: mail.html, text: mail.text }),
    });
    if (!res.ok) errors.push(`${to.email}: ${res.status} ${await res.text()}`);
  }

  if (errors.length === recipients.length) return json({ error: "ERR_MAIL_SEND", details: errors }, 502);
  await admin.from("leave_requests").update({ notified_at: new Date().toISOString() }).eq("id", r.id);
  return json({ ok: true, sent: recipients.length - errors.length, errors });
});
