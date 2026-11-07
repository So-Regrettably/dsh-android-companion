# DSHA 升级 0.2.0-rc.2 → 0.2.1-rc.2

> 2026-11-07 完成。旧版 App 界面损坏，换新包名重装，全量迁移数据 + 系统依赖。

## 为什么要升

旧版 `com.dsh.client`（v0.2.0-rc2）App 界面坏了：内置 Python 解压器逐个撞 317 个符号链接
（`libsqlite3.so.0` FILE/LINK 冲突），报 `BUNDLED_PYTHON_UNAVAILABLE`。根因是 APK Java 层的
误报（proot 里 `python3.12` 实际能跑），外面改不了 → 只能换新版。

## 关键变化

| 项 | 旧版 | 新版 |
|---|---|---|
| 包名 | `com.dsh.client` | `dsh.android.client`（可共存） |
| 版本 | 0.2.0-rc.2 (build170) | 0.2.1-rc.2 (build190) |
| Web 端口 | 固定 3080 | **固定 38571**（`web_fallback_port`） |
| uid | u0_a234 (10234) | u0_a264 (10264) |
| SELinux | `c234,c256,c512,c768` | `c8,c257,c512,c768` |
| 插件配置 | onebot.conf | profiles/web/cordis.patch.yml 的 `dsh-onebot` 条目 |

## 来源

GitHub `DSH-APP/DSHA`：`github.com/DSH-APP/DSHA/releases`。APK `dsha-0.2.1-rc.2.apk` 278.66MB，
SHA-256 `d62f17f23a7949f0f25285ec7afa44cb35de24a6bc91887ba4600023d18ffee0`。

下载走系统代理（`curl --proxy http://127.0.0.1:7897`，41MB/s）；`pm install` 要先
`cp` 到 `/data/local/tmp/`（直接装 `/sdcard` 报 SELinux denied）。

## 迁移清单

### 数据（/root）—— 「新版没有的才迁」策略
- 人设 AGENTS.md / AGENTS.local.md、memory/、diary/、models/（512MB 三模型）、.ssh/、全部脚本
- .dsh：plugin-src/（QQ 插件 + 补丁）、media/（chat-sessions 映射）、sessions/、voices/、reminders/

### 系统依赖（★ 最容易漏，rootfs 里的 apt/pip 安装不会自动迁）
1. **ffmpeg**（STT 重采样）—— 二进制 + 417 个 .so + pulseaudio/blas/lapack 子目录
2. **pip 包** `/usr/local/lib/python3.12/dist-packages`（385MB）—— numpy/requests/vosk/sherpa_onnx/onnxruntime
3. **系统 pip 包** `/usr/lib/python3/dist-packages`（39 项）—— cffi 的 `_cffi_backend`、cryptography、adb_shell_wifi
4. **edge-tts** 等命令、**simhei.ttf** 字体

### 插件启用（新版 bundles 里没有第三方插件）
- 改 `profiles/web/package.json`：dependencies + bundles 加 `dsh-onebot-qq`、`dsh-meme`
- 建 `profiles/web/node_modules/{dsh-onebot-qq,dsh-meme}` 符号链接 → `../../../../.dsh/plugin-src/xxx`
- 复制旧版 `cordis.patch.yml`（含 mode:forward + url + token + botQQ + stt + font 配置）
- API key：旧版 `refs.DSHA_DEEPSEEK_OFFICIAL_API_KEY` 合并进新版 `.credentials.yaml`

## 踩坑记录

1. **连接配置**：新版插件默认 `reverse` 模式 + 空 accessToken 会报错，必须用 cordis.patch.yml
   显式指定 `mode: forward`。
2. **ffmpeg 依赖链极深**：libraw1394 → librom1394 → libpulsecommon → libblas/liblapack，
   逐个补很费劲，用 `ldd /usr/bin/ffmpeg | grep "not found"` 一次性定位。
3. **端口僵尸**：`nohup` 起的 proot 不受 `am force-stop` 控制，会占端口导致 App 报
   "环境任务正在执行"。迁移后先 force-stop 清僵尸，再让 App 接管。
4. **会话文件 5.4MB 未迁移**：旧会话（10-29 起，幻觉根因）不搬，换新会话。

## 守护脚本适配

- 全部 `/data/adb/*.sh`：`com.dsh.client` → `dsh.android.client`、`3080` → `38571`、`u0_a234` → `u0_a264`
- `dsh-start.sh` 重写：动态定位 lib 路径 + 完整新版启动命令（DSHA_STARTUP_PROFILE 等环境变量）
- `dsh-heal.sh` 重写：检测 38571 → 唤起 App + 点「重试启动」(540,1265) → proot 兜底
- 备份在 `/data/adb/backup-scripts-1107/`

## 权限拉满

无障碍（已自动开启）、MANAGE_EXTERNAL_STORAGE、SYSTEM_ALERT_WINDOW、RECORD_AUDIO、
电池白名单（`dumpsys deviceidle whitelist +dsh.android.client`）、RUN_IN_BACKGROUND。
