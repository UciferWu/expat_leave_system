// Supabase Edge Function: admin-users
// 管理员创建账号 / 重置密码 / 停用启用账号
// Création de comptes, réinitialisation du mot de passe, activation / désactivation (admin uniquement)
//
// 部署 / Déploiement : Supabase Dashboard → Edge Functions → Deploy a new function
// → Via Editor → 名称填 admin-users → 粘贴本文件 → Deploy
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY 由平台自动注入，无需手动配置。

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// 生成易读的临时密码（去掉易混淆字符）/ Mot de passe temporaire lisible
function tempPassword(len = 10): string {
  const chars = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";
  const buf = new Uint32Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (n) => chars[n % chars.length]).join("");
}

const PROFILE_FIELDS = [
  "full_name", "employee_no", "position", "department", "nationality", "work_country",
  "role", "approver_id", "hire_date", "probation_end", "annual_days", "sick_days", "lang",
] as const;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "ERR_METHOD" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // 1. 确认调用者是在职管理员 / Vérifier que l'appelant est un admin actif
  const authHeader = req.headers.get("Authorization") ?? "";
  const asCaller = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: who, error: whoErr } = await asCaller.auth.getUser();
  if (whoErr || !who?.user) return json({ error: "ERR_UNAUTHENTICATED" }, 401);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: me } = await admin
    .from("profiles").select("id, role, active").eq("id", who.user.id).single();
  if (!me || me.role !== "admin" || !me.active) return json({ error: "ERR_FORBIDDEN" }, 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "ERR_BAD_REQUEST" }, 400); }
  const action = body.action as string;

  try {
    // ---------------- 创建账号 / Créer un compte ----------------
    if (action === "create") {
      const email = String(body.email ?? "").trim().toLowerCase();
      const fullName = String(body.full_name ?? "").trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: "ERR_EMAIL" }, 400);
      if (!fullName) return json({ error: "ERR_NAME" }, 400);
      const password = (body.password as string)?.trim() || tempPassword();
      if (password.length < 8) return json({ error: "ERR_PASSWORD_SHORT" }, 400);

      const { data: created, error } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { full_name: fullName, lang: body.lang ?? "fr" },
      });
      if (error) {
        const exists = /already|registered|exists/i.test(error.message);
        return json({ error: exists ? "ERR_EMAIL_EXISTS" : error.message }, 400);
      }
      const uid = created.user!.id;

      const patch: Record<string, unknown> = { email, must_change_password: true };
      for (const k of PROFILE_FIELDS) if (k in body) patch[k] = body[k] === "" ? null : body[k];
      patch.full_name = fullName;
      if (!patch.role) patch.role = "employee";
      // 触发器已建档，这里补全字段 / le trigger a créé le profil ; on le complète
      const { error: pErr } = await admin.from("profiles").upsert({ id: uid, ...patch });
      if (pErr) {
        await admin.auth.admin.deleteUser(uid); // 回滚 / annulation
        return json({ error: pErr.message }, 400);
      }

      return json({ ok: true, user_id: uid, email, password });
    }

    // ---------------- 重置密码 / Réinitialiser ----------------
    if (action === "reset_password") {
      const uid = String(body.user_id ?? "");
      const password = (body.password as string)?.trim() || tempPassword();
      if (password.length < 8) return json({ error: "ERR_PASSWORD_SHORT" }, 400);
      const { error } = await admin.auth.admin.updateUserById(uid, { password });
      if (error) return json({ error: error.message }, 400);
      await admin.from("profiles").update({ must_change_password: true }).eq("id", uid);
      return json({ ok: true, password });
    }

    // ---------------- 停用 / 启用 / Activer – désactiver ----------------
    if (action === "set_active") {
      const uid = String(body.user_id ?? "");
      const active = Boolean(body.active);
      if (uid === me.id && !active) return json({ error: "ERR_SELF_DEACTIVATE" }, 400);
      const { error } = await admin.auth.admin.updateUserById(uid, {
        ban_duration: active ? "none" : "876000h",
      });
      if (error) return json({ error: error.message }, 400);
      await admin.from("profiles").update({ active }).eq("id", uid);
      return json({ ok: true });
    }

    return json({ error: "ERR_ACTION" }, 400);
  } catch (e) {
    return json({ error: (e as Error).message ?? "ERR_UNKNOWN" }, 500);
  }
});
