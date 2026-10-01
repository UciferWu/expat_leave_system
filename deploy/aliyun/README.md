# 部署到阿里云 ECS（Linux 主机）

一条命令在一台 Linux 主机上装好整个休假系统：网页、数据库、登录、附件存储、建号和邮件函数。
使用 Supabase 官方开源的自部署版本（固定为 `self-hosted/v0.8.2`），前端代码不需要任何修改。

适用于：阿里云 **香港或海外地域**（无需 ICP 备案），Alibaba Cloud Linux 3 / CentOS 7（已停止维护，可用但建议日后升级）/ Rocky / Ubuntu / Debian，**内存 ≥ 2 GB（建议 4 GB）**，磁盘可用 ≥ 10 GB。

---

## 一、安装（约 15–20 分钟）

> 通过**阿里云云堡垒机**登录的也完全适用：在堡垒机里打开这台主机的 SSH 会话（网页终端），以下命令都在那里运行。
> 堡垒机账号通常不是 root，所以命令前面要加 `sudo`。

**1. 请阿里云账号管理员放行端口**（堡垒机账号看不到 ECS 控制台）：
ECS 所在**安全组** → 入方向 → 添加规则：协议 TCP，端口 **80**，授权对象 `0.0.0.0/0`；并确认这台 ECS 有**公网 IP 或已绑定 EIP**。

**2. 部署前检查**（只读，不做修改），把结果截图发给 Claude：

```bash
curl -fsSL https://raw.githubusercontent.com/UciferWu/expat_leave_system/main/deploy/aliyun/check.sh | bash
```

**3. 安装**：

```bash
sudo git clone https://github.com/UciferWu/expat_leave_system /opt/leave/app
sudo bash /opt/leave/app/deploy/aliyun/install.sh
```

> 如果提示没有 git：CentOS 7 运行 `sudo yum install -y git`，Alibaba Cloud Linux 3 运行 `sudo dnf install -y git`，Ubuntu 运行 `sudo apt install -y git`。

**4. 按提示输入第一个管理员的邮箱、姓名和密码**。

完成后屏幕会显示网址（`http://公网IP`），用刚才的管理员账号登录即可。

脚本会自动完成：安装 Docker（使用阿里云镜像源）→ 内存不足 4 GB 时添加交换空间 → 放行主机防火墙 80 端口 → 生成全部密钥 →
启动服务 → 运行数据库脚本 001–010 → 创建管理员 → 设置每天凌晨 2:30 自动备份。
中途失败可以直接重新运行，已完成的步骤会跳过。

---

## 二、日常维护

| 操作 | 命令 |
|---|---|
| 更新到最新版本（会先自动备份） | `sudo bash /opt/leave/app/deploy/aliyun/update.sh` |
| 手动备份 | `sudo bash /opt/leave/app/deploy/aliyun/backup.sh` |
| 查看服务状态 | `cd /opt/leave/supabase && sudo docker compose ps` |
| 查看某个服务的日志 | `cd /opt/leave/supabase && sudo docker compose logs --tail 100 functions`（或 `auth`、`db`、`web`） |
| 重启全部服务 | `cd /opt/leave/supabase && sudo docker compose restart` |

- **备份**保存在 `/opt/leave/backups/`（数据库 + 附件，保留 14 天）。建议另外在阿里云控制台为这台 ECS 设置**自动快照**。
- **全部密钥**在 `/opt/leave/supabase/.env`，请妥善保管，不要外传或提交到 GitHub。

### 数据库管理后台（Studio）
出于安全考虑不对外开放。需要时在自己电脑上运行：

```bash
ssh -L 8000:127.0.0.1:8000 root@公网IP
```

然后浏览器打开 http://localhost:8000 ，用户名、密码见 `.env` 中的 `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD`。

---

## 三、开启邮件提醒

| 操作 | 收件人 |
|---|---|
| 员工提交申请 | 审批人（未指定审批人时发给管理员） |
| 批准 / 驳回 / 修改已批准的休假 / 管理员撤销 | 申请人 |
| 员工撤回待审批的申请 | 审批人 |

邮件按收件人的界面语言（中 / 法 / 英）发送，附申请信息和直达链接。

**配置方法**：推荐用公司邮箱的 SMTP 发信，只需一个邮箱账号和密码（或客户端授权码），不用改域名解析。

```bash
cd /opt/leave/app && git pull
bash /opt/leave/app/deploy/aliyun/update.sh
bash /opt/leave/app/deploy/aliyun/mail-setup.sh
```

按提示选择邮箱类型（阿里 / 腾讯 / 网易企业邮箱、Microsoft 365、Gmail、其他、Resend），填写账号和授权码，
最后输入一个收件邮箱，脚本会立即发送一封测试邮件。阿里云 ECS 禁止 25 端口外发，请使用 465 或 587 端口。

**使用 Microsoft 365 / Office 365（包括开启了 MFA 的账号）**：通过 Microsoft Graph API 发信，需要 IT 先在 Microsoft 365 中注册一个应用，步骤见 [MICROSOFT365.md](MICROSOFT365.md)。

---

## 四、绑定域名、开启 HTTPS

1. 域名解析中添加 A 记录：`leave` → 本机公网 IP；安全组放行 **80 和 443**。
2. 在服务器上运行（把域名换成实际的，邮箱用于接收证书到期提醒，可省略）：

```bash
cd /opt/leave/app && git pull
bash /opt/leave/app/deploy/aliyun/enable-https.sh leave.公司域名 it@公司域名
```

脚本会：检查域名解析 → 休假系统改为只在本机 8081 端口 → 安装服务器**统一入口网关**（`/opt/gateway`）→
自动申请并续期免费 HTTPS 证书。完成后通过 `https://leave.公司域名` 访问，直接用 IP 访问会自动跳转。
以后在这台服务器上增加其他应用，见 [deploy/gateway/README.md](../gateway/README.md)。

---

## 五、架构说明

```
浏览器 ──80──▶ leave-web (Nginx)
                 ├── /                          休假系统网页
                 └── /auth /rest /storage /functions ─▶ api-gw (Envoy, 仅本机 8000)
                                                         ├── auth      登录
                                                         ├── rest      数据接口
                                                         ├── storage   附件（保存在 volumes/storage）
                                                         ├── functions admin-users、notify-leave
                                                         └── studio    管理后台（仅 SSH 隧道）
                                                   db (PostgreSQL 17，数据在 volumes/db/data)
```

与官方配置相比：关闭了本系统用不到的实时推送（realtime）和连接池（supavisor），网关只监听本机，
对外只开放 80 端口。改动全部在 `docker-compose.leave.yml` 中。
