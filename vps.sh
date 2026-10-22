#!/usr/bin/env bash
# VPS 工具：Root SSH 登录、SSH 端口、防火墙、Swap、标准 BBR、状态探针。
# 适用于使用 systemd 的 Debian/Ubuntu；支持 curl -fsSL URL | sudo bash。

if (( EUID != 0 )); then
    printf '请使用 root 权限运行。\n' >&2
    exit 1
fi

# 独立读取终端，避免管道运行时将脚本内容当成菜单或密码。
if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '需要交互终端，请通过 SSH 登录后运行。\n' >&2
    exit 1
fi

ssh_service_name() {
    if systemctl list-unit-files sshd.service --no-legend | grep -q '^sshd.service'; then
        printf 'sshd\n'
    else
        printf 'ssh\n'
    fi
}

confirm_firewall_change() {
    local answer
    printf '\n⚠️ 危险操作检测！\n操作类型：%s\n影响范围：本机 iptables / ip6tables 入站规则（IPv4 / IPv6）及开机恢复服务。\n风险评估：%s\n' "$1" "$2"
    IFS= read -r -u 3 -p '请确认是否继续？[是/确认/继续，其他输入取消]: ' answer || return 1
    [[ "$answer" == 是 || "$answer" == 确认 || "$answer" == 继续 ]]
}

# 同时保护配置端口、实际 sshd 监听端口、socket 激活端口和当前会话端口。
detect_ssh_ports() (
    set -e -o pipefail
    command -v sshd >/dev/null || { printf '未安装 OpenSSH 服务。\n' >&2; exit 1; }
    command -v ss >/dev/null || { printf '缺少 ss 命令，请先安装 iproute2。\n' >&2; exit 1; }
    sshd -t
    config=$(sshd -T)
    listeners=$(ss -H -ltnp)
    ports=$(awk '$1 == "port" {print $2} $1 == "listenaddress" {sub(/^.*:/, "", $2); print $2}' <<< "$config")
    ports+=$'\n'$(awk '/"sshd(-session)?"/ {sub(/^.*:/, "", $4); print $4}' <<< "$listeners")
    for socket in ssh.socket sshd.socket; do
        if systemctl is-active --quiet "$socket"; then
            listen=$(systemctl show "$socket" --property=Listen --value)
            socket_ports=$(awk '{for (i=2; i<=NF; i++) if ($i == "(Stream)") {p=$(i-1); sub(/^.*:/, "", p); print p}}' <<< "$listen")
            [[ -n "$socket_ports" ]] || { printf '无法检测 %s 的监听端口，停止操作。\n' "$socket" >&2; exit 1; }
            ports+=$'\n'"$socket_ports"
        fi
    done
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r client_ip client_port server_ip server_port <<< "$SSH_CONNECTION"
        ports+=$'\n'"$server_port"
    fi
    ports=$(while IFS= read -r port; do
        [[ -n "$port" ]] || continue
        [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || {
            printf '检测到无效 SSH 端口：%s，停止操作。\n' "$port" >&2; exit 1;
        }
        printf '%s\n' "$((10#$port))"
    done <<< "$ports" | sort -nu)
    [[ -n "$ports" ]] || { printf '未检测到 SSH 端口，停止操作。\n' >&2; exit 1; }
    printf '%s\n' "$ports"
)

# 只管理自己的入站链，保留 OUTPUT、FORWARD、NAT 及其他自定义链。
render_firewall_rules() {
    local family=$1 port
    cat <<'RULES'
*filter
:VPS_INPUT - [0:0]
-F VPS_INPUT
-A VPS_INPUT -i lo -j ACCEPT
-A VPS_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A VPS_INPUT -m conntrack --ctstate INVALID -j DROP
# 端口规则
RULES
    if [[ "$family" == 4 ]]; then
        printf '%s\n' '-A VPS_INPUT -p icmp -j ACCEPT' \
            '-A VPS_INPUT -p udp --sport 67 --dport 68 -j ACCEPT'
    else
        printf '%s\n' '-A VPS_INPUT -p ipv6-icmp -j ACCEPT' \
            '-A VPS_INPUT -s fe80::/10 -p udp --sport 547 --dport 546 -j ACCEPT'
    fi
    printf '%s\n' '-A VPS_INPUT -p tcp --dport 443 -j ACCEPT'
    while IFS= read -r port; do
        [[ "$port" == 443 ]] && continue
        printf '%s\n' "-A VPS_INPUT -p tcp --dport $port -j ACCEPT"
    done <<< "$2"
    printf '%s\n' '-A VPS_INPUT -j DROP' 'COMMIT'
}

# 在同一次提交内移除旧入口并置顶，避免重复运行累积跳转规则。
prepare_firewall_restore() {
    sed '$d' "$1"
    awk '$0 == "-A INPUT -j VPS_INPUT" {print "-D INPUT -j VPS_INPUT"}' "$2"
    printf '%s\n' '-I INPUT 1 -j VPS_INPUT' 'COMMIT'
}

# 同时供菜单和开机服务使用；IPv4 / IPv6 不能跨协议族原子提交，失败时回滚。
restore_firewall_rules() (
    set -e -o pipefail
    rules_dir=$1
    work=$(mktemp -d)
    live_changed=no
    trap '
        status=$?
        if (( status != 0 )) && [[ "$live_changed" == yes ]]; then
            iptables-restore --wait 5 < "$work/old.v4" || printf "恢复 IPv4 失败。\n" >&2
            ip6tables-restore --wait 5 < "$work/old.v6" || printf "恢复 IPv6 失败。\n" >&2
        fi
        if (( status == 0 )); then
            rm -rf "$work"
        else
            printf "防火墙恢复材料保留在：%s\n" "$work" >&2
        fi
    ' EXIT
    iptables-save -t filter > "$work/old.v4"
    ip6tables-save -t filter > "$work/old.v6"
    for family in 4 6; do
        [[ "$(tail -n 1 "$rules_dir/rules.v$family")" == COMMIT ]]
        prepare_firewall_restore "$rules_dir/rules.v$family" "$work/old.v$family" > "$work/new.v$family"
    done
    iptables-restore --wait 5 --test --noflush < "$work/new.v4"
    ip6tables-restore --wait 5 --test --noflush < "$work/new.v6"
    iptables-restore --wait 5 --noflush < "$work/new.v4"
    live_changed=yes
    ip6tables-restore --wait 5 --noflush < "$work/new.v6"
)

# 三个入口共用持久化和回滚，避免运行规则与开机配置不一致。
apply_firewall_rules() (
    set -e -o pipefail
    candidate=$1
    rules_dir=/etc/vps-firewall
    unit_file=/etc/systemd/system/vps-firewall.service
    umask 077
    backup=$(mktemp -d "/etc/vps-firewall-backup.XXXXXX")
    iptables-save -t filter > "$backup/live.v4"
    ip6tables-save -t filter > "$backup/live.v6"
    for file in rules.v4 rules.v6 restore.sh; do
        if [[ -f "$rules_dir/$file" ]]; then cp -p "$rules_dir/$file" "$backup/$file"; fi
    done
    unit_existed=no was_enabled=no live_changed=no files_changed=no
    if [[ -f "$unit_file" ]]; then cp -p "$unit_file" "$backup/service"; unit_existed=yes; fi
    if systemctl is-enabled --quiet vps-firewall.service; then was_enabled=yes; fi
    trap '
        status=$?
        if (( status != 0 )); then
            restored=yes
            if [[ "$live_changed" == yes ]]; then
                iptables-restore --wait 5 < "$backup/live.v4" || restored=no
                ip6tables-restore --wait 5 < "$backup/live.v6" || restored=no
            fi
            if [[ "$files_changed" == yes ]]; then
                if [[ "$was_enabled" == no ]]; then systemctl disable vps-firewall.service || restored=no; fi
                for file in rules.v4 rules.v6 restore.sh; do
                    if [[ -f "$backup/$file" ]]; then
                        cp -p "$backup/$file" "$rules_dir/$file" || restored=no
                    else
                        rm -f "$rules_dir/$file" || restored=no
                    fi
                done
                if [[ "$unit_existed" == yes ]]; then
                    cp -p "$backup/service" "$unit_file" || restored=no
                else
                    rm -f "$unit_file" || restored=no
                fi
                systemctl daemon-reload || restored=no
            fi
            printf "防火墙配置失败，原配置恢复结果：%s；备份：%s\n" "$restored" "$backup" >&2
        fi
    ' EXIT
    restore_firewall_rules "$candidate"
    live_changed=yes
    files_changed=yes
    mkdir -p "$rules_dir"
    install -m 600 "$candidate/rules.v4" "$rules_dir/rules.v4"
    install -m 600 "$candidate/rules.v6" "$rules_dir/rules.v6"
    {
        printf '#!/usr/bin/env bash\nset -e -o pipefail\nPATH=/usr/sbin:/usr/bin:/sbin:/bin\n'
        declare -f prepare_firewall_restore restore_firewall_rules
        printf 'restore_firewall_rules /etc/vps-firewall\n'
    } > "$rules_dir/restore.sh"
    chmod 700 "$rules_dir/restore.sh"
    cat > "$unit_file" <<UNIT
[Unit]
Description=VPS iptables firewall
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $rules_dir/restore.sh
ExecReload=/bin/bash $rules_dir/restore.sh

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$unit_file"
    systemctl daemon-reload
    systemctl enable vps-firewall.service
    printf 'iptables 规则已应用并设置开机恢复；原配置备份：%s\n' "$backup"
)

enable_firewall() (
    set -e -o pipefail
    ssh_ports=$(detect_ssh_ports)
    for manager in ufw firewalld nftables netfilter-persistent; do
        if systemctl is-active --quiet "$manager.service"; then
            printf '%s 正在管理防火墙，请先统一管理方式。\n' "$manager" >&2
            exit 1
        fi
    done
    if [[ -f /etc/vps-firewall/rules.nft ]]; then
        printf '检测到旧版 nftables 配置，请先停用并迁移旧规则，避免两套规则同时生效。\n' >&2
        exit 1
    fi
    printf '将放行 TCP 443 和以下 SSH TCP 端口：\n%s\n' "$ssh_ports"
    printf '其他本机新入站端口（包括 80）将被关闭；保留回环、已有连接、ICMP 和 DHCP。\n'
    printf '本脚本入站链优先于已有 INPUT 规则；出站、转发、Docker 映射端口及云安全组需另行管理。\n'
    confirm_firewall_change '启用 iptables / ip6tables 防火墙（缺少命令时安装 iptables）' \
        '替换本脚本入站链，其他入站服务将无法新建连接；重复启用会恢复 443 放行。' || exit 0
    missing=no
    for tool in iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore; do
        command -v "$tool" >/dev/null || missing=yes
    done
    if [[ "$missing" == yes ]]; then
        apt-get update
        apt-get install -y iptables
    fi
    candidate=$(mktemp -d)
    trap 'rm -rf "$candidate"' EXIT
    render_firewall_rules 4 "$ssh_ports" > "$candidate/rules.v4"
    render_firewall_rules 6 "$ssh_ports" > "$candidate/rules.v6"
    apply_firewall_rules "$candidate"
    printf '请保留当前 SSH 会话并另开连接验证。\n'
)

# 将新的端口动作放在已有端口规则之前，但保留已建立连接和回环流量。
update_firewall_port() (
    set -e -o pipefail
    port=$1 action=$2
    candidate=$(mktemp -d)
    trap 'rm -rf "$candidate"' EXIT
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
    [[ "$action" == ACCEPT || "$action" == DROP ]]
    for family in 4 6; do
        grep -qx '# 端口规则' "/etc/vps-firewall/rules.v$family"
        awk -v port="$port" -v action="$action" '
            $1 == "-A" && $2 == "VPS_INPUT" && $5 == "--dport" && $6 == port && $8 == action {next}
            {print}
            $0 == "# 端口规则" {
                print "-A VPS_INPUT -p tcp --dport " port " -j " action
                if (action == "DROP") print "-A VPS_INPUT -p udp --dport " port " -j DROP"
            }
        ' "/etc/vps-firewall/rules.v$family" > "$candidate/rules.v$family"
    done
    apply_firewall_rules "$candidate"
)

close_firewall_port() (
    set -e -o pipefail
    [[ -f /etc/vps-firewall/rules.v4 && -f /etc/vps-firewall/rules.v6 ]] || {
        printf '请先使用菜单 4 启用防火墙。\n'; exit 1;
    }
    iptables --wait 5 -C INPUT -j VPS_INPUT
    ip6tables --wait 5 -C INPUT -j VPS_INPUT
    ssh_ports=$(detect_ssh_ports)
    IFS= read -r -u 3 -p '请输入要关闭的端口（1-65535，同时阻止 TCP / UDP）: ' port
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || { printf '端口必须是 1-65535 的整数。\n'; exit 1; }
    port=$((10#$port))
    (( port >= 1 && port <= 65535 )) || { printf '端口必须在 1-65535 范围内。\n'; exit 1; }
    while IFS= read -r ssh_port; do
        [[ "$port" != "$ssh_port" ]] || { printf '端口 %s 用于 SSH，拒绝关闭以免失联。\n' "$port" >&2; exit 1; }
    done <<< "$ssh_ports"
    confirm_firewall_change "关闭入站端口 $port（TCP / UDP）" \
        '该端口将拒绝新的入站连接，已有连接继续；Docker 映射端口需单独管理。' || exit 0
    update_firewall_port "$port" DROP
    printf '已关闭端口 %s 的新入站连接。\n' "$port"
)

setup_ssh() (
    set -e
    local password config=/etc/ssh/sshd_config service=ssh

    command -v sshd >/dev/null || { printf '未安装 OpenSSH 服务。\n'; exit 1; }
    sshd -t
    IFS= read -r -u 3 -p '请输入新的 root 密码: ' password
    printf '\n'
    [[ -n "$password" ]] || { printf '密码不能为空。\n'; exit 1; }
    printf 'root:%s\n' "$password" | chpasswd
    unset password

    cp -p "$config" "${config}.bak"
    # 将全局设置置于 Include 和 Match 之前，兼容云服务器配置。
    sed -i '/^[[:space:]]*PermitRootLogin[[:space:]]/d; /^[[:space:]]*PasswordAuthentication[[:space:]]/d' "$config"
    sed -i '1i PermitRootLogin yes\nPasswordAuthentication yes' "$config"
    if ! sshd -t; then
        cp -p "${config}.bak" "$config"
        printf 'SSH 配置验证失败，已恢复原配置。\n' >&2
        exit 1
    fi

    service=$(ssh_service_name)
    systemctl restart "$service"
    printf 'Root 密码登录已启用，原配置备份：%s.bak\n' "$config"
)

setup_ssh_port() (
    set -e
    # 子 shell 隔离变量；不用 local，确保 EXIT 回滚时仍能读取备份信息。
    socket='' backup='' changed=no firewall_changed=no
    socket_config='' socket_existed=no
    configs=(/etc/ssh/sshd_config)

    command -v sshd >/dev/null || { printf '未安装 OpenSSH 服务。\n'; exit 1; }
    command -v ss >/dev/null || { printf '缺少 ss 命令，请先安装 iproute2。\n'; exit 1; }
    sshd -t
    listeners=$(ss -H -ltn)
    # 在动态端口范围内选择一个尚未监听的 TCP 端口。
    for ((status = 0; status < 100; status++)); do
        random_port=$((49152 + RANDOM % 16384))
        if ! awk -v port="$random_port" '$4 ~ (":" port "$") {found=1} END {exit !found}' <<< "$listeners"; then
            break
        fi
    done
    (( status < 100 )) || { printf '未找到可用随机端口，请稍后重试。\n'; exit 1; }
    IFS= read -r -u 3 -p "请输入 SSH 端口（1-65535，回车使用随机端口 $random_port）: " port
    port=${port:-$random_port}
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || { printf '端口必须是 1-65535 的整数。\n'; exit 1; }
    port=$((10#$port))
    (( port >= 1 && port <= 65535 )) || { printf '端口必须在 1-65535 范围内。\n'; exit 1; }
    if [[ -n "$(ss -H -ltn "sport = :$port")" ]]; then
        printf '端口 %s 已被监听，请选择其他端口。\n' "$port" >&2
        exit 1
    fi
    printf '请确保服务器防火墙和云安全组已放行 TCP %s；保留当前连接，另开终端验证。\n' "$port"
    service=$(ssh_service_name)
    for file in ssh.socket sshd.socket; do
        if systemctl is-active --quiet "$file" || systemctl is-enabled --quiet "$file"; then
            socket=$file
            socket_config="/etc/systemd/system/${socket}.d/99-vps-port.conf"
            break
        fi
    done
    for file in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$file" ]] && configs+=("$file")
    done
    backup=$(mktemp -d "/etc/ssh/vps-port-backup.XXXXXX")
    for file in "${configs[@]}"; do
        cp -p --parents "$file" "$backup"
    done
    if [[ -n "$socket_config" && -f "$socket_config" ]]; then
        cp -p --parents "$socket_config" "$backup"
        socket_existed=yes
    fi

    restart_ssh_port() {
        if [[ -n "$socket" ]]; then
            systemctl daemon-reload && systemctl restart "$socket" "$service"
        else
            systemctl restart "$service"
        fi
    }
    # 验证或重启失败时恢复本次修改，备份保留供手动恢复。
    trap '
        status=$?
        if (( status != 0 )) && [[ "$changed" == yes ]]; then
            for file in "${configs[@]}"; do
                cp -p "$backup$file" "$file" || true
            done
            if [[ -n "$socket_config" ]]; then
                if [[ "$socket_existed" == yes ]]; then
                    cp -p "$backup$socket_config" "$socket_config" || true
                else
                    rm -f "$socket_config" || true
                fi
            fi
            restart_ssh_port || true
            if [[ "$firewall_changed" == yes ]]; then
                apply_firewall_rules "$backup/firewall"
            fi
            printf "修改失败，已尝试恢复原配置。请检查 SSH 服务；备份：%s\n" "$backup" >&2
        fi
    ' EXIT
    changed=yes
    # Port 可以重复累加，需同时处理主配置和常见的 Include 配置。
    sed -i -E '/^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]/d' "${configs[@]}"
    if [[ -s /etc/ssh/sshd_config ]]; then
        sed -i "1i Port $port" "/etc/ssh/sshd_config"
    else
        printf 'Port %s\n' "$port" > "/etc/ssh/sshd_config"
    fi
    sshd -t
    if [[ "$(sshd -T | awk '$1 == "port" {print $2}')" != "$port" ]]; then
        printf '其他 Include 文件仍定义了端口，请先检查 SSH 配置。\n' >&2
        exit 1
    fi
    if sshd -T | awk -v port="$port" '$1 == "listenaddress" && $2 !~ (":" port "$") {bad=1} END {exit !bad}'; then
        printf 'ListenAddress 指定了其他端口，请先检查 SSH 配置。\n' >&2
        exit 1
    fi
    if [[ -n "$socket" ]]; then
        mkdir -p "${socket_config%/*}"
        printf '[Socket]\nListenStream=\nListenStream=%s\n' "$port" > "$socket_config"
    fi
    # 启用本脚本防火墙后，先放行并持久化新 SSH 端口再重启服务。
    if [[ -f /etc/vps-firewall/rules.v4 || -f /etc/vps-firewall/rules.v6 ]]; then
        mkdir -p "$backup/firewall"
        cp -p "/etc/vps-firewall/rules.v4" "/etc/vps-firewall/rules.v6" "$backup/firewall/"
        update_firewall_port "$port" ACCEPT
        firewall_changed=yes
    fi
    restart_ssh_port
    [[ -n "$(ss -H -ltn "sport = :$port")" ]] || { printf '新端口未监听。\n' >&2; exit 1; }
    printf 'SSH 端口已改为 %s。连接命令：ssh -p %s root@服务器IP\n备份：%s\n' "$port" "$port" "$backup"
)

setup_swap() (
    set -e
    local size
    IFS= read -r -u 3 -p '请输入 Swap 大小（1-9999 GB，默认 2）: ' size
    size=${size:-2}
    [[ "$size" =~ ^[1-9][0-9]{0,3}$ ]] || { printf '请输入 1-9999 的整数。\n'; exit 1; }
    if [[ -L /swapfile || ( -e /swapfile && ! -f /swapfile ) ]]; then
        printf '/swapfile 不是普通文件，停止操作。\n' >&2
        exit 1
    fi

    # 仅调整本脚本的 Swap 文件，保留其他交换分区。
    if awk '$1 == "/swapfile" {found=1} END {exit !found}' /proc/swaps; then
        swapoff "/swapfile"
    fi
    umask 077
    # dd 避免某些文件系统上 fallocate 预分配文件无法用作 Swap。
    dd if=/dev/zero of=/swapfile bs=1M count="$((size * 1024))" status=progress
    chmod 600 "/swapfile"
    mkswap "/swapfile"
    swapon "/swapfile"
    cp -p "/etc/fstab" "/etc/fstab.bak"
    sed -i '\|^[[:space:]]*/swapfile[[:space:]]|d' "/etc/fstab"
    printf '/swapfile none swap sw 0 0\n' >> "/etc/fstab"
    printf 'vm.swappiness=10\n' > "/etc/sysctl.d/99-swap.conf"
    sysctl -p "/etc/sysctl.d/99-swap.conf"
    printf 'Swap %s GB 配置完成。\n' "$size"
)

enable_bbr() (
    set -e
    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        printf '当前内核不支持 BBR。\n' >&2
        exit 1
    fi
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > "/etc/sysctl.d/99-bbr.conf"
    # sysctl.conf 通常最后加载，移除其中重复的旧设置。
    if [[ -f /etc/sysctl.conf ]]; then
        cp -p "/etc/sysctl.conf" "/etc/sysctl.conf.bak"
        sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d; /^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' "/etc/sysctl.conf"
    fi
    sysctl -p "/etc/sysctl.d/99-bbr.conf"
    printf '标准 BBR 已开启。\n'
)

check_site() {
    local code
    code=$(curl -sSL --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_code}' "$1") || {
        printf '%s: 连接失败\n' "$2"
        return
    }
    printf '%s: HTTP %s\n' "$2" "$code"
}

run_probe() {
    printf '\n[系统状态]\n'
    printf '内核：%s | CPU：%s 核\n' "$(uname -r)" "$(getconf _NPROCESSORS_ONLN)"
    free -h
    df -h /
    printf '拥塞控制：%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control)"
    printf '默认队列：%s\n' "$(sysctl -n net.core.default_qdisc)"
    if ! command -v curl >/dev/null; then
        printf '未安装 curl，跳过网站检测。\n'
        return
    fi
    printf '\n[网站连通性：HTTP 状态不代表服务已解锁]\n'
    check_site 'https://gemini.google.com/app' 'Gemini' &
    check_site 'https://www.youtube.com/' 'YouTube' &
    check_site 'https://www.netflix.com/title/80018499' 'Netflix' &
    wait
}

while true; do
    printf '\nVPS 工具\n1) 开启 Root SSH 密码登录\n2) 配置 Swap\n3) 开启标准 BBR\n4) 一键启用 iptables 防火墙（放行 443 / SSH）\n5) 关闭指定端口（TCP / UDP）\n7) 系统与网站探针\n8) 修改 SSH 端口（随机 / 自定义）\n0) 退出\n'
    IFS= read -r -u 3 -p '请选择 [1/2/3/4/5/7/8/0]: ' choice || break
    case "$choice" in
        1) setup_ssh ;;
        2) setup_swap ;;
        3) enable_bbr ;;
        4) enable_firewall ;;
        5) close_firewall_port ;;
        7) run_probe ;;
        8) setup_ssh_port ;;
        0) break ;;
        *) printf '无效选项。\n' ;;
    esac
done
