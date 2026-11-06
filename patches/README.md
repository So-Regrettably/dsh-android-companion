# 插件补丁

这两个文件是 [`dsh-onebot-qq`](https://www.npmjs.com/package/dsh-onebot-qq) 的两个小补丁。它们修的是**会真实伤害使用者**的问题，不是风格问题。

> ⚠️ **升级插件会覆盖 `lib/` 下的文件。** 升级后需要把这两个文件重新贴回去，然后重启 DSH。

---

## `split.js` — 别把标识符里的下划线当斜体

### 问题

出站文本会经过一层 Markdown 清洗，其中处理斜体的正则写的是：

```js
.replace(/(^|[^_])_([^_]+)_([^_]|$)/g, '$1$2$3')
```

它不分词边界，见 `_xxx_` 就剥。于是：

| 原文 | 清洗后 |
|---|---|
| `qq_send_image` | `qqsendimage` |
| `PLAY_MAX_EXTRA` | `PLAYMAXEXTRA` |
| `/root/.dsh/media/a_b_c.jpg` | `/root/.dsh/media/abc.jpg` |

最难受的是**你察觉不到**。AI 会照着被改坏的名字去调工具，失败了也只会说"工具不存在"；用户看到的是它把工具名记错了，实际上是下游把名字改了。

第三条更狠：文件名被改，照着这个路径去读文件会读到一个不存在的。

### 修法

加上词边界限制，并用反向引用保证 `_` 与 `__` 配对：

```js
.replace(/(^|[\s，。！？；：、（）()【】「」《》<>"'‘“])(_{1,2})([^_\n]+)\2(?=[\s，。！？；：、（）()【】「」《》<>"'’”]|$)/g, '$1$3')
```

只有下划线两侧是空白或标点时才算强调。

### 判断依据

聊天场景里几乎没人用 `_斜体_`，但标识符里的下划线到处都是。**为一个几乎用不上的功能破坏大量正常文本，是负收益。**

实测 5 个用例：

| 输入 | 输出 |
|---|---|
| `qq_send_image` | 原样 |
| `PLAY_MAX_EXTRA` | 原样 |
| `/root/.dsh/media/a_b_c.jpg` | 原样 |
| `他说 _斜体_ 啊` | `他说 斜体 啊` |
| `这是 **粗体** 文字` | `这是 粗体 文字` |

---

## `connection.js` — 一个 `close()` 能带走整个进程

### 问题

`stop()` 里原来是这样：

```js
socket.removeAllListeners();   // ← 连自己的 'error' 监听一起清了
try {
    socket.close();
} catch {
    // already closing
}
```

看起来没问题——`close()` 还有 try/catch 包着。

但 WebSocket 在 **CONNECTING 状态**下调 `close()` **不抛同步异常**，而是 `emit('error', Error('WebSocket was closed before the connection was established'))`。

而 `removeAllListeners()` 已经把 `error` 监听器一起清掉了。没人接的 `error` 事件，在 EventEmitter 里会**抛 uncaught exception**，直接杀掉进程。

`try/catch` 拦不住，因为异常不是在 `close()` 里同步抛的。

### 现象

DSH 每隔一段时间莫名消失。翻日志只看到一行：

```
dsh: fatal uncaught exception: Error: WebSocket was closed before the connection was established
    at WebSocket.close (…/ws/lib/websocket.js:319:7)
    at OneBotConnection.stop (…/lib/connection.js:191:24)
```

然后靠守护脚本拉起来。看起来像"偶发崩溃"，实际是每次停止插件时都可能触发。

### 修法

顺序反过来：

```js
socket.on('error', () => { });   // 先挂一个吞异常的空监听
try {
    socket.close();
} catch {
    // already closing
}
socket.removeAllListeners();     // close 之后再清理
```

---

## 通用教训

这两个 bug 都不是"逻辑写错了"，而是**顺序**和**边界**没考虑到：

- **清洗与分块**：先分条再清洗，跨越边界的结构就匹配不到了
- **关闭与清理**：先清监听再关闭，关闭过程中发出的事件就没人接

任何"先 A 后 B"的管线，都值得问一句：**A 的产物会不会破坏 B 依赖的前提？**
