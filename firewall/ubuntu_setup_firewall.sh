#!/bin/bash
# Description: Ubuntu/Debian 防火墙 - 禁用 Ping，可选中国 IP 限制和 EdgeOne 回源例外。

set -euo pipefail

# shellcheck source=firewall/firewall_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/firewall_common.sh"

install_packages() {
    echo ">>> 正在安装必要工具..."
    apt update
    apt install -y ufw ipset iptables python3 ca-certificates cron
    systemctl enable --now cron
}

render_ufw_block() {
    local family="$1"
    local parent="ufw-before-input"
    local china_set="china"
    local eo_set="edgeone"
    if [ "$family" = 6 ]; then
        parent="ufw6-before-input"
        china_set="china6"
        eo_set="edgeone6"
    fi
    echo '# BEGIN INIT-SERVER IPSET RULES'
    echo ':init-server-input - [0:0]'
    echo "-A $parent -j init-server-input"
    echo '-A init-server-input -i lo -j RETURN'
    if [ "$family" = 4 ]; then
        echo '-A init-server-input -p icmp --icmp-type echo-request -j DROP'
    else
        echo '-A init-server-input -p ipv6-icmp --icmpv6-type echo-request -j DROP'
    fi
    echo '-A init-server-input -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN'
    if [ "$family" = 6 ]; then
        # 保留邻居发现、路径 MTU 等 IPv6 控制报文，交由 UFW 原有规则检查。
        echo '-A init-server-input -p ipv6-icmp -j RETURN'
    fi
    if "$EDGEONE_ENABLED"; then
        echo "-A init-server-input -m set --match-set $eo_set src -j RETURN"
    fi
    if "$CHINA_ENABLED" && { [ "$family" = 4 ] || "$CHINA_IPV6_ENABLED"; }; then
        echo "-A init-server-input -m set --match-set $china_set src -j RETURN"
        echo '-A init-server-input -j DROP'
    fi
    echo '# END INIT-SERVER IPSET RULES'
}

inject_ufw_rules() (
    set -euo pipefail
    local rules_file="$1"
    local family="$2"
    local tmp_file=""
    local block=""
    local restore_command="iptables-restore"
    [ "$family" = 6 ] && restore_command="ip6tables-restore"
    if [ ! -f "$rules_file" ]; then
        echo "错误：未找到 UFW 规则文件: $rules_file" >&2
        exit 1
    fi
    tmp_file="$(mktemp)"
    trap 'rm -f "$tmp_file"' EXIT
    block="$(render_ufw_block "$family")"
    # 将检查放在 UFW 的现有 ACCEPT 之前；同时移除旧版管理块。
    awk -v block="$block" '
        $0 == "# BEGIN CHINA-IPSET RULES" || $0 == "# BEGIN INIT-SERVER IPSET RULES" {
            skip = 1; next
        }
        $0 == "# END CHINA-IPSET RULES" || $0 == "# END INIT-SERVER IPSET RULES" {
            skip = 0; next
        }
        skip { next }
        $0 == "*filter" { in_filter = 1 }
        in_filter && !inserted && /^-A / {
            print block
            inserted = 1
        }
        $0 == "COMMIT" { in_filter = 0 }
        { print }
        END { if (!inserted || skip) exit 1 }
    ' "$rules_file" > "$tmp_file"
    "$restore_command" --test < "$tmp_file"
    cp "$rules_file" "${rules_file}.bak.$(date +%Y%m%d%H%M%S)"
    install -m 0644 "$tmp_file" "$rules_file"
)

configure_ufw() {
    local port=""
    echo ">>> 正在配置 UFW..."
    # 关闭 IPV6 时 UFW 不会加载 before6.rules，必须同步启用双栈规则。
    if ! grep -Eq '^[[:space:]]*IPV6=yes[[:space:]]*$' "/etc/default/ufw"; then
        echo ">>> 正在启用 UFW IPv6 规则支持..."
        cp "/etc/default/ufw" "/etc/default/ufw.bak.$(date +%Y%m%d%H%M%S)"
        sed -i '/^[[:space:]]*IPV6=/d' "/etc/default/ufw"
        echo 'IPV6=yes' >> "/etc/default/ufw"
    fi
    ufw default deny incoming
    ufw default allow outgoing
    while read -r port; do
        [ -z "$port" ] && continue
        ufw allow "${port}/tcp" comment "SSH"
    done < <(get_ssh_ports)
    inject_ufw_rules "/etc/ufw/before.rules" 4
    inject_ufw_rules "/etc/ufw/before6.rules" 6
    ufw --force enable
    ufw reload
}

main() {
    require_root
    choose_firewall_options
    if all_sources_skipped; then
        return 0
    fi
    require_command apt
    require_command systemctl
    install_packages
    require_command ipset
    require_command python3
    require_command ufw
    require_command crontab
    prepare_ipsets
    configure_ipset_restore_service ufw.service
    configure_ufw
    install_update_jobs

    echo "Ubuntu/Debian 防火墙配置完成"
    print_policy_summary
    ufw status verbose
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
