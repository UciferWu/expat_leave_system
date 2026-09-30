# Supabase 官方自部署配置（副本）

本目录是 [supabase/supabase](https://github.com/supabase/supabase) 仓库 `docker/` 目录在发布版
**`self-hosted/v0.8.2`**（commit 564eab8）时的副本，只保留了本系统用到的文件，内容未作修改。
许可证：Apache License 2.0（见 LICENSE）。

放在仓库里是为了让安装不依赖新版 git（CentOS 7 自带的 git 无法按需下载官方仓库的子目录），
并确保每次安装的版本完全一致。本系统的改动都在上一级目录的 `docker-compose.leave.yml` 中。
