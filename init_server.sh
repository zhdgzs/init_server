#!/bin/bash

set -euo pipefail

DEFAULT_SWAP_SIZE_GB=4
DEFAULT_SWAP_FILE="/swapfile"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREWALL_DIR="$(cd "${SCRIPT_DIR}/firewall" && pwd)"
UBUNTU_FIREWALL_SCRIPT="${FIREWALL_DIR}/ubuntu_setup_firewall.sh"
CENTOS_FIREWALL_SCRIPT="${FIREWALL_DIR}/centos_setup_firewall.sh"
DOCKER_INSTALL_SCRIPT_URL="https://linuxmirrors.cn/docker.sh"
ONEPANEL_INSTALL_SCRIPT_URL="https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：请使用 root 用户运行此脚本 (sudo -i)"
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

resolve_firewall_script() {
    local os_id=""
    local os_like=""
    local choice=""

    if [ ! -f /etc/os-release ]; then
        echo "错误：无法识别当前系统，未找到 /etc/os-release"
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    os_id="${ID:-unknown}"
    os_like="${ID_LIKE:-}"

    case "$os_id" in
        ubuntu|debian|raspbian|linuxmint|elementary|neon|pop|zorin|deepin|uos)
            echo "$UBUNTU_FIREWALL_SCRIPT"
            return 0
            ;;
        centos|rocky|almalinux|anolis|openanolis|opencloudos|alinux|alinux3|aliyun|tlinux|tencentos|rhel|ol|fedora)
            echo "$CENTOS_FIREWALL_SCRIPT"
            return 0
            ;;
    esac

    case "$os_like" in
        *debian*|*ubuntu*)
            echo "$UBUNTU_FIREWALL_SCRIPT"
            return 0
            ;;
        *rhel*|*centos*|*fedora*)
            echo "$CENTOS_FIREWALL_SCRIPT"
            return 0
            ;;
    esac

    echo ">>> 未能自动判断应使用哪个防火墙脚本。"
    echo "1) Ubuntu/Debian 防火墙脚本"
    echo "2) CentOS/RHEL 防火墙脚本"

    while true; do
        read -r -p "请输入选项 1 或 2: " choice
        case "$choice" in
            1)
                echo "$UBUNTU_FIREWALL_SCRIPT"
                return 0
                ;;
            2)
                echo "$CENTOS_FIREWALL_SCRIPT"
                return 0
                ;;
        esac
        echo "输入无效，请重新输入。"
    done
}

swap_is_enabled() {
    swapon --noheadings --show=NAME >/dev/null 2>&1
    [ -n "$(swapon --noheadings --show=NAME 2>/dev/null)" ]
}

ensure_swap_prerequisites() {
    require_command swapon
    require_command mkswap
    require_command grep
    require_command chmod
}

prompt_swap_size_gb() {
    local input=""

    while true; do
        read -r -p "请输入需要创建的虚拟内存大小，单位 G [默认 ${DEFAULT_SWAP_SIZE_GB}]: " input

        if [ -z "$input" ]; then
            echo "$DEFAULT_SWAP_SIZE_GB"
            return 0
        fi

        input="${input%[Gg]}"
        if [[ "$input" =~ ^[1-9][0-9]*$ ]]; then
            echo "$input"
            return 0
        fi

        echo "输入无效，请输入正整数，例如 4 或 8。"
    done
}

allocate_swap_file() {
    local size_gb="$1"

    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${size_gb}G" "$DEFAULT_SWAP_FILE"
        return 0
    fi

    require_command dd
    dd if=/dev/zero of="$DEFAULT_SWAP_FILE" bs=1G count="$size_gb" status=progress
}

ensure_swap_in_fstab() {
    if grep -Eq "^${DEFAULT_SWAP_FILE}[[:space:]]" /etc/fstab; then
        return 0
    fi

    echo "${DEFAULT_SWAP_FILE} none swap sw 0 0" >> /etc/fstab
}

enable_swap_if_needed() {
    local swap_size_gb=""

    ensure_swap_prerequisites

    if swap_is_enabled; then
        echo ">>> 检测到系统已开启虚拟内存："
        swapon --show
        return 0
    fi

    echo ">>> 当前系统未开启虚拟内存。"
    swap_size_gb="$(prompt_swap_size_gb)"

    if [ -f "$DEFAULT_SWAP_FILE" ]; then
        echo ">>> 检测到已存在 ${DEFAULT_SWAP_FILE}，将复用该文件重新启用 swap。"
    else
        echo ">>> 正在创建 ${swap_size_gb}G 虚拟内存文件: ${DEFAULT_SWAP_FILE}"
        allocate_swap_file "$swap_size_gb"
    fi

    chmod 600 "$DEFAULT_SWAP_FILE"
    mkswap "$DEFAULT_SWAP_FILE"
    swapon "$DEFAULT_SWAP_FILE"
    ensure_swap_in_fstab

    echo ">>> 虚拟内存已启用："
    swapon --show
}

maybe_init_docker() {
    local reply=""

    read -r -p "是否需要初始化 Docker ? (y/n): " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo ">>> 跳过 Docker 初始化。"
        return 0
    fi

    require_command curl
    require_command bash

    if command -v docker >/dev/null 2>&1; then
        echo ">>> 检测到当前系统已安装 Docker，版本信息如下："
        docker --version || true
    else
        echo ">>> 检测到当前系统未安装 Docker。"
    fi

    echo ">>> 开始执行 Docker 在线安装脚本..."
    if ! bash <(curl -sSL "$DOCKER_INSTALL_SCRIPT_URL"); then
        echo "错误：Docker 在线安装脚本执行失败。"
        exit 1
    fi

    if command -v docker >/dev/null 2>&1; then
        echo ">>> Docker 安装流程执行完成，当前版本："
        docker --version || true
    fi
}

is_1panel_installed() {
    if command -v 1pctl >/dev/null 2>&1; then
        return 0
    fi

    if [ -x /usr/local/bin/1pctl ] || [ -x /usr/bin/1pctl ]; then
        return 0
    fi

    if [ -d /opt/1panel ]; then
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files 2>/dev/null | grep -q '^1panel\.service'; then
            return 0
        fi
    fi

    return 1
}

maybe_install_1panel() {
    local install_reply=""

    if is_1panel_installed; then
        echo ">>> 检测到 1Panel 已安装，跳过安装步骤。"
        return 0
    fi

    echo ">>> 检测到当前系统未安装 1Panel。"

    read -r -p "是否需要安装 1Panel ? (y/n): " install_reply
    if [[ ! "$install_reply" =~ ^[Yy]$ ]]; then
        echo ">>> 跳过 1Panel 安装。"
        return 0
    fi

    require_command curl
    require_command bash

    echo ">>> 正在按 1Panel V2 官方文档执行在线安装脚本..."
    if ! bash -c "$(curl -sSL "$ONEPANEL_INSTALL_SCRIPT_URL")"; then
        echo "错误：1Panel V2 官方安装脚本执行失败。"
        exit 1
    fi

    echo ">>> 1Panel 安装脚本已执行完成。"
}

maybe_setup_firewall() {
    local reply=""
    local firewall_script=""

    read -r -p "是否需要设置防火墙 ? (y/n): " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo ">>> 跳过防火墙初始化。"
        return 0
    fi

    firewall_script="$(resolve_firewall_script)"
    if [ ! -f "$firewall_script" ]; then
        echo "错误：未找到防火墙脚本: $firewall_script"
        exit 1
    fi

    echo ">>> 开始执行防火墙初始化脚本: $firewall_script"
    bash "$firewall_script"
}

main() {
    require_root
    enable_swap_if_needed

    # 预留后续更多基础配置入口。
    maybe_init_docker
    maybe_install_1panel
    maybe_setup_firewall

    echo "----------------------------------------"
    echo "服务器基础初始化脚本执行完毕！"
    echo "----------------------------------------"
}

main "$@"
