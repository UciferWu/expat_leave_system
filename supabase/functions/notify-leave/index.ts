// Supabase Edge Function: notify-leave
// 休假流程邮件提醒 / Notifications e-mail du circuit de congé / Leave workflow email notifications
//
//   新申请          → 审批人（未指定审批人时发给所有管理员）
//   批准 / 驳回      → 申请人
//   修改已批准休假   → 申请人
//   管理员撤销休假   → 申请人
//   员工撤回待审批   → 审批人
//
// 网页在每次操作后调用本函数：{ request_id }。函数只发送"由调用者本人产生、尚未通知"的操作记录，
// 每条记录只发送一次（leave_events.notified_at）。
//
// 发信方式（二选一，均通过环境变量 / Secrets 配置）：
//   ① 公司邮箱 SMTP（推荐，无需改域名解析）
//        MAIL_SMTP_HOST  例如 smtp.qiye.aliyun.com
//        MAIL_SMTP_PORT  465（SSL，默认）或 587（STARTTLS）
//        MAIL_SMTP_USER  发信邮箱账号
//        MAIL_SMTP_PASS  密码或客户端授权码
//   ② Resend：RESEND_API_KEY
//   MAIL_FROM  （可选）发件人，例如 "员工休假系统 <leave@公司域名>"；SMTP 默认用 MAIL_SMTP_USER
//   APP_URL    平台网址，用于邮件中的链接
//
// 测试：以 service_role 密钥调用 { "test_to": "someone@example.com" } 发送一封测试邮件。

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// =====================================================================
// 邮件文案 / Textes
// =====================================================================
type Kind = "submitted" | "approved" | "rejected" | "modified" | "revoked" | "withdrawn" | "test";
type Lang = "zh" | "fr" | "en";

const COMMON: Record<Lang, Record<string, string>> = {
  zh: {
    employee: "申请人", type: "假期类型", period: "休假时间", oldPeriod: "原休假时间", newPeriod: "新休假时间",
    days: "天数", reason: "事由", destination: "休假期间所在地", contact: "紧急联系方式", ref: "编号",
    attachment: "附件", attachmentVal: "{n} 个，请在系统中查看", by: "处理人",
    balanceSubmitted: "申请人{kind}余额", balanceSubmittedVal: "剩余 {avail} 天（审批中 {pend} 天，含本次）",
    balanceApproved: "你的{kind}余额", balanceApprovedVal: "剩余 {avail} 天",
    view: "查看详情", fallback: "如果按钮无法点击，请复制以下链接到浏览器打开：",
    footer: "此邮件由员工休假系统自动发送，请勿直接回复。",
    am: "上午", pm: "下午", annual: "年假", sick: "病假", company: "Winning Consortium",
  },
  fr: {
    employee: "Demandeur", type: "Type de congé", period: "Période", oldPeriod: "Période initiale", newPeriod: "Nouvelle période",
    days: "Durée", reason: "Motif", destination: "Lieu pendant le congé", contact: "Contact d'urgence", ref: "Référence",
    attachment: "Justificatifs", attachmentVal: "{n} fichier(s) — à consulter dans la plateforme", by: "Traité par",
    balanceSubmitted: "Solde {kind} du demandeur", balanceSubmittedVal: "{avail} j restants ({pend} j en attente, cette demande comprise)",
    balanceApproved: "Votre solde {kind}", balanceApprovedVal: "{avail} j restants",
    view: "Voir le détail", fallback: "Si le bouton ne fonctionne pas, copiez ce lien dans votre navigateur :",
    footer: "E-mail envoyé automatiquement par la plateforme de gestion des congés. Merci de ne pas y répondre.",
    am: "matin", pm: "après-midi", annual: "congés annuels", sick: "congés maladie", company: "Winning Consortium",
  },
  en: {
    employee: "Employee", type: "Leave type", period: "Period", oldPeriod: "Original period", newPeriod: "New period",
    days: "Duration", reason: "Reason", destination: "Location during leave", contact: "Emergency contact", ref: "Reference",
    attachment: "Attachments", attachmentVal: "{n} file(s) — view them in the platform", by: "Handled by",
    balanceSubmitted: "Employee {kind} balance", balanceSubmittedVal: "{avail} days left ({pend} pending, incl. this request)",
    balanceApproved: "Your {kind} balance", balanceApprovedVal: "{avail} days left",
    view: "View details", fallback: "If the button does not work, copy this link into your browser:",
    footer: "This email was sent automatically by the leave management system. Please do not reply.",
    am: "morning", pm: "afternoon", annual: "annual leave", sick: "sick leave", company: "Winning Consortium",
  },
};

// subject / title / intro / button / commentLabel / color
const KINDS: Record<Lang, Record<Kind, [string, string, string, string, string]>> = {
  zh: {
    submitted: ["【休假审批】{name} · {type} · {short}（{days}）", "新的休假申请待你审批", "{name} 提交了一份休假申请，请登录系统审批。", "查看并审批", ""],
    approved:  ["【休假已批准】{type} · {short}（{days}）", "你的休假申请已批准", "{actor} 已批准你的休假申请。", "", "审批意见"],
    rejected:  ["【休假被驳回】{type} · {short}", "你的休假申请被驳回", "{actor} 驳回了你的休假申请。", "", "驳回原因"],
    modified:  ["【休假已修改】{type} · {short}（{days}）", "你的休假已被修改", "{actor} 修改了你已批准的休假，请留意新的休假时间。", "", "修改原因"],
    revoked:   ["【休假已撤销】{type} · {short}", "你的休假已被撤销", "{actor} 撤销了你已批准的休假，相应天数已退回余额。", "", "撤销原因"],
    withdrawn: ["【申请已撤回】{name} · {type} · {short}", "休假申请已撤回", "{name} 撤回了一份待你审批的休假申请，无需再处理。", "", ""],
    test:      ["【测试邮件】员工休假系统邮件配置成功", "邮件配置成功", "这是一封测试邮件。能收到它，说明员工休假系统的邮件提醒已经配置好了。", "打开系统", ""],
  },
  fr: {
    submitted: ["[Congé à valider] {name} · {type} · {short} ({days})", "Nouvelle demande de congé à valider", "{name} a soumis une demande de congé. Merci de vous connecter pour la traiter.", "Voir et valider", ""],
    approved:  ["[Congé approuvé] {type} · {short} ({days})", "Votre demande de congé est approuvée", "{actor} a approuvé votre demande de congé.", "", "Commentaire"],
    rejected:  ["[Congé refusé] {type} · {short}", "Votre demande de congé est refusée", "{actor} a refusé votre demande de congé.", "", "Motif du refus"],
    modified:  ["[Congé modifié] {type} · {short} ({days})", "Votre congé a été modifié", "{actor} a modifié votre congé approuvé. Merci de noter les nouvelles dates.", "", "Motif de la modification"],
    revoked:   ["[Congé révoqué] {type} · {short}", "Votre congé a été révoqué", "{actor} a révoqué votre congé approuvé ; les jours ont été recrédités.", "", "Motif de la révocation"],
    withdrawn: ["[Demande annulée] {name} · {type} · {short}", "Demande de congé annulée", "{name} a annulé une demande qui était en attente de votre validation. Aucune action n'est requise.", "", ""],
    test:      ["[Test] Configuration e-mail réussie", "Configuration réussie", "Ceci est un e-mail de test : les notifications de la plateforme de congés fonctionnent.", "Ouvrir la plateforme", ""],
  },
  en: {
    submitted: ["[Leave approval] {name} · {type} · {short} ({days})", "New leave request awaiting your approval", "{name} has submitted a leave request. Please sign in to review it.", "Review and approve", ""],
    approved:  ["[Leave approved] {type} · {short} ({days})", "Your leave request has been approved", "{actor} approved your leave request.", "", "Comment"],
    rejected:  ["[Leave rejected] {type} · {short}", "Your leave request has been rejected", "{actor} rejected your leave request.", "", "Reason"],
    modified:  ["[Leave changed] {type} · {short} ({days})", "Your leave has been changed", "{actor} changed your approved leave. Please note the new dates.", "", "Reason for change"],
    revoked:   ["[Leave revoked] {type} · {short}", "Your leave has been revoked", "{actor} revoked your approved leave; the days have been credited back.", "", "Reason"],
    withdrawn: ["[Request withdrawn] {name} · {type} · {short}", "Leave request withdrawn", "{name} withdrew a request that was awaiting your approval. No action is needed.", "", ""],
    test:      ["[Test] Email notifications are working", "Email setup successful", "This is a test email: leave system notifications are configured correctly.", "Open the platform", ""],
  },
};
const COLORS: Record<Kind, string> = {
  submitted: "#1e40af", approved: "#15803d", rejected: "#b91c1c", modified: "#b45309",
  revoked: "#475569", withdrawn: "#475569", test: "#1e40af",
};

const esc = (v: unknown) => String(v ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" } as Record<string, string>)[c]);
const fill = (s: string, v: Record<string, string>) => s.replace(/\{(\w+)\}/g, (_, k) => v[k] ?? "");
const num = (n: unknown) => { const v = Number(n || 0); return Number.isInteger(v) ? String(v) : v.toFixed(1).replace(/\.0$/, ""); };

export type Period = { start: string; end: string; startHalf?: boolean; endHalf?: boolean; days?: number };
export type MailData = {
  name: string; employeeNo?: string | null; department?: string | null;
  typeName: string; color?: string;
  period: Period; oldPeriod?: Period | null;
  reason?: string | null; destination?: string | null; contact?: string | null; ref?: string | null;
  attachments?: number; balance?: { kind: string; available: number; pending: number } | null;
  actorName?: string | null; comment?: string | null; link: string;
};

export function renderEmail(langIn: string, kind: Kind, d: MailData) {
  const lang = (["zh", "fr", "en"].includes(langIn) ? langIn : "fr") as Lang;
  const C = COMMON[lang], [subjectT, titleT, introT, buttonT, commentLabel] = KINDS[lang][kind];
  const loc = lang === "zh" ? "zh-CN" : lang === "en" ? "en-GB" : "fr-FR";
  const fd = (iso: string, withYear = true) => new Intl.DateTimeFormat(loc,
    { weekday: "short", day: "numeric", month: "short", ...(withYear ? { year: "numeric" } : {}), timeZone: "UTC" })
    .format(new Date(iso + "T00:00:00Z"));
  const fdays = (n: unknown) => lang === "zh" ? `${num(n)} 天` : lang === "en" ? `${num(n)} ${Number(n) === 1 ? "day" : "days"}` : `${num(n)} j`;
  const fperiod = (p: Period) => p.start === p.end
    ? fd(p.start) + (p.startHalf ? ` (${C.pm})` : p.endHalf ? ` (${C.am})` : "")
    : `${fd(p.start)}${p.startHalf ? ` (${C.pm})` : ""} → ${fd(p.end)}${p.endHalf ? ` (${C.am})` : ""}`;
  const fshort = (p: Period) => p.start === p.end ? fd(p.start, false) : `${fd(p.start, false)} – ${fd(p.end, false)}`;

  const v = { name: d.name, actor: d.actorName || "", type: d.typeName,
    short: d.period?.start ? fshort(d.period) : "", days: d.period?.days != null ? fdays(d.period.days) : "" };
  const subject = fill(subjectT, v);
  const intro = fill(introT, v);
  const button = buttonT || C.view;
  const color = COLORS[kind];

  const row = (k: string, val: string) =>
    `<tr><td style="padding:9px 0;color:#64748b;font-size:14px;vertical-align:top;width:40%">${esc(k)}</td>` +
    `<td style="padding:9px 0;color:#0f172a;font-size:14px;font-weight:600;text-align:right">${val}</td></tr>`;
  const rows: string[] = [];
  if (kind !== "test") {
    if (kind === "submitted" || kind === "withdrawn") {
      rows.push(row(C.employee, esc(d.name) + (d.employeeNo ? ` · ${esc(d.employeeNo)}` : "") +
        (d.department ? `<br><span style="color:#64748b;font-weight:400">${esc(d.department)}</span>` : "")));
    }
    rows.push(row(C.type, `<span style="display:inline-block;width:9px;height:9px;border-radius:5px;background:${esc(d.color || "#2563eb")};margin-right:6px"></span>${esc(d.typeName)}`));
    if (kind === "modified" && d.oldPeriod) {
      rows.push(row(C.oldPeriod, `<span style="color:#94a3b8;text-decoration:line-through;font-weight:400">${esc(fperiod(d.oldPeriod))} · ${esc(fdays(d.oldPeriod.days))}</span>`));
      rows.push(row(C.newPeriod, esc(fperiod(d.period))));
    } else {
      rows.push(row(C.period, esc(fperiod(d.period))));
    }
    if (d.period.days != null) rows.push(row(C.days, `<span style="font-size:16px">${esc(fdays(d.period.days))}</span>`));
    if (d.balance && kind === "submitted") {
      rows.push(row(fill(C.balanceSubmitted, { kind: C[d.balance.kind] || "" }),
        esc(fill(C.balanceSubmittedVal, { avail: num(d.balance.available), pend: num(d.balance.pending) }))));
    }
    if (d.balance && (kind === "approved" || kind === "modified" || kind === "revoked")) {
      rows.push(row(fill(C.balanceApproved, { kind: C[d.balance.kind] || "" }),
        esc(fill(C.balanceApprovedVal, { avail: num(d.balance.available) }))));
    }
    if (kind === "submitted") {
      if (d.reason) rows.push(row(C.reason, esc(d.reason)));
      if (d.destination) rows.push(row(C.destination, esc(d.destination)));
      if (d.contact) rows.push(row(C.contact, esc(d.contact)));
      if (d.attachments) rows.push(row(C.attachment, esc(fill(C.attachmentVal, { n: String(d.attachments) }))));
    }
    if (d.actorName && kind !== "submitted" && kind !== "withdrawn") rows.push(row(C.by, esc(d.actorName)));
    if (d.ref) rows.push(row(C.ref, esc(d.ref)));
  }
  const commentBlock = commentLabel && d.comment
    ? `<tr><td style="padding:4px 24px 8px"><div style="background:#f8fafc;border-left:3px solid ${color};border-radius:6px;padding:10px 12px">
        <div style="color:#64748b;font-size:12px;font-weight:600;margin-bottom:3px">${esc(commentLabel)}</div>
        <div style="color:#0f172a;font-size:14px;line-height:1.5">${esc(d.comment)}</div></div></td></tr>` : "";

  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f3f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'PingFang SC','Microsoft YaHei',Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f5f9;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e2e8f0">
  <tr><td style="background:${color};padding:20px 24px">
    <div style="color:#ffffffb3;font-size:12px;font-weight:600;letter-spacing:.3px">${esc(C.company)}</div>
    <div style="color:#ffffff;font-size:19px;font-weight:700;margin-top:4px">${esc(titleT)}</div></td></tr>
  <tr><td style="padding:20px 24px 4px;color:#334155;font-size:15px;line-height:1.5">${esc(intro)}</td></tr>
  ${rows.length ? `<tr><td style="padding:4px 24px 8px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid #eef2f7">${rows.join("")}</table></td></tr>` : ""}
  ${commentBlock}
  <tr><td align="center" style="padding:16px 24px 8px">
    <a href="${esc(d.link)}" style="display:inline-block;background:${color};color:#ffffff;text-decoration:none;font-weight:700;font-size:15px;padding:13px 28px;border-radius:10px">${esc(button)}</a></td></tr>
  <tr><td style="padding:8px 24px 20px;color:#64748b;font-size:12px;line-height:1.5">${esc(C.fallback)}<br>
    <a href="${esc(d.link)}" style="color:#2563eb;word-break:break-all">${esc(d.link)}</a></td></tr>
  <tr><td style="padding:14px 24px;background:#f8fafc;color:#94a3b8;font-size:11px;border-top:1px solid #eef2f7">${esc(C.footer)}</td></tr>
</table></td></tr></table></body></html>`;

  const text = [titleT, "", intro, "",
    kind !== "test" ? `${C.type}: ${d.typeName}` : "",
    kind !== "test" ? `${C.period}: ${fperiod(d.period)}` : "",
    commentLabel && d.comment ? `${commentLabel}: ${d.comment}` : "",
    "", `${button}: ${d.link}`].filter((x, i, a) => x !== "" || (i > 0 && a[i - 1] !== "")).join("\n");
  return { subject, html, text };
}

// =====================================================================
// 发信 / Envoi
// =====================================================================
const env = (k: string) => (typeof Deno !== "undefined" ? Deno.env.get(k) : undefined) || "";
// deno-lint-ignore no-explicit-any
let smtp: any = null;

export async function sendMail(to: string, subject: string, html: string, text: string) {
  const host = env("MAIL_SMTP_HOST");
  if (host) {
    const port = Number(env("MAIL_SMTP_PORT") || 465);
    const user = env("MAIL_SMTP_USER");
    if (!smtp) {
      const nodemailer = (await import("npm:nodemailer@6.9.16")).default;
      smtp = nodemailer.createTransport({
        host, port, secure: port === 465,
        auth: user ? { user, pass: env("MAIL_SMTP_PASS") } : undefined,
        connectionTimeout: 15000, greetingTimeout: 15000, socketTimeout: 30000,
      });
    }
    const from = env("MAIL_FROM") || `员工休假系统 / Congés <${user}>`;
    await smtp.sendMail({ from, to, subject, html, text });
    return;
  }
  const resendKey = env("RESEND_API_KEY");
  if (resendKey) {
    const from = env("MAIL_FROM");
    if (!from) throw new Error("MAIL_FROM is required with Resend");
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to: [to], subject, html, text }),
    });
    if (!res.ok) throw new Error(`Resend ${res.status}: ${await res.text()}`);
    return;
  }
  throw new Error("ERR_MAIL_NOT_CONFIGURED");
}

// =====================================================================
// 处理请求 / Handler
// =====================================================================
if (typeof Deno !== "undefined") Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "ERR_METHOD" }, 405);

  const url = env("SUPABASE_URL"), anonKey = env("SUPABASE_ANON_KEY"), serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  const appUrl = (env("APP_URL") || "https://uciferwu.github.io/expat_leave_system/").replace(/#.*$/, "");
  const authHeader = req.headers.get("Authorization") ?? "";
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "ERR_BAD_REQUEST" }, 400); }

  // ---------- 测试邮件（仅限 service_role）/ E-mail de test ----------
  if (body.test_to) {
    if (authHeader !== `Bearer ${serviceKey}`) return json({ error: "ERR_FORBIDDEN" }, 403);
    const lang = String(body.lang || "zh");
    const m = renderEmail(lang, "test", { name: "", typeName: "", period: { start: "", end: "" }, link: appUrl });
    try { await sendMail(String(body.test_to), m.subject, m.html, m.text); return json({ ok: true }); }
    catch (e) { return json({ error: (e as Error).message }, 502); }
  }

  // ---------- 调用者身份 / Appelant ----------
  const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: who } = await asCaller.auth.getUser();
  if (!who?.user) return json({ error: "ERR_UNAUTHENTICATED" }, 401);
  const callerId = who.user.id;

  const id = String(body.request_id ?? "");
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: r } = await admin.from("leave_requests").select("*").eq("id", id).maybeSingle();
  if (!r) return json({ error: "ERR_NOT_FOUND" }, 404);

  // 只处理由调用者本人产生、尚未通知的记录 / Seuls les événements de l'appelant non encore notifiés
  const { data: events } = await admin.from("leave_events").select("*")
    .eq("request_id", id).eq("actor_id", callerId).is("notified_at", null).order("id");
  if (!events?.length) return json({ ok: true, sent: 0 });

  const [{ data: emp }, { data: lt }] = await Promise.all([
    admin.from("profiles").select("id,full_name,employee_no,department,email,lang,active").eq("id", r.user_id).single(),
    admin.from("leave_types").select("*").eq("code", r.type_code).single(),
  ]);

  async function approvers() {
    if (r.approver_id) {
      const { data: ap } = await admin.from("profiles").select("email,lang,active").eq("id", r.approver_id).maybeSingle();
      if (ap?.active && ap.email) return [{ email: ap.email, lang: ap.lang }];
    }
    const { data: admins } = await admin.from("profiles").select("id,email,lang").eq("role", "admin").eq("active", true);
    return (admins || []).filter((a) => a.email && a.id !== r.user_id).map((a) => ({ email: a.email, lang: a.lang }));
  }
  async function balance() {
    if (!lt?.balance_kind) return null;
    const { data: b } = await admin.rpc("_leave_balance",
      { p_user: r.user_id, p_year: Number(r.start_date.slice(0, 4)), p_kind: lt.balance_kind });
    const row = Array.isArray(b) ? b[0] : b;
    return row ? { kind: lt.balance_kind, available: Number(row.available), pending: Number(row.pending) } : null;
  }

  const link = `${appUrl}#req/${r.id}`;
  const current: Period = { start: r.start_date, end: r.end_date, startHalf: r.start_half, endHalf: r.end_half, days: Number(r.days) };
  const results: unknown[] = [];

  for (const ev of events) {
    // 先占用，避免并发重复发送 / Réservation atomique
    const { data: claimed } = await admin.from("leave_events").update({ notified_at: new Date().toISOString() })
      .eq("id", ev.id).is("notified_at", null).select("id");
    if (!claimed?.length) continue;

    let kind: Kind; let recipients: { email: string; lang: string }[] = [];
    if (ev.action === "submitted") { kind = "submitted"; recipients = await approvers(); }
    else if (ev.action === "approved" || ev.action === "rejected" || ev.action === "modified") { kind = ev.action; }
    else if (ev.action === "cancelled" && ev.actor_id === r.user_id) { kind = "withdrawn"; recipients = await approvers(); }
    else if (ev.action === "cancelled") { kind = "revoked"; }
    else continue;
    if (kind !== "submitted" && kind !== "withdrawn") {
      if (emp?.active && emp.email) recipients = [{ email: emp.email, lang: emp.lang }];
    }
    recipients = recipients.filter((x, i, a) => a.findIndex((y) => y.email === x.email) === i);
    if (!recipients.length) { results.push({ event: ev.id, skipped: "no_recipient" }); continue; }

    const det = ev.details || {};
    const toP = (p: Record<string, unknown> | undefined): Period | null => p && p.start ? {
      start: String(p.start), end: String(p.end), startHalf: !!p.start_half, endHalf: !!p.end_half, days: Number(p.days) } : null;
    const period = kind === "modified" ? (toP(det.new) || current) : current;
    const bal = ["submitted", "approved", "modified", "revoked"].includes(kind) ? await balance() : null;

    const errors: string[] = [];
    for (const to of recipients) {
      const lang = ["zh", "fr", "en"].includes(to.lang) ? to.lang : "fr";
      const typeName = lang === "zh" ? lt?.name_zh : lang === "en" ? (lt?.name_en || lt?.name_fr) : lt?.name_fr;
      const m = renderEmail(lang, kind, {
        name: emp?.full_name || "", employeeNo: emp?.employee_no, department: emp?.department,
        typeName: typeName || r.type_code, color: lt?.color, period, oldPeriod: toP(det.old),
        reason: r.reason, destination: r.destination, contact: r.contact, ref: r.ref_no,
        attachments: r.attachment_paths?.length || (r.attachment_path ? 1 : 0),
        balance: bal, actorName: ev.actor_name, comment: ev.comment, link,
      });
      try { await sendMail(to.email, m.subject, m.html, m.text); }
      catch (e) { errors.push(`${to.email}: ${(e as Error).message}`); }
    }
    if (errors.length === recipients.length) {
      // 全部失败：恢复为未通知，下次操作时会重试 / échec : sera retenté
      await admin.from("leave_events").update({ notified_at: null }).eq("id", ev.id);
    }
    results.push({ event: ev.id, kind, sent: recipients.length - errors.length, errors });
  }
  return json({ ok: true, results });
});
