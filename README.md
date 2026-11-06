# Linux 服务器初始化脚本

用于 Linux 服务器的交互式基础初始化，仓库按场景分成三个入口：

- **[vps.sh](vps.sh)**：dd / 重装系统后的单文件工具，处理 APT 换源、基础包、SSH 登录方式、nftables 防火墙、Swap、BBR、时区校时和状态探针。无需克隆仓库，一条命令即可运行。
- **[init_server.sh](init_server.sh)**：完整初始化，依次处理 Swap、Docker、1Panel 和防火墙。防火墙支持可选的中国 IP 访问限制、腾讯云 EdgeOne 回源例外，以及 IP 集自动更新和重启恢复。
- **[install_cpa.sh](install_cpa.sh)**：交互式生成 CPA (CLI Proxy API) + CPA Manager Plus 的 `docker-compose.yaml`、配置、挂载目录和可选 nginx 反代配置，只写文件不启动容器。

## 脚本职责

| 文件 | 用途 |
| --- | --- |
| [vps.sh](vps.sh) | dd 后精简系统的单文件工具：APT 国内镜像、基础包、账号密码 / 公钥 / 密码登录开关、Swap、BBR、nftables 防火墙、SSH 端口、时区校时、状态探针。 |
| [init_server.sh](init_server.sh) | 总入口，检查并配置 Swap，按需安装 Docker、1Panel，再按发行版调用防火墙脚本。 |
| [install_cpa.sh](install_cpa.sh) | 生成 CPA 与 CPA Manager Plus 的 compose 文件、`cpa-data/config.yaml`、挂载目录和可选 nginx 反代配置；只写文件，不启动容器。 |
| [firewall/ubuntu_setup_firewall.sh](firewall/ubuntu_setup_firewall.sh) | Ubuntu / Debian 系列的 UFW 配置，管理 IPv4 / IPv6 入站规则、SSH 放行和禁止 Ping。 |
| [firewall/centos_setup_firewall.sh](firewall/centos_setup_firewall.sh) | CentOS / RHEL / Rocky / Alibaba Cloud Linux 等系统的 firewalld 配置。 |
| [firewall/firewall_common.sh](firewall/firewall_common.sh) | 防火墙共用逻辑：检查已有策略、独立询问跳过或覆盖、检测 SSH 端口、安装更新器、配置定时任务和启动恢复服务。 |
| [firewall/ipset_manager.py](firewall/ipset_manager.py) | 使用 Python 3 标准库获取并校验网段，签名调用 EdgeOne API，更新及保存 IP 集，启动时恢复已启用集合。 |
| [edgeone.example.json](edgeone.example.json) | EdgeOne 凭据格式示例，仅包含空字段；真实凭据填写到被 Git 忽略的 `edgeone.json`。 |

`firewall_common.sh` 是供两个防火墙入口加载的函数库；`ipset_manager.py` 是配套更新器，通常由初始化脚本、定时任务或 systemd 调用。

## 使用方式

### vps.sh：dd 后的精简系统

单文件、无外部依赖，直接管道执行：

```bash
curl -fsSL https://raw.githubusercontent.com/zhdgzs/init_server/main/vps.sh | sudo bash
# 国内访问 raw 较慢时改用 jsDelivr
curl -fsSL https://cdn.jsdelivr.net/gh/zhdgzs/init_server@main/vps.sh | sudo bash
```

脚本开头会 `exec 3<>/dev/tty`，菜单和密码都从终端 fd 3 读取，所以管道执行不会把脚本正文当成输入。
需要 root 和真实终端（SSH 登录后运行）；在 cron、CI 等非交互环境会提示“需要交互终端”后退出。

想先审阅再执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/zhdgzs/init_server/main/vps.sh
less vps.sh && sudo bash vps.sh
```

### init_server.sh：完整初始化（含防火墙策略）

需完整保留仓库目录结构，在仓库根目录运行：

```bash
sudo bash "init_server.sh"
```

只需配置防火墙时，可直接按系统选择：

```bash
sudo bash "firewall/ubuntu_setup_firewall.sh"
# CentOS / RHEL / Rocky / Alibaba Cloud Linux
sudo bash "firewall/centos_setup_firewall.sh"
```

### install_cpa.sh：CPA 部署文件

```bash
sudo bash "install_cpa.sh"
```

默认在当前目录下生成 `cpa-deploy/`（也可指定其他目标目录，已存在时直接复用），内含：

- `docker-compose.yaml`：`cli-proxy-api` 与 `cpa-manager-plus` 两个服务及 `cpa-network` 网络。
- `cpa-data/config.yaml`：CPA 配置，默认密钥会提示尽快修改。
- `cpa-data/{auths,logs,plugins}`、`cpa-manager-plus-data`：挂载目录。
- 可选 nginx 反向代理配置，默认写入 `/etc/nginx/conf.d/cpa.conf`，按域名和证书目录替换模板。

脚本**只写文件不启动容器**；同名文件已存在时跳过写入，保留现有内容。若检测到 `docker compose`，会额外执行一次 `config` 语法校验。

### 运行条件

- 使用 root 权限、Bash 和 systemd；防火墙入口通过 `apt`、`dnf` 或 `yum` 安装所需依赖。
- `vps.sh` 面向使用 systemd 且内核带 nftables 的 Debian 11+ / Ubuntu 20.04+；APT 换源选项只处理 Debian。
- 安装软件、下载网段和调用 EdgeOne API 时需要联网；选择安装 Docker / 1Panel 时需已有 `curl`。
- 防火墙需要内核支持 ipset、IPv4 / IPv6 netfilter；不是 Windows、macOS 或通用容器初始化脚本。
- 运行会实际修改主机配置。远程配置前，应确认 SSH 来源、SSH 端口以及业务和管理面板需要开放的端口。

## vps.sh 功能

菜单共 11 项，所有修改类操作都在独立子 shell 中执行，单项失败只退出该功能，不会让整个菜单崩溃。

| 选项 | 功能 | 说明 |
| --- | --- | --- |
| 1 | 替换 APT 源为国内镜像 | 写入 deb822 格式的 `/etc/apt/sources.list.d/debian.sources`：清华 `debian` 与 `security.debian.org`，suite 取自 `/etc/os-release` 的 `VERSION_CODENAME`。已是目标内容时逐字节比对后直接跳过。 |
| 2 | 一键更新并安装基础包 | 只安装缺失的包，带 dpkg 锁等待与非交互模式。 |
| 3 | 设置账号密码（同时开启密码登录） | 账号默认 `root`，登录 shell 为 `nologin` / `false` 时提前警告；只有目标是 root 才动 `PermitRootLogin`。 |
| 4 | 添加登录公钥（密钥登录） | 用 `ssh-keygen` 实际解析公钥、拒绝私钥、按 key blob 去重；仅当策略真的禁止密钥登录时才改 sshd 配置。 |
| 5 | 密码登录开关（关闭前校验密钥） | 关闭前必须已存在至少一个授权公钥，否则拒绝执行；同时关闭 `KbdInteractiveAuthentication`，避免 PAM 继续接受密码。 |
| 6 | 配置 Swap | 默认 `2 GB`，用 `dd` 创建 `/swapfile`，写入 fstab 与 `vm.swappiness=10`，保留其他交换分区。 |
| 7 | 开启标准 BBR | 写入 `fq` + `bbr`，并清理 `/etc/sysctl.conf` 中的重复旧设置。 |
| 8 | 一键启用 nftables 防火墙 | 只放行 TCP 443 与检测到的 SSH 端口，其余入站默认丢弃。 |
| 9 | 修改 SSH 端口 | 随机端口在 49152-65535 未监听范围内选取，也可手输；兼容 `sshd.service` 与 `ssh.socket`。 |
| 10 | 时区与自动校时 | 显示现状后设置时区（默认 `Asia/Shanghai`）并启用 chrony / systemd-timesyncd，最多等 20 秒复核同步状态。 |
| 11 | 系统与网站探针 | 内核、CPU、内存、磁盘、拥塞控制算法，以及 Gemini / YouTube / Netflix 的 HTTP 状态。 |

### APT 换源与 ca-certificates

全新系统常常没有 `ca-certificates`，https 源会直接卡在证书校验。选项 1 的顺序是：

1. 校验发行版为 Debian、版本代号有效、`debian-archive-keyring` 存在。
2. 渲染目标内容并与现有 `debian.sources` 逐字节比对，同时确认 `/etc/apt/sources.list` 里没有生效的源定义；都满足则直接返回。
3. 缺 CA 时先写清华 **http** 镜像，`apt-get update` 可用后从该镜像安装 `ca-certificates`，再升级为 https 并再次验证。全程不依赖国内访问缓慢的官方源。
4. 验证 `apt-get update`：退出码非零，或输出中出现 `E:` / `Err:` / `W: Failed to fetch` 都算失败，此时还原两个文件和包索引。
5. CA 安装失败时保留已验证可用的 http 镜像；https 验证失败时优先回退 http，只有 http 也不可用才整体回滚。

原文件只在首次运行时备份为 `<文件>.vps.bak`，重复执行不会覆盖原件。

### nftables 防火墙

只声明自己的 `table inet vps`，不 flush 整个规则集，Docker、面板等其他工具的表不受影响：

- `chain input`：`hook input priority -10`，`policy drop`，等价于“排在其他入站规则之前 + 末尾丢弃”。
- 固定放行回环、`ESTABLISHED,RELATED`，丢弃 `INVALID`，放行 ICMP / ICMPv6 与 DHCPv4 / DHCPv6 回包。
- `/etc/vps-firewall/ports.list` 是放行端口的唯一数据源，`rules.nft` 由它生成；渲染后先 `nft -c -f` 预检，再 `nft -f` 一次提交原子替换。
- `vps-firewall.service` 在 `network-pre.target` 之前 `nft -f rules.nft` 恢复规则。
- `ufw` / `firewalld` / `nftables` / `netfilter-persistent` 任一在运行则拒绝执行，避免两套策略互相覆盖。

放行端口固定为 TCP 443 加检测到的 SSH 端口。`detect_ssh_ports` 会合并 `sshd -T` 的 `port` / `listenaddress`、`ss -ltnp` 中 sshd 的实际监听、socket 激活端口和当前会话端口。
重复执行选项 8 会把放行列表重置为“443 + 当前 SSH 端口”，因此手工加入的额外端口不会保留。

调整 SSH 端口时先放行新端口再重启 sshd；若验证失败，由 `trap` 还原 sshd 配置、重启服务并恢复原防火墙端口列表。

### vps.sh 生成的文件

| 路径 | 用途 |
| --- | --- |
| `/etc/apt/sources.list.d/debian.sources`、`/etc/apt/sources.list` | 选项 1 写入的镜像源；首次运行前生成 `.vps.bak` 备份。 |
| `/root/.ssh/authorized_keys` | 选项 4 追加的登录公钥，目录 `0700`、文件 `0600`。 |
| `/etc/ssh/sshd_config`、`/etc/ssh/sshd_config.d/*.conf` | 选项 3 / 4 / 5 调整的登录策略，修改前备份为 `.bak`；选项 9 的备份位于 `/etc/ssh/vps-port-backup.*`。 |
| `/swapfile`、`/etc/fstab`、`/etc/sysctl.d/99-swap.conf` | 选项 6 创建的 Swap、启动挂载项和 `vm.swappiness`。 |
| `/etc/sysctl.d/99-bbr.conf`、`/etc/sysctl.conf` | 选项 7 写入的 BBR 参数；`/etc/sysctl.conf` 中重复项会被删除并备份。 |
| `/etc/vps-firewall/ports.list`、`/etc/vps-firewall/rules.nft` | 选项 8 的放行端口列表与生成的 nftables 规则，权限 `0600`。 |
| `/etc/systemd/system/vps-firewall.service` | 开机恢复 nftables 规则的服务。 |

这些规则只作用于本机 INPUT，不覆盖 Docker 映射端口等 FORWARD 流量，也不修改云安全组。

## 总入口执行流程

### 1. 检查和配置 Swap

如果已经启用任意 Swap，仅显示当前状态并跳过。否则询问大小，默认 `4 GB`，使用 `/swapfile`：

- 优先使用 `fallocate` 分配文件，不存在该命令时使用 `dd`。
- 如果 `/swapfile` 已存在，直接复用现有文件，不按新输入大小调整文件容量。
- 设置文件权限为 `0600`，执行 `mkswap` 和 `swapon`，向 `/etc/fstab` 添加启动挂载项，并避免重复写入。

未启用 Swap 时，总入口会要求输入大小并创建或启用 Swap；此步骤没有独立的“跳过”选项。

### 2. 按需安装 Docker

检查 Docker 是否已安装，并显示 Docker 版本、daemon 可用状态和 Compose 版本。
随后询问是否执行安装；已安装的主机也会询问是否仍需运行安装脚本，只有输入 `y` 才执行。

安装使用 [LinuxMirrors Docker 安装脚本](https://linuxmirrors.cn/docker.sh)，具体安装交互由该在线脚本负责。
执行后再次显示 Docker 和 Compose 的检测结果。

### 3. 按需安装 1Panel

通过 `1pctl` 命令、常见安装路径和 `1panel.service` 检测是否已安装；检测到安装记录便直接跳过。
未安装时询问是否安装，只有输入 `y` 才调用 [1Panel V2 官方安装脚本](https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)。

此步骤仅负责安装入口，不负责已有 1Panel 的更新或重装。Docker 和 1Panel 安装会执行下载的在线脚本。

### 4. 按需初始化防火墙

询问是否设置防火墙；确认后读取 `/etc/os-release` 的 `ID` / `ID_LIKE`，为 Debian 系或 RHEL 系选择对应入口。
两个防火墙入口先检查已有的 `china` 和 `edgeone` 策略，再独立询问跳过、覆盖或首次启用。

执行配置时安装防火墙工具、ipset、Python 3、CA 证书和 cron，启用对应的 cron 服务，并设置入站规则、更新任务和启动恢复服务。
UFW 入口设置默认拒绝入站、允许出站；firewalld 入口保留现有 zone 配置，并添加本脚本管理的 direct 规则。

## 防火墙重复运行

执行前分别检查 `china` 和 `edgeone` 的配置及 UFW / firewalld 持久化、运行时规则，兼容旧版中国 IP 规则。
每项发现已有配置或规则时，独立询问是否覆盖，**各自默认跳过**：

- 输入 `n` 或直接回车：保留该项原策略、IP 集和更新任务，不拉取该项 IP；跳过 EdgeOne 时沿用原凭据文件路径。
- 输入 `y` 或 `确认`：询问是否启用该项策略，然后按新选择重新配置；覆盖并启用 EdgeOne 时读取当前仓库的 `edgeone.json`。
- 未发现该项已有配置或规则：直接询问是否启用该项策略。

例如可以跳过 `china`、只覆盖 `edgeone`，也可以反过来。两项都跳过时正常返回，不安装依赖、不写配置、不重载防火墙。
修改其中一项时，共用的防火墙规则块和启动恢复服务会按两项的最终策略重新生成，被跳过项的策略保持不变。
覆盖针对本脚本管理的规则，不清空用户另行添加的业务规则。输入结束则中止，不视为同意覆盖。
如果被保留的 EdgeOne 凭据文件丢失，需恢复该文件或在当前仓库填写 `edgeone.json` 并覆盖 EdgeOne，才能完成另一项的重新配置。

## 防火墙策略

每项首次配置或确认覆盖后，询问对应策略，回车默认选择否，输入结束则中止：

1. 是否禁止非中国 IP 访问。
2. 是否允许腾讯云 EdgeOne 回源 IP 访问。

| 中国 IP 限制 | EdgeOne 回源例外 | 新入站连接的来源限制 |
| --- | --- | --- |
| 否 | 否 | 无地域限制 |
| 是 | 否 | 仅中国 IP |
| 否 | 是 | 无地域限制，同时维护 EdgeOne 集合 |
| 是 | 是 | 中国 IP 或 EdgeOne 回源 IP |

通过来源检查后，仍需通过 UFW / firewalld 的业务端口规则。**EdgeOne 例外不会开放所有端口**。
例如回源使用 HTTP/HTTPS，需要自行放行 TCP 80/443。脚本自动放行 SSH 端口，保留禁止 Ping 的行为。
已建立连接和回环流量不受地域限制；IPv6 控制报文继续由防火墙原有规则检查。

同时管理 IPv4 和 IPv6，集合分别为 `china`、`china6`、`edgeone`、`edgeone6`。
Ubuntu/Debian 会启用 UFW 的 IPv6 规则支持；目标系统需具备可用的 IPv6 netfilter 支持。
跳过旧版仅 IPv4 的 `china` 策略时，保留 IPv4 范围和旧更新任务，确认覆盖后才升级为双栈。
这些规则仅作用于本机 INPUT，不覆盖 Docker 映射端口等 FORWARD 流量，也不修改云安全组。

再次运行并确认覆盖后可以调整选项：关闭选项会撤销相应规则和更新任务，旧集合及保存文件保留，但不再被本脚本规则引用或恢复。

## EdgeOne 接口与凭据

使用官方 [DescribeOriginACL](https://cloud.tencent.com/document/product/1552/120408) 接口：

- 接口域名：`teo.tencentcloudapi.com`。
- API 版本：`2022-09-01`，签名方式：`TC3-HMAC-SHA256`。
- 需要腾讯云 `SecretId`、`SecretKey` 和 EdgeOne 站点 `ZoneId`。
- 子账号至少需要对目标站点执行 `teo:DescribeOriginACL` 的权限。
- 该站点及实际回源的域名/四层实例必须先在控制台启用“源站防护”，否则没有可用的专用回源网段。

凭据从**仓库根目录的 `edgeone.json`** 读取，不再通过终端询问。首次使用前，在仓库根目录创建配置文件：

```bash
test -e "edgeone.json" || install -m 0600 "edgeone.example.json" "edgeone.json"
```

将 `edgeone.json` 的三个空字段填写为实际值，保留 `edgeone.example.json` 中的空值作为公共模板：

| JSON 字段 | 含义 | 从哪里获取 |
| --- | --- | --- |
| `zone_id` | 需要查询回源网段的 EdgeOne 站点唯一 ID，格式为 `zone-xxxxxxxxxxxxxxxx`。 | [EdgeOne 站点管理](https://console.cloud.tencent.com/edgeone/zones)中目标站点的站点 ID，或通过 `DescribeZones` 接口查询。 |
| `secret_id` | 腾讯云 API 密钥对的身份标识，用于标识发起请求的账号。 | [访问管理 CAM → API 密钥管理](https://console.cloud.tencent.com/cam/capi)中密钥对的 `SecretId`。 |
| `secret_key` | 与该 `SecretId` 配对的密钥，用于计算 API 请求签名。 | 同一条 API 密钥记录的 `SecretKey`，创建密钥时按页面提示查看或保存。 |

### 获取站点 ID：`zone_id`

1. 登录 [EdgeOne 控制台的站点管理页面](https://console.cloud.tencent.com/edgeone/zones)。
2. 找到使用当前服务器作为源站的站点，进入站点详情或概览，查看并复制以 `zone-` 开头的站点 ID。
3. 将完整 ID 填入 `zone_id`。这里填写的是站点 ID，不是域名、CNAME、源站 IP、腾讯云 AppId 或套餐 ID。

如果控制台页面未直接显示站点 ID，可打开 [API Explorer 的 DescribeZones 接口](https://console.cloud.tencent.com/api/explorer?Product=teo&Version=2022-09-01&Action=DescribeZones)，
使用具有站点查询权限的账号查询站点列表，在返回的 `Zones` 中按 `ZoneName` 找到目标站点，复制对应的 `ZoneId`。
通过此方式查询还需具有 `teo:DescribeZones` 权限；脚本日常更新只调用 `DescribeOriginACL`。

### 获取 API 密钥：`secret_id` 和 `secret_key`

1. 打开腾讯云 [API 密钥管理](https://console.cloud.tencent.com/cam/capi)。建议在 CAM 中为专用子用户创建或管理密钥，并授权其访问目标 EdgeOne 站点。
2. 使用一对有效密钥，或通过页面的“新建密钥”创建一对；子用户的密钥管理权限不足时，需要由账号管理员操作。
3. 将同一对密钥的 `SecretId` 和 `SecretKey` 分别填入 `secret_id` 和 `secret_key`，不要混用不同密钥对中的值。
4. 如果已有密钥的 `SecretKey` 无法查看且没有保存，应创建新的密钥对，并同时更新这两个字段。

这是腾讯云 API 访问密钥，不是腾讯云登录密码、EdgeOne 回源鉴权密钥或 HTTPS 证书私钥。
密钥所属账号必须有目标站点的 `teo:DescribeOriginACL` 权限；对应站点及回源域名/四层实例也需已启用“源站防护”。
仅创建 API 密钥不会自动授予站点权限，也不会自动开启源站防护。

### 保存与更新

`.gitignore` 已忽略根目录的 `/edgeone.json`，仅提交不含真实凭据的 `edgeone.example.json`。
启用 EdgeOne 时会校验文件及字段并将文件权限设为 `0600`；文件缺失、字段为空或格式错误会中止配置。

`/etc/init-server-firewall/config.json` 仍保存防火墙策略，但只记录 `edgeone_credentials_file` 的绝对路径，不再保存密钥副本。
定时更新每次从该路径读取最新凭据，因此轮换密钥只需修改 `edgeone.json`。仓库目录需要保留在原位置；
移动仓库后应重新运行防火墙初始化并确认覆盖 EdgeOne，以更新记录的路径。开机恢复 IP 集只读取系统中的策略和网段快照，不需要访问密钥。

从此前将密钥保存于 `/etc/init-server-firewall/config.json` 的版本升级时，先将凭据填写到仓库的 `edgeone.json`，
再运行防火墙脚本并确认覆盖 EdgeOne；成功后系统配置改为保存文件路径，原有内嵌密钥会被移除。
密钥不嵌入更新脚本，不作为进程命令行参数传递。无需安装腾讯云 SDK，使用 Python 3 标准库完成签名、请求和网段校验。

2025-06-27 后旧接口 `DescribeOriginProtection` 已停止迭代，因此这里使用新版接口。
接口返回当前 `CurrentOriginACL` 和待生效 `NextOriginACL`：更新器放行两者的完整网段并集，
API 切换到新版本后自动移除已退役网段。不会调用云端启用、修改或确认更新接口；
同一站点可能对应多个源站，本机更新完成不代表其他源站已经完成，故保留云端变更通知。

该配置目前对应一个 ZoneId。仅添加 IP 例外不能替代源站鉴权。

## 更新与恢复

- 中国网段来自 IPdeny，每周一 03:00 更新。
- EdgeOne 按官方低频轮询建议，在每月第 1、4、7……天的 03:15 更新，月末间隔可能少于三天。
- 时间以服务器时区为准，任务位于 `/etc/cron.d/init-server-ipsets`。
- 确认覆盖 `china` 时，旧脚本生成的中国 IP 周更新任务会从 root crontab 中迁移；跳过时原任务保留。
- 日志位于 `/var/log/ipset-update.log`；失败以非零状态退出。
- 下载、API、网段校验或集合更新失败时保留原有集合；使用临时集合和 `ipset swap` 更新，并通过文件锁串行执行。
- `ipset-restore.service` 在防火墙启动前从 `/etc/ipset/*.conf` 恢复已启用集合，不依赖联网下载。

手动更新：

```bash
sudo python3 "/usr/local/lib/init-server-firewall/ipset_manager.py" update
sudo python3 "/usr/local/lib/init-server-firewall/ipset_manager.py" update --source edgeone
```

首次获取数据失败会中止初始化。启用地域限制前，应确保管理端来源属于中国网段，否则当前 SSH 会话虽然保留，新连接仍可能被阻止。

## init_server.sh 运行后生成的文件

| 路径 | 用途 |
| --- | --- |
| `/swapfile`、`/etc/fstab` | 总入口新建或复用的 Swap 及其启动挂载配置。 |
| 仓库根目录 `edgeone.json` | 用户填写的 EdgeOne 凭据，Git 忽略，初始化时设置权限 `0600`。 |
| `/etc/init-server-firewall/config.json` | 中国 IP / EdgeOne 策略及凭据文件的绝对路径，权限 `0600`，不保存密钥。 |
| `/usr/local/lib/init-server-firewall/ipset_manager.py` | 安装后的 IP 集更新与恢复程序；EdgeOne 更新会读取仓库中的凭据文件。 |
| `/etc/ipset/china.conf`、`china6.conf`、`edgeone.conf`、`edgeone6.conf` | 启用相应策略后保存的 IP 集快照，旧版 IPv4 策略可能只有 `china.conf`。 |
| `/etc/systemd/system/ipset-restore.service` | 在防火墙启动前恢复 IP 集的服务。 |
| `/etc/systemd/system/ufw.service.d/ipset.conf` 或 `/etc/systemd/system/firewalld.service.d/ipset.conf` | 对应防火墙服务的启动依赖配置。 |
| `/etc/cron.d/init-server-ipsets` | 本脚本管理的 IP 集更新任务；被跳过的旧版中国 IP 任务仍可能保留在 root crontab。 |
| `/var/log/ipset-update.log` | 定时更新的结果与错误日志。 |
| `/etc/ufw/before.rules`、`/etc/ufw/before6.rules`、`/etc/default/ufw` | Ubuntu / Debian 入口修改的 UFW 配置，修改前生成带时间戳的备份。 |

firewalld 入口通过 `firewall-cmd --permanent` 保存规则，使用 `INIT_SERVER_INPUT` 管理链；UFW 使用 `init-server-input` 管理链。
系统文件在实际执行初始化时才生成。Git 版本控制中只包含凭据示例，真实密钥保存在本机被忽略的 `edgeone.json` 中。

## 查看状态与语法检查

`vps.sh` 相关状态：

```bash
sudo nft list table inet vps
sudo cat "/etc/vps-firewall/ports.list"
sudo systemctl status vps-firewall.service
sudo sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractiveauthentication) '
sudo ssh-keygen -lf "/root/.ssh/authorized_keys"
sudo cat "/etc/apt/sources.list.d/debian.sources"
```

`init_server.sh` / 防火墙脚本可按系统查看当前规则和更新日志：

```bash
sudo ufw status verbose
# firewalld 系统
sudo firewall-cmd --list-all
sudo firewall-cmd --direct --get-all-rules

sudo ipset list -name
sudo systemctl status ipset-restore.service
sudo tail -n 50 "/var/log/ipset-update.log"
```

`ufw status` 主要显示端口规则，地域限制需结合 `/etc/ufw/before.rules`、`before6.rules` 和对应 IP 集查看。

只检查 Bash 语法，不执行初始化：

```bash
bash -n "init_server.sh" "vps.sh" "install_cpa.sh" "firewall/firewall_common.sh" "firewall/ubuntu_setup_firewall.sh" "firewall/centos_setup_firewall.sh"
```
