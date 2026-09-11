#!/bin/bash
# Description: CentOS/RHEL/Alibaba Cloud Linux 防火墙 - 禁用 Ping，可选中国 IP 限制和 EdgeOne 回源例外。

set -euo pipefail

# shellcheck source=firewall/firewall_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/firewall_common.sh"

run_firewall_cmd() {
    firewall-cmd "$@" >/dev/null
}

package_install() {
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y ipset iptables firewalld python3 ca-certificates cronie
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ipset iptables firewalld python3 ca-certificates cronie
    else
        echo "错误：未检测到 dnf 或 yum。"
        exit 1
    fi
    systemctl enable --now crond
}

configure_direct_rules() {
    local family="$1"
    local china_set="china"
    local eo_set="edgeone"
    local protocol="icmp"
    local icmp_option="--icmp-type"
    local chain="INIT_SERVER_INPUT"
    if [ "$family" = ipv6 ]; then
        china_set="china6"
        eo_set="edgeone6"
        protocol="ipv6-icmp"
        icmp_option="--icmpv6-type"
    fi
    if ! run_firewall_cmd --permanent --direct --query-chain "$family" filter "$chain"; then
        run_firewall_cmd --permanent --direct --add-chain "$family" filter "$chain"
    fi
    run_firewall_cmd --permanent --direct --remove-rules "$family" filter "$chain"
    run_firewall_cmd --permanent --direct --add-rule "$family" filter "$chain" 0 -i lo -j RETURN
    run_firewall_cmd --permanent --direct --add-rule "$family" filter "$chain" 1 -p "$protocol" "$icmp_option" echo-request -j DROP
    run_firewall_cmd --permanent --direct --add-rule "$family" filter "$chain" 2 -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
    if [ "$family" = ipv6 ]; then
        run_firewall_cmd --permanent --direct --add-rule "$family" filter "$chain" 3 -p ipv6-icmp -j RETURN
    fi
    if "$EDGEONE_ENABLED"; then
        run_firewall_cmd --permanent --direct --add-rule "$family" filter "$chain" 10 -m set --match-set "$eo_set" src -j RETURN
    fi
    if "$CHINA_ENABLED" && { [ "$family" = ipv4 ] || "$CHINA_IPV6_ENABLED"; }; then
        run_firewall_cmd --permanent --direct --add-rule "$family" filter "$chain" 11 -m set --match-set "$china_set" src -j RETURN
        run_firewall_cmd --permanent --direct --add-rule "$family" filter "$chain" 20 -j DROP
    fi
    if ! run_firewall_cmd --permanent --direct --query-rule "$family" filter INPUT 2 -j "$chain"; then
        run_firewall_cmd --permanent --direct --add-rule "$family" filter INPUT 2 -j "$chain"
    fi
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

    # 清理旧脚本添加的规则，确保重新运行选择关闭后不再限制中国 IP。
    local -a legacy_rule=()
    for priority in 0 1 2; do
        case "$priority" in
            0) legacy_rule=(-i lo -j ACCEPT) ;;
            1) legacy_rule=(-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT) ;;
            2) legacy_rule=(-m set ! --match-set china src -j DROP) ;;
        esac
        if run_firewall_cmd --permanent --direct --query-rule ipv4 filter INPUT "$priority" "${legacy_rule[@]}"; then
            run_firewall_cmd --permanent --direct --remove-rule ipv4 filter INPUT "$priority" "${legacy_rule[@]}"
        fi
    done
    configure_direct_rules ipv4
    configure_direct_rules ipv6
    run_firewall_cmd --check-config
    run_firewall_cmd --reload
}

main() {
    require_root
    choose_firewall_options
    if all_sources_skipped; then
        return 0
    fi
    require_command systemctl
    package_install
    require_command firewall-cmd
    require_command ipset
    require_command python3
    require_command crontab
    prepare_ipsets
    configure_ipset_restore_service firewalld.service
    configure_firewalld
    install_update_jobs

    echo "CentOS/RHEL 防火墙配置完成"
    print_policy_summary
    firewall-cmd --state
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
