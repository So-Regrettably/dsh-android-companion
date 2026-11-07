# 踩坑清单

> 20 条，每条都是真事。格式统一：**现象 → 原因 → 修法**。
>
> 这些坑分两类：一类会让你判断错（以为坏了其实没坏，或者以为好了其实没好），一类会真的把东西弄坏。第一类更多，也更难查。

---

## A 类：会让你判断错的

### 1. `ps -A -o NAME | grep dsh-` 永远是 0

**现象**：查守护进程，15 个全部显示不在跑，以为全挂了。

**原因**：Android 的 toybox `ps`，`NAME` 列只显示解释器名（`sh`），不显示脚本名。grep 永远匹配不到。

**修法**：读 `/proc/PID/cmdline`：

```sh
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
  case "$c" in *dsh-*) echo "$p $c";; esac
done
```

同理，**kill 完也要用这个复核**，别信 `kill` 的返回码。

### 2. `free -m` 显示只剩 211MB，其实还有 2.3GB

**现象**：`free` 显示 free 211MB，以为内存爆了，准备清后台。

**原因**：Linux 会拿空闲内存做缓存（Cached 2.36GB）。`free` 的 free 列不含可回收缓存。

**修法**：看 `MemAvailable`：

```sh
grep MemAvailable /proc/meminfo
```

Android 上 `free` 根本不显示 available 这一列，所以别用它判断内存压力。

### 3. 日志里消息断在半句，以为入站被截断了

**现象**：日志里 `followup from ...` 的正文停在半句话，看着像消息被切了，差点去改入站解析。

**原因**：日志打印写的是 `final.slice(0, 120)` —— **只打前 120 个字符**。真消息完整到达。

**修法**：怀疑"内容被截断"时，去源头核对。用 OneBot 的 `get_friend_msg_history` 把历史消息拉出来逐字比对。**日志是给人看的摘要，不是事实记录。**

### 4. 应用密码在 PHP 脚本里校验永远 FAIL

**现象**：写了个 PHP 探针调 `wp_authenticate_application_password()`，输入正确的应用密码，永远返回 `NULL`，以为密码错了。

**原因**：WordPress 的这个函数第 400 行左右有这么一段：

```php
$is_api_request = ( XMLRPC_REQUEST || REST_REQUEST );
if ( ! $is_api_request ) {
    return $input_user;   // 直接回传输入值（null）
}
```

**它只对 REST / XML-RPC 请求生效。** 普通页面调用它，无论密码对错都返回 null。

**修法**：别用 PHP 页面测。直接打 REST：

```bash
curl -u "USER:APP_PASSWORD" https://site/wp-json/wp/v2/users/me
```

### 5. 用截图 OCR 转写应用密码，一定出错

**现象**：WordPress 生成应用密码后截图，转写成 24 位字符，认证一直 401。

**原因**：应用密码里有大量 `ssr1` / `l/r` / `DtW4` 这类易混字符。肉眼和 OCR 都会看错，而且**看不出自己看错了**（格式完全正确，长度也对）。

**修法**：不要经过截图。在服务器上直接生成并打印明文：

```php
list($plain, $item) = WP_Application_Passwords::create_new_application_password(
    $uid, array('name' => 'ci-publisher')
);
echo $plain;
```

---

## B 类：配置改了但没生效

### 6. `nginx -s reload` 不会重新绑定 listen

**现象**：把 `listen 888` 改成 `listen 127.0.0.1:888`，`nginx -t` 通过，`reload` 成功，但 `ss -lntp` 一看还是 `*:888`。

**原因**：`reload` 只重启 worker，**监听 socket 由 master 持有**，listen 指令的变更需要完整重启才生效。

**修法**：

```bash
/etc/init.d/nginx restart     # 不是 reload
```

**教训**：这一条差点让我报"改好了"。**改完必须用 `ss` 复核实际绑定，不能只看配置文件。**

### 7. 宝塔的 `enable-php.conf` 不传 `Authorization` 头

**现象**：WordPress 应用密码、任何 REST API 的 Basic Auth 全部 401，报 `rest_not_logged_in`（不是"密码错误"）。

**原因**：宝塔默认的 PHP location 块只 `include fastcgi.conf`，没有 `HTTP_AUTHORIZATION` 的传递。PHP 里 `$_SERVER['HTTP_AUTHORIZATION']` 是空的，WordPress 收不到凭据。

**修法**：在 `/www/server/nginx/conf/enable-php.conf` 的 location 块里加一行，然后**完整重启 nginx**：

```nginx
fastcgi_param HTTP_AUTHORIZATION $http_authorization;
```

### 8. 改了 `/data/adb/*.sh` 不重启，改动不生效

**现象**：改完守护脚本，等了几分钟发现行为没变。

**原因**：`sh` 不热加载。脚本已经在内存里跑着，改文件对运行中的进程没有任何影响。

**修法**：`kill` 掉对应守护，用 `nohup setsid sh ... &` 重新拉起。**然后用 `/proc` 复核实例数**——`kill`（默认 TERM）有时不生效，`nohup` 又起了新的，会出现两个实例同时跑，各自做一遍备份/清理。

### 9. `kill` 返回 0 不代表进程死了

**现象**：`kill 2263` 之后 `nohup setsid` 重启，结果两个 maintenance 实例同时在跑，日志里备份动作出现两次。

**原因**：SIGTERM 可能被忽略，或进程正卡在不可中断的等待里。

**修法**：用 `kill -9`，并且**用 `/proc` 遍历确认实例数**，不要看返回码。

---

## C 类：Android / proot 特有的

### 10. proot 里 `apt install` 之后 node 报找不到 `.so`

**现象**：容器里装完包，`node` 突然报 `libstdc++.so.6: cannot open shared object file`，proot 退出码 127。装之前好好的。

**原因**：SELinux 上下文。root 身份解压出来的文件被标成 `u:object_r:app_data_file:s0`（**没有 MLS categories**），而 app 域的进程是 `u:object_r:app_data_file:s0:c234,c256,c512,c768`。内核直接拒绝，但报的错是"找不到文件"。

**修法**：把新装的文件全部重标：

```bash
find $ROOTFS -newerct "装包时刻" -type f -exec \
  chcon u:object_r:app_data_file:s0:c234,c256,c512,c768 {} +
```

⚠️ **符号链接必须单独处理**：`find -type f` 修不到链接本身，而 `libstdc++.so.6` 正是一个链接：

```bash
find ... -type l -exec chcon -h u:object_r:app_data_file:s0:c234,c256,c512,c768 {} +
```

### 11. `su -c` 的环境里没有 `/system/bin`

**现象**：`su -c 'ls'` 报 `ls: inaccessible or not found`。

**原因**：`su -c` 不继承调用者的 PATH。

**修法**：要么写绝对路径，要么显式 `export PATH=/system/bin:$PATH`。

### 12. `am start` 不会自动把 proot 拉起来

**现象**：`force-stop` 之后 `am start` 启动 App，界面显示「DSH 未运行」，服务起不来。

**原因**：App 内的启动器在某些环境（装过 ffmpeg 之后）执行 node 会失败，而 App 不会降级到 shell 方式。

**修法**：别用 `am start` 等它自己好。直接走 root 侧的 `dsh-start.sh`（libproot 手工起）。同时要清掉 App 的「恢复模式」标记，否则界面会一直停在恢复页：

```bash
sed -i 's|name="web_startup_recovery_requested" value="true"|...value="false"|' \
  /data/data/<pkg>/shared_prefs/<prefs>.xml
```

### 13. 批量 `pm disable-user` 会杀掉宿主进程

**现象**：批量禁用几个包之后，DSH 的会话 id 变了，上下文全断。

**原因**：包变更会触发 `dsh.android.client` 重启。

**修法**：不要批量。一次一个，禁完观察。`com.xiaomi.market` 这类 MIUI 核心包禁不掉，别浪费时间去试。

### 14. 容器里 `getHours()` 拿到的是 UTC

**现象**：定时任务在北京时间凌晨 8 点触发，而不是晚上 8 点。

**原因**：容器没有 tzdata，`TZ` 是 UTC。`date`、`getHours()`、`toLocaleString()` 全部按 UTC 走。

**修法**：统一按「`Date.now() + 8h` 之后读 `getUTC*`」处理。`date` 命令同理：

```bash
date -u -d "today 08:00" +%s      # 拿北京时间早八点的时间戳
```

---

## D 类：真的会把东西弄坏的

### 15. 先分条再清洗，原文整段漏出去

**现象**：它会把你发给它的原文复述回来，外面还包着 `<user_message>` 标签。第一版修法是"剥标签"，结果标签没了、原文照样发出来。

**原因**：两处叠加。

1. 只删标签不删正文 → 内容还在
2. 改成整块删之后，**清洗发生在分条之后**：如果标签正好落在两条消息的边界上，每一条单独看都匹配不到完整的 `<user_message>...</user_message>`，正则失效

**修法**：**把清洗挪到分条之前**，对整段洗一遍，再切。每块发送前保留一道边界清洗当第二道网。

**通用教训**：任何"先切分再处理"的管线，都要问一句——**有没有跨切分边界的结构？**

### 16. Markdown 清洗把标识符里的下划线当斜体吃掉

**现象**：AI 在回复里说"要发图就调 `qqsendimage`"。以为它记错了工具名，其实是清洗代码改坏的。

**原因**：这条正则：

```js
.replace(/(^|[^_])_([^_]+)_([^_]|$)/g, '$1$2$3')
```

它见 `_xxx_` 就当斜体剥。于是：

| 原文 | 清洗后 |
|---|---|
| `qq_send_image` | `qqsendimage` |
| `PLAY_MAX_EXTRA` | `PLAYMAXEXTRA` |
| `/root/.dsh/media/a_b_c.jpg` | `/root/.dsh/media/abc.jpg` |

第三条最要命——**文件名都变了**，照着这个路径去读文件会读到一个不存在的。

**修法**：加上词边界限制，并用反向引用保证 `_` 和 `__` 配对：

```js
.replace(/(^|[\s，。！？；：、（）()【】「」《》<>"'‘“])(_{1,2})([^_\n]+)\2(?=[\s，。！？；：、（）()【】「」《》<>"'’”]|$)/g, '$1$3')
```

**判断**：聊天场景里几乎没人用 `_斜体_`，但标识符里的下划线到处都是。为一个几乎用不上的功能破坏大量正常文本，是负收益。

### 17. `removeAllListeners()` 在 `close()` 之前，能带走整个进程

**现象**：DSH 每隔一段时间莫名消失，日志里只有一行 `fatal uncaught exception`，栈指向 `WebSocket.close`。

**原因**：

```js
socket.removeAllListeners();   // ← 连自己的 'error' 监听一起清了
try { socket.close(); } catch {}
```

WebSocket 在 **CONNECTING** 状态下调 `close()` **不抛同步异常**，而是 `emit('error', Error('WebSocket was closed before the connection was established'))`。监听器已被清空 → 没有 error handler → EventEmitter 抛 uncaught → 进程退出。

`try/catch` 拦不住，因为异常不是在 `close()` 里同步抛的。

**修法**：顺序反过来。

```js
socket.on('error', () => { });   // 先挂一个吞异常的空监听
try { socket.close(); } catch {}
socket.removeAllListeners();     // close 之后再清理
```

### 18. 清理脚本按目录整体扫，会删掉别人的文件

**现象**：一批 TTS 语音副本突然消失，怀疑有脚本在清 `media/`。

**原因**：两个来源叠加。

1. 插件有个 6 小时的 TTL，按前缀白名单清 `media_*` / `stt_*`（这个是**对的**，状态文件不受影响）
2. 自己的 TTS 脚本把副本放进同一个目录，然后**自己也做数量上限**，只留 8 条 —— 一次批量生成就淘汰一批

**修法**：清理永远用**前缀白名单**，不要按目录整体扫。自己的工具管好自己的文件。判断"谁删了我的东西"时，先看目录里有哪些前缀、各自归谁。

### 19. heredoc 喂给 `ssh`，第一个命令吃掉剩下的脚本

**现象**：备份脚本里 `ssh` 之后 `scp` 没执行，但整个脚本返回 0，看起来"成功"。

**原因**：内层脚本从 stdin 喂给 `bash`，第一个 `ssh` 把剩下的 stdin 全读走了，后面的 `scp` 根本没跑。

**修法**：内层脚本**落成文件再执行**，`ssh` 加 `-n`（不读 stdin），`scp` 加 `</dev/null`。外层只认真正的产物（比如 `RSHA=` / `LEFT=` 这种机器可读的输出），不要看返回码。

### 20. 加了参数但没实现，等于没加

**现象**：给一个检查命令加了 `--timeout 3`，用了一个月都以为生效了。

**原因**：参数被解析了，但函数里从来没读过它。默认值一直用着。

**修法**：**每加一个参数，都要做一次"它真的改变了行为"的验证**。比如加 `--timeout`，就把超时设成 0 秒，看是不是真的立刻返回。同理还有 `--id-only`：过滤后才判断，等于没实现。

---

## 最后一条，不是坑但最重要

**不要相信"它自己说成功了"。**

本文里至少 6 条属于同一类：判断的依据是结构（进程在、返回 0、日志有行、配置改对了），而不是内容（真的能发、真的能读、真的绑上了）。

所以每次改完，问自己一句：**"我能拿出什么证据证明它现在真的在按我想的方式工作？"** 拿不出来，就是还没改完。
