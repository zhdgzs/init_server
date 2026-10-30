#!/bin/bash

# ============================================================
# CPA (CLI Proxy API) + CPA Manager Plus 交互式部署脚本
#
# 功能：
#   1. 询问工作目录（当前目录已存在 cpa-deploy 时自动跳过）
#   2. 生成 docker-compose.yaml / cpa-data/config.yaml 及所有挂载目录
#   3. 可选生成 nginx 反向代理配置（域名 + SSL 证书目录自动替换）
#   4. 不启动任何容器，只写文件
#
# 用法：
#   bash install_cpa.sh
# ============================================================

set -euo pipefail

COMPOSE_NAME="cpa-deploy"
DEFAULT_NGINX_CONF="/etc/nginx/conf.d/cpa.conf"
LOG_DIR="${CPA_LOG_DIR:-/www/wwwlogs}"
DEFAULT_SECRET="123456"

PWD_DIR="$(pwd)"
DEPLOY_DIR=""
COMPOSE_FILE=""
CONFIG_FILE=""
COMPOSE_CMD=""
SUDO=""

info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*"; }
title() { echo -e "\n\033[36m==> $*\033[0m"; }

# ---------------- 交互辅助 ----------------

# ask <提示> [默认值]  -> 输出用户输入（空则用默认值）
ask() {
    local prompt="$1" default="${2:-}" input=""
    if [ -t 0 ]; then
        if [ -n "$default" ]; then
            read -r -p "${prompt} [${default}]: " input || true
        else
            read -r -p "${prompt}: " input || true
        fi
    fi
    printf '%s' "${input:-$default}"
}

# confirm <提示> <默认 y|n>  -> 返回 0 表示确认
confirm() {
    local prompt="$1" default="${2:-n}" input=""
    if [ -t 0 ]; then
        read -r -p "${prompt} " input || true
    fi
    input="${input:-$default}"
    case "$input" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# 非交互（例如被管道调用）时给出提示
require_tty() {
    if [ ! -t 0 ]; then
        error "该脚本为交互式脚本，请在终端中直接运行：bash $0"
        exit 1
    fi
}

is_root() { [ "$(id -u)" -eq 0 ]; }

# 需要 root 权限的操作（写 /etc/nginx、建 /www 等）
as_root() {
    if is_root; then
        "$@"
    else
        if ! command -v sudo >/dev/null 2>&1; then
            error "当前用户非 root 且未安装 sudo，无法执行: $*"
            exit 1
        fi
        sudo "$@"
    fi
}

# 目录输入规范化：支持 ~、相对路径、去掉末尾 /、避免重复 cpa-deploy
normalize_dir() {
    local dir="$1"

    case "$dir" in
        "~")    dir="$HOME" ;;
        "~/"*)  dir="${HOME}/${dir#\~/}" ;;
    esac

    case "$dir" in
        /*) ;;
        *)  dir="${PWD_DIR}/${dir}" ;;
    esac

    dir="${dir%/}"
    [ -z "$dir" ] && dir="/"

    printf '%s' "$dir"
}

# ---------------- 步骤 1：确定工作目录 ----------------

resolve_workdir() {
    title "步骤 1/4：确认工作目录"

    if [ -d "${PWD_DIR}/${COMPOSE_NAME}" ]; then
        DEPLOY_DIR="${PWD_DIR}/${COMPOSE_NAME}"
        info "当前目录已存在 ${COMPOSE_NAME}，跳过目录选择"
        info "部署目录：${DEPLOY_DIR}"
    else
        echo "当前目录：${PWD_DIR}"
        if confirm "是否在当前目录生成 ${COMPOSE_NAME} 文件夹？[Y/n]" "y"; then
            DEPLOY_DIR="${PWD_DIR}/${COMPOSE_NAME}"
        else
            local target
            while :; do
                target="$(ask "请输入目标目录（将在此目录下生成 ${COMPOSE_NAME}）" "${PWD_DIR}")"
                target="$(normalize_dir "$target")"
                if [ -d "$target" ] || mkdir -p "$target" 2>/dev/null; then
                    break
                fi
                error "目录不可用：${target}，请重新输入"
            done

            case "$(basename "$target")" in
                "$COMPOSE_NAME") DEPLOY_DIR="$target" ;;
                *)               DEPLOY_DIR="${target}/${COMPOSE_NAME}" ;;
            esac
        fi
        info "部署目录：${DEPLOY_DIR}"
    fi

    COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yaml"
    CONFIG_FILE="${DEPLOY_DIR}/cpa-data/config.yaml"
}

# ---------------- 步骤 2：目录结构 ----------------

create_dirs() {
    title "步骤 2/4：创建目录结构"

    # 依据 docker-compose.yaml 中的挂载点，逐级创建所有需要的目录
    #   ./cpa-data/config.yaml      -> 文件（下一步写入）
    #   ./cpa-data/auths            -> /root/.cli-proxy-api
    #   ./cpa-data/logs             -> /CLIProxyAPI/logs
    #   ./cpa-data/plugins          -> /CLIProxyAPI/plugins
    #   ./cpa-manager-plus-data     -> /data
    mkdir -p \
        "${DEPLOY_DIR}/cpa-data/auths" \
        "${DEPLOY_DIR}/cpa-data/logs" \
        "${DEPLOY_DIR}/cpa-data/plugins" \
        "${DEPLOY_DIR}/cpa-manager-plus-data"

    chmod 755 "${DEPLOY_DIR}" \
              "${DEPLOY_DIR}/cpa-data" \
              "${DEPLOY_DIR}/cpa-data/auths" \
              "${DEPLOY_DIR}/cpa-data/logs" \
              "${DEPLOY_DIR}/cpa-data/plugins" \
              "${DEPLOY_DIR}/cpa-manager-plus-data"

    info "已创建：cpa-data/{auths,logs,plugins}、cpa-manager-plus-data"
}

write_compose() {
    if [ -f "${COMPOSE_FILE}" ]; then
        warn "已存在 docker-compose.yaml，跳过写入（保留现有文件）"
        return 0
    fi

    cat > "${COMPOSE_FILE}" <<'YAML'
services:
  cli-proxy-api:
    image: eceasy/cli-proxy-api:latest
    container_name: cli-proxy-api
    restart: unless-stopped
    networks:
      - cpa-network
    ports:
      - "8317:8317"
      - "8085:8085"
      - "1455:1455"
      - "54545:54545"
      - "51121:51121"
      - "11451:11451"
    volumes:
      - ./cpa-data/config.yaml:/CLIProxyAPI/config.yaml
      - ./cpa-data/auths:/root/.cli-proxy-api
      - ./cpa-data/logs:/CLIProxyAPI/logs
      - ./cpa-data/plugins:/CLIProxyAPI/plugins

  cpa-manager-plus:
    image: seakee/cpa-manager-plus:latest
    container_name: cpa-manager-plus
    restart: unless-stopped
    networks:
      - cpa-network
    ports:
      - '18317:18317'
    environment:
      HTTP_ADDR: "0.0.0.0:18317"
      USAGE_DB_PATH: "/data/usage.sqlite"
      CPA_MANAGER_DATA_KEY_PATH: "/data/data.key"
      USAGE_COLLECTOR_MODE: "auto"
      USAGE_RESP_QUEUE: "usage"
      USAGE_RESP_POP_SIDE: "right"
      USAGE_BATCH_SIZE: "100"
      USAGE_POLL_INTERVAL_MS: "500"
      USAGE_QUERY_LIMIT: "50000"
      USAGE_CORS_ORIGINS: "*"
    volumes:
      - ./cpa-manager-plus-data:/data
    depends_on:
      - cli-proxy-api

networks:
  cpa-network:
    driver: bridge
YAML
    chmod 644 "${COMPOSE_FILE}"
    info "已写入：docker-compose.yaml"
}

write_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        warn "已存在 cpa-data/config.yaml，跳过写入（保留现有配置）"
        return 0
    fi

    cat > "${CONFIG_FILE}" <<'YAML'
# Server host/interface to bind to. Default is empty ("") to bind all interfaces (IPv4 + IPv6).
# Use "127.0.0.1" or "localhost" to restrict access to local machine only.
host: ""
# Server port
port: 8317
# TLS settings for HTTPS. When enabled, the server listens with the provided certificate and key.
tls:
  enable: false
  cert: ""
  key: ""
# Management API settings
remote-management:
  allow-remote: true
  secret-key: "123456"
  disable-control-panel: false
  panel-github-repository: "https://github.com/router-for-me/Cli-Proxy-API-Management-Center"
auth-dir: "/root/.cli-proxy-api"

# API keys for authentication
api-keys:
  - "123456"

debug: false
pprof:
  enable: false
  addr: "127.0.0.1:8316"

plugins:
  enabled: true
  dir: "plugins"
  configs:
    cpa-codex-candy-eval:
      enabled: true
      store:
        id: cpa-codex-candy-eval
        name: Codex 降智测试
        description: 在 CPA 管理面板中通过糖果测试、模型指纹测试和 ModelTrace 模型归因，检测凭证是否降智或被替换模型。
        author: haowang02
        version: 0.4.4
        release-tag: v0.4.4
        repository: https://github.com/haowang02/cpa-plugin-codex-candy-eval
        homepage: https://github.com/haowang02/cpa-plugin-codex-candy-eval
        license: MIT
        tags:
          - Management
          - Codex
          - Evaluation
        source-id: official
        source-name: Official
        source-url: https://raw.githubusercontent.com/router-for-me/CLIProxyAPI-Plugins-Store/main/registry.json
        install:
          type: github-release
    example:
      enabled: false
      priority: 1
      config1: true
      config2: "string"
      config3: 3
      mode: "safe" # enum example: safe, fast
# When true, disable high-overhead request logging and HTTP middleware features to reduce per-request memory usage under high concurrency.
commercial-mode: false
logging-to-file: false
logs-max-total-size-mb: 0
error-logs-max-files: 10
usage-statistics-enabled: true
redis-usage-queue-retention-seconds: 60
proxy-url: ""
force-model-prefix: false
passthrough-headers: false
request-retry: 3
max-retry-credentials: 0
max-retry-interval: 30
disable-cooling: false
save-cooldown-status: false
transient-error-cooldown-seconds: 0

disable-claude-cloak-mode: false

# Claude Code compatibility settings.
claude-code:
  disable-cloaking-model-list: false
disable-image-generation: false
video-result-auth-cache-ttl: "3h"

quota-exceeded:
  switch-project: true # Whether to automatically switch to another project when a quota is exceeded
  switch-preview-model: true # Whether to automatically switch to a preview model when a quota is exceeded
  antigravity-credits: true # Whether to use credits as last-resort fallback when all free-tier auths are exhausted for Claude models

routing:
  strategy: "fill-first" # round-robin (default), weighted-round-robin, fill-first
  session-affinity: false # default: false
  session-affinity-ttl: "1h"
codex:

  identity-confuse: false
  disable-codex-cloaking: false

  stream-bootstrap-buffering: false

  live-media-relay:
    enabled: false
    max-sessions: 32
    disable-private-remote-ips: false
    public-ip: ""
    udp-port-min: 0
    udp-port-max: 0

  optimize-multi-agent-v2: false

xai:
  inject-x-search: false
ws-auth: true
nonstream-keepalive-interval: 0

credential-concurrency:
  cpa-heartbeat-timeout: 3s
  cpa-cancel-bound: 5s
  reclaim-grace: 5s
  cleanup-interval: 5s
  release-flush-interval: 250ms
  release-max-backoff: 2s
  busy-retry-min: 250ms
  busy-retry-max: 1s
  max-limit: 1000000
credential-in-flight:
  snapshot-interval: 2s
  stale-after: 10s
  max-part-bytes: 262144
  max-part-count: 64
  max-revision-bytes: 16777216
  max-aggregate-groups: 100000
  max-details: 10000
  max-string-bytes: 256
  staging-retention: 1m
discovery:
  service-type: _ai-gateway._tcp
  subtypes:
    - _chat-completions
    - _responses
    - _messages
    - _generate-content
    - _interactions
YAML
    chmod 644 "${CONFIG_FILE}"
    info "已写入：cpa-data/config.yaml"
}

# ---------------- 步骤 3：nginx ----------------

validate_domain() {
    local d="$1"
    [ -n "$d" ] || return 1
    case "$d" in
        http://*|https://*|*/*|*" "*) return 1 ;;
    esac
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ "$d" == *.* ]] || return 1
    return 0
}

write_nginx_conf() {
    local domain="$1" cert_dir="$2" target="$3"
    local tmp=""
    tmp="$(mktemp)"

    cat > "$tmp" <<'NGINX'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

upstream cpa_api {
    server 127.0.0.1:8317;
}

upstream cpamp {
    server 127.0.0.1:18317;
}

server {
    listen      80;
    listen [::]:80;

    server_name __DOMAIN__;

    return 301 https://$host$request_uri;
}

server {
    listen      443 ssl;
    listen [::]:443 ssl;

    server_name __DOMAIN__;

    client_max_body_size 128m;

    access_log  /www/wwwlogs/cpa.access.log;
    error_log   /www/wwwlogs/cpa.error.log;

    ssl_certificate     __CERT_DIR__/cert.pem;
    ssl_certificate_key __CERT_DIR__/cert.key;
    ssl_session_timeout 5m;
    ssl_protocols TLSv1.3 TLSv1.2;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:HIGH:!aNULL:!MD5:!RC4:!DHE;
    ssl_prefer_server_ciphers on;

    proxy_http_version 1.1;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        $connection_upgrade;

    # 默认进入 CPAMP 面板
    location = / {
        return 302 /management.html;
    }

    # ===== CPA Manager Plus =====

    location = /management.html { proxy_pass http://cpamp; }
    location = /health          { proxy_pass http://cpamp; }
    location = /status          { proxy_pass http://cpamp; }
    location = /setup           { proxy_pass http://cpamp; }

    # CPAMP 兼容接口与运行时接口
    location ^~ /usage-service/ { proxy_pass http://cpamp; }

    # /v0/management/* 先进入 CPAMP：
    # - 用量 / 模型价格 / API 密钥别名 / 仪表盘 / 请求监控 /
    #   Codex 账号巡检 / 导入导出 等由 CPAMP 自己处理
    # - 其他 CPA 管理接口由 CPAMP 使用服务端保存的 CPA Management Key 继续代理到 CPA
    #
    # 注意：不要只配置 location = /v0/management
    # 应使用带尾斜杠的前缀匹配 /v0/management/
    location ^~ /v0/management/ { proxy_pass http://cpamp; }

    # Candy eval probes this optional v8 endpoint using the CPAMP login key.
    # Keep it on CPAMP; unsupported versions return 404 and the plugin falls
    # back to /v0/management/config instead of reporting a false auth failure.
    location = /v8/management/config/api-keys { proxy_pass http://cpamp; }

    # CPAMP 插件页面资源。缺少此规则时，插件页面可能打开空白或资源 404。
    location ^~ /v0/resource/plugins/ { proxy_pass http://cpamp; }

    # /models 由 CPAMP 提供兼容代理
    # 如果 CPAMP 尚未完成 setup，访问此路径可能返回 412
    location = /models          { proxy_pass http://cpamp; }

    # ===== CPA / CLI Proxy API =====

    # OpenAI / Claude Code / Codex 等实际 API 请求应直接走 CPA
    location ^~ /v1/                 { proxy_pass http://cpa_api; }
    location ^~ /v1beta/             { proxy_pass http://cpa_api; }
    location ^~ /backend-api/codex/  { proxy_pass http://cpa_api; }
    location ^~ /api/                { proxy_pass http://cpa_api; }

    # CPA 特殊路由与 OAuth 回调
    location = /v1internal:method    { proxy_pass http://cpa_api; }
    location = /healthz              { proxy_pass http://cpa_api; }
    location = /anthropic/callback   { proxy_pass http://cpa_api; }
    location = /codex/callback       { proxy_pass http://cpa_api; }
    location = /google/callback      { proxy_pass http://cpa_api; }
    location = /antigravity/callback { proxy_pass http://cpa_api; }

    # 兜底给 CPA
    # 用于 CPA 根路径、Amp 路由以及未来新增接口
    location / {
        proxy_pass http://cpa_api;
    }

}
NGINX

    # 替换占位符（用 | 作分隔符，避免路径中的 / 冲突）
    sed -i \
        -e "s|__DOMAIN__|${domain}|g" \
        -e "s|__CERT_DIR__|${cert_dir}|g" \
        "$tmp"

    if ! as_root mkdir -p "$(dirname "$target")"; then
        rm -f "$tmp"
        error "无法创建目录：$(dirname "$target")"
        exit 1
    fi

    if [ -f "$target" ]; then
        local backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
        if as_root cp -a "$target" "$backup"; then
            warn "已备份原配置：${backup}"
        fi
    fi

    if ! as_root install -m 644 "$tmp" "$target"; then
        rm -f "$tmp"
        error "写入 nginx 配置失败：${target}（请使用 root 运行）"
        exit 1
    fi
    rm -f "$tmp"

    info "已写入 nginx 配置：${target}"
}

setup_nginx() {
    title "步骤 3/4：nginx 反向代理"

    if ! confirm "是否需要配置 nginx 反向代理？[y/N]" "n"; then
        info "跳过 nginx 配置"
        return 0
    fi

    if ! command -v nginx >/dev/null 2>&1; then
        error "未找到 nginx 命令，请先安装 nginx 后再运行本脚本的 nginx 步骤"
        exit 1
    fi

    # --- 配置文件路径 ---
    local conf_path=""
    conf_path="$(ask "nginx 配置文件路径" "$DEFAULT_NGINX_CONF")"
    conf_path="$(normalize_dir "$conf_path")"
    if [ -d "$conf_path" ]; then
        conf_path="${conf_path%/}/cpa.conf"
    fi
    info "配置文件：${conf_path}"

    # --- 域名 ---
    local domain=""
    while :; do
        domain="$(ask "请输入域名（例如 cpa.xxx.xxx）" "")"
        domain="${domain#http://}"
        domain="${domain#https://}"
        domain="${domain%/}"
        if validate_domain "$domain"; then
            break
        fi
        error "域名格式不正确，请重新输入（例如 cpa.example.com）"
    done
    info "域名：${domain}"

    # --- 证书目录 ---
    local cert_dir=""
    while :; do
        cert_dir="$(ask "请输入 SSL 证书目录（例如 /opt/proxy/xxx，目录内需有 cert.pem / cert.key）" "")"
        cert_dir="$(normalize_dir "$cert_dir")"
        if [ -n "$cert_dir" ] && [ "$cert_dir" != "/" ]; then
            break
        fi
        error "证书目录不能为空"
    done
    info "证书目录：${cert_dir}"

    if [ ! -f "${cert_dir}/cert.pem" ] || [ ! -f "${cert_dir}/cert.key" ]; then
        warn "未在 ${cert_dir} 下同时找到 cert.pem / cert.key"
        if ! confirm "是否仍继续写入配置并测试 nginx？[y/N]" "n"; then
            warn "已跳过 nginx 配置写入"
            return 0
        fi
    fi

    # --- 日志目录 ---
    if [ ! -d "$LOG_DIR" ]; then
        info "创建日志目录：${LOG_DIR}"
        if ! as_root mkdir -p "$LOG_DIR"; then
            error "创建日志目录失败：${LOG_DIR}（请使用 root 运行）"
            exit 1
        fi
        as_root chmod 755 "$LOG_DIR" || true
    else
        info "日志目录已存在：${LOG_DIR}"
    fi

    # --- 写入配置 ---
    write_nginx_conf "$domain" "$cert_dir" "$conf_path"

    # --- nginx -t 校验 ---
    title "校验 nginx 配置：nginx -t"
    if ! as_root nginx -t; then
        error "nginx 配置校验失败，已中断（未执行 reload）"
        error "请检查配置后手动修复：${conf_path}"
        exit 1
    fi
    info "nginx -t 校验通过"

    # --- reload ---
    title "重载 nginx：nginx -s reload"
    if ! as_root nginx -s reload; then
        error "nginx 重载失败，已中断"
        exit 1
    fi
    info "nginx 已重载，访问地址：https://${domain}"
}

# ---------------- 步骤 4：汇总 ----------------

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        COMPOSE_CMD=""
    fi
}

print_summary() {
    title "步骤 4/4：完成"

    local ip=""
    ip="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
    ip="${ip:-<服务器IP>}"

    cat <<EOF

============================================================
部署目录：${DEPLOY_DIR}
  ├── docker-compose.yaml
  ├── cpa-data/
  │   ├── config.yaml              # CPA 配置文件
  │   ├── auths/                   # 凭证目录
  │   ├── logs/                    # 日志目录
  │   └── plugins/                 # 插件目录
  └── cpa-manager-plus-data/       # Manager Plus 数据（sqlite/密钥）
============================================================
直接端口访问：
  CPA:           http://${ip}:8317
  CPA 管理面板:  http://${ip}:8317/management.html
  Manager Plus:  http://${ip}:18317
============================================================

⚠️  重要：请立即修改默认密钥（当前均为默认值 ${DEFAULT_SECRET}）

  1) 修改 API 密钥（客户端调用 CPA 时使用）
     文件：${CONFIG_FILE}
     修改：api-keys: 下的 "123456"

  2) 修改管理面板密钥（登录管理面板时使用）
     文件：${CONFIG_FILE}
     修改：remote-management.secret-key 的 "123456"

  快速修改命令（替换 NEW_KEY / NEW_SECRET）：
     sed -i 's/- "123456"/- "NEW_KEY"/' ${CONFIG_FILE}
     sed -i 's/secret-key: "123456"/secret-key: "NEW_SECRET"/' ${CONFIG_FILE}

  提示：若 8317 / 18317 端口未开放，请检查防火墙 / 云厂商安全组。

============================================================
未启动任何容器，需要时手动执行：
EOF

    if [ -n "$COMPOSE_CMD" ]; then
        echo "     cd ${DEPLOY_DIR} && ${COMPOSE_CMD} up -d"
    else
        echo "     （未检测到 docker compose，请先安装 Docker）"
        echo "     cd ${DEPLOY_DIR} && docker compose up -d"
    fi

    echo "============================================================"
    echo
}

main() {
    require_tty
    echo "============================================================"
    echo "   CPA (CLI Proxy API) + CPA Manager Plus 交互式部署"
    echo "============================================================"

    resolve_workdir
    create_dirs
    write_compose
    write_config
    setup_nginx
    detect_compose

    # 可选：仅做 compose 语法校验（不启动）
    if [ -n "$COMPOSE_CMD" ]; then
        if ( cd "${DEPLOY_DIR}" && ${COMPOSE_CMD} config >/dev/null 2>&1 ); then
            info "docker-compose.yaml 语法校验通过"
        else
            warn "docker-compose.yaml 语法校验未通过，请手动检查：${COMPOSE_FILE}"
        fi
    fi

    print_summary
}

main "$@"
