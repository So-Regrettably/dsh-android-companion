#!/usr/bin/env python3
"""imgfind —— 归档图片的检索与取回（2026-11-06）

为什么不用 OCR：这台机器只有 1.7G 内存，rapidocr 那套（onnxruntime + 检测/识别模型）
装下来要几百 MB，常驻还会抢内存 —— 而图片检索是个低频操作。
所以这里走纯文本索引：归档时自动登记（日期/大小/时间），内容靠你自己补一句备注。

用法：
    imgfind                      最近 7 天的图（按时间倒序）
    imgfind --list 30            最近 30 天
    imgfind --date 2026-11-06    某一天
    imgfind 三角洲                搜备注和文件名
    imgfind --note <文件名或序号> "今天那张三角洲战绩"   给图写备注（下次能搜到）
    imgfind --send <文件名或序号> 打印绝对路径，拿去 qq_send_image
    imgfind --stat               归档总量

索引存在 /root/images/index.jsonl，一行一条，imgkeep 归档时会自动补。
"""
import glob
import json
import os
import shutil
import sys
import time

BASE = "/root/images"
INDEX = os.path.join(BASE, "index.jsonl")


def load_index():
    idx = {}
    if os.path.isfile(INDEX):
        with open(INDEX, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("f"):
                    idx[rec["f"]] = rec
    return idx


def save_index(idx):
    tmp = INDEX + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for rec in sorted(idx.values(), key=lambda r: r.get("ts", 0)):
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    os.replace(tmp, INDEX)


def scan(idx):
    """把归档目录里还没登记的文件补进索引。返回新增条数。"""
    added = 0
    for path in glob.glob(os.path.join(BASE, "20*", "*")):
        if not os.path.isfile(path):
            continue
        rel = os.path.relpath(path, BASE)
        if rel in idx:
            continue
        st = os.stat(path)
        idx[rel] = {
            "f": rel,
            "ts": int(st.st_mtime),
            "size": st.st_size,
            "note": "",
        }
        added += 1
    return added


def fmt(ts):
    return time.strftime("%m-%d %H:%M", time.localtime(ts))


def size_h(n):
    if n > 1024 * 1024:
        return "%.1fM" % (n / 1048576.0)
    return "%.0fK" % (n / 1024.0)


def brief(rec):
    note = rec.get("note") or ""
    tail = ("  「%s」" % note) if note else ""
    return "  %s  %-6s %s%s" % (fmt(rec.get("ts", 0)), size_h(rec.get("size", 0)), rec["f"], tail)


def sort_desc(recs):
    return sorted(recs, key=lambda r: r.get("ts", 0), reverse=True)


def find_one(idx, key):
    """按序号（从最近列表里的行号）或文件名子串定位一张图。"""
    recs = sort_desc(list(idx.values()))
    if key.isdigit():
        n = int(key)
        if 1 <= n <= len(recs):
            return recs[n - 1]
        return None
    hits = [r for r in recs if key in os.path.basename(r["f"])]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        print("有多张匹配，用更长的片段或序号：")
        for h in hits[:10]:
            print(brief(h))
    return None


def main():
    idx = load_index()
    added = scan(idx)
    if added:
        save_index(idx)

    args = sys.argv[1:]

    if not args:
        args = ["--list", "7"]

    if args[0] == "--stat":
        recs = list(idx.values())
        total = sum(r.get("size", 0) for r in recs)
        days = sorted({r["f"].split(os.sep)[0] for r in recs})
        print("归档 %d 张，共 %.1f MB，跨 %d 天" % (len(recs), total / 1e6, len(days)))
        if days:
            print("最早 %s，最新 %s" % (days[0], days[-1]))
        return

    if args[0] == "--list":
        days = int(args[1]) if len(args) > 1 else 7
        cutoff = time.time() - days * 86400
        recs = [r for r in idx.values() if r.get("ts", 0) >= cutoff]
        recs = sort_desc(recs)
        if not recs:
            print("最近 %d 天没有归档的图。" % days)
            return
        print("最近 %d 天共 %d 张（序号可直接用于 --send / --note）：" % (days, len(recs)))
        for i, r in enumerate(recs, 1):
            print("%2d %s" % (i, brief(r).lstrip()))
        return

    if args[0] == "--date":
        if len(args) < 2:
            print("用法：imgfind --date 2026-11-06")
            return
        recs = sort_desc([r for r in idx.values() if r["f"].startswith(args[1])])
        if not recs:
            print("%s 没有归档的图。" % args[1])
            return
        print("%s 共 %d 张：" % (args[1], len(recs)))
        for i, r in enumerate(recs, 1):
            print("%2d %s" % (i, brief(r).lstrip()))
        return

    if args[0] == "--note":
        if len(args) < 3:
            print('用法：imgfind --note <序号或文件名> "一句描述"')
            return
        rec = find_one(idx, args[1])
        if not rec:
            print("ERR:NO_MATCH 没有找到「%s」" % args[1])
            return
        rec["note"] = " ".join(args[2:]).strip()
        save_index(idx)
        print("已记下：%s → 「%s」" % (rec["f"], rec["note"]))
        return

    if args[0] == "--send":
        if len(args) < 2:
            print("用法：imgfind --send <序号或文件名>")
            return
        rec = find_one(idx, args[1])
        if not rec:
            print("ERR:NO_MATCH 没有找到「%s」" % args[1])
            return
        path = os.path.join(BASE, rec["f"])
        if not os.path.isfile(path):
            print("ERR:FILE_GONE 索引里有但文件没了：%s" % rec["f"])
            return
        # 插件的出站围栏只认 mediaDir，直接给 /root/images 下的路径会被拦掉。
        # 跟 /root/say 一个套路：拷一份进 media/onebot 再打印那个路径。
        send = os.path.join("/root/.dsh/media/onebot", os.path.basename(rec["f"]))
        try:
            os.makedirs(os.path.dirname(send), exist_ok=True)
            shutil.copy2(path, send)
            print(send)
        except OSError as exc:
            print("ERR:COPY_FAIL %r（原图仍在这儿：%s）" % (exc, path))
        return

    # 默认：关键词搜索（备注 + 文件名 + 日期）
    kw = " ".join(args)
    low = kw.lower()
    hits = []
    for r in idx.values():
        hay = (r.get("note") or "") + " " + r["f"]
        if low in hay.lower():
            hits.append(r)
    if not hits:
        print("没搜到「%s」。用 imgfind --list 30 看看都有哪些，缺备注可以用 --note 补。" % kw)
        return
    hits = sort_desc(hits)
    print("搜到 %d 张：" % len(hits))
    for r in hits:
        print(brief(r))


if __name__ == "__main__":
    main()
