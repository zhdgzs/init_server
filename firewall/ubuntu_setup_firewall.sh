#!/bin/bash
# Description: Ubuntu/Debian 一键配置防火墙 - 禁用 Ping + 仅允许中国 IP 访问已放行端口

set -euo pipefail

IPSET_NAME="china"
IPSET_SAVE_FILE="/etc/ipset/china.conf"
IPSET_RESTORE_SERVICE="/etc/systemd/system/ipset-restore.service"
CHINA_IP_URL="https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone"
UPDATE_SCRIPT="/usr/local/bin/update-china-ips.sh"
UFW_BEFORE_RULES="/etc/ufw/before.rules"
MANAGED_BLOCK_START="# BEGIN CHINA-IPSET RULES"
MANAGED_BLOCK_END="# END CHINA-IPSET RULES"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：必须以 root 权限运行此脚本"
        exit 1
    fi
}

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "错误：缺少必要命令: $cmd"
        exit 1
    fi
}

install_packages() {
    echo ">>> 正在安装必要工具..."
    apt update
    apt install -y ufw ipset iptables curl cron
    systemctl enable --now cron
}

get_ssh_ports() {
    local ports=()
    local port=""

    if command -v sshd >/dev/null 2>&1; then
        while read -r port; do
            [ -n "$port" ] && ports+=("$port")
        done < <(sshd -T 2>/dev/null | awk '/^port / {print $2}' | sort -u)
    fi

    if [ "${#ports[@]}" -eq 0 ]; then
        ports=(22)
    fi

    printf '%s\n' "${ports[@]}"
}

create_ipset_data() {
    local tmp_file=""
    local tmp_set="${IPSET_NAME}_tmp"
    local valid_count=0
    local ip=""

    tmp_file="$(mktemp /tmp/cn.XXXXXX.zone)"

    echo ">>> 正在下载中国 IP 列表..."
    curl -fsSL "$CHINA_IP_URL" -o "$tmp_file"

    if [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file"
        echo "错误：中国 IP 列表下载失败或内容为空。"
        exit 1
    fi

    ipset destroy "$tmp_set" 2>/dev/null || true
    ipset create "$tmp_set" hash:net family inet

    while read -r ip; do
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
            ipset add "$tmp_set" "$ip" -exist
            valid_count=$((valid_count + 1))
        fi
    done < "$tmp_file"

    rm -f "$tmp_file"

    if [ "$valid_count" -lt 1000 ]; then
        ipset destroy "$tmp_set" 2>/dev/null || true
        echo "错误：中国 IP 数量异常，已中止。"
        exit 1
    fi

    if ipset list -n | grep -qx "$IPSET_NAME"; then
        ipset swap "$tmp_set" "$IPSET_NAME"
        ipset destroy "$tmp_set"
    else
        ipset rename "$tmp_set" "$IPSET_NAME"
    fi

    mkdir -p "$(dirname "$IPSET_SAVE_FILE")"
    ipset save "$IPSET_NAME" -f "$IPSET_SAVE_FILE"
}

configure_ipset_restore_service() {
    cat > "$IPSET_RESTORE_SERVICE" <<EOF
[Unit]
Description=Restore ${IPSET_NAME} ipset on boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ipset destroy ${IPSET_NAME} 2>/dev/null || true; ipset restore -exist -f ${IPSET_SAVE_FILE}'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ipset-restore.service
}

inject_ufw_rules() {
    local tmp_file=""
    local managed_block=""

    managed_block="$(cat <<EOF
${MANAGED_BLOCK_START}
# 允许已建立连接
-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# 允许回环接口
-A ufw-before-input -i lo -j ACCEPT
# 禁止 Ping
-A ufw-before-input -p icmp --icmp-type echo-request -j DROP
# 拒绝非中国 IP 的新入站流量
-A ufw-before-input -m set ! --match-set ${IPSET_NAME} src -j DROP
${MANAGED_BLOCK_END}
EOF
)"

    if [ ! -f "$UFW_BEFORE_RULES" ]; then
        echo "错误：未找到 UFW 规则文件: $UFW_BEFORE_RULES"
        exit 1
    fi

    cp "$UFW_BEFORE_RULES" "${UFW_BEFORE_RULES}.bak.$(date +%Y%m%d%H%M%S)"
    tmp_file="$(mktemp)"

    awk -v start="$MANAGED_BLOCK_START" -v end="$MANAGED_BLOCK_END" -v block="$managed_block" '
        $0 == start { skip = 1; next }
        $0 == end { skip = 0; next }
        skip { next }
        !inserted && $0 == "COMMIT" {
            print block
            inserted = 1
        }
        { print }
    ' "$UFW_BEFORE_RULES" > "$tmp_file"

    install -m 0644 "$tmp_file" "$UFW_BEFORE_RULES"
    rm -f "$tmp_file"
}

configure_ufw() {
    local port=""

    echo ">>> 正在配置 UFW..."
    ufw default deny incoming
    ufw default allow outgoing

    while read -r port; do
        [ -z "$port" ] && continue
        ufw allow "${port}/tcp" comment "SSH"
    done < <(get_ssh_ports)

    inject_ufw_rules

    ufw --force enable
    ufw reload
}

install_update_script() {
    echo ">>> 正在安装中国 IP 自动更新脚本..."

    cat > "$UPDATE_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

IPSET_NAME="${IPSET_NAME}"
IPSET_SAVE_FILE="${IPSET_SAVE_FILE}"
CHINA_IP_URL="${CHINA_IP_URL}"
TMP_FILE="\$(mktemp /tmp/cn.XXXXXX.zone)"
TMP_SET="\${IPSET_NAME}_tmp_\$(date +%s)"
LOG_FILE="/var/log/ipset-update.log"

cleanup() {
    rm -f "\$TMP_FILE"
    ipset destroy "\$TMP_SET" 2>/dev/null || true
}

trap cleanup EXIT

echo "[\$(date)] 开始更新中国 IP 集" >> "\$LOG_FILE"
curl -fsSL "\$CHINA_IP_URL" -o "\$TMP_FILE"

if [ ! -s "\$TMP_FILE" ]; then
    echo "[\$(date)] 下载失败或文件为空" >> "\$LOG_FILE"
    exit 1
fi

ipset create "\$TMP_SET" hash:net family inet

VALID_COUNT=0
while read -r ip; do
    if [[ "\$ip" =~ ^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}\$ ]]; then
        ipset add "\$TMP_SET" "\$ip" -exist
        VALID_COUNT=\$((VALID_COUNT + 1))
    fi
done < "\$TMP_FILE"

if [ "\$VALID_COUNT" -lt 1000 ]; then
    echo "[\$(date)] 有效 IP 数量异常: \$VALID_COUNT" >> "\$LOG_FILE"
    exit 1
fi

if ipset list -n | grep -qx "\$IPSET_NAME"; then
    ipset swap "\$TMP_SET" "\$IPSET_NAME"
    ipset destroy "\$TMP_SET"
else
    ipset rename "\$TMP_SET" "\$IPSET_NAME"
fi

ipset save "\$IPSET_NAME" -f "\$IPSET_SAVE_FILE"
echo "[\$(date)] 更新完成，有效条目数: \$VALID_COUNT" >> "\$LOG_FILE"
EOF

    chmod +x "$UPDATE_SCRIPT"
    echo ">>> 正在配置 crontab 每周自动更新任务..."

    if ! crontab -l 2>/dev/null | grep -Fq "$UPDATE_SCRIPT"; then
        (crontab -l 2>/dev/null; echo "0 3 * * 1 $UPDATE_SCRIPT") | crontab -
        echo ">>> 已写入 crontab: 0 3 * * 1 $UPDATE_SCRIPT"
    else
        echo ">>> 已存在对应 crontab，跳过重复写入。"
    fi
}

main() {
    require_root
    require_command apt
    require_command systemctl

    install_packages
    require_command ipset
    require_command ufw
    require_command curl
    require_command crontab
    create_ipset_data
    configure_ipset_restore_service
    configure_ufw
    install_update_script

    echo "----------------------------------------"
    echo "Ubuntu/Debian 防火墙配置完成"
    echo "当前 UFW 状态："
    ufw status verbose
    echo "----------------------------------------"
}

main "$@"
