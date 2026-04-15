#!/bin/bash

set -euo pipefail

DOCKER_CE_MIRROR_BASE="https://mirrors.tuna.tsinghua.edu.cn/docker-ce"
REGISTRY_MIRROR_URL="https://docker.1ms.run"
CONFIG_FILE="/etc/docker/daemon.json"
ONEPANEL_INSTALL_SCRIPT_URL="https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh"

OS_ID=""
OS_LIKE=""
OS_NAME=""
PACKAGE_FAMILY=""
APT_REPO_DIST=""
RPM_REPO_DIST=""
RPM_PACKAGE_MANAGER=""
INSTALLED_DOCKER_PACKAGES=()

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

detect_rpm_package_manager() {
    if command -v dnf >/dev/null 2>&1; then
        RPM_PACKAGE_MANAGER="dnf"
        return 0
    fi

    if command -v yum >/dev/null 2>&1; then
        RPM_PACKAGE_MANAGER="yum"
        return 0
    fi

    echo "错误：当前系统属于 RPM 系，但未检测到 dnf 或 yum。"
    exit 1
}

get_json_python() {
    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
        return 0
    fi

    if command -v python >/dev/null 2>&1; then
        echo "python"
        return 0
    fi

    return 1
}

prompt_unknown_os_choice() {
    local default_choice=""
    local prompt_suffix=""
    local choice=""

    case "$OS_LIKE" in
        *debian*|*ubuntu*)
            default_choice="1"
            prompt_suffix=" [默认 1]"
            ;;
        *rhel*|*centos*|*fedora*)
            default_choice="2"
            prompt_suffix=" [默认 2]"
            ;;
    esac

    echo ">>> 未识别的操作系统: ${OS_NAME:-$OS_ID}"
    echo ">>> 请选择按哪一类系统安装 Docker："
    echo "1) Ubuntu 系"
    echo "2) CentOS 系"

    while true; do
        read -r -p "请输入选项 1 或 2${prompt_suffix}: " choice

        if [ -z "$choice" ] && [ -n "$default_choice" ]; then
            choice="$default_choice"
        fi

        case "$choice" in
            1)
                PACKAGE_FAMILY="apt"
                APT_REPO_DIST="ubuntu"
                return 0
                ;;
            2)
                PACKAGE_FAMILY="rpm"
                RPM_REPO_DIST="centos"
                return 0
                ;;
        esac

        echo "输入无效，请重新输入。"
    done
}

detect_os() {
    echo ">>> 正在检测操作系统类型..."

    if [ ! -f /etc/os-release ]; then
        echo "错误：无法识别操作系统版本"
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"

    case "$OS_ID" in
        ubuntu)
            PACKAGE_FAMILY="apt"
            APT_REPO_DIST="ubuntu"
            ;;
        debian|raspbian)
            PACKAGE_FAMILY="apt"
            APT_REPO_DIST="debian"
            ;;
        linuxmint|elementary|neon|pop|zorin)
            PACKAGE_FAMILY="apt"
            APT_REPO_DIST="ubuntu"
            ;;
        deepin|uos)
            PACKAGE_FAMILY="apt"
            APT_REPO_DIST="debian"
            ;;
        fedora)
            PACKAGE_FAMILY="rpm"
            RPM_REPO_DIST="fedora"
            ;;
        centos|rocky|almalinux|anolis|openanolis|opencloudos|alinux|alinux3|aliyun|tlinux|tencentos)
            PACKAGE_FAMILY="rpm"
            RPM_REPO_DIST="centos"
            ;;
        rhel|ol)
            PACKAGE_FAMILY="rpm"
            RPM_REPO_DIST="rhel"
            ;;
        *)
            prompt_unknown_os_choice
            ;;
    esac

    echo ">>> 当前系统: $OS_NAME"
    if [ "$PACKAGE_FAMILY" = "apt" ]; then
        echo ">>> 安装策略: Ubuntu/Debian 系，Docker CE 仓库类型: $APT_REPO_DIST"
    else
        detect_rpm_package_manager
        echo ">>> 安装策略: CentOS/RHEL 系，Docker CE 仓库类型: $RPM_REPO_DIST"
        echo ">>> 检测到 RPM 包管理器: $RPM_PACKAGE_MANAGER"
    fi
}

get_apt_codename() {
    if [ "$APT_REPO_DIST" = "ubuntu" ] && [ -n "${UBUNTU_CODENAME:-}" ]; then
        echo "$UBUNTU_CODENAME"
        return 0
    fi

    if [ -n "${VERSION_CODENAME:-}" ]; then
        echo "$VERSION_CODENAME"
        return 0
    fi

    if command -v lsb_release >/dev/null 2>&1; then
        lsb_release -cs
        return 0
    fi

    echo "错误：无法确定当前系统的发行版代号，无法配置 Docker 仓库。"
    exit 1
}

install_docker_apt() {
    local codename=""

    require_command apt-get
    require_command curl

    codename="$(get_apt_codename)"

    echo ">>> 开始配置 APT 仓库并安装 Docker..."

    apt-get update
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${APT_REPO_DIST}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: ${DOCKER_CE_MIRROR_BASE}/linux/${APT_REPO_DIST}
Suites: ${codename}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

configure_rpm_repo_file() {
    local repo_path="$1"

    if [ ! -f "$repo_path" ]; then
        echo "错误：未找到 Docker 仓库文件: $repo_path"
        exit 1
    fi

    sed -i "s|https://download.docker.com|${DOCKER_CE_MIRROR_BASE}|g" "$repo_path"
}

install_docker_rpm() {
    local repo_url="https://download.docker.com/linux/${RPM_REPO_DIST}/docker-ce.repo"

    echo ">>> 开始配置 RPM 仓库并安装 Docker..."

    if [ "$RPM_PACKAGE_MANAGER" = "dnf" ]; then
        if ! dnf config-manager --help >/dev/null 2>&1; then
            dnf install -y dnf-plugins-core
        fi

        if [ "$RPM_REPO_DIST" = "fedora" ]; then
            dnf config-manager addrepo --from-repofile "$repo_url"
        else
            dnf config-manager --add-repo "$repo_url"
        fi
        configure_rpm_repo_file /etc/yum.repos.d/docker-ce.repo
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        return 0
    fi

    yum install -y yum-utils
    require_command yum-config-manager
    yum-config-manager --add-repo "$repo_url"
    configure_rpm_repo_file /etc/yum.repos.d/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

collect_installed_apt_docker_packages() {
    local package=""
    local installed_packages=()
    local docker_packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
        docker-ce-rootless-extras
    )

    for package in "${docker_packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
            installed_packages+=("$package")
        fi
    done

    printf '%s\n' "${installed_packages[@]}"
}

collect_installed_rpm_docker_packages() {
    local package=""
    local installed_packages=()
    local docker_packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
        docker-ce-rootless-extras
    )

    for package in "${docker_packages[@]}"; do
        if rpm -q "$package" >/dev/null 2>&1; then
            installed_packages+=("$package")
        fi
    done

    printf '%s\n' "${installed_packages[@]}"
}

uninstall_docker() {
    local installed_packages=("$@")

    echo ">>> 正在卸载当前 Docker 软件包..."

    if [ "$PACKAGE_FAMILY" = "apt" ]; then
        if [ "${#installed_packages[@]}" -gt 0 ]; then
            apt-get purge -y "${installed_packages[@]}"
            apt-get autoremove -y
        else
            echo ">>> 未检测到通过 APT 安装的 Docker 相关软件包，跳过卸载包步骤。"
        fi

        return 0
    fi

    if [ "${#installed_packages[@]}" -gt 0 ]; then
        if [ "$RPM_PACKAGE_MANAGER" = "dnf" ]; then
            dnf remove -y "${installed_packages[@]}"
        else
            yum remove -y "${installed_packages[@]}"
        fi
    else
        echo ">>> 未检测到通过 ${RPM_PACKAGE_MANAGER} 安装的 Docker 相关软件包，跳过卸载包步骤。"
    fi
}

load_installed_docker_packages() {
    local installed_output=""
    local package=""

    INSTALLED_DOCKER_PACKAGES=()

    if [ "$PACKAGE_FAMILY" = "apt" ]; then
        installed_output="$(collect_installed_apt_docker_packages)"
    else
        installed_output="$(collect_installed_rpm_docker_packages)"
    fi

    if [ -z "$installed_output" ]; then
        return 0
    fi

    while IFS= read -r package; do
        [ -n "$package" ] && INSTALLED_DOCKER_PACKAGES+=("$package")
    done <<< "$installed_output"
}

stop_docker_service() {
    echo ">>> 正在停止 Docker 服务..."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop docker >/dev/null 2>&1 || true
        return 0
    fi

    if command -v service >/dev/null 2>&1; then
        service docker stop >/dev/null 2>&1 || true
    fi
}

handle_existing_docker() {
    local reinstall_reply=""
    local confirm_reply=""
    local continue_reply=""
    local package=""

    echo ">>> Docker 已安装，版本信息如下："
    docker --version

    read -r -p "是否需要卸载并重新安装 Docker ? (y/n): " reinstall_reply
    if [[ ! "$reinstall_reply" =~ ^[Yy]$ ]]; then
        echo ">>> 保留当前 Docker 安装，跳过重装。"
        return 1
    fi

    echo ">>> 即将卸载当前 Docker 软件包并重新安装。"
    echo ">>> 注意：此操作不会主动删除 /var/lib/docker，但会中断当前 Docker 服务。"
    load_installed_docker_packages

    if [ "${#INSTALLED_DOCKER_PACKAGES[@]}" -gt 0 ]; then
        echo ">>> 即将卸载以下 Docker 软件包："
        for package in "${INSTALLED_DOCKER_PACKAGES[@]}"; do
            echo " - $package"
        done

        read -r -p "请输入 YES 进行二次确认并开始卸载: " confirm_reply
        if [ "$confirm_reply" != "YES" ]; then
            echo ">>> 未通过二次确认，取消重装，保留当前 Docker 安装。"
            return 1
        fi

        stop_docker_service
        uninstall_docker "${INSTALLED_DOCKER_PACKAGES[@]}"
        return 0
    fi

    echo ">>> 未识别到可卸载的 Docker 软件包。当前 Docker 可能不是通过系统包管理器安装的。"
    echo ">>> 如果继续，后续将直接安装仓库中的 Docker 软件包，这更接近覆盖安装。"
    read -r -p "是否仍然继续安装 ? (y/n): " continue_reply
    if [[ ! "$continue_reply" =~ ^[Yy]$ ]]; then
        echo ">>> 已取消重装，保留当前 Docker 安装。"
        return 1
    fi

    return 0
}

ensure_docker_service() {
    echo ">>> 正在启动并设置 Docker 服务开机自启..."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    elif command -v service >/dev/null 2>&1; then
        service docker start
    else
        echo "错误：未找到 systemctl 或 service，无法启动 Docker 服务。"
        exit 1
    fi
}

docker_is_healthy() {
    docker info >/dev/null 2>&1
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

read_current_registry_mirrors() {
    local json_python="$1"
    local file_path="$2"

    "$json_python" - "$file_path" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if not isinstance(data, dict):
    raise SystemExit("daemon.json 顶层必须是 JSON 对象")

mirrors = data.get("registry-mirrors", [])
if not isinstance(mirrors, list):
    raise SystemExit("registry-mirrors 必须是数组")

print(json.dumps(mirrors, ensure_ascii=False))
PY
}

write_registry_mirrors() {
    local json_python="$1"
    local file_path="$2"
    local mirror_url="$3"

    "$json_python" - "$file_path" "$mirror_url" <<'PY'
import json
import sys

path, mirror = sys.argv[1], sys.argv[2]

with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if not isinstance(data, dict):
    raise SystemExit("daemon.json 顶层必须是 JSON 对象")

data["registry-mirrors"] = [mirror]

with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
}

configure_registry_mirror() {
    local json_python=""
    local current_mirrors="[]"
    local target_mirrors=""
    local temp_file=""
    local reply=""

    echo ">>> 正在检查 Docker registry-mirrors 配置..."

    target_mirrors="[\"${REGISTRY_MIRROR_URL}\"]"
    mkdir -p /etc/docker

    if ! json_python="$(get_json_python)"; then
        if [ ! -f "$CONFIG_FILE" ]; then
            cat > "$CONFIG_FILE" <<EOF
{
  "registry-mirrors": [
    "${REGISTRY_MIRROR_URL}"
  ]
}
EOF

            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart docker
            elif command -v service >/dev/null 2>&1; then
                service docker restart
            fi

            echo ">>> 已创建新的 daemon.json 并写入 registry-mirrors。"
            return 0
        fi

        echo "错误：未找到 python3/python，无法在保留现有 daemon.json 配置的前提下只修改 registry-mirrors。"
        exit 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        printf '{}\n' > "$CONFIG_FILE"
    fi

    if ! current_mirrors="$(read_current_registry_mirrors "$json_python" "$CONFIG_FILE" 2>/dev/null)"; then
        echo "错误：$CONFIG_FILE 不是有效的 JSON，无法安全地只修改 registry-mirrors。"
        exit 1
    fi

    echo ">>> 当前 registry-mirrors: $current_mirrors"

    if [ "$current_mirrors" = "$target_mirrors" ]; then
        echo ">>> registry-mirrors 已是目标值，无需修改。"
        return 0
    fi

    if [ "$current_mirrors" != "[]" ]; then
        read -r -p "是否仅将 registry-mirrors 更新为 ${target_mirrors} ? (y/n): " reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            echo ">>> 跳过 registry-mirrors 修改，保留原有配置。"
            return 0
        fi
    fi

    temp_file="$(mktemp)"
    cp "$CONFIG_FILE" "$temp_file"
    write_registry_mirrors "$json_python" "$temp_file" "$REGISTRY_MIRROR_URL"
    install -m 0644 "$temp_file" "$CONFIG_FILE"
    rm -f "$temp_file"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart docker
    elif command -v service >/dev/null 2>&1; then
        service docker restart
    fi

    echo ">>> registry-mirrors 已更新，其它 daemon.json 配置保持不变。"
}

main() {
    require_root
    detect_os

    if command -v docker >/dev/null 2>&1; then
        if handle_existing_docker; then
            echo ">>> 开始重新安装 Docker..."
            if [ "$PACKAGE_FAMILY" = "apt" ]; then
                install_docker_apt
            else
                install_docker_rpm
            fi
        fi
    else
        echo ">>> Docker 未安装，开始执行安装流程..."
        if [ "$PACKAGE_FAMILY" = "apt" ]; then
            install_docker_apt
        else
            install_docker_rpm
        fi
    fi

    ensure_docker_service
    configure_registry_mirror

    if ! docker_is_healthy; then
        echo "错误：Docker 命令存在，但 Docker daemon 当前不可用，请检查服务状态。"
        exit 1
    fi

    maybe_install_1panel

    echo "----------------------------------------"
    echo "初始化脚本执行完毕！"
    docker --version
    echo "----------------------------------------"
}

main "$@"
