#!/bin/bash
# Description: CentOS/RHEL/Alibaba Cloud Linux 一键配置防火墙 - 禁用 Ping + 仅允许中国 IP 访问已放行端口

set -euo pipefail

IPSET_NAME="china"
IPSET_SAVE_FILE="/etc/ipset/china.conf"
IPSET_RESTORE_SERVICE="/etc/systemd/system/ipset-restore.service"
CHINA_IP_URL="https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone"
UPDATE_SCRIPT="/usr/local/bin/update-china-ips-centos.sh"

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

run_firewall_cmd() {
    firewall-cmd "$@" >/dev/null
}

package_install() {
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y ipset firewalld curl cronie
        systemctl enable --now crond
        return 0
    fi

    if command -v yum >/dev/null 2>&1; then
        yum install -y ipset firewalld curl cronie
        systemctl enable --now crond
        return 0
    fi

    echo "错误：未检测到 dnf 或 yum。"
    exit 1
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

configure_firewalld() {
    local port=""

    echo ">>> 正在配置 firewalld..."
    systemctl enable --now firewalld

    while read -r port; do
        [ -z "$port" ] && continue
        run_firewall_cmd --permanent --add-port="${port}/tcp"
    done < <(get_ssh_ports)

    run_firewall_cmd --permanent --add-icmp-block=echo-request

    run_firewall_cmd --permanent --direct --remove-rule ipv4 filter INPUT 0 -i lo -j ACCEPT 2>/dev/null || true
    run_firewall_cmd --permanent --direct --remove-rule ipv4 filter INPUT 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    run_firewall_cmd --permanent --direct --remove-rule ipv4 filter INPUT 2 -m set ! --match-set "$IPSET_NAME" src -j DROP 2>/dev/null || true

    run_firewall_cmd --permanent --direct --add-rule ipv4 filter INPUT 0 -i lo -j ACCEPT
    run_firewall_cmd --permanent --direct --add-rule ipv4 filter INPUT 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    run_firewall_cmd --permanent --direct --add-rule ipv4 filter INPUT 2 -m set ! --match-set "$IPSET_NAME" src -j DROP

    run_firewall_cmd --reload
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
    package_install
    require_command systemctl
    require_command firewall-cmd
    require_command ipset
    require_command curl
    require_command crontab
    create_ipset_data
    configure_ipset_restore_service
    configure_firewalld
    install_update_script

    echo "----------------------------------------"
    echo "CentOS/RHEL 防火墙配置完成"
    echo "当前 firewalld 状态："
    firewall-cmd --state
    echo "----------------------------------------"
}

main "$@"
