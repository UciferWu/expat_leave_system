# 法籍员工休假申请审批平台 · Plateforme de congés des expatriés

几内亚法籍员工的休假申请、查询与审批平台。纯静态网页（GitHub Pages）+ Supabase，手机可直接使用，中文 / 法文 / 英文一键切换，账号只能由管理员创建。

Plateforme de demande, de suivi et de validation des congés des salariés français en Guinée. Site statique (GitHub Pages) + Supabase, utilisable sur mobile, bilingue chinois / français, comptes créés uniquement par l'administrateur.

---

## 功能 / Fonctionnalités

| 角色 Rôle | 能做什么 Ce qu'il peut faire |
|---|---|
| 员工 Employé | 申请休假（全天/半天、附件、事由、休假地、紧急联系方式）；查看年假余额；按年份和状态查询自己的申请；撤回待审批的申请<br>Demander un congé (journée / demi-journée, justificatif…) ; consulter son solde ; suivre et annuler ses demandes en attente |
| 审批人 Valideur | 审批被分配给自己的员工申请（驳回必须写原因）；查看申请人年假余额；查看今天在休假的下属<br>Valider ou refuser (motif obligatoire) ; voir le solde du demandeur ; voir qui est en congé aujourd'hui |
| 管理员 Administrateur | 创建账号、重置密码、停用账号；指定每人的审批人；调整每人每年的年假额度、结转与调整；维护假期类型和法定假日；查看全部申请、导出 CSV；撤销已批准的假期<br>Créer / désactiver des comptes, réinitialiser les mots de passe ; désigner les valideurs ; gérer les droits annuels, types de congé et jours fériés ; exporter en CSV ; révoquer un congé approuvé |

### 业务规则 / Règles métier
- 一级审批：申请提交时自动路由到该员工的审批人；未指定审批人时由管理员审批。任何人都不能审批自己的申请。
- 天数由数据库计算，默认**几内亚劳动法口径：工作日 = 周一至周六，扣除法定假日**；可在「设置」改为周一至周五或自然日。
- 每人单独设置**年假天数/年**和**病假天数/年**（留空用默认值 30 / 15 天）；修改后从今年起生效，以往年份保持原天数。
- 入职当年按剩余自然日比例自动折算，四舍五入到半天。例：年假 25 天、7 月 1 日入职 → 当年 12.5 天。
- 余额 = 当年额度 + 上年结转 + 调整 − 已批准 − 审批中；年假、病假分别计算，不足时无法提交也无法批准。
- 设置了试用期截止日期的员工，试用期结束前不能申请年假（病假等其他假期不受限）。
- 天数按员工**工作国家**的计算方式和法定假日计算，每个国家可单独设置计算方式（几内亚、科特迪瓦默认周一至周六；中国、新加坡默认周一至周五）；支持中国的调休上班日；工作国家默认列表：中国、几内亚、科特迪瓦、新加坡（可在设置里维护）。
- 系统从 2026 年开始使用，不显示也不能申请 2026 年以前的假期。
- 已批准的休假可由该申请的审批人或管理员修改日期（如提前返岗），必须填写原因；天数和余额自动重算，修改前后的日期记入流转记录。员工本人不能修改自己已批准的休假。已批准的申请只有管理员可以撤销，且必须填写原因；审批人和员工只能通过修改休假调整日期。
- 年假不能跨年申请；同一员工的申请日期不能重叠；最多补报 60 天前的假期。
- 所有写操作都经过数据库函数校验，网页端无法绕过（行级安全 RLS）。
- Validation à un niveau ; décompte calculé côté base (par défaut jours ouvrables lundi–samedi hors fériés, modifiable) ; contrôle du solde à la demande et à la validation ; pas de chevauchement ; pas d'auto-validation.

---

## 部署步骤 / Déploiement (≈ 15 min)

### 1. Supabase 数据库 / Base de données
1. 在 [supabase.com](https://supabase.com) 新建项目（区域建议 West EU / Paris）。
2. **SQL Editor** → 依次粘贴并运行 `001_schema.sql`、`002_storage.sql`、`003_entitlements_probation_countries.sql`、`004_modify_leave_english.sql`、`005_country_count_mode_holidays.sql`、`006_email_notifications.sql`、`007_opening_balances.sql`、`008_frozen_entitlements_no_revoke.sql`、`009_admin_revoke_approved.sql`（都在 `supabase/migrations/`）。
3. **Authentication → Sign In / Providers**：关闭 **Allow new users to sign up**（禁止自助注册，只有管理员能建号）。
4. **Authentication → URL Configuration**：Site URL 填 `https://uciferwu.github.io/expat_leave_system/`。

### 2. 创建第一个管理员 / Premier administrateur
**Authentication → Users → Add user → Create new user**，填你的邮箱和密码，勾选 *Auto Confirm User*。
系统中的**第一个用户会自动成为管理员**，之后的账号都在平台「管理 → 用户」里创建。

### 3. 部署账号管理函数 / Fonction de gestion des comptes
**Edge Functions → Deploy a new function → Via Editor**，函数名填 `admin-users`，把 `supabase/functions/admin-users/index.ts` 的全部内容粘贴进去 → **Deploy**。
（或命令行 / ou en CLI : `supabase functions deploy admin-users`）

这个函数在服务器端使用 service_role 密钥，**网页里永远不会出现 service_role 密钥**。

### 3b. 邮件通知（可选）/ Notifications par e-mail (facultatif)
员工提交申请后，系统自动给审批人发邮件（按审批人的界面语言），附申请信息和"查看并审批"链接；未指定审批人时发给所有管理员。

1. 注册 [Resend](https://resend.com)（每月免费 3000 封）→ **Domains → Add Domain**，添加公司域名（或其子域名，如 `mail.公司域名`），按提示在域名 DNS 里添加记录，等待显示 *Verified*。
2. Resend → **API Keys → Create API Key**，复制 `re_` 开头的密钥。
3. Supabase → **Edge Functions → Secrets**，添加：
   - `RESEND_API_KEY` = 上一步的密钥
   - `MAIL_FROM` = `员工休假系统 <leave@你的已验证域名>`
4. **Edge Functions → Deploy a new function → Via Editor**，函数名 `notify-leave`，粘贴 `supabase/functions/notify-leave/index.ts` → Deploy。

邮件发送失败不会影响申请提交；同一申请只发送一次。

### 4. 填写配置 / Configuration
编辑 `config.js`，填入 **Settings → API** 中的 Project URL 和 anon public key，提交到 GitHub。

### 5. 开启 GitHub Pages
仓库 **Settings → Pages** → Source 选 *Deploy from a branch* → `main` / `/ (root)` → Save。
几分钟后访问：`https://uciferwu.github.io/expat_leave_system/`

### 6. 上线前检查 / Avant la mise en service
- 「管理 → 设置」确认天数计算方式和默认年假天数。
- 「法定假日」里补充当年伊斯兰节日（开斋节、宰牲节、圣纪节等，日期每年由政府公布）。已预置 2026、2027 年固定日期假日，请核对。
- 在「用户」里给每位员工指定审批人；在「年假额度」里录入上年结转。

员工在手机浏览器打开网址后，可「添加到主屏幕」，像 App 一样使用。
Sur mobile, « Ajouter à l'écran d'accueil » pour l'utiliser comme une application.

---

## 文件结构 / Structure

```
index.html                                  前端（单文件）/ interface
config.js                                   Supabase 地址与公开密钥 / URL + clé anon
manifest.webmanifest, icon.svg              添加到主屏幕 / écran d'accueil
supabase/migrations/001_schema.sql          表、权限、业务函数、初始数据
supabase/migrations/002_storage.sql         附件存储桶与权限
supabase/functions/admin-users/index.ts     管理员建号 / 重置密码 / 停用
```

## 暂未包含 / Non inclus (évolutions possibles)
邮件或企业微信通知、多级审批、日历视图、按入职时间自动计算年假。
