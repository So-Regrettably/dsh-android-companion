# dsh-android-companion

> 在一台普通 Android 手机上，跑一个 7×24 不下线的 AI 伴侣——通过 QQ 和你说话，能自己看屏幕、点应用、发语音，还会在半夜自己写日记。

这不是一个"手机上跑大模型"的项目。模型在云端（DeepSeek），手机做的是：**让它活着、让它能感知、让它能动手、让它不烧钱**。

> **当前版本**：DSHA 0.2.1-rc.2（包名 `dsh.android.client`，Web 端口 38571）。升级过程见 [docs/upgrade-0.2.1.md](docs/upgrade-0.2.1.md)。

---

## 它长什么样

```
┌─────────────────────────── Android 手机 ───────────────────────────┐
│                                                                    │
│  ┌── 宿主机（root）──────────────┐   ┌── proot 容器 ────────────┐  │
│  │                               │   │                          │  │
│  │  Magisk + service.d           │   │  Ubuntu rootfs           │  │
│  │    15 个守护脚本              │   │    ├── dsh web (:38571)   │  │
│  │      ├ dsh-heal    端口自愈   │   │    ├── 插件 dsh-onebot   │  │
│  │      ├ dsh-remind  提醒/看门狗│   │    ├── /root/say  (TTS)  │  │
│  │      ├ dsh-budget  预算熔断   │   │    ├── /root/stt.py(STT) │  │
│  │      ├ dsh-heartbeat 主动开口 │   │    ├── /root/screen 看屏 │  │
│  │      ├ dsh-maintenance 备份   │   │    └── /root/AGENTS.md   │  │
│  │      ├ dsh-cron / outbox      │   │                          │  │
│  │      └ dsh-key / screen 代理  │   │  它在这里读写、思考、说话 │  │
│  └───────────────┬───────────────┘   └────────────▲─────────────┘  │
│                  │ adb / am / screencap           │ WebSocket      │
│                  └────────────────────────────────┘                │
└───────────────────────────────────┬────────────────────────────────┘
                                    │ WebSocket (OneBot 11)
                         ┌──────────▼──────────┐
                         │  VPS（Docker）      │
                         │    NapCat ←→ QQ     │
                         └──────────┬──────────┘
                                    │
                               ┌────▼────┐
                               │  手机QQ │
                               │ （你）  │
                               └─────────┘
```

为什么中间要隔一台 VPS：手机 IP 会变、会被 NAT、会断网。VPS 有固定地址，两端重连都往那一头连。**手机只负责生产消息，VPS 只负责和 QQ 通信。**

---

## 四个核心问题，和它们的答案

这套东西真正的难点不在"接上 QQ"——那是一个下午的事。难的是下面四件。

### 一、怎么让它不死

Android 会杀后台。DSH 跑在 proot 容器里，容器随 App 进程一起死。

**做法：不依赖 App 的生命周期。**

用 Magisk 的 `service.d` 起一组 root 侧守护脚本，每个脚本盯一件事：

| 脚本 | 频率 | 管什么 |
|---|---|---|
| `dsh-heal` | 120s | 端口 38571 没了就用 libproot 手工拉起 |
| `dsh-remind` | 30s | 提醒队列、内存守护、卡死看门狗、收工/换会话 |
| `dsh-budget` | 10min | 重读额度、写账本、超限熔断 |
| `dsh-heartbeat` | 可变 | 主动开口的节奏与准入 |
| `dsh-maintenance` | 1h | 属主/SELinux 自愈、备份、日志轮转、会话归档 |
| `dsh-cron` | 20s | 定时任务闸门 |
| `dsh-outbox` | 20s | 发送失败的重试队列 |

关键细节：**`dsh-heal` 起 DSH 不用 `am start`**。因为装完 ffmpeg 之后，App 内启动器执行 node 会报 `libstdc++.so.6: cannot open shared object file`（proot 退出码 127），而 shell 手工起的 proot 一切正常。所以自愈走 `/data/adb/dsh-start.sh`：

```sh
export LD_LIBRARY_PATH=$PLIB:$ROOTFS/../lib:$LIB
export PROOT_LOADER=$LIB/libprootloader.so
export PROOT_TMP_DIR=$ROOTFS/../tmp
export PROOT_L2S_DIR=$ROOTFS/.l2s
exec $PLIB/libproot.so --link2symlink -L --kill-on-exit -0 \
  --rootfs=$ROOTFS --cwd=/root \
  $BINDS /bin/bash -c '... exec dsh web --host 127.0.0.1 --port 38571'
```

**判断"活着"不能只看进程在不在。** 最有用的一条判据是「日志还在不在长」——进程活着但不干活（CPU 空转、无输出）是最难发现的状态。所以看门狗盯的是：

```
turn/end 不来  +  日志 5 分钟不增长  +  CPU 空转  →  先重启
15 分钟内再犯  →  轮换会话
```

### 二、怎么让它能看见、能动手

早期方案是截图丢给模型，让它看图猜坐标。**这条路又慢又贵又容易错**：一张 PNG 8.9MB、3.2 秒，模型还得从画面里"量"出坐标来。

现在是**读控件树**：

```
uiautomator dump → 解析 XML → 每个可点控件带 text / resource-id / bounds
```

模型拿到的是文本（200~1300 token），坐标是界面自己给的，不是猜的。同一台设备上，读界面的耗时从 350ms 降到 120ms，token 省 60~85%。

两个必须知道的实操细节：

- **`input tap x y` 的按压时间太短，很多页面不认**。同一组坐标换成 `input swipe x y x y 100`（100ms 按压），成功率立刻不一样。这条能解释一大半"坐标明明对了但点了没反应"。
- **全屏遮罩会让所有点击失灵**。有些 App 一打开就弹签到/活动遮罩，点击被吃掉，而遮罩本身没有文字。所以点之前要先检测「有没有一个全屏的、可点的、无文字的最上层节点」。

### 三、怎么让它像个人

这一块全是细节，没有一处是"架构"层面的。

**长回复必须分条，而且要像人一样分。** 硬切 200 字 + 0ms 间隔，读起来像机器。实际参数是：

```
单条上限    120 字
基础停顿    900ms
每字追加    25ms
停顿封顶    4500ms
再叠抖动    0~600ms
```

一条 40 字的消息停 1.9 秒，一条 110 字的停 3.6 秒——**字数越多停越久**，因为人打完一段长话确实要更久。抖动是为了避免"每条都精确 3.6 秒"的机械感。

**想沉默的时候，真的什么都别输出。** 不给它"（无）""（空）""silence"这种占位符——出站管线里专门有一层过滤，这类整条丢弃。

**心跳要克制。** 主动开口有配额：工作日 40~46 分钟一次，周末 43~49 分钟；闲聊 15 次/天、玩 6 次/天；工作日 17 点前不打扰。宁可少说，不要为了热闹硬找话。

### 四、怎么让它不烧钱

单轮价格随上下文长度**线性**上涨。实测数据：

| 会话大小 | 单轮成本 |
|---|---|
| 1 MB | ¥0.12 |
| 2 MB | ¥0.22 |
| 3.4 MB | ¥0.33（**且请求开始挂起**） |

3.4MB 那档会进入一个很恶心的状态：`followup` 有、`turn/end` 不来、CPU 0%、连接还在但没有数据。不是报错，是"卡住"。

所以有两条硬机制：

1. **每天 05:00 换会话**（先备份 `chat-sessions.json`，然后清空重启）。新会话单价锁在最低档，一天总成本约 ¥0.1。
2. **预算熔断**：9 元写 ALARM + 注入提醒，10 元写 BRAKE + `force-stop`，次日 08:00 自动解。当日临时额度写 `override` 文件，日期不匹配自动失效。

> ⚠️ 额度必须**每轮重读**。踩过一次：`load_limits()` 只在启动时读一次，结果放宽额度跑了两天都没生效。

---

## 快速开始

这不是一个 `npm install` 就能跑的项目——它假设你有一台已经 root 的小米手机、一个能跑 Docker 的 VPS、以及一个愿意被 AI 用的 QQ 号。

```
前置条件
├─ Android 8.0+，已 root（Magisk），装了 DSH App
├─ VPS 一台（1C1G 够用），能跑 Docker
└─ 一个 QQ 小号（建议，别用主号）
```

步骤概要，详细见 [docs/deploy.md](docs/deploy.md)：

1. **VPS**：`docker run` 起 NapCat，配 OneBot 11 反向/正向 WS，扫码登录
2. **手机**：装 DSH App，跑一次让它把 proot 解出来
3. **手机**：装 `dsh-onebot-qq` 插件，改 `cordis.patch.yml` 指向你的 WS
4. **手机 root**：把 `host/` 下的脚本推到 `/data/adb/`，`service.d` 里挂上自启
5. **容器内**：把 `container/` 下的工具推到 `/root/`，改掉里面的路径占位符
6. **收尾**：写 `/root/AGENTS.md`（它的说明书），重启，验证

---

## 这个仓库里有什么

```
.
├── README.md                  ← 你正在看的
├── docs/
│   ├── architecture.md        架构与数据流，每个判断的理由
│   ├── deploy.md              从裸机到能聊天的完整步骤
│   ├── pitfalls.md            ★ 20 条踩坑记录，每条都有现象和修法
│   └── cost.md                token 成本实测与控制手段
├── host/                      宿主机（Android root）守护脚本
│   ├── dsh-heal.sh            端口自愈
│   ├── dsh-remind.sh          提醒 / 内存 / 看门狗
│   ├── dsh-maintenance.sh     自愈 / 备份 / 轮转 / 宿主快照
│   └── service.d/             启动挂载
├── container/                 proot 容器内的工具
│   ├── say                    TTS，三档逐级回落
│   ├── stt.py                 STT，三档逐级回落
│   ├── imgfind.py             归档图片的检索与取回
│   └── status.py              一条命令看全身
└── patches/                   给上游插件的补丁（附理由）
    ├── split.js               Markdown 清洗：别把标识符里的下划线当斜体
    └── connection.js          WebSocket 关闭顺序：一个 uncaught 能带走整个进程
```

---

## 三条通用经验

写这套东西踩了太多坑，但如果只能带走三条：

**1. 判断成功要看内容，不要看结构。**

这一类 bug 我统称"假成功"。几个真实的例子：

- 授权守护脚本把坐标点在了"模型配置"页，而它的成功判据是"能读到自己的界面"——于是永远成功
- 云备份脚本用 heredoc 喂 stdin，第一个 `ssh` 把剩下的脚本吃掉了，`scp` 根本没跑，但返回码是 0
- 日志里一条命令输出 `[ERR]`，而判据写的是 `grep -q OK || echo ERR`，顺序反了，错误被当成成功

**每加一个参数都要实测它真的改变了行为。** 我加过一个 `--timeout`，从头到尾被静默忽略，用了一个月才发现。

**2. 清理类脚本，先想清楚"谁的文件"。**

`/root/.dsh/media/onebot/` 这一个目录里躺着五种东西：入站图片、TTS 副本、会话状态、注入队列、审计日志。它们的生命周期完全不同。

所以清理必须**白名单前缀**，不能按目录整体扫：

```js
// 只删自己造的，状态文件必须活着
if (!name.startsWith('media_') && !name.startsWith('stt_')) continue;
```

同理，`/root/say` 把语音副本放进这个目录时，自己也要管好上限——否则它会成为"我的语音怎么被删了"的元凶（这条真踩过）。

**3. 顺序比逻辑更容易错。**

两个真实的顺序 bug：

- **清洗和分条**：先分条再清洗，跨越分条边界的 `</user_message>` 就匹配不到了，整段原文漏出去。必须**先清洗再分块**。
- **关连接和清监听**：先 `removeAllListeners()` 再 `close()`，而 `close()` 在 CONNECTING 状态下会 `emit('error')`——没有监听器，uncaught，进程直接死。必须**先挂 error 兜底再 close**。

---

## 免责与合规

- 这是个人自用项目的记录，**不是产品**。它依赖第三方服务（DeepSeek API、QQ），随时可能因为对方改动而失效。
- 用 QQ 机器人请遵守腾讯的服务条款。**建议用小号**，做好随时被封的准备。自动化操作个人账号存在风险，本项目不对此负责。
- 手机 root 有风险，请自行评估。脚本里涉及 `force-stop`、`pm disable` 的地方都写了原因，动手前请读完。
- 仓库内所有配置示例均为占位符，**不包含任何真实凭据**。

## License

MIT。随便用，出事别找我。
