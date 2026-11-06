# 部署

从一台裸机到"能聊天"，按这个顺序做，一次只做一步。

> 下文所有 `<...>` 都是占位符，替换成你自己的。**别把真实凭据提交进仓库。**

---

## 0. 前置

| 项 | 要求 | 说明 |
|---|---|---|
| 手机 | Android 8.0+，已 root（Magisk） | 需要 `su` 能执行任意命令 |
| 手机 | 装 DSH App | 跑一次，让它把 rootfs 解出来 |
| VPS | 任意 Linux，1C1G 起 | 能跑 Docker，有固定公网 IP |
| QQ | 建议小号 | 自动化有风险，别用主号 |

确认手机已 root：

```bash
adb shell su -c 'id'
# uid=0(root) 才继续
```

---

## 1. VPS：起 NapCat

```bash
docker run -d --name napcat \
  --restart unless-stopped \
  -e NAPCAT_UID=1000 -e NAPCAT_GID=1000 \
  -p 3001:3001 \
  -p 6099:6099 \
  -v /opt/napcat/config:/app/napcat/config \
  -v /opt/napcat/.config/QQ:/app/.config/QQ \
  mlikiowa/napcat-docker:latest
```

- `6099` 是 WebUI（看二维码、看日志）
- `3001` 是 OneBot 11 的 HTTP/WS 端口

**扫码登录**：打开 `http://<你的VPS>:6099`，用手机 QQ 扫码。

> ⚠️ **手机 QQ 不能同时登录同一个号**。它会把 NapCat 顶下线，而且弹的是「下线通知」这种模板文案，看起来像封号，其实只是被顶。处置：`am force-stop com.tencent.mobileqq`（有时要两次）。

**配 OneBot**：编辑 `/opt/napcat/config/onebot11_<QQ号>.json`，把 WebSocket 服务端打开，并**设一个 access token**：

```json
{
  "network": {
    "websocketServers": [
      {
        "name": "dsh",
        "enable": true,
        "host": "0.0.0.0",
        "port": 3001,
        "token": "<自己生成一串>",
        "heartInterval": 30000,
        "reconnectInterval": 30000
      }
    ]
  }
}
```

改完 `docker restart napcat`。

**验证**（这一步千万别跳）：

```bash
pip install websocket-client
python - <<'EOF'
import websocket, json, time
ws = websocket.create_connection("ws://<VPS>:3001",
        header=["Authorization: Bearer <token>"], timeout=15)
ws.send(json.dumps({"action":"get_login_info","params":{},"echo":"t"}))
print(ws.recv())
EOF
```

返回里有 `"status":"ok"` 和你的 QQ 昵称，才算通。

---

## 2. 手机：让 proot 活起来

装 DSH App，打开一次，等它初始化完（会在 `/data/data/<包名>/files/linux/ubuntu` 下解出 rootfs）。

确认：

```bash
adb shell su -c 'ls /data/data/com.dsh.client/files/linux/ubuntu/root'
```

### 手工起 DSH

这一步是整套方案的核心。**不要用 `am start`**——App 内启动器在某些环境下执行 node 会失败（`libstdc++.so.6: cannot open shared object file`，退出码 127）。

写一个 `/data/adb/dsh-start.sh`：

```sh
#!/system/bin/sh
PLIB=/data/local/tmp/plib
ROOTFS=/data/data/com.dsh.client/files/linux/ubuntu
LIB=/data/app/<具体路径>/lib/arm64

export LD_LIBRARY_PATH=$PLIB:$ROOTFS/../lib:$LIB
export PROOT_LOADER=$LIB/libprootloader.so
export PROOT_LOADER_32=$LIB/libprootloader32.so
export PROOT_TMP_DIR=$ROOTFS/../tmp
export PROOT_L2S_DIR=$ROOTFS/.l2s

exec $PLIB/libproot.so --link2symlink -L --kill-on-exit -0 \
  --rootfs=$ROOTFS --cwd=/root \
  -b $ROOTFS/.l2s:$ROOTFS/.l2s \
  -b /dev -b /dev/urandom:/dev/random -b /proc -b /sys -b /system -b /apex \
  -b /proc/self/fd:/dev/fd -b /storage/emulated/0:/sdcard \
  /bin/bash -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; \
    export DSH_HOME=/root/.dsh; cd /root; \
    exec dsh web --no-open --host 127.0.0.1 --port 3080 >> /root/dsh-web.log 2>&1'
```

`<具体路径>` 从 `ls /data/app/*/com.dsh.client*/lib/arm64` 里取。

先手工跑一次，确认 3080 通了再往下：

```bash
adb shell su -c 'nohup setsid sh /data/adb/dsh-start.sh >/dev/null 2>&1 &'
sleep 20 && adb shell su -c 'ss -lntp | grep 3080'
```

---

## 3. 手机：装插件、指到你自己的 WS

插件是 `dsh-onebot-qq`。装好后改它的配置层（`/root/.dsh/profiles/web/cordis.patch.yml`）：

```yaml
- id: dsh-onebot
  config:
    mode: forward
    url: "ws://<你的VPS>:3001"
    accessToken: "<上一步设的 token>"
    adminUsers: ["<你的QQ号>"]
    botQQ: "<机器人QQ号>"
    dmPolicy: open
    groupPolicy: disabled
    workspacePath: "/root"
    # 入站图/语音的临时件保留多久（小时）。默认 6，太短，
    # 隔天想回看一张图就没了。
    tempTtlHours: 24
    interimRecall: false          # 中间消息留着，不撤回
    injectEnabled: true           # 允许心跳往会话里注入
    injectIntervalMs: 5000
    sttEnabled: true
    sttEngine: custom
    sttCommand: "/root/stt.sh"
    sttArgs: ["{file}", "{out}"]
```

改完重启 DSH。日志里看到这两行才算通：

```
[dsh-onebot] OneBot connected
[dsh-onebot] bridge ready (1 resumed chat(s))
```

---

## 4. 手机 root：把守护挂上

把 `host/` 下的脚本推到 `/data/adb/`，然后为每个脚本在 `service.d/` 里加一个启动壳：

```sh
#!/system/bin/sh
# /data/adb/service.d/99-dsh-heal.sh
nohup setsid sh /data/adb/dsh-heal.sh >/dev/null 2>&1 &
```

**顺序很重要**：先 `heal`（保证服务在），再 `budget`（避免一上来就烧钱），最后才是 `heartbeat` 这类主动行为。

每个脚本顶部都有它盯什么、频率多少的注释。**先只开 `heal` 一个，跑一天确认稳定，再加下一个。** 一次全开，出问题分不清是谁的锅。

### 权限与标签

`/data/adb/` 下的脚本需要：

```bash
chown root:root /data/adb/dsh-*.sh
chmod 755 /data/adb/dsh-*.sh
chcon u:object_r:adb_data_file:s0 /data/adb/dsh-*.sh
```

**改完任何脚本都要 kill 重启对应守护**——`sh` 不热加载。

---

## 5. 容器内：工具

把 `container/` 下的文件推到 `/root/`，改掉里面的路径占位符。

proot 里的文件属主必须是 app 的 uid，标签必须是带 MLS categories 的那个：

```bash
chown 10234:10234 /path/to/rootfs/root/say
chmod 755 /path/to/rootfs/root/say
chcon u:object_r:app_data_file:s0:c234,c256,c512,c768 /path/to/rootfs/root/say
```

（`10234` 是 `u0_a234`，用 `adb shell su -c 'stat -c %u /data/data/com.dsh.client'` 确认你自己的。）

**别把 root 属主的文件放进 `profiles/web/`**——插件热加载会 EACCES，界面会卡在「等待鉴权」。

---

## 6. 写它的说明书

`/root/AGENTS.md` 是它每轮都会读的说明。写清楚：

- 它是谁、怎么说话（语气、长度、什么时候该沉默）
- 它有什么工具、怎么用
- 哪些事不能做（改配置、删记忆、发敏感内容）
- 遇到不确定的事先问

这份文件会进每一轮的上下文，所以**越长越贵**。40KB 大概是上限——再长就该拆成按需读的子文档了。

---

## 7. 验收清单

按顺序过一遍，每一条都要能拿出证据：

- [ ] `ss -lntp | grep 3080` 有输出
- [ ] `dsh-web.log` 里有 `OneBot connected`
- [ ] `dsh-web.log` 里有 `bridge ready`
- [ ] 从 QQ 真发一条消息，能收到回复
- [ ] `kill -9` 掉 node，120 秒内自己起来（证明 heal 有效）
- [ ] 重启手机，服务能自己起来（证明 service.d 有效）
- [ ] `/root/status` 全部正常
- [ ] 备份能跑通，`sha256` 两端一致

> 最后一条最重要：**"能跑"和"挂了能自己回来"是两件事**。只验证前者，等于没验证。
