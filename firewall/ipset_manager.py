#!/usr/bin/env python3
"""中国和 EdgeOne IP 集的获取、校验、原子替换与启动恢复。"""

import argparse
import datetime
import fcntl
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.request


CONFIG_FILE = Path("/etc/init-server-firewall/config.json")
SAVE_DIR = Path("/etc/ipset")
LOCK_FILE = "/run/lock/init-server-ipsets.lock"
CHINA_URLS = {
    4: "https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone",
    6: "https://www.ipdeny.com/ipv6/ipaddresses/aggregated/cn-aggregated.zone",
}
SET_NAMES = {"china": ("china", "china6"), "edgeone": ("edgeone", "edgeone6")}


def load_edgeone_credentials(path):
    path = Path(path)
    if not path.is_file():
        raise ValueError("未找到 EdgeOne 凭据文件: {}，请参照仓库的 edgeone.example.json 创建".format(path))
    with path.open(encoding="utf-8") as stream:
        credentials = json.load(stream)
    if not isinstance(credentials, dict):
        raise ValueError("EdgeOne 凭据必须是 JSON 对象")
    values = {}
    for key in ("zone_id", "secret_id", "secret_key"):
        value = credentials.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ValueError("请在 edgeone.json 中填写非空字符串字段: " + key)
        values[key] = value.strip()
    if not re.fullmatch(r"zone-[A-Za-z0-9]+", values["zone_id"]):
        raise ValueError("edgeone.json 中的 zone_id 格式无效")
    return values


def atomic_write(path, content, mode=0o600):
    path = Path(path)
    descriptor, name = tempfile.mkstemp(dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def configure(path, china, edgeone, keep_edgeone=False, previous_path=None, china_ipv6=True,
              credentials_file=None):
    config = {"china": china, "edgeone": edgeone, "china_ipv6": china_ipv6}
    if edgeone:
        # 跳过时沿用原凭据文件路径；只在显式覆盖时重新指定仓库位置。
        if keep_edgeone and previous_path is not None and previous_path.is_file():
            with previous_path.open() as stream:
                previous = json.load(stream)
            credentials_file = previous.get("edgeone_credentials_file", credentials_file)
        if credentials_file is None:
            raise ValueError("启用 EdgeOne 时必须指定 --credentials-file，指向仓库中的 edgeone.json")
        credentials_file = Path(credentials_file).resolve()
        load_edgeone_credentials(credentials_file)
        credentials_file.chmod(0o600)
        config["edgeone_credentials_file"] = str(credentials_file)
    atomic_write(path, json.dumps(config, ensure_ascii=False) + "\n")


def signed_request(config, timestamp):
    # 按腾讯云 API 3.0 的 TC3-HMAC-SHA256 规范签名；密钥不进入命令行。
    host = "teo.tencentcloudapi.com"
    payload = json.dumps({"ZoneId": config["zone_id"]}, separators=(",", ":")).encode()
    date = datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).strftime("%Y-%m-%d")
    content_type = "application/json; charset=utf-8"
    headers = "content-type:{}\nhost:{}\n".format(content_type, host)
    canonical = "POST\n/\n\n{}\ncontent-type;host\n{}".format(
        headers, hashlib.sha256(payload).hexdigest()
    )
    scope = date + "/teo/tc3_request"
    to_sign = "TC3-HMAC-SHA256\n{}\n{}\n{}".format(
        timestamp, scope, hashlib.sha256(canonical.encode()).hexdigest()
    )

    def sign(key, message):
        return hmac.new(key, message.encode(), hashlib.sha256).digest()

    key = sign(("TC3" + config["secret_key"]).encode(), date)
    key = sign(sign(key, "teo"), "tc3_request")
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    authorization = (
        "TC3-HMAC-SHA256 Credential={}/{}, SignedHeaders=content-type;host, Signature={}"
    ).format(config["secret_id"], scope, signature)
    return urllib.request.Request(
        "https://" + host, data=payload, method="POST", headers={
            "Content-Type": content_type,
            "Host": host,
            "Authorization": authorization,
            "X-TC-Action": "DescribeOriginACL",
            "X-TC-Version": "2022-09-01",
            "X-TC-Timestamp": str(timestamp),
        }
    )


def read_url(request):
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8")


def validate_networks(values, version):
    if not isinstance(values, list):
        raise ValueError("IP 网段必须是数组")
    networks = set()
    for value in values:
        if not isinstance(value, str):
            raise ValueError("IP 网段必须是字符串")
        network = ipaddress.ip_network(value.strip(), strict=True)
        if network.version != version or network.prefixlen == 0:
            raise ValueError("IP 地址族不匹配或包含默认路由")
        networks.add(str(network))
    return sorted(networks)


def parse_edgeone(data):
    response = data["Response"]
    if response.get("Error"):
        # 只记录错误码，避免将服务端返回的请求信息或凭据写入日志。
        raise ValueError("EdgeOne API 错误: " + str(response["Error"].get("Code", "Unknown")))
    info = response.get("OriginACLInfo") or {}
    if info.get("Status") not in ("online", "updating"):
        raise ValueError("EdgeOne 源站防护未启用，请先在控制台启用")
    current = info.get("CurrentOriginACL")
    if not current:
        raise ValueError("EdgeOne 当前回源网段为空")
    combined = {4: set(), 6: set()}
    versions = [current]
    if info.get("NextOriginACL"):
        versions.append(info["NextOriginACL"])
    for version in versions:
        addresses = version.get("EntireAddresses")
        if not isinstance(addresses, dict):
            raise ValueError("EdgeOne 回源网段结构异常")
        count = 0
        for family in (4, 6):
            entries = validate_networks(addresses["IPv{}".format(family)], family)
            count += len(entries)
            combined[family].update(entries)
        if count == 0:
            raise ValueError("EdgeOne 回源网段为空，保留原有集合")
    # 预先放行下一版本，当前版本在 API 完成切换后才移除。
    return {name: sorted(combined[family])
            for name, family in zip(SET_NAMES["edgeone"], (4, 6))}


def fetch_sets(config, source):
    if source == "edgeone":
        credentials_file = config.get("edgeone_credentials_file")
        if not credentials_file:
            raise ValueError("缺少 EdgeOne 凭据文件路径，请按新版说明配置 edgeone.json 并覆盖 EdgeOne 策略")
        credentials = load_edgeone_credentials(credentials_file)
        return parse_edgeone(json.loads(read_url(signed_request(credentials, int(time.time())))))
    sets = {}
    for name, family in zip(SET_NAMES["china"], (4, 6)):
        if family == 6 and not config.get("china_ipv6", True):
            continue
        entries = validate_networks(read_url(CHINA_URLS[family]).splitlines(), family)
        if len(entries) < (1000 if family == 4 else 100):
            raise ValueError("中国 IPv{} 网段数量异常".format(family))
        sets[name] = entries
    return sets


def ipset(*args, **kwargs):
    return subprocess.run(["ipset"] + list(args), check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, **kwargs).stdout


def replace_sets(sets):
    existing = set(ipset("list", "-name").splitlines())
    temporary = {}
    switched = []
    previous = {}
    saved = {}
    try:
        # 全部校验、填充完毕才替换正在使用的集合，单条失败也不发布半份数据。
        for name, entries in sets.items():
            temp_name = "{}_tmp_{}".format(name, os.getpid())
            family = "inet6" if name.endswith("6") else "inet"
            ipset("create", temp_name, "hash:net", "family", family, "maxelem", "262144")
            temporary[name] = temp_name
            ipset("restore", input="".join("add {} {}\n".format(temp_name, net) for net in entries))
            # 旧版集合容量可能不同，create -exist 仍会因参数不匹配失败。
            if name not in existing:
                ipset("create", name, "hash:net", "family", family, "maxelem", "262144")
            path = SAVE_DIR / (name + ".conf")
            previous[name] = path.read_text() if path.exists() else None
        for name, temp_name in temporary.items():
            ipset("swap", temp_name, name)
            switched.append(name)
        for name in sets:
            saved[name] = ipset("save", name)
        for name, content in saved.items():
            atomic_write(SAVE_DIR / (name + ".conf"), content)
    except Exception:
        for name in reversed(switched):
            ipset("swap", temporary[name], name)
        for name in saved:
            path = SAVE_DIR / (name + ".conf")
            if previous[name] is not None:
                atomic_write(path, previous[name])
            elif path.exists():
                path.unlink()
        raise
    finally:
        for temp_name in temporary.values():
            subprocess.run(["ipset", "destroy", temp_name], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)


def update(config, sources):
    failed = False
    for source in sources:
        if not config.get(source):
            continue
        try:
            sets = fetch_sets(config, source)
            replace_sets(sets)
            print("{} {} 更新完成: {}".format(datetime.datetime.now().isoformat(), source,
                                            {name: len(items) for name, items in sets.items()}))
        except Exception as error:
            failed = True
            # 不输出可能含 HTTP 请求细节的异常文本。
            detail = str(error) if isinstance(error, ValueError) else type(error).__name__
            print("{} 更新失败，保留原集合: {}".format(source, detail), file=sys.stderr)
    if failed:
        raise RuntimeError("IP 集更新未全部成功")


def restore(config):
    for source, names in SET_NAMES.items():
        if config.get(source):
            for name in names:
                if name == "china6" and not config.get("china_ipv6", True):
                    continue
                ipset("restore", "-exist", "-f", str(SAVE_DIR / (name + ".conf")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("configure", "update", "restore"))
    parser.add_argument("--config", type=Path, default=CONFIG_FILE)
    parser.add_argument("--china", action="store_true")
    parser.add_argument("--edgeone", action="store_true")
    parser.add_argument("--keep-edgeone", action="store_true")
    parser.add_argument("--previous-config", type=Path)
    parser.add_argument("--credentials-file", type=Path)
    parser.add_argument("--china-ipv4-only", action="store_true")
    parser.add_argument("--source", choices=("all", "china", "edgeone"), default="all")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("必须以 root 权限运行")
    try:
        if args.command == "configure":
            configure(args.config, args.china, args.edgeone, args.keep_edgeone,
                      args.previous_config, not args.china_ipv4_only, args.credentials_file)
            return
        with open(LOCK_FILE, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with args.config.open() as stream:
                config = json.load(stream)
            if args.command == "restore":
                restore(config)
            else:
                sources = ("china", "edgeone") if args.source == "all" else (args.source,)
                update(config, sources)
    except Exception as error:
        detail = str(error) if isinstance(error, (ValueError, RuntimeError)) else type(error).__name__
        print("错误: " + detail, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
