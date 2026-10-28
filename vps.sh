#!/usr/bin/env bash
# VPS 工具：APT 国内镜像、Root SSH 登录、SSH 端口、nftables 防火墙、Swap、标准 BBR、状态探针。
# 适用于使用 systemd 且内核带 nft 的 Debian 11+ / Ubuntu 20.04+；支持 curl -fsSL URL | sudo bash。

if (( EUID != 0 )); then
    printf '请使用 root 权限运行。\n' >&2
    exit 1
fi

# 独立读取终端，避免管道运行时将脚本内容当成菜单或密码。
if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '需要交互终端，请通过 SSH 登录后运行。\n' >&2
    exit 1
fi

# 防火墙状态目录：ports.list 是唯一数据源，rules.nft 由它生成。
rules_dir=/etc/vps-firewall
ports_file=$rules_dir/ports.list
rules_file=$rules_dir/rules.nft
unit_file=/etc/systemd/system/vps-firewall.service

ssh_service_name() {
    if systemctl list-unit-files sshd.service --no-legend | grep -q '^sshd.service'; then
        printf 'sshd\n'
    else
        printf 'ssh\n'
    fi
}

confirm_firewall_change() {
    local answer
    printf '\n⚠️ 危险操作检测！\n操作类型：%s\n影响范围：本机 nftables 「inet vps」 规则表（IPv4 / IPv6）及开机恢复服务。\n风险评估：%s\n' "$1" "$2"
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

# 只声明自己的 table，其他工具（Docker、面板）的 table 不受影响。
render_firewall_rules() {
    cat <<'NFT'
# 由 vps.sh 生成，请勿手工修改。
table inet vps {
    chain input {
        type filter hook input priority -10; policy drop;
        iif lo accept
        ct state established,related accept
        ct state invalid drop
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept
        udp sport 67 udp dport 68 accept
        ip6 saddr fe80::/10 udp sport 547 udp dport 546 accept
NFT
    if [[ -n "$1" ]]; then
        printf '        tcp dport { %s } accept\n' "$(printf '%s\n' "$1" | paste -sd,)"
    fi
    printf '    }\n}\n'
}

read_allowed_ports() {
    [[ -f "$ports_file" ]] || return 0
    awk '$1 ~ /^[0-9]+$/ && $1 + 0 >= 1 && $1 + 0 <= 65535 {print $1 + 0}' "$ports_file" | sort -n -u
}

write_firewall_unit() {
    cat > "$unit_file" <<UNIT
[Unit]
Description=VPS nftables firewall
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table inet vps
ExecStart=/usr/sbin/nft -f $rules_file

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$unit_file"
}

# 先校验再原子替换：失败时 live 规则和落盘文件都保持原样，无需回滚逻辑。
apply_firewall_rules() (
    set -e -o pipefail
    ports=$(printf '%s\n' "$1" | awk '$1 ~ /^[0-9]+$/ && $1 + 0 >= 1 && $1 + 0 <= 65535 {print $1 + 0}' | sort -n -u)
    [[ -n "$ports" ]] || { printf '端口列表为空，停止操作以免全部入站被丢弃。\n' >&2; exit 1; }
    umask 077
    mkdir -p "$rules_dir"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    render_firewall_rules "$ports" > "$work/rules.nft"
    # 删除旧 table 与加载新 table 在同一次提交内完成，中间不存在空窗。
    if nft list table inet vps >/dev/null 2>&1; then
        { printf 'delete table inet vps\n'; cat "$work/rules.nft"; } > "$work/apply.nft"
    else
        cp "$work/rules.nft" "$work/apply.nft"
    fi
    nft -c -f "$work/apply.nft"
    nft -f "$work/apply.nft"
    printf '%s\n' "$ports" > "$work/ports.list"
    install -m 600 "$work/ports.list" "$ports_file"
    install -m 600 "$work/rules.nft" "$rules_file"
    write_firewall_unit
    systemctl daemon-reload
    systemctl enable vps-firewall.service
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
    printf '将放行 TCP 443 和以下 SSH TCP 端口：\n%s\n' "$ssh_ports"
    printf '其他本机新入站端口（包括 80）将被关闭；保留回环、已有连接、ICMP 和 DHCP。\n'
    printf '本脚本只写自己的 table，出站、转发、Docker 映射端口及云安全组需另行管理。\n'
    confirm_firewall_change '启用 nftables 防火墙（缺少 nft 时安装 nftables）' \
        '规则表为默认丢弃，其他入站服务将无法新建连接；重复启用不会累积规则。' || exit 0
    if ! command -v nft >/dev/null; then
        apt-get update
        apt-get install -y nftables
    fi
    apply_firewall_rules "$(printf '443\n%s\n' "$ssh_ports")"
    printf '规则已写入 %s 并设置开机恢复。\n' "$rules_file"
    printf '请保留当前 SSH 会话并另开连接验证。\n'
)

# 新系统常常没有 ca-certificates，https 源会直接卡在证书校验；用现有源先补上。
ensure_ca_certificates() (
    set -e -o pipefail
    if dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'install ok installed'; then
        return 0
    fi
    printf '检测到缺少 ca-certificates，先用当前源安装（https 镜像需要 CA 证书）。\n'
    apt-get -o DPkg::Lock::Timeout=120 update
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y ca-certificates
)

# 把 APT 源换成清华镜像；验证失败则整体回退，不留下半成品配置。
setup_apt_mirror() (
    set -e -o pipefail
    keyring=/usr/share/keyrings/debian-archive-keyring.gpg
    legacy=/etc/apt/sources.list
    mirror_file=/etc/apt/sources.list.d/debian.sources
    legacy_changed=no
    failed=no
    log=''
    mirror_scheme=https

    command -v apt-get >/dev/null || { printf '未找到 apt-get，本选项仅支持 Debian。\n' >&2; exit 1; }
    [[ -r /etc/os-release ]] || { printf '无法读取 /etc/os-release。\n' >&2; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == debian ]] || { printf '当前系统 ID=%s，本选项只处理 Debian。\n' "${ID:-未知}" >&2; exit 1; }
    [[ "${VERSION_CODENAME:-}" =~ ^[a-z][a-z0-9-]*$ ]] || {
        printf '无法从 /etc/os-release 取得版本代号，停止操作。\n' >&2
        exit 1
    }
    codename=$VERSION_CODENAME
    [[ -f "$keyring" ]] || { printf '缺少 %s，请先安装 debian-archive-keyring。\n' "$keyring" >&2; exit 1; }

    # 必须在写 https 源之前完成：那时 apt 还能用发行版自带的 http 源。
    if ! ensure_ca_certificates; then
        mirror_scheme=http
        printf '无法安装 ca-certificates，本次使用 http 镜像；apt 仍按签名校验软件包。\n' >&2
        printf '之后装好 ca-certificates 可重跑本选项切回 https。\n' >&2
    fi

    printf '将把 APT 源替换为清华镜像（Debian %s）：\n' "$codename"
    printf '  deb       %s://mirrors.tuna.tsinghua.edu.cn/debian\n' "$mirror_scheme"
    printf '  security  %s://security.debian.org/debian-security\n' "$mirror_scheme"
    printf '原配置备份为 <文件>.vps.bak，仅首次运行保存。\n'

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    umask 077
    cat > "$work/debian.sources" <<SOURCES
Types: deb
URIs: $mirror_scheme://mirrors.tuna.tsinghua.edu.cn/debian
Suites: $codename $codename-updates $codename-backports
Components: main contrib non-free non-free-firmware
Signed-By: $keyring

Types: deb
URIs: $mirror_scheme://security.debian.org/debian-security
Suites: $codename-security
Components: main contrib non-free non-free-firmware
Signed-By: $keyring
SOURCES

    for file in "$legacy" "$mirror_file"; do
        if [[ -f "$file" && ! -e "$file.vps.bak" ]]; then cp -p "$file" "$file.vps.bak"; fi
    done
    mkdir -p "${mirror_file%/*}"
    install -m 644 "$work/debian.sources" "$mirror_file"

    # 经典格式的 sources.list 会和新文件重复，整体停用（已有备份可恢复）。
    if [[ -f "$legacy" ]] && grep -qE '^[[:space:]]*(deb(-src)?[[:space:]]|Types:)' "$legacy"; then
        printf '# 由 vps.sh 停用，原内容见 %s.vps.bak\n' "$legacy" > "$legacy"
        legacy_changed=yes
    fi

    printf '正在验证镜像源...\n'
    if ! log=$(apt-get update 2>&1); then failed=yes; fi
    if grep -qE '^(E:|Err:|W: Failed to fetch)' <<< "$log"; then failed=yes; fi

    if [[ "$failed" == yes ]]; then
        printf '%s\n' "$log" >&2
        if [[ "$legacy_changed" == yes ]]; then
            if [[ -f "$legacy.vps.bak" ]]; then cp -p "$legacy.vps.bak" "$legacy"; else rm -f "$legacy"; fi
        fi
        if [[ -f "$mirror_file.vps.bak" ]]; then
            cp -p "$mirror_file.vps.bak" "$mirror_file"
        else
            rm -f "$mirror_file"
        fi
        apt-get update >/dev/null 2>&1 || printf '恢复后 apt-get update 仍未成功，请检查网络。\n' >&2
        printf '镜像源验证失败，已恢复原配置。\n' >&2
        exit 1
    fi
    printf 'APT 源已切换到清华镜像，软件包列表已更新。\n'
)

# 精简系统补齐常用工具：先更新索引，只安装缺失的包。
install_base_packages() (
    set -e -o pipefail
    packages=(curl wget git sudo ca-certificates unzip zip tar gzip bash-completion openssh-client gnupg)
    missing=()

    command -v apt-get >/dev/null || { printf '未找到 apt-get，本选项仅支持 Debian / Ubuntu。\n' >&2; exit 1; }
    command -v dpkg-query >/dev/null || { printf '未找到 dpkg-query，系统环境异常。\n' >&2; exit 1; }

    for pkg in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '基础包已全部安装，无需操作。\n'
        return 0
    fi
    printf '将更新索引并安装 %d 个缺失的基础包：\n%s\n' "${#missing[@]}" "${missing[*]}"

    # DPkg::Lock::Timeout：新系统首次启动时 apt 可能正被自动更新占用。
    if ! apt-get -o DPkg::Lock::Timeout=120 update; then
        printf 'apt-get update 失败；若是 https 源缺少 CA 证书，请先运行菜单 1。\n' >&2
        exit 1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y "${missing[@]}"
    printf '基础包安装完成：%s\n' "${missing[*]}"
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
    socket='' backup='' socket_config='' socket_existed=no
    changed=no firewall_changed=no firewall_ports_before=''
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
                apply_firewall_rules "$firewall_ports_before" || true
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
    # 启用本脚本防火墙后，先放行新 SSH 端口再重启服务，避免重启后失联。
    if [[ -f "$ports_file" ]] && nft list table inet vps >/dev/null 2>&1; then
        firewall_ports_before=$(read_allowed_ports)
        apply_firewall_rules "$(printf '%s\n%s\n' "$firewall_ports_before" "$port")"
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
    printf '\nVPS 工具\n1) 替换 APT 源为国内镜像（清华）\n2) 一键更新并安装基础包\n3) 开启 Root SSH 密码登录\n4) 配置 Swap\n5) 开启标准 BBR\n6) 一键启用 nftables 防火墙（放行 443 / SSH）\n7) 修改 SSH 端口（随机 / 自定义）\n8) 系统与网站探针\n0) 退出\n'
    IFS= read -r -u 3 -p '请选择 [1/2/3/4/5/6/7/8/0]: ' choice || break
    case "$choice" in
        1) setup_apt_mirror ;;
        2) install_base_packages ;;
        3) setup_ssh ;;
        4) setup_swap ;;
        5) enable_bbr ;;
        6) enable_firewall ;;
        7) setup_ssh_port ;;
        8) run_probe ;;
        0) break ;;
        *) printf '无效选项。\n' ;;
    esac
done
