#!/usr/bin/env python3
# 刷新 Clash 订阅 -> 重新生成极简配置 -> 热重载 mihomo
import json, os, re, sys, time, urllib.request

SUB_URL = "https://cdn2.xmrth.one/s/pPvt3DeuH9V9?clash=1&neo=1"
CONF_DIR = "/root/.dsh/clash"
MIN = os.path.join(CONF_DIR, "min.yaml")
UA = "ClashMetaForAndroid/2.10.1"

HEAD = """mixed-port: 7897
allow-lan: false
mode: rule
log-level: info
external-controller: 127.0.0.1:9090
secret: dsh
ipv6: false
dns:
  enable: true
  ipv6: false
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
proxies:
"""


def fetch():
    req = urllib.request.Request(SUB_URL, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=40) as r:
        return r.read().decode("utf-8", "replace")


def parse_nodes(text):
    nodes, started = [], False
    for line in text.split("\n"):
        s = line.strip()
        if s == "proxies:":
            started = True
            continue
        if started:
            if not s.startswith("- "):
                if s and not s.startswith("-"):
                    break
                continue
            raw = s[2:]
            try:
                nodes.append(json.loads(raw))
            except Exception:
                pass
    return nodes


def build(nodes):
    body = "\n".join("  - " + json.dumps(n, ensure_ascii=False) for n in nodes)
    names = [n["name"] for n in nodes]
    groups = "\nproxy-groups:\n  - name: PROXY\n    type: url-test\n    url: https://www.gstatic.com/generate_204\n    interval: 300\n    tolerance: 100\n    proxies:\n"
    groups += "\n".join('      - "%s"' % n for n in names)
    return HEAD + body + groups + "\nrules:\n  - MATCH,PROXY\n"


def reload_mihomo():
    try:
        body = json.dumps({"path": MIN, "force": True}).encode()
        req = urllib.request.Request(
            "http://127.0.0.1:9090/configs?force=true",
            data=body, method="PUT",
            headers={"Authorization": "Bearer dsh", "Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10).read()
        return "reloaded"
    except Exception as e:
        return "reload failed: %s" % e


def main():
    try:
        text = fetch()
        nodes = parse_nodes(text)
        if len(nodes) < 3:
            print("节点太少(%d)，保留旧配置" % len(nodes))
            return 1
        new = build(nodes)
        old = ""
        if os.path.exists(MIN):
            old = open(MIN, encoding="utf-8").read()
        if new != old:
            open(MIN, "w", encoding="utf-8").write(new)
            print("已更新配置：%d 个节点，%s" % (len(nodes), reload_mihomo()))
        else:
            print("配置未变化（%d 节点）" % len(nodes))
        return 0
    except Exception as e:
        print("刷新失败：%s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
