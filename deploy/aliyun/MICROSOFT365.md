# 用 Microsoft 365（Office 365）发送休假系统的邮件提醒

休假系统通过 **Microsoft Graph API** 发信：使用在公司 Microsoft 365 中注册的一个"应用"身份，
不需要任何人的登录密码，**不受多重验证（MFA / Authenticator）影响**，也不受微软停用 SMTP 账号密码认证的影响。

本文给 **Microsoft 365 管理员（IT）** 使用，约 15 分钟。完成后请把第 5 步的 4 项信息交给系统管理员。

---

## 1. 准备一个发信邮箱

建议用**共享邮箱**（不占用许可证）：
Exchange 管理中心 <https://admin.exchange.microsoft.com> → **收件人 → 邮箱 → 添加共享邮箱**
- 显示名称：`员工休假系统`
- 邮箱地址：`leave@公司域名`

> 员工收到的邮件发件人就是这个地址。

## 2. 注册应用

Microsoft Entra 管理中心 <https://entra.microsoft.com> → **应用注册 → 新注册**
- 名称：`员工休假系统邮件`
- 受支持的帐户类型：**仅此组织目录中的帐户**
- 重定向 URI：留空 → **注册**

在应用的"概述"页记下：
- **应用程序(客户端) ID**
- **目录(租户) ID**

## 3. 创建客户端密码

同一应用 → **证书和密码 → 客户端密码 → 新客户端密码**
- 说明：`leave-system`；有效期：**24 个月**
- 复制 **"值"** 那一列（不是"机密 ID"）。**它只显示这一次**。

> ⚠ 请在日历中记下到期日。到期前需要新建一个密码，并在服务器上重新运行 `mail-setup.sh` 填入。

## 4. 授予"只能用 leave 邮箱发信"的权限

**推荐方式：只允许该应用以 `leave@公司域名` 的身份发信**（Exchange Online 的"应用 RBAC"）。

先在 Entra 管理中心 → **企业应用程序** → 搜索 `员工休假系统邮件` → 概述页记下 **对象 ID**
（注意：是"企业应用程序"里的对象 ID，不是"应用注册"里的）。

然后在 Exchange Online PowerShell 中运行（替换尖括号内容）：

```powershell
Connect-ExchangeOnline

New-ServicePrincipal -AppId <应用程序(客户端)ID> -ObjectId <企业应用程序的对象ID> -DisplayName "员工休假系统邮件"

New-ManagementScope -Name "Leave mailbox only" -RecipientRestrictionFilter "PrimarySmtpAddress -eq 'leave@公司域名'"

New-ManagementRoleAssignment -App <应用程序(客户端)ID> -Role "Application Mail.Send" -CustomResourceScope "Leave mailbox only"

# 检查：leave 邮箱应显示 InScope = True，其他邮箱应为 False
Test-ServicePrincipalAuthorization -Identity <应用程序(客户端)ID> -Resource leave@公司域名
```

> ⚠ 采用这种方式时，**不要**再在 Entra 的"API 权限"里给该应用添加 Microsoft Graph 的 `Mail.Send` 应用程序权限，
> 否则两种授权叠加，限制会失效，应用可以用任何邮箱发信。
> 权限设置后可能需要半小时到两小时才生效。

<details>
<summary>简便方式（不推荐）：直接授予全公司范围的发信权限</summary>

应用 → **API 权限 → 添加权限 → Microsoft Graph → 应用程序权限 → Mail.Send → 添加**，再点 **"代表 xxx 授予管理员同意"**。

缺点：该应用可以用公司**任何**邮箱的名义发信，客户端密码一旦泄露风险较大。
</details>

## 5. 交给系统管理员的 4 项信息

| 项目 | 示例 |
|---|---|
| 目录(租户) ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| 应用程序(客户端) ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| 客户端密码的值 | `abc8Q~……`（请通过安全方式传递，不要放在普通邮件或群聊里） |
| 发信邮箱 | `leave@公司域名` |

系统管理员在服务器上运行：

```bash
bash /opt/leave/app/deploy/aliyun/mail-setup.sh
```

选择 **4) Microsoft 365**，依次填入这 4 项，脚本会立即发送一封测试邮件确认。

## 常见错误

| 提示 | 原因 |
|---|---|
| `Microsoft 登录失败 … invalid_client` | 客户端密码错误或已过期；或填成了"机密 ID"而不是"值" |
| `Microsoft 登录失败 … tenant … not found` | 租户 ID 填错 |
| `Microsoft Graph 403 … Access is denied` | 第 4 步权限未生效（等待最多 2 小时），或发信邮箱与授权范围不一致 |
| `Microsoft Graph 404 … not found` | 发信邮箱地址填错，或该邮箱尚未创建 |
