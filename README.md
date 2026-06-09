# Linux 一键 HTTPS / 反向代理部署脚本

这个目录包含一个交互式脚本：[deploy-web.sh](/Users/caijinsong/Documents/Codex/2026-06-08/linux-ssl-nignx-caddy/outputs/deploy-web.sh)。

它可以在常见 Linux 服务器上完成：

- 菜单式操作：新建、更新、删除、只申请证书、查看状态
- 选择部署 `Nginx + acme.sh` 或 `Caddy`
- 询问域名、邮箱、SSL 证书机构、站点类型
- 支持选择 `Let's Encrypt` 或 `ZeroSSL` 申请 SSL 证书
- 支持 HTTP 验证或 DNS API 验证
- DNS API 支持 `Cloudflare`、`阿里云 Aliyun`、`腾讯云 DNSPod`、`AWS Route53`
- 支持泛域名证书，例如 `*.example.com`
- 可选同时配置 `www` 域名，例如 `example.com` 和 `www.example.com`
- 部署前自动检查域名 A/AAAA 解析是否指向本机公网 IP
- 部署后检查 SSL 自动续期机制
- 部署后检查 HTTP/HTTPS 可访问性、证书有效期和反向代理后端响应
- 自动保存站点状态，方便后续查看和删除
- 支持反向代理到后端服务，例如 `http://127.0.0.1:3000`
- 支持静态网站目录
- 自动开放系统防火墙的 `80/tcp` 和 `443/tcp`
- 为 Nginx 调用 acme.sh 申请并配置 HTTPS
- 为 Caddy 写入独立站点配置文件，由 Caddy 自动申请和续期证书
- 配置失败时自动回滚已修改的 Nginx/Caddy 配置文件

## 使用方法

把脚本上传到服务器后执行：

```bash
chmod +x deploy-web.sh
sudo ./deploy-web.sh
```

也可以直接用 Bash 执行：

```bash
sudo bash deploy-web.sh
```

启动后会显示：

```text
1) 新建站点
2) 更新站点
3) 删除站点
4) 只申请证书
5) 查看状态
```

`更新站点` 会先选择已有状态记录，再重新询问配置并覆盖同名站点配置。如果更新时改了域名，脚本会询问是否删除旧状态记录。

## 支持范围

脚本支持以下包管理器：

- `apt-get`：Debian / Ubuntu
- `dnf`：Fedora / RHEL 新版本 / CentOS Stream
- `yum`：CentOS / RHEL 老版本
- `pacman`：Arch Linux

脚本支持以下防火墙：

- `ufw`
- `firewalld`

如果服务器使用云厂商安全组，还需要在云控制台额外放行 `80` 和 `443` 端口。

## 状态记录

部署成功后，脚本会保存站点状态到：

```text
/etc/deploy-web/sites/
```

状态记录包含域名、Web 服务、站点模式、证书机构、验证方式、反向代理后端、静态目录、Web 配置文件路径和证书路径。DNS API Token 不会写进状态文件；acme.sh 会把续期所需凭据保存在 `/root/.acme.sh`。

## Caddy 多站点

Caddy 会使用主配置文件导入独立站点配置：

```text
/etc/caddy/Caddyfile
/etc/caddy/conf.d/你的域名.caddy
```

删除 Caddy 站点时，脚本只删除对应的 `conf.d` 站点文件，不会清空整个 `Caddyfile`。

## 配置回滚

脚本写入 Nginx/Caddy 配置前会保存事务备份。如果配置校验、证书申请后的正式配置、或服务 reload 失败，会自动恢复修改前的配置，并尝试 reload 回旧状态。

## DNS 解析预检查

部署前，脚本会尝试获取本机公网 IPv4/IPv6，并检查配置域名的 A/AAAA 记录。

- HTTP 验证：域名通常必须解析到本机公网 IP，否则证书申请会失败。
- Nginx 的 HTTP 验证使用 acme.sh webroot 模式，临时校验目录为 `/var/www/deploy-web-acme`。
- DNS API 验证：证书申请本身不依赖域名解析到本机，但部署后访问仍然需要正确解析。
- 如果使用 Cloudflare 代理模式，解析结果可能是 Cloudflare IP，脚本会提示不匹配，并允许你确认后继续。

## www 域名

输入普通域名时，脚本会询问是否同时配置：

```text
www.你的域名
```

如果选择开启，Nginx/Caddy 配置和证书申请都会同时包含两个域名。

## DNS API 申请证书

选择 `DNS API 验证` 时，脚本会自动安装并使用 `acme.sh` 申请证书。证书会安装到：

```text
/etc/ssl/deploy-web/你的域名/fullchain.pem
/etc/ssl/deploy-web/你的域名/privkey.pem
/etc/ssl/deploy-web/你的域名/cert.pem
/etc/ssl/deploy-web/你的域名/ca.pem
```

如果是泛域名 `*.example.com`，路径会变成：

```text
/etc/ssl/deploy-web/wildcard.example.com/
```

脚本会自动把 Nginx 或 Caddy 配置到这些证书路径，并让 `acme.sh` 在续期后 reload 对应服务。

## 自动续期

脚本部署完成后会检查续期机制：

- Nginx + HTTP/DNS 验证：使用 `acme.sh` 创建续期任务，续期后自动 reload Nginx。
- Caddy 普通自动 HTTPS：Caddy 自身负责证书续期。
- DNS API 验证：`acme.sh` 会创建 cron 续期任务，续期后自动 reload Nginx 或 Caddy。

## 健康检查

部署完成后，脚本会检查：

```text
后端服务响应
http://域名
https://域名
HTTPS 证书有效期
```

泛域名本身无法直接访问，脚本会跳过 `*.example.com`，但会检查根域名。

### Cloudflare

推荐使用 Cloudflare API Token。Token 至少需要：

```text
Zone:DNS:Edit
Zone:Zone:Read
```

权限范围建议限制到对应域名的 Zone。

脚本会询问：

```text
Cloudflare API Token
Cloudflare Account ID，可留空
Cloudflare Zone ID，可留空
```

脚本会自动验证 Cloudflare API Token，并在没有输入 Zone ID 时尝试自动发现 Zone ID。

### 阿里云

脚本会询问：

```text
AccessKey ID
AccessKey Secret
```

### 腾讯云 DNSPod

脚本会询问：

```text
SecretId
SecretKey
```

### AWS Route53

脚本会询问：

```text
AWS Access Key ID
AWS Secret Access Key
Route53 等待秒数，可留空
```

## 注意事项

- 运行前请确认域名已经解析到服务器公网 IP。
- Nginx 模式下，脚本会创建站点配置，并使用 acme.sh 申请和安装证书。
- Caddy 模式下，脚本会尽量启用 Caddy 官方软件源，并使用 `/etc/caddy/conf.d/` 管理独立站点配置。
- HTTP 验证需要公网可以访问服务器 `80` 端口。
- DNS API 验证不依赖 `80` 端口申请证书，但脚本仍会开放 `80/443`，方便 HTTP 跳转 HTTPS。
- 选择 ZeroSSL 时，需要输入 ZeroSSL 后台提供的 `EAB KID` 和 `EAB HMAC Key`。
- DNS API 凭据会被 `acme.sh` 保存到 `/root/.acme.sh`，用于后续自动续期。
- 如果同时配置 `www`，请确保 `www` 记录也已经解析到服务器，或在 Cloudflare 中配置好对应记录。
- 配置事务失败时会自动回滚；正常部署成功后不会保留临时事务备份。
- 如果服务器网络无法访问软件源或证书机构，安装或证书签发会失败；这种情况下先检查 DNS、出站网络和云厂商安全组。
