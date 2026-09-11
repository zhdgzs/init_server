#!/bin/bash
# 两种防火墙共用的交互、IP 集安装和更新任务。

FIREWALL_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGEONE_CREDENTIALS_FILE="$(dirname "$FIREWALL_SOURCE_DIR")/edgeone.json"
IPSET_MANAGER="/usr/local/lib/init-server-firewall/ipset_manager.py"
IPSET_CONFIG="/etc/init-server-firewall/config.json"
FIREWALL_RULE_FILES=("/etc/ufw/before.rules" "/etc/ufw/before6.rules" "/etc/firewalld/direct.xml")
CHINA_ENABLED=false
EDGEONE_ENABLED=false
CHINA_CONFIGURED=false
EDGEONE_CONFIGURED=false
CHINA_SKIP=false
EDGEONE_SKIP=false
CHINA_IPV6_ENABLED=true

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：必须以 root 权限运行此脚本"
        exit 1
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "错误：缺少必要命令: $1"
        exit 1
    fi
}

ask_yes_no() {
    local reply=""
    while true; do
        if ! read -r -p "$1 [y/N]: " reply; then
            echo "错误：输入结束，已中止。" >&2
            exit 1
        fi
        case "$reply" in
            y|Y|yes|YES|是|确认|继续) return 0 ;;
            n|N|no|NO|否|"") return 1 ;;
            *) echo "请输入 y 或 n。" ;;
        esac
    done
}

has_existing_source_rules() {
    local source="$1"
    local rules_file=""
    local command=""
    local rules=""
    local pattern="--match-set[[:space:]]+${source}6?[[:space:]]+src"
    for rules_file in "${FIREWALL_RULE_FILES[@]}"; do
        if [ -f "$rules_file" ] && grep -Eq -- "$pattern" "$rules_file"; then
            return 0
        fi
    done
    # 检查尚未保存的运行时规则；不启动防火墙服务，也不安装检查工具。
    for command in iptables-save ip6tables-save; do
        if command -v "$command" >/dev/null 2>&1; then
            if rules="$("$command" -t filter 2>/dev/null)"; then
                if grep -Eq -- "$pattern" <<< "$rules"; then
                    return 0
                fi
            fi
        fi
    done
    return 1
}

load_existing_options() {
    local state=""
    if [ -f "$IPSET_CONFIG" ]; then
        require_command python3
        state="$(python3 -c '
import json, sys
with open(sys.argv[1]) as stream:
    config = json.load(stream)
values = [config.get("china", False), config.get("edgeone", False),
          "china" in config, "edgeone" in config, config.get("china_ipv6", True)]
if any(type(value) is not bool for value in values):
    raise ValueError("防火墙配置中的策略开关必须是布尔值")
print(" ".join(str(value).lower() for value in values))
' "$IPSET_CONFIG")"
        read -r CHINA_ENABLED EDGEONE_ENABLED CHINA_CONFIGURED EDGEONE_CONFIGURED CHINA_IPV6_ENABLED <<< "$state"
    else
        # 旧版本只配置中国 IPv4，跳过时保留其原有覆盖范围。
        if has_existing_source_rules china; then
            CHINA_CONFIGURED=true
            CHINA_ENABLED=true
            CHINA_IPV6_ENABLED=false
        fi
        if has_existing_source_rules edgeone; then
            EDGEONE_CONFIGURED=true
            EDGEONE_ENABLED=true
        fi
    fi
}

choose_source_policy() {
    local source="$1"
    local prompt="$2"
    local configured_var="${source^^}_CONFIGURED"
    local enabled_var="${source^^}_ENABLED"
    local skip_var="${source^^}_SKIP"
    if "${!configured_var}"; then
        echo ">>> 检测到已有 ${source} 策略，当前启用状态: ${!enabled_var}"
        if ! ask_yes_no "是否覆盖 ${source} 的规则和 IP 集配置？选择 n 或直接回车跳过"; then
            printf -v "$skip_var" '%s' true
            echo ">>> 跳过 ${source}，保留原有策略和 IP 集配置。"
            return 0
        fi
    fi
    printf -v "$skip_var" '%s' false
    printf -v "$enabled_var" '%s' false
    if ask_yes_no "$prompt"; then
        printf -v "$enabled_var" '%s' true
    fi
}

choose_firewall_options() {
    load_existing_options
    choose_source_policy china "是否需要禁止非中国 IP 访问（IPv4 和 IPv6）？"
    if ! "$CHINA_SKIP"; then
        CHINA_IPV6_ENABLED=true
    fi
    choose_source_policy edgeone "是否允许腾讯云 EdgeOne 回源 IP 访问（豁免地域限制，仍需放行业务端口）？"
    echo ">>> 中国 IP 限制: $CHINA_ENABLED；EdgeOne 回源例外: $EDGEONE_ENABLED"
}

all_sources_skipped() {
    if "$CHINA_SKIP" && "$EDGEONE_SKIP"; then
        echo ">>> 两项均已跳过，保留现有防火墙配置。"
        return 0
    fi
    return 1
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

prepare_ipsets() (
    set -euo pipefail
    local staged_config=""
    local options=()
    install -d -m 0755 "/usr/local/lib/init-server-firewall" "/etc/ipset"
    install -d -m 0700 "/etc/init-server-firewall"
    install -m 0755 "$FIREWALL_SOURCE_DIR/ipset_manager.py" "$IPSET_MANAGER"
    staged_config="$(mktemp "/etc/init-server-firewall/config.XXXXXX")"
    trap 'rm -f "$staged_config"' EXIT
    if "$CHINA_ENABLED"; then options+=(--china); fi
    if "$EDGEONE_ENABLED"; then
        options+=(--edgeone --credentials-file "$EDGEONE_CREDENTIALS_FILE")
    fi
    if "$EDGEONE_SKIP"; then options+=(--keep-edgeone --previous-config "$IPSET_CONFIG"); fi
    if ! "$CHINA_IPV6_ENABLED"; then options+=(--china-ipv4-only); fi
    python3 "$IPSET_MANAGER" configure --config "$staged_config" "${options[@]}"
    if ! "$CHINA_SKIP"; then
        python3 "$IPSET_MANAGER" update --config "$staged_config" --source china
    fi
    if ! "$EDGEONE_SKIP"; then
        python3 "$IPSET_MANAGER" update --config "$staged_config" --source edgeone
    fi
    install -m 0600 "$staged_config" "$IPSET_CONFIG"
)

configure_ipset_restore_service() {
    local firewall_service="$1"
    cat > "/etc/systemd/system/ipset-restore.service" <<EOF
[Unit]
Description=Restore init-server IP sets before the firewall
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target ufw.service firewalld.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 $IPSET_MANAGER restore

[Install]
WantedBy=multi-user.target
EOF
    install -d -m 0755 "/etc/systemd/system/${firewall_service}.d"
    cat > "/etc/systemd/system/${firewall_service}.d/ipset.conf" <<EOF
[Unit]
Requires=ipset-restore.service
After=ipset-restore.service
EOF
    systemctl daemon-reload
    systemctl enable ipset-restore.service
}

install_update_jobs() {
    local old_jobs=""
    local retained_jobs=""
    local cron_file="${1:-/etc/cron.d/init-server-ipsets}"
    local managed_jobs=""
    if [ -f "$cron_file" ]; then
        managed_jobs="$(< "$cron_file")"
    fi
    # 迁移旧版的两条中国 IP 更新任务，保留用户的其他 crontab 项。
    old_jobs="$(crontab -l 2>/dev/null || true)"
    retained_jobs="$(printf '%s\n' "$old_jobs" | awk '
        $0 != "0 3 * * 1 /usr/local/bin/update-china-ips.sh" &&
        $0 != "0 3 * * 1 /usr/local/bin/update-china-ips-centos.sh"
    ')"
    if ! "$CHINA_SKIP" && [ "$old_jobs" != "$retained_jobs" ]; then
        printf '%s\n' "$retained_jobs" | crontab -
    fi
    {
        echo 'SHELL=/bin/bash'
        echo 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        if "$CHINA_SKIP"; then
            printf '%s\n' "$managed_jobs" | awk '/--source china([[:space:]]|$)/'
        elif "$CHINA_ENABLED"; then
            echo "0 3 * * 1 root /usr/bin/python3 $IPSET_MANAGER update --source china >> /var/log/ipset-update.log 2>&1"
        fi
        if "$EDGEONE_SKIP"; then
            printf '%s\n' "$managed_jobs" | awk '/--source edgeone([[:space:]]|$)/'
        elif "$EDGEONE_ENABLED"; then
            echo "15 3 */3 * * root /usr/bin/python3 $IPSET_MANAGER update --source edgeone >> /var/log/ipset-update.log 2>&1"
        fi
    } > "$cron_file"
    chmod 0644 "$cron_file"
}

print_policy_summary() {
    echo "中国 IP 限制: $CHINA_ENABLED；IPv6 限制: $CHINA_IPV6_ENABLED（仅中国 IP 限制开启时生效）"
    echo "EdgeOne 回源例外: $EDGEONE_ENABLED（仍需放行业务端口）"
    echo "IP 集更新日志: /var/log/ipset-update.log"
    echo "规则作用于本机 INPUT；Docker 映射端口等 FORWARD 流量不在此范围。"
}
