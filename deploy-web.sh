#!/usr/bin/env bash
set -Eeuo pipefail

# Interactive one-click Nginx/Caddy deployment helper for common Linux servers.
# Supports Debian/Ubuntu, RHEL/CentOS/Fedora-like systems, and Arch-like systems.

APP_NAME="deploy-web"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LETSENCRYPT_ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"
ZEROSSL_ACME_SERVER="https://acme.zerossl.com/v2/DV90"
CERT_BASE_DIR="/etc/ssl/deploy-web"
STATE_BASE_DIR="/etc/deploy-web"
STATE_SITES_DIR="${STATE_BASE_DIR}/sites"
STATE_VERSION="1"

log() {
  printf '\033[1;34m[%s]\033[0m %s\n' "$APP_NAME" "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

err() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

die() {
  err "$*"
  exit 1
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 运行：sudo bash $0"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

prompt() {
  local var_name="$1"
  local label="$2"
  local default="${3:-}"
  local value

  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$label: " value
  fi

  printf -v "$var_name" '%s' "$value"
}

prompt_required() {
  local var_name="$1"
  local label="$2"
  local value

  while true; do
    read -r -p "$label: " value
    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return
    fi
    warn "该项不能为空。"
  done
}

prompt_secret_required() {
  local var_name="$1"
  local label="$2"
  local value

  while true; do
    read -r -s -p "$label: " value
    echo
    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return
    fi
    warn "该项不能为空。"
  done
}

prompt_secret() {
  local var_name="$1"
  local label="$2"
  local value

  read -r -s -p "$label，可留空: " value
  echo
  printf -v "$var_name" '%s' "$value"
}

prompt_yes_no() {
  local var_name="$1"
  local label="$2"
  local default="${3:-n}"
  local value
  local hint

  if [[ "$default" == "y" ]]; then
    hint="Y/n"
  else
    hint="y/N"
  fi

  while true; do
    read -r -p "$label [$hint]: " value
    value="${value:-$default}"
    case "$value" in
      y|Y|yes|YES) printf -v "$var_name" 'y'; return ;;
      n|N|no|NO) printf -v "$var_name" 'n'; return ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

validate_domain() {
  local domain="$1"
  local base_domain="$domain"

  if [[ "$base_domain" == \*.* ]]; then
    base_domain="${base_domain#*.}"
  fi

  [[ "$base_domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

safe_name_for_domain() {
  local domain="$1"

  printf '%s' "${domain//\*/wildcard}"
}

base_domain_for_domain() {
  local domain="$1"

  if [[ "$domain" == \*.* ]]; then
    printf '%s' "${domain#*.}"
  else
    printf '%s' "$domain"
  fi
}

nginx_server_names() {
  local domain="${1:-$DOMAIN}"
  local base_domain
  local names=()

  if [[ "$domain" == \*.* ]]; then
    base_domain="$(base_domain_for_domain "$domain")"
    names+=("$base_domain" "$domain")
  else
    names+=("$domain")
  fi

  if [[ "${INCLUDE_WWW:-n}" == "y" && "$domain" != www.* && "$domain" != \*.* ]]; then
    names+=("www.${domain}")
  fi

  printf '%s' "${names[*]}"
}

build_cert_domains() {
  local domain="$1"
  local base_domain

  CERT_DOMAINS=()
  if [[ "$domain" == \*.* ]]; then
    base_domain="$(base_domain_for_domain "$domain")"
    CERT_DOMAINS+=("$base_domain" "$domain")
  else
    CERT_DOMAINS+=("$domain")
    if [[ "${INCLUDE_WWW:-n}" == "y" && "$domain" != www.* ]]; then
      CERT_DOMAINS+=("www.${domain}")
    fi
  fi
}

caddy_site_label() {
  nginx_server_names "$1" | sed 's/ /, /g'
}

default_site_root_for_domain() {
  local domain="$1"

  printf '/var/www/%s/html' "$(safe_name_for_domain "$domain")"
}

state_file_for_domain() {
  local domain="$1"

  printf '%s/%s.env' "$STATE_SITES_DIR" "$(safe_name_for_domain "$domain")"
}

ensure_state_dirs() {
  mkdir -p "$STATE_BASE_DIR" "$STATE_SITES_DIR"
  chmod 700 "$STATE_BASE_DIR" "$STATE_SITES_DIR" 2>/dev/null || chmod 700 "$STATE_SITES_DIR"
}

quote_state_value() {
  printf '%q' "$1"
}

save_state() {
  local state_file
  local cert_domains_str

  ensure_state_dirs
  state_file="$(state_file_for_domain "$DOMAIN")"
  cert_domains_str="${CERT_DOMAINS[*]}"

  {
    printf 'STATE_VERSION=%s\n' "$(quote_state_value "$STATE_VERSION")"
    printf 'SAVED_AT=%s\n' "$(quote_state_value "$(date -Iseconds)")"
    printf 'DOMAIN=%s\n' "$(quote_state_value "$DOMAIN")"
    printf 'INCLUDE_WWW=%s\n' "$(quote_state_value "${INCLUDE_WWW:-n}")"
    printf 'CERT_DOMAINS_STR=%s\n' "$(quote_state_value "$cert_domains_str")"
    printf 'RUNTIME=%s\n' "$(quote_state_value "${RUNTIME:-}")"
    printf 'CERT_PROVIDER=%s\n' "$(quote_state_value "${CERT_PROVIDER:-}")"
    printf 'CHALLENGE_MODE=%s\n' "$(quote_state_value "${CHALLENGE_MODE:-}")"
    printf 'DNS_PROVIDER=%s\n' "$(quote_state_value "${DNS_PROVIDER:-}")"
    printf 'DNS_HOOK=%s\n' "$(quote_state_value "${DNS_HOOK:-}")"
    printf 'MODE=%s\n' "$(quote_state_value "${MODE:-}")"
    printf 'BACKEND=%s\n' "$(quote_state_value "${BACKEND:-}")"
    printf 'STATIC_ROOT=%s\n' "$(quote_state_value "${STATIC_ROOT:-}")"
    printf 'CERT_DIR=%s\n' "$(quote_state_value "${CERT_DIR:-}")"
    printf 'CERT_FULLCHAIN=%s\n' "$(quote_state_value "${CERT_FULLCHAIN:-}")"
    printf 'CERT_KEY=%s\n' "$(quote_state_value "${CERT_KEY:-}")"
  } >"$state_file"
  chmod 600 "$state_file"
  log "已保存站点状态：${state_file}"
}

load_state_for_domain() {
  local domain="$1"
  local state_file

  state_file="$(state_file_for_domain "$domain")"
  [[ -f "$state_file" ]] || return 1
  # shellcheck disable=SC1090
  source "$state_file"
  IFS=' ' read -r -a CERT_DOMAINS <<<"${CERT_DOMAINS_STR:-$domain}"
  return 0
}

list_saved_sites() {
  ensure_state_dirs

  if ! compgen -G "${STATE_SITES_DIR}/*.env" >/dev/null; then
    warn "当前没有已记录的站点。"
    return 1
  fi

  for state_file in "${STATE_SITES_DIR}"/*.env; do
    printf '  - %s\n' "$(basename "$state_file" .env)"
  done
}

select_action() {
  local action_choice

  echo
  echo "请选择操作："
  echo "  1) 新建站点"
  echo "  2) 更新站点"
  echo "  3) 删除站点"
  echo "  4) 只申请证书"
  echo "  5) 查看状态"
  while true; do
    read -r -p "选择 [1-5]: " action_choice
    case "$action_choice" in
      1) ACTION="create"; break ;;
      2) ACTION="update"; break ;;
      3) ACTION="delete"; break ;;
      4) ACTION="cert-only"; break ;;
      5) ACTION="status"; break ;;
      *) warn "请输入 1 到 5。" ;;
    esac
  done
}

detect_pkg_manager() {
  if command_exists apt-get; then
    PKG_MANAGER="apt"
  elif command_exists dnf; then
    PKG_MANAGER="dnf"
  elif command_exists yum; then
    PKG_MANAGER="yum"
  elif command_exists pacman; then
    PKG_MANAGER="pacman"
  else
    die "未识别包管理器。当前脚本支持 apt、dnf、yum、pacman。"
  fi
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      apt-get update
      ;;
    dnf)
      dnf makecache
      ;;
    yum)
      yum makecache
      ;;
    pacman)
      pacman -Sy --noconfirm
      ;;
  esac
}

pkg_install() {
  local packages=("$@")

  case "$PKG_MANAGER" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    pacman)
      pacman -S --noconfirm --needed "${packages[@]}"
      ;;
  esac
}

install_nginx_stack() {
  log "安装 Nginx 和 Certbot..."
  pkg_update

  case "$PKG_MANAGER" in
    apt)
      pkg_install nginx certbot python3-certbot-nginx
      ;;
    dnf|yum)
      pkg_install nginx certbot python3-certbot-nginx
      ;;
    pacman)
      pkg_install nginx certbot certbot-nginx
      ;;
  esac
}

install_caddy_stack() {
  log "安装 Caddy..."
  pkg_update

  case "$PKG_MANAGER" in
    apt)
      pkg_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg
      mkdir -p /usr/share/keyrings
      curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" >/etc/apt/sources.list.d/caddy-stable.list
      apt-get update
      pkg_install caddy
      ;;
    dnf)
      pkg_install dnf-plugins-core || pkg_install dnf5-plugins || true
      dnf -y copr enable @caddy/caddy || true
      pkg_update
      pkg_install caddy
      ;;
    yum)
      pkg_install yum-plugin-copr || pkg_install dnf-plugins-core || true
      yum -y copr enable @caddy/caddy || true
      pkg_update
      pkg_install caddy
      ;;
    pacman)
      pkg_install caddy
      ;;
  esac
}

install_acme_sh_stack() {
  local email="$1"
  local acme_bin="/root/.acme.sh/acme.sh"

  if [[ -x "$acme_bin" ]]; then
    return
  fi

  log "安装 acme.sh，用于 DNS API 申请证书..."
  pkg_update

  case "$PKG_MANAGER" in
    apt)
      pkg_install curl socat openssl ca-certificates cron
      ;;
    dnf|yum)
      pkg_install curl socat openssl ca-certificates cronie
      ;;
    pacman)
      pkg_install curl socat openssl ca-certificates cronie
      ;;
  esac

  if command_exists systemctl; then
    systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
  fi

  if [[ -n "$email" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="$email"
  else
    curl -fsSL https://get.acme.sh | sh
  fi

  [[ -x "$acme_bin" ]] || die "acme.sh 安装失败。"
}

install_network_check_tools() {
  log "安装/确认 DNS 预检查工具..."
  pkg_update

  case "$PKG_MANAGER" in
    apt)
      pkg_install curl dnsutils || warn "DNS 预检查工具安装失败，将尽量使用系统已有命令。"
      ;;
    dnf|yum)
      pkg_install curl bind-utils || warn "DNS 预检查工具安装失败，将尽量使用系统已有命令。"
      ;;
    pacman)
      pkg_install curl bind || warn "DNS 预检查工具安装失败，将尽量使用系统已有命令。"
      ;;
  esac
}

systemctl_if_available() {
  if command_exists systemctl; then
    systemctl "$@"
  else
    return 1
  fi
}

enable_and_restart_service() {
  local service="$1"

  if command_exists systemctl; then
    systemctl enable "$service"
    systemctl restart "$service"
  else
    service "$service" restart
  fi
}

reload_service() {
  local service="$1"

  if command_exists systemctl; then
    systemctl reload "$service" || systemctl restart "$service"
  else
    service "$service" reload || service "$service" restart
  fi
}

service_reload_command() {
  local service="$1"

  if command_exists systemctl; then
    printf 'systemctl reload %s || systemctl restart %s || true' "$service" "$service"
  else
    printf 'service %s reload || service %s restart || true' "$service" "$service"
  fi
}

open_firewall_ports() {
  log "配置防火墙，开放 80/tcp 和 443/tcp..."

  if command_exists ufw; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    if ufw status | grep -qi "inactive"; then
      local enable_ufw
      prompt_yes_no enable_ufw "检测到 UFW 未启用，是否现在启用 UFW？建议确认 SSH 规则后再启用" "n"
      if [[ "$enable_ufw" == "y" ]]; then
        ufw allow OpenSSH || true
        ufw --force enable
      else
        warn "UFW 当前未启用；规则已添加，但不会生效，直到你启用 UFW。"
      fi
    fi
    return
  fi

  if command_exists firewall-cmd; then
    if ! firewall-cmd --state >/dev/null 2>&1; then
      local enable_firewalld
      prompt_yes_no enable_firewalld "检测到 firewalld 未运行，是否现在启用 firewalld？" "n"
      if [[ "$enable_firewalld" == "y" ]]; then
        systemctl_if_available enable --now firewalld || die "启用 firewalld 失败。"
      else
        warn "firewalld 未运行，跳过防火墙配置。"
        return
      fi
    fi

    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
    return
  fi

  warn "未检测到 UFW 或 firewalld。请手动确认云厂商安全组和系统防火墙已开放 80/443。"
}

get_public_ips() {
  PUBLIC_IPS=()

  if command_exists curl; then
    local ipv4=""
    local ipv6=""
    ipv4="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    ipv6="$(curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
    [[ -n "$ipv4" ]] && PUBLIC_IPS+=("$ipv4")
    [[ -n "$ipv6" ]] && PUBLIC_IPS+=("$ipv6")
  fi
}

resolve_domain_ips() {
  local domain="$1"

  if command_exists dig; then
    {
      dig +short A "$domain"
      dig +short AAAA "$domain"
    } | sed '/^$/d'
  elif command_exists host; then
    host "$domain" 2>/dev/null | awk '/has address|has IPv6 address/ {print $NF}'
  elif command_exists nslookup; then
    nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}'
  elif command_exists getent; then
    getent ahosts "$domain" | awk '{print $1}' | sort -u
  else
    return 1
  fi
}

cloudflare_api_get() {
  local path="$1"

  curl -fsS --max-time 15 \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4${path}"
}

verify_cloudflare_token() {
  local response

  log "验证 Cloudflare API Token..."
  response="$(cloudflare_api_get "/user/tokens/verify" 2>/dev/null || true)"
  if grep -q '"success"[[:space:]]*:[[:space:]]*true' <<<"$response"; then
    log "Cloudflare API Token 验证通过。"
  else
    warn "Cloudflare API Token 验证失败。请确认 Token 有 Zone:DNS:Edit 和 Zone:Zone:Read 权限。"
  fi
}

discover_cloudflare_zone_id() {
  local domain="$1"
  local candidate
  local response
  local zone_id
  local zone_name
  local base_domain

  if [[ -n "${CF_ZONE_ID:-}" ]]; then
    return
  fi

  base_domain="$(base_domain_for_domain "$domain")"
  base_domain="${base_domain#www.}"
  candidate="$base_domain"

  log "尝试自动发现 Cloudflare Zone ID..."
  while [[ "$candidate" == *.* ]]; do
    response="$(cloudflare_api_get "/zones?name=${candidate}&per_page=1" 2>/dev/null || true)"
    if grep -q '"success"[[:space:]]*:[[:space:]]*true' <<<"$response"; then
      zone_id="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$response" | head -n 1)"
      zone_name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$response" | head -n 1)"
      if [[ -n "$zone_id" ]]; then
        CF_ZONE_ID="$zone_id"
        log "已发现 Cloudflare Zone：${zone_name:-$candidate} (${CF_ZONE_ID})"
        return
      fi
    fi
    candidate="${candidate#*.}"
  done

  warn "未能自动发现 Cloudflare Zone ID。如果 DNS API 失败，请手动输入 Zone ID 后重试。"
}

enhance_cloudflare_settings() {
  if ! command_exists curl; then
    warn "当前系统未安装 curl，跳过 Cloudflare Token 预校验；后续安装依赖后 acme.sh 仍会尝试使用该 Token。"
    return
  fi

  verify_cloudflare_token
  discover_cloudflare_zone_id "$DOMAIN"
}

precheck_dns_resolution() {
  local domain="$1"
  local check_domain
  local resolved_ips
  local public_ip
  local matched
  local has_warning="n"

  if [[ "$CHALLENGE_MODE" == "dns-api" ]]; then
    log "检查域名解析，用于确认部署后访问是否可能正常..."
  else
    log "检查域名解析，HTTP 验证需要域名指向本机公网 IP..."
  fi

  install_network_check_tools
  get_public_ips

  if [[ "${#PUBLIC_IPS[@]}" -eq 0 ]]; then
    warn "无法获取本机公网 IP，跳过解析匹配检查。"
    return
  fi

  build_cert_domains "$domain"
  for check_domain in "${CERT_DOMAINS[@]}"; do
    if [[ "$check_domain" == \*.* ]]; then
      warn "跳过泛域名 ${check_domain} 的直接解析检查。"
      continue
    fi

    resolved_ips="$({ resolve_domain_ips "$check_domain" 2>/dev/null || true; } | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [[ -z "$resolved_ips" ]]; then
      warn "${check_domain} 当前没有查到 A/AAAA 记录。"
      has_warning="y"
      continue
    fi

    matched="n"
    for public_ip in "${PUBLIC_IPS[@]}"; do
      if grep -Fq "$public_ip" <<<"$resolved_ips"; then
        matched="y"
        break
      fi
    done

    if [[ "$matched" == "y" ]]; then
      log "${check_domain} 解析正常：${resolved_ips}"
    else
      warn "${check_domain} 当前解析到：${resolved_ips}；本机公网 IP：${PUBLIC_IPS[*]}"
      has_warning="y"
    fi
  done

  if [[ "$has_warning" == "y" ]]; then
    local continue_anyway
    prompt_yes_no continue_anyway "DNS 解析可能未就绪，是否仍继续部署？" "n"
    if [[ "$continue_anyway" != "y" ]]; then
      die "已取消。请先修改 DNS 解析后重新运行脚本。"
    fi
  fi
}

check_certbot_renewal() {
  log "检查 Certbot 自动续期..."

  if command_exists systemctl && systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer
    log "certbot.timer 已启用。"
  else
    warn "未检测到 certbot.timer。多数发行版会安装 cron 续期任务，请使用 certbot renew --dry-run 手动确认。"
  fi

  if [[ "$CERT_PROVIDER" == "letsencrypt" ]]; then
    local run_dry_run
    prompt_yes_no run_dry_run "是否立即执行 Certbot 续期演练 certbot renew --dry-run？可能需要几分钟" "n"
    if [[ "$run_dry_run" == "y" ]]; then
      certbot renew --dry-run
    fi
  else
    warn "ZeroSSL 使用自定义 ACME 服务，跳过 Certbot dry-run。"
  fi
}

check_acme_sh_renewal() {
  local acme_bin="/root/.acme.sh/acme.sh"

  log "检查 acme.sh 自动续期..."
  if [[ ! -x "$acme_bin" ]]; then
    warn "未找到 acme.sh，无法检查 DNS API 续期。"
    return
  fi

  "$acme_bin" --cron --home /root/.acme.sh || warn "acme.sh 续期检查命令执行失败，请稍后手动运行：/root/.acme.sh/acme.sh --cron --home /root/.acme.sh"

  if command_exists crontab; then
    if crontab -l 2>/dev/null | grep -Fq "acme.sh"; then
      log "检测到 acme.sh cron 续期任务。"
    else
      warn "未在当前 root crontab 中看到 acme.sh 续期任务，请确认 acme.sh 安装日志。"
    fi
  else
    warn "系统没有 crontab 命令，无法检查 acme.sh cron 任务。"
  fi
}

check_caddy_renewal() {
  log "检查 Caddy 自动续期..."

  if [[ "$CHALLENGE_MODE" == "dns-api" ]]; then
    warn "当前 Caddy 使用 acme.sh 安装的证书，续期由 acme.sh 管理。"
    check_acme_sh_renewal
    return
  fi

  if command_exists systemctl; then
    systemctl is-enabled caddy >/dev/null 2>&1 && log "Caddy 服务已启用，Caddy 会自动续期证书。" || warn "Caddy 服务未设置开机自启，请检查：systemctl enable caddy"
  else
    warn "无法通过 systemctl 检查 Caddy 状态；Caddy 正常运行时会自动续期证书。"
  fi
}

check_renewal_setup() {
  case "$RUNTIME" in
    nginx)
      if [[ "$CHALLENGE_MODE" == "dns-api" ]]; then
        check_acme_sh_renewal
      else
        check_certbot_renewal
      fi
      ;;
    caddy)
      check_caddy_renewal
      ;;
  esac
}

http_status_for_url() {
  local url="$1"

  curl -kfsS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "$url" 2>/dev/null || true
}

check_https_certificate() {
  local domain="$1"
  local cert_end

  if ! command_exists openssl; then
    warn "未找到 openssl，跳过证书有效期检查。"
    return
  fi

  cert_end="$(echo | openssl s_client -servername "$domain" -connect "${domain}:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
  if [[ -n "$cert_end" ]]; then
    log "${domain} 证书有效期至：${cert_end}"
  else
    warn "无法读取 ${domain} 的 HTTPS 证书信息。"
  fi
}

run_health_checks() {
  local domain
  local http_code
  local https_code
  local backend_code

  log "执行部署后健康检查..."

  if [[ "$MODE" == "proxy" && -n "${BACKEND:-}" ]]; then
    backend_code="$(http_status_for_url "$BACKEND")"
    if [[ -n "$backend_code" ]]; then
      log "后端 ${BACKEND} 响应状态：${backend_code}"
    else
      warn "后端 ${BACKEND} 暂无响应，请确认后端服务已启动。"
    fi
  fi

  for domain in "${CERT_DOMAINS[@]}"; do
    if [[ "$domain" == \*.* ]]; then
      continue
    fi

    http_code="$(http_status_for_url "http://${domain}")"
    if [[ -n "$http_code" ]]; then
      log "http://${domain} 响应状态：${http_code}"
    else
      warn "http://${domain} 暂无响应。"
    fi

    https_code="$(http_status_for_url "https://${domain}")"
    if [[ -n "$https_code" ]]; then
      log "https://${domain} 响应状态：${https_code}"
    else
      warn "https://${domain} 暂无响应。"
    fi

    check_https_certificate "$domain"
  done
}

backup_file_if_exists() {
  local path="$1"

  if [[ -e "$path" ]]; then
    cp -a "$path" "${path}.bak.${TIMESTAMP}"
    warn "已备份现有文件：${path}.bak.${TIMESTAMP}"
  fi
}

ensure_static_root() {
  local root="$1"
  local domain="$2"

  mkdir -p "$root"
  if [[ ! -f "$root/index.html" ]]; then
    cat >"$root/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${domain}</title>
</head>
<body>
  <h1>${domain} 已部署成功</h1>
</body>
</html>
EOF
  fi
}

write_nginx_config() {
  local domain="$1"
  local mode="$2"
  local backend="$3"
  local root="$4"
  local conf_path
  local conf_name
  local server_names

  conf_name="$(safe_name_for_domain "$domain")"
  server_names="$(nginx_server_names "$domain")"

  if [[ -d /etc/nginx/sites-available ]]; then
    conf_path="/etc/nginx/sites-available/${conf_name}.conf"
  else
    conf_path="/etc/nginx/conf.d/${conf_name}.conf"
  fi

  backup_file_if_exists "$conf_path"

  if [[ "$mode" == "proxy" ]]; then
    cat >"$conf_path" <<EOF
server {
    listen 80;
    server_name ${server_names};

    location / {
        proxy_pass ${backend};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Real-IP \$remote_addr;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  else
    ensure_static_root "$root" "$domain"
    cat >"$conf_path" <<EOF
server {
    listen 80;
    server_name ${server_names};

    root ${root};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  fi

  if [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sfn "$conf_path" "/etc/nginx/sites-enabled/${conf_name}.conf"
  fi

  if [[ -e /etc/nginx/sites-enabled/default ]]; then
    local disable_default
    prompt_yes_no disable_default "是否禁用 Nginx 默认站点？" "y"
    if [[ "$disable_default" == "y" ]]; then
      mv /etc/nginx/sites-enabled/default "/etc/nginx/sites-enabled/default.bak.${TIMESTAMP}"
    fi
  fi

  nginx -t
  enable_and_restart_service nginx
}

write_nginx_config_with_cert() {
  local domain="$1"
  local mode="$2"
  local backend="$3"
  local root="$4"
  local cert_fullchain="$5"
  local cert_key="$6"
  local conf_path
  local conf_name
  local server_names

  conf_name="$(safe_name_for_domain "$domain")"
  server_names="$(nginx_server_names "$domain")"

  if [[ -d /etc/nginx/sites-available ]]; then
    conf_path="/etc/nginx/sites-available/${conf_name}.conf"
  else
    conf_path="/etc/nginx/conf.d/${conf_name}.conf"
  fi

  backup_file_if_exists "$conf_path"

  {
    cat <<EOF
server {
    listen 80;
    server_name ${server_names};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${server_names};

    ssl_certificate ${cert_fullchain};
    ssl_certificate_key ${cert_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

EOF

    if [[ "$mode" == "proxy" ]]; then
      cat <<EOF
    location / {
        proxy_pass ${backend};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Real-IP \$remote_addr;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
EOF
    else
      ensure_static_root "$root" "$domain"
      cat <<EOF
    root ${root};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF
    fi

    cat <<EOF
}
EOF
  } >"$conf_path"

  if [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sfn "$conf_path" "/etc/nginx/sites-enabled/${conf_name}.conf"
  fi

  if [[ -e /etc/nginx/sites-enabled/default ]]; then
    local disable_default
    prompt_yes_no disable_default "是否禁用 Nginx 默认站点？" "y"
    if [[ "$disable_default" == "y" ]]; then
      mv /etc/nginx/sites-enabled/default "/etc/nginx/sites-enabled/default.bak.${TIMESTAMP}"
    fi
  fi

  nginx -t
  enable_and_restart_service nginx
}

issue_nginx_certificate() {
  local domain="$1"
  local email="$2"
  local cert_provider="$3"
  local zerossl_eab_kid="$4"
  local zerossl_eab_hmac="$5"
  local certbot_args=(--nginx --agree-tos --redirect --non-interactive)
  local cert_domain

  build_cert_domains "$domain"
  for cert_domain in "${CERT_DOMAINS[@]}"; do
    certbot_args+=(-d "$cert_domain")
  done

  case "$cert_provider" in
    letsencrypt)
      certbot_args+=(--server "$LETSENCRYPT_ACME_SERVER")
      ;;
    zerossl)
      certbot_args+=(--server "$ZEROSSL_ACME_SERVER" --eab-kid "$zerossl_eab_kid" --eab-hmac-key "$zerossl_eab_hmac")
      ;;
  esac

  if [[ -n "$email" ]]; then
    certbot_args+=(--email "$email")
  else
    certbot_args+=(--register-unsafely-without-email)
  fi

  log "使用 Certbot 通过 ${cert_provider} 为 ${domain} 申请并配置 HTTPS..."
  certbot "${certbot_args[@]}"
  nginx -t
  enable_and_restart_service nginx
}

provider_to_acme_sh_server() {
  local cert_provider="$1"

  case "$cert_provider" in
    letsencrypt) printf 'letsencrypt' ;;
    zerossl) printf 'zerossl' ;;
  esac
}

prepare_cert_paths() {
  local domain="$1"
  local safe_domain

  safe_domain="$(safe_name_for_domain "$domain")"
  CERT_DIR="${CERT_BASE_DIR}/${safe_domain}"
  CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
  CERT_KEY="${CERT_DIR}/privkey.pem"
  CERT_CERT="${CERT_DIR}/cert.pem"
  CERT_CA="${CERT_DIR}/ca.pem"
}

grant_caddy_cert_access() {
  local caddy_user=""

  if id -u caddy >/dev/null 2>&1; then
    caddy_user="caddy"
  elif id -u www-data >/dev/null 2>&1; then
    caddy_user="www-data"
  fi

  if [[ -n "$caddy_user" ]]; then
    chown -R "${caddy_user}:${caddy_user}" "$CERT_DIR"
    chmod 750 "$CERT_DIR"
    chmod 640 "$CERT_KEY"
  else
    warn "未找到 caddy 或 www-data 用户，Caddy 可能无法读取 ${CERT_KEY}。"
  fi
}

build_acme_domain_args() {
  local domain="$1"
  local cert_domain

  ACME_DOMAIN_ARGS=()
  build_cert_domains "$domain"
  ACME_PRIMARY_DOMAIN="${CERT_DOMAINS[0]}"
  for cert_domain in "${CERT_DOMAINS[@]}"; do
    ACME_DOMAIN_ARGS+=(-d "$cert_domain")
  done
}

export_dns_provider_env() {
  case "$DNS_PROVIDER" in
    cloudflare)
      export CF_Token="$CF_TOKEN"
      if [[ -n "${CF_ACCOUNT_ID:-}" ]]; then
        export CF_Account_ID="$CF_ACCOUNT_ID"
      fi
      if [[ -n "${CF_ZONE_ID:-}" ]]; then
        export CF_Zone_ID="$CF_ZONE_ID"
      fi
      ;;
    aliyun)
      export Ali_Key="$ALI_KEY"
      export Ali_Secret="$ALI_SECRET"
      ;;
    tencent)
      export Tencent_SecretId="$TENCENT_SECRET_ID"
      export Tencent_SecretKey="$TENCENT_SECRET_KEY"
      ;;
    route53)
      export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID_VALUE"
      export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY_VALUE"
      if [[ -n "${AWS_DNS_SLOWRATE_VALUE:-}" ]]; then
        export AWS_DNS_SLOWRATE="$AWS_DNS_SLOWRATE_VALUE"
      fi
      ;;
  esac
}

issue_dns_certificate() {
  local domain="$1"
  local email="$2"
  local cert_provider="$3"
  local zerossl_eab_kid="$4"
  local zerossl_eab_hmac="$5"
  local runtime="$6"
  local acme_bin="/root/.acme.sh/acme.sh"
  local acme_server
  local reload_cmd

  install_acme_sh_stack "$email"
  acme_server="$(provider_to_acme_sh_server "$cert_provider")"

  if [[ "$cert_provider" == "zerossl" ]]; then
    log "注册 ZeroSSL ACME 账号..."
    "$acme_bin" --register-account -m "$email" --server "$acme_server" --eab-kid "$zerossl_eab_kid" --eab-hmac-key "$zerossl_eab_hmac"
  fi

  export_dns_provider_env
  build_acme_domain_args "$domain"
  prepare_cert_paths "$domain"
  mkdir -p "$CERT_DIR"

  log "使用 acme.sh 通过 DNS API 申请证书..."
  "$acme_bin" --issue --dns "$DNS_HOOK" --server "$acme_server" "${ACME_DOMAIN_ARGS[@]}"

  if [[ "$runtime" == "none" ]]; then
    reload_cmd="true"
  else
    reload_cmd="$(service_reload_command "$runtime")"
  fi
  if [[ "$runtime" == "none" ]]; then
    log "安装证书到 ${CERT_DIR}。"
  else
    log "安装证书到 ${CERT_DIR}，并配置续期后自动 reload ${runtime}..."
  fi
  "$acme_bin" --install-cert -d "$ACME_PRIMARY_DOMAIN" \
    --cert-file "$CERT_CERT" \
    --key-file "$CERT_KEY" \
    --fullchain-file "$CERT_FULLCHAIN" \
    --ca-file "$CERT_CA" \
    --reloadcmd "$reload_cmd"

  chmod 755 "$CERT_DIR"
  chmod 644 "$CERT_FULLCHAIN" "$CERT_CERT" "$CERT_CA"
  chmod 600 "$CERT_KEY"

  if [[ "$runtime" == "caddy" ]]; then
    grant_caddy_cert_access
  fi
}

write_caddy_config() {
  local domain="$1"
  local email="$2"
  local cert_provider="$3"
  local zerossl_eab_kid="$4"
  local zerossl_eab_hmac="$5"
  local mode="$6"
  local backend="$7"
  local root="$8"
  local conf_path="/etc/caddy/Caddyfile"
  local site_label

  site_label="$(caddy_site_label "$domain")"

  mkdir -p /etc/caddy
  backup_file_if_exists "$conf_path"

  {
    printf '{\n'
    if [[ -n "$email" ]]; then
      printf '    email %s\n' "$email"
    fi

    case "$cert_provider" in
      letsencrypt)
        printf '    acme_ca %s\n' "$LETSENCRYPT_ACME_SERVER"
        ;;
      zerossl)
        printf '    acme_ca %s\n' "$ZEROSSL_ACME_SERVER"
        printf '    acme_eab {\n'
        printf '        key_id %s\n' "$zerossl_eab_kid"
        printf '        mac_key %s\n' "$zerossl_eab_hmac"
        printf '    }\n'
        ;;
    esac
    printf '}\n\n'

    printf '%s {\n' "$site_label"
    if [[ "$mode" == "proxy" ]]; then
      printf '    reverse_proxy %s\n' "$backend"
    else
      ensure_static_root "$root" "$domain"
      printf '    root * %s\n' "$root"
      printf '    file_server\n'
    fi
    printf '}\n'
  } >"$conf_path"

  caddy validate --config "$conf_path"
  enable_and_restart_service caddy
}

write_caddy_config_with_cert() {
  local domain="$1"
  local mode="$2"
  local backend="$3"
  local root="$4"
  local cert_fullchain="$5"
  local cert_key="$6"
  local conf_path="/etc/caddy/Caddyfile"
  local site_label

  site_label="$(caddy_site_label "$domain")"

  mkdir -p /etc/caddy
  backup_file_if_exists "$conf_path"

  {
    printf '%s {\n' "$site_label"
    printf '    tls %s %s\n' "$cert_fullchain" "$cert_key"
    if [[ "$mode" == "proxy" ]]; then
      printf '    reverse_proxy %s\n' "$backend"
    else
      ensure_static_root "$root" "$domain"
      printf '    root * %s\n' "$root"
      printf '    file_server\n'
    fi
    printf '}\n'
  } >"$conf_path"

  caddy validate --config "$conf_path"
  enable_and_restart_service caddy
}

collect_domain_inputs() {
  while true; do
    prompt_required DOMAIN "请输入域名，例如 example.com"
    if validate_domain "$DOMAIN"; then
      break
    fi
    warn "域名格式看起来不正确，请重新输入。"
  done

  if [[ "$DOMAIN" != \*.* && "$DOMAIN" != www.* ]]; then
    prompt_yes_no INCLUDE_WWW "是否同时配置 www.${DOMAIN}？" "y"
  else
    INCLUDE_WWW="n"
  fi
  build_cert_domains "$DOMAIN"
}

collect_cert_provider_inputs() {
  local cert_provider_choice

  echo
  echo "请选择 SSL 证书机构："
  echo "  1) Let's Encrypt"
  echo "  2) ZeroSSL"
  while true; do
    read -r -p "选择 [1-2]: " cert_provider_choice
    case "$cert_provider_choice" in
      1) CERT_PROVIDER="letsencrypt"; break ;;
      2) CERT_PROVIDER="zerossl"; break ;;
      *) warn "请输入 1 或 2。" ;;
    esac
  done

  if [[ "$CERT_PROVIDER" == "zerossl" ]]; then
    prompt_required EMAIL "请输入邮箱（ZeroSSL 必填）"
    prompt_required ZEROSSL_EAB_KID "请输入 ZeroSSL EAB KID"
    prompt_required ZEROSSL_EAB_HMAC "请输入 ZeroSSL EAB HMAC Key"
  else
    prompt EMAIL "请输入 Let's Encrypt 邮箱，可留空" ""
    ZEROSSL_EAB_KID=""
    ZEROSSL_EAB_HMAC=""
  fi
}

collect_dns_provider_inputs() {
  local dns_provider_choice

  if [[ -z "${EMAIL:-}" ]]; then
    prompt_required EMAIL "请输入邮箱（DNS API 申请证书需要）"
  fi

  echo
  echo "请选择 DNS 服务商："
  echo "  1) Cloudflare（推荐）"
  echo "  2) 阿里云 Aliyun"
  echo "  3) 腾讯云 DNSPod"
  echo "  4) AWS Route53"
  while true; do
    read -r -p "选择 [1-4]: " dns_provider_choice
    case "$dns_provider_choice" in
      1) DNS_PROVIDER="cloudflare"; DNS_HOOK="dns_cf"; break ;;
      2) DNS_PROVIDER="aliyun"; DNS_HOOK="dns_ali"; break ;;
      3) DNS_PROVIDER="tencent"; DNS_HOOK="dns_tencent"; break ;;
      4) DNS_PROVIDER="route53"; DNS_HOOK="dns_aws"; break ;;
      *) warn "请输入 1 到 4。" ;;
    esac
  done

  case "$DNS_PROVIDER" in
    cloudflare)
      prompt_secret_required CF_TOKEN "请输入 Cloudflare API Token"
      prompt CF_ACCOUNT_ID "请输入 Cloudflare Account ID" ""
      prompt CF_ZONE_ID "请输入 Cloudflare Zone ID" ""
      enhance_cloudflare_settings
      ;;
    aliyun)
      prompt_required ALI_KEY "请输入阿里云 AccessKey ID"
      prompt_secret_required ALI_SECRET "请输入阿里云 AccessKey Secret"
      ;;
    tencent)
      prompt_required TENCENT_SECRET_ID "请输入腾讯云 SecretId"
      prompt_secret_required TENCENT_SECRET_KEY "请输入腾讯云 SecretKey"
      ;;
    route53)
      prompt_required AWS_ACCESS_KEY_ID_VALUE "请输入 AWS Access Key ID"
      prompt_secret_required AWS_SECRET_ACCESS_KEY_VALUE "请输入 AWS Secret Access Key"
      prompt AWS_DNS_SLOWRATE_VALUE "请输入 Route53 等待秒数，可留空" ""
      ;;
  esac
}

collect_challenge_inputs() {
  local challenge_choice

  echo
  echo "请选择证书验证方式："
  echo "  1) HTTP 验证，需要公网访问 80 端口"
  echo "  2) DNS API 验证，支持 Cloudflare / 阿里云 / 腾讯云 / Route53，可申请泛域名证书"
  if [[ "$DOMAIN" == \*.* ]]; then
    warn "检测到泛域名，只能使用 DNS API 验证。"
    CHALLENGE_MODE="dns-api"
  else
    while true; do
      read -r -p "选择 [1-2]: " challenge_choice
      case "$challenge_choice" in
        1) CHALLENGE_MODE="http"; break ;;
        2) CHALLENGE_MODE="dns-api"; break ;;
        *) warn "请输入 1 或 2。" ;;
      esac
    done
  fi

  if [[ "$CHALLENGE_MODE" == "dns-api" ]]; then
    collect_dns_provider_inputs
  else
    DNS_PROVIDER=""
    DNS_HOOK=""
  fi
}

collect_cert_only_inputs() {
  RUNTIME="none"
  MODE="cert-only"
  BACKEND=""
  STATIC_ROOT=""
  CHALLENGE_MODE="dns-api"

  collect_domain_inputs
  collect_cert_provider_inputs
  warn "只申请证书模式使用 DNS API 验证，不会修改 Nginx/Caddy 配置。"
  collect_dns_provider_inputs
}

collect_inputs() {
  local runtime_choice mode_choice

  echo
  echo "请选择要部署的 Web 服务："
  echo "  1) Nginx + Certbot"
  echo "  2) Caddy 自动 HTTPS"
  while true; do
    read -r -p "选择 [1-2]: " runtime_choice
    case "$runtime_choice" in
      1) RUNTIME="nginx"; break ;;
      2) RUNTIME="caddy"; break ;;
      *) warn "请输入 1 或 2。" ;;
    esac
  done

  collect_domain_inputs
  collect_cert_provider_inputs
  collect_challenge_inputs

  echo
  echo "请选择站点类型："
  echo "  1) 反向代理到后端服务"
  echo "  2) 静态网站目录"
  while true; do
    read -r -p "选择 [1-2]: " mode_choice
    case "$mode_choice" in
      1) MODE="proxy"; break ;;
      2) MODE="static"; break ;;
      *) warn "请输入 1 或 2。" ;;
    esac
  done

  if [[ "$MODE" == "proxy" ]]; then
    prompt BACKEND "请输入后端地址" "http://127.0.0.1:3000"
    STATIC_ROOT=""
  else
    BACKEND=""
    prompt STATIC_ROOT "请输入网站目录" "$(default_site_root_for_domain "$DOMAIN")"
  fi
}

print_summary() {
  echo
  log "部署信息确认："
  echo "  Web 服务：${RUNTIME}"
  echo "  域名：${DOMAIN}"
  echo "  配置域名：${CERT_DOMAINS[*]}"
  echo "  证书机构：${CERT_PROVIDER}"
  echo "  验证方式：${CHALLENGE_MODE}"
  if [[ "$CHALLENGE_MODE" == "dns-api" ]]; then
    echo "  DNS 服务商：${DNS_PROVIDER}"
  fi
  echo "  邮箱：${EMAIL:-未填写}"
  if [[ "$MODE" == "proxy" ]]; then
    echo "  模式：反向代理"
    echo "  后端：${BACKEND}"
  else
    echo "  模式：静态网站"
    echo "  目录：${STATIC_ROOT}"
  fi
  echo
}

confirm_or_cancel() {
  local confirmed

  prompt_yes_no confirmed "确认开始部署？" "y"
  if [[ "$confirmed" != "y" ]]; then
    die "已取消。"
  fi
}

deploy_site() {
  precheck_dns_resolution "$DOMAIN"
  open_firewall_ports

  case "$RUNTIME" in
    nginx)
      install_nginx_stack
      if [[ "$CHALLENGE_MODE" == "dns-api" ]]; then
        issue_dns_certificate "$DOMAIN" "$EMAIL" "$CERT_PROVIDER" "$ZEROSSL_EAB_KID" "$ZEROSSL_EAB_HMAC" nginx
        write_nginx_config_with_cert "$DOMAIN" "$MODE" "$BACKEND" "$STATIC_ROOT" "$CERT_FULLCHAIN" "$CERT_KEY"
      else
        write_nginx_config "$DOMAIN" "$MODE" "$BACKEND" "$STATIC_ROOT"
        issue_nginx_certificate "$DOMAIN" "$EMAIL" "$CERT_PROVIDER" "$ZEROSSL_EAB_KID" "$ZEROSSL_EAB_HMAC"
      fi
      ;;
    caddy)
      install_caddy_stack
      if [[ "$CHALLENGE_MODE" == "dns-api" ]]; then
        issue_dns_certificate "$DOMAIN" "$EMAIL" "$CERT_PROVIDER" "$ZEROSSL_EAB_KID" "$ZEROSSL_EAB_HMAC" caddy
        write_caddy_config_with_cert "$DOMAIN" "$MODE" "$BACKEND" "$STATIC_ROOT" "$CERT_FULLCHAIN" "$CERT_KEY"
      else
        write_caddy_config "$DOMAIN" "$EMAIL" "$CERT_PROVIDER" "$ZEROSSL_EAB_KID" "$ZEROSSL_EAB_HMAC" "$MODE" "$BACKEND" "$STATIC_ROOT"
      fi
      ;;
  esac

  save_state
  check_renewal_setup
  run_health_checks

  echo
  log "部署完成，已配置域名：${CERT_DOMAINS[*]}"
  warn "如果访问失败，请确认域名 A/AAAA 记录已解析到本机公网 IP，并且云服务器安全组开放了 80 和 443。"
}

issue_certificate_only() {
  collect_cert_only_inputs
  print_summary
  confirm_or_cancel

  issue_dns_certificate "$DOMAIN" "$EMAIL" "$CERT_PROVIDER" "$ZEROSSL_EAB_KID" "$ZEROSSL_EAB_HMAC" none
  save_state
  check_acme_sh_renewal

  echo
  log "证书申请完成：${CERT_FULLCHAIN}"
}

update_site() {
  local old_domain
  local old_state_file
  local remove_old_state

  list_saved_sites || return
  prompt_required old_domain "请输入要更新的现有域名"
  if ! load_state_for_domain "$old_domain"; then
    die "未找到 ${old_domain} 的状态记录。"
  fi

  old_domain="$DOMAIN"
  old_state_file="$(state_file_for_domain "$old_domain")"
  log "当前记录：${old_domain} (${RUNTIME:-unknown}, ${MODE:-unknown})"
  warn "接下来会重新询问配置，并覆盖同名站点配置。"

  collect_inputs
  print_summary
  confirm_or_cancel
  deploy_site

  if [[ "$old_domain" != "$DOMAIN" && -f "$old_state_file" ]]; then
    prompt_yes_no remove_old_state "检测到域名已从 ${old_domain} 改为 ${DOMAIN}，是否删除旧状态记录？" "y"
    if [[ "$remove_old_state" == "y" ]]; then
      rm -f "$old_state_file"
    fi
  fi
}

show_site_status() {
  local domain
  local run_checks

  list_saved_sites || return
  prompt_required domain "请输入要查看的域名"
  if ! load_state_for_domain "$domain"; then
    die "未找到 ${domain} 的状态记录。"
  fi

  echo
  log "站点状态："
  echo "  域名：${DOMAIN}"
  echo "  配置域名：${CERT_DOMAINS[*]}"
  echo "  Web 服务：${RUNTIME:-未记录}"
  echo "  模式：${MODE:-未记录}"
  echo "  证书机构：${CERT_PROVIDER:-未记录}"
  echo "  验证方式：${CHALLENGE_MODE:-未记录}"
  echo "  DNS 服务商：${DNS_PROVIDER:-未记录}"
  echo "  后端：${BACKEND:-未记录}"
  echo "  静态目录：${STATIC_ROOT:-未记录}"
  echo "  证书目录：${CERT_DIR:-未记录}"

  if [[ "${RUNTIME:-}" == "nginx" ]] && command_exists systemctl; then
    systemctl is-active nginx >/dev/null 2>&1 && log "Nginx 正在运行。" || warn "Nginx 未处于运行状态。"
  elif [[ "${RUNTIME:-}" == "caddy" ]] && command_exists systemctl; then
    systemctl is-active caddy >/dev/null 2>&1 && log "Caddy 正在运行。" || warn "Caddy 未处于运行状态。"
  fi

  prompt_yes_no run_checks "是否执行访问和证书健康检查？" "y"
  if [[ "$run_checks" == "y" ]]; then
    run_health_checks
  fi
}

delete_site() {
  local domain
  local state_file
  local conf_name
  local delete_certs
  local clear_caddy
  local confirmed

  list_saved_sites || return
  prompt_required domain "请输入要删除的域名"
  if ! load_state_for_domain "$domain"; then
    die "未找到 ${domain} 的状态记录。"
  fi

  echo
  warn "即将删除站点配置：${DOMAIN} (${RUNTIME:-unknown})"
  prompt_yes_no confirmed "确认删除？" "n"
  if [[ "$confirmed" != "y" ]]; then
    die "已取消。"
  fi

  conf_name="$(safe_name_for_domain "$DOMAIN")"
  case "${RUNTIME:-}" in
    nginx)
      rm -f "/etc/nginx/sites-enabled/${conf_name}.conf"
      rm -f "/etc/nginx/sites-available/${conf_name}.conf"
      rm -f "/etc/nginx/conf.d/${conf_name}.conf"
      nginx -t && reload_service nginx
      ;;
    caddy)
      prompt_yes_no clear_caddy "是否清空 /etc/caddy/Caddyfile？这适用于该 Caddyfile 只由本脚本管理的情况" "n"
      if [[ "$clear_caddy" == "y" ]]; then
        backup_file_if_exists /etc/caddy/Caddyfile
        printf '# Cleared by deploy-web at %s\n' "$(date -Iseconds)" >/etc/caddy/Caddyfile
        caddy validate --config /etc/caddy/Caddyfile && reload_service caddy
      else
        warn "已保留 Caddyfile，请手动移除对应站点块。"
      fi
      ;;
    none)
      warn "该记录为只申请证书模式，没有 Web 服务配置需要删除。"
      ;;
  esac

  if [[ -n "${CERT_DIR:-}" && -d "$CERT_DIR" ]]; then
    prompt_yes_no delete_certs "是否同时删除证书目录 ${CERT_DIR}？" "n"
    if [[ "$delete_certs" == "y" ]]; then
      rm -rf "$CERT_DIR"
    fi
  fi

  state_file="$(state_file_for_domain "$DOMAIN")"
  rm -f "$state_file"
  log "删除完成。"
}

main() {
  need_root
  detect_pkg_manager
  select_action

  case "$ACTION" in
    create|update)
      if [[ "$ACTION" == "update" ]]; then
        update_site
      else
        collect_inputs
        print_summary
        confirm_or_cancel
        deploy_site
      fi
      ;;
    cert-only)
      issue_certificate_only
      ;;
    status)
      show_site_status
      ;;
    delete)
      delete_site
      ;;
  esac
}

main "$@"
