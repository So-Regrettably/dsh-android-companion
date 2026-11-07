#!/usr/bin/python3
"""status —— 一条命令看全：服务、预算、备份、定时任务、最近错误、内存、前台。

她说的对：以前要翻四五个文件才知道自己什么状况。

    status          # 全部
    status -s       # 只看有没有毛病（有异常才多说话）
"""
import json
import os
import re
import subprocess
import sys
import time

ROOT = "/root"
WEB = "http://127.0.0.1:38571/"
PATHENV = "export PATH=/system/bin:/vendor/bin:/system/xbin:$PATH; "


def su(cmd, timeout=10):
    try:
        r = subprocess.run(["su", "-c", PATHENV + cmd], capture_output=True, timeout=timeout)
        return (r.stdout or b"").decode("utf-8", "replace").strip()
    except Exception:
        return ""


def bj(ts=None):
    return time.strftime("%m-%d %H:%M:%S", time.gmtime((ts or time.time()) + 8 * 3600))


def read(path, limit=4000):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()[:limit]
    except OSError:
        return ""


def web_code():
    try:
        out = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "4", WEB],
            capture_output=True, timeout=8).stdout.decode()
        return out.strip()
    except Exception:
        return "?"


def sec_service():
    code = web_code()
    ok = code in ("200", "401", "404")
    pid = ""
    try:
        out = subprocess.run(["sh", "-c", "ss -lntp 2>/dev/null | grep :38571 | head -1"],
                             capture_output=True, timeout=8).stdout.decode()
        m = re.search(r"pid=(\d+)", out)
        if m:
            pid = m.group(1)
    except Exception:
        pass
    focus = su("dumpsys window | grep -m1 mCurrentFocus").split("=", 1)[-1][:70]
    return ok, code, pid, focus


def sec_budget():
    txt = read(ROOT + "/budget.txt").strip().splitlines()
    tail = txt[-1] if txt else "（没有账本）"
    over = os.path.exists("/data/adb/budget/BRAKE")
    alarm = os.path.exists("/data/adb/budget/ALARM")
    return tail, over, alarm


def sec_backup():
    raw = read(ROOT + "/.dsh/last-backup.json", 2000)
    if not raw:
        return None
    try:
        d = json.loads(raw)
    except Exception:
        return None
    try:
        t = time.mktime(time.strptime(d.get("at", ""), "%Y-%m-%d %H:%M:%S"))
        age_h = (time.time() + 8 * 3600 - t) / 3600.0
    except Exception:
        age_h = None
    return d, age_h


def sec_cron():
    jobs_dir = ROOT + "/.cron/jobs"
    if not os.path.isdir(jobs_dir):
        return [], 0
    jobs = []
    now = time.time()
    for name in sorted(os.listdir(jobs_dir)):
        if not name.endswith(".job"):
            continue
        try:
            line = open(os.path.join(jobs_dir, name), encoding="utf-8").readline()
            epoch, period, text = line.rstrip("\n").split("\t", 2)
            jobs.append({"epoch": int(epoch), "period": int(period), "text": text})
        except Exception:
            continue
    dues = [j for j in jobs if j["epoch"] <= now]
    return sorted(jobs, key=lambda j: j["epoch"]), len(dues)


def sec_errors():
    log = ROOT + "/dsh-web.log"
    if not os.path.exists(log):
        return []
    out = []
    try:
        with open(log, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if ("故障参考号" in line) or ("turn/end" in line and "error" in line):
                    out.append(line.strip()[:120])
    except OSError:
        pass
    return out[-3:]



def sec_media():
    """收图那条线：media 目录里能收到什么、最新一张多久了、目录还可写吗。"""
    d = ROOT + "/.dsh/media/onebot"
    info = {"dir": d, "writable": False, "images": 0, "voices": 0, "newest_h": None}
    if not os.path.isdir(d):
        return info
    info["writable"] = os.access(d, os.W_OK)
    now = time.time()
    newest = None
    try:
        for name in os.listdir(d):
            if name.startswith("media_"):
                info["images"] += 1
            elif name.startswith("say-") and name.endswith(".mp3"):
                info["voices"] += 1
            fp = os.path.join(d, name)
            try:
                mt = os.path.getmtime(fp)
            except OSError:
                continue
            if newest is None or mt > newest:
                newest = mt
    except OSError:
        pass
    if newest is not None:
        info["newest_h"] = (now - newest) / 3600.0
    return info

def sec_mem():
    try:
        with open("/proc/meminfo", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("MemAvailable"):
                    kb = int(line.split()[1])
                    return "%.1f GB 可用" % (kb / 1024.0 / 1024.0)
    except OSError:
        pass
    return "?"


def main():
    brief = "-s" in sys.argv[1:]
    problems = []

    ok, code, pid, focus = sec_service()
    if not ok:
        problems.append("服务没起来（38571 回了 %s）" % code)

    tail, over, alarm = sec_budget()
    if over:
        problems.append("预算熔断中（BRAKE 在，今天不能再花）")
    elif alarm:
        problems.append("预算接近上限（ALARM 在）")

    bk = sec_backup()
    if bk is None:
        problems.append("没见过备份记录（/root/.dsh/last-backup.json 不在）")
    else:
        d, age_h = bk
        if age_h is not None and age_h > 24:
            problems.append("上次备份是 %.0f 小时前（超过一天，最好让他跑一次）" % age_h)

    jobs, dues = sec_cron()
    if dues:
        problems.append("有 %d 个定时任务已经到点但没触发（看看 dsh-cron 守护还在不在）" % dues)

    mp = sec_media()
    if not mp["writable"]:
        problems.append("收图目录写不进去（%s）" % mp["dir"])
    elif mp["images"] == 0 and mp["newest_h"] is not None and mp["newest_h"] > 24:
        problems.append("一天多没收到过图片（收图那条线可能又断了）")

    errs = sec_errors()
    if errs:
        problems.append("日志里有 %d 条最近的错误记录" % len(errs))

    if brief:
        if problems:
            print("有 %d 件事要看：" % len(problems))
            for p in problems:
                print("  ! " + p)
        else:
            print("都正常")
        return 0 if not problems else 1

    print("═══ 她现在什么样（%s 北京）═══" % bj())
    print()
    print("服务    %s  38571 回了 %s%s" %
          ("在跑" if ok else "没跑", code, ("，pid " + pid) if pid else ""))
    print("前台    %s" % (focus or "?"))
    print("内存    %s" % sec_mem())
    print()
    print("预算    %s%s" % (tail, "   ⚠ 已熔断" if over else ("   · 接近上限" if alarm else "")))
    if bk is None:
        print("备份    没有记录")
    else:
        d, age_h = bk
        age = ("%.0f 小时前" % age_h) if age_h is not None else "时间不明"
        print("备份    %s  %s  校验 %s" % (d.get("at", "?"), age, str(d.get("sha256", ""))[:12]))
    if mp["newest_h"] is None:
        print("收图    目录是空的（一张都没落下）")
    else:
        print("收图    %d 张图 / %d 条语音，最新一个 %.1f 小时前%s" %
              (mp["images"], mp["voices"], mp["newest_h"],
               "" if mp["writable"] else "   ⚠ 目录不可写"))
    print()
    if not jobs:
        print("定时    没有任务")
    else:
        print("定时    %d 个（上限 6）：" % len(jobs))
        for j in jobs[:6]:
            when = time.strftime("%m-%d %H:%M", time.gmtime(j["epoch"] + 8 * 3600))
            per = ("每%d分" % (j["period"] // 60)) if 0 < j["period"] < 86400 else \
                  ("每天" if j["period"] == 86400 else
                   ("每周" if j["period"] == 604800 else
                    ("一次" if j["period"] == 0 else "?")))
            print("        %s  %s  %s" % (when, per, j["text"][:40]))
    print()
    if errs:
        print("最近错误：")
        for e in errs:
            print("        " + e)
    else:
        print("最近错误：无")

    if problems:
        print()
        print("要看的事：")
        for p in problems:
            print("  ! " + p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
