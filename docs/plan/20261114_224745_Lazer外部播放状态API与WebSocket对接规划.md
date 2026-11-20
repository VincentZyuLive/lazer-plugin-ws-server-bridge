# Lazer 外部播放状态 API 与 WebSocket 对接规划

> 撰写时间：2026-11-14 22:47:45 (UTC+08:00)
> 涉及仓库：`Lazer`（待提 PR）、`splayer-status-html-overlay-for-obs`（消费端）
> 状态：**规划稿，未开始实现**

---

## 1. 背景与目标

OBS 直播挂件、桌面小组件、歌词覆盖层这类消费端，需要实时读取播放器的：

- 当前曲目（歌名 / 歌手 / 专辑 / 封面 / 时长）
- 播放状态（playing / paused / idle）、进度位置、音量
- 结构化歌词（逐行、逐字、翻译）

Lazer 目前**没有任何对外暴露播放状态的方式**：

- 系统媒体控制（Windows SMTC / Linux MPRIS / macOS NowPlaying）只有歌名与播放状态，**没有歌词、没有精确进度、没有封面原图**
- `lib/tv/lan_remote.dart` 已经起了一个 `HttpServer`，但它绑定在「大屏模式 + 遥控页」这个产品场景上，只服务内置遥控页面，不对外开放

目标：给 Lazer 上游提一个 PR，新增**应用级**外部 API（HTTP + WebSocket），协议字段与现有主流播放器的外部 API 既有约定保持一致，使现有 OBS 挂件零改动或极小改动即可对接。

### 非目标（明确排除）

- ❌ 不做 Lua 插件能力。插件 VM 是刻意收窄的沙箱（禁 `io` / `os` / 端口 / 进程），给它开服务器会破坏安全模型，维护者不会接受。
- ❌ 不支持 Android / iOS / Web。见 §4。
- ❌ 不做远程公网访问。默认仅 loopback。

---

## 2. 生态调研（协议事实标准）

三份实现互为兼容，可视为事实标准：

| 参考 | 形态 | HTTP 端点 | WS 地址 | 门控方式 |
| --- | --- | --- | --- | --- |
| 参考 A（Electron 播放器） | Node `hono` + `ws` | `/api/{info,status,volume,now-playing,lyrics,play,pause,stop,seek,volume,next,prev}` | `/ws` | `enabled` 总开关 + `wsEnabled` 子开关 |
| 参考 B（Go 播放器） | `net/http` + `gorilla/websocket` | 同上（逐字对齐） | `/ws` | `enable` + `enableWs` + `allowLan` |
| 消费端（本项目 overlay） | 纯浏览器 | 轮询 `/api/status`、`/api/now-playing`、`/api/lyrics` | 订阅 `/ws` | — |

**结论：端点与消息格式已经是既成事实，Lazer 只需照做。**

### 2.1 两参考在 CORS 上的分歧（重要）

| 项 | 参考 A | 参考 B |
| --- | --- | --- |
| HTTP `Access-Control-Allow-Origin` | **不设置** | `*` |
| WS `Origin` 校验 | **无**（只查开关） | **有** `allowedOrigin()` |
| 安全性依赖 | 默认仅监听 `127.0.0.1` | 默认仅监听 `127.0.0.1` |

**Lazer 的取舍：采用 B 的 Origin 白名单 + A 的双开关。** 理由：

1. 消费端可能是 `file://` 打开的本地 HTML，也可能是 `http://localhost:端口` 起的页面，必须有 `*` 或明确的来源允许列表，否则 CORS 直接拦住。
2. 但 `*` 配合「无 Origin 校验」会让任意网页在用户开启功能后都能读播放状态，因此 WS 升级前必须校验 `Origin`，HTTP 也走同一套判定。

---

## 3. Lazer 侧可行性

### 3.1 已有可复用骨架

`lib/tv/lan_remote.dart` 已实现一整套生产级模式，**照抄结构即可**：`HttpServer.bind` + 端口生命周期（`_start()`，改成范围循环）、opt-in 开关与 SharedPreferences 持久化（`initialize` / `setEnabled`）、`_reconcile()` 状态收敛（含启用/禁用竞态）、`snapshot` 序列化、`command(Map)` 的 8 个 case、`_handle()` 的 try/catch/finally 兜底，以及 `test/lan_remote_test.dart` 的 3 个真实 loopback 用例范式。

### 3.2 `AppState` 数据齐备（零新增字段）

`lib/state/app_state.dart` 现有公开成员：

| 协议需要的字段 | Lazer 来源 | 备注 |
| --- | --- | --- |
| 曲目 id | `state.current?.id` | |
| 曲目标题 | `state.current?.title` | |
| 歌手列表 | `state.current?.artists` | `List<MusicArtist>`（含 id/name） |
| 专辑名 | `state.current?.album` | |
| 专辑 id | `state.current?.albumId` | |
| 时长 | `state.current?.duration` | `Duration` |
| 封面 | `state.current?.coverUrl` | |
| 播放位置 | `state.precisePosition` | **优先于此**：含 seek 乐观值 |
| 播放中 | `state.playing` | `bool` |
| 音量 | `state.volume` | `double` 0…1 |
| 歌词 | `state.lyrics` | `List<LyricLine>` |
| 当前行 | `state.currentLyricLine` | 二分查找已实现 |

`LyricLine` 结构（`lib/lyrics/lyric_document.dart`）：

```dart
class LyricLine {
  final Duration time;          // 行起始
  final String text;
  final String? translation;    // 翻译行
  final List<LyricWord> words;  // 逐字
  final Duration? end;          // 行结束（可选）
}
class LyricWord { final Duration start; final Duration duration; final String text; }
```

> 逐字比参考实现更强（有 `duration` 而非仅有起止），映射时换算成 `{word, startTime, endTime}`。

### 3.3 刷新节流现成参考

- `AppState.playbackInterval = Duration(milliseconds: 100)`（`_ticker`）
- `_tickNotifier.pulse()` 是 UI 刷新的脉冲
- **禁止**直接监听 `AppState` 转发到 WS：它是 `ChangeNotifier`，每帧 notify 会打爆 socket。必须自己做 diff + 定时器（见 §6）。

### 3.4 订阅方式的选择（三条路，只选第三条）

| 方案 | 做法 | 评估 |
| --- | --- | --- |
| A | `state.addListener()` 直接推送 | ❌ 播放中每 100ms notify 一次，1 分钟 600 条消息，客户端与 CPU 双爆 |
| B | `state.ticks.addListener()`（`_tickNotifier`） | ⚠️ 仅播放时有脉冲，暂停时收不到状态变化 |
| C | 自有 1s `Timer.periodic` + 拉取快照做 diff | ✅ 与播放状态解耦，暂停/空闲同样能检测到变化 |

选 **C**。伪代码：

```dart
Timer? _ticker;
String? _lastTrackId;
int _lastLyricSignature = 0;
String? _lastState;
DateTime _lastStatusAt = DateTime.fromMillisecondsSinceEpoch(0);

void _startTicker() {
  _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _broadcast());
}

void _broadcast() {
  if (_clients.isEmpty) return;                 // 无连接时零开销
  final snapshot = _snapshot();

  final trackId = snapshot.track?['id'] as String?;
  if (trackId != _lastTrackId) {                // 含切歌与停止
    _lastTrackId = trackId;
    _send({'kind': 'event', 'type': 'track', 'data': {'track': snapshot.track}});
    _lastLyricSignature = -1;                   // 强制下一轮补推歌词
  }

  final signature = _lyricSignature(snapshot);
  if (signature != _lastLyricSignature) {
    _lastLyricSignature = signature;
    _send({'kind': 'event', 'type': 'lyric',
           'data': {'source': snapshot.lyricSource, 'lyric': snapshot.lyric}});
  }

  final status = snapshot.status;
  final now = DateTime.now();
  if (status['state'] != _lastState ||
      now.difference(_lastStatusAt) >= const Duration(seconds: 1)) {
    _lastState = status['state'] as String?;
    _lastStatusAt = now;
    _send({'kind': 'event', 'type': 'status', 'data': status},
          stamp: snapshot.sendTimestamp);
  }
}

int _lyricSignature(_Snapshot s) =>
    Object.hash(s.track?['id'], s.lyric.length, s.lyricOffsetMs);
```

要点：

- `_clients.isEmpty` 短路，**没有 WS 连接时完全不计算快照**（避免空转）。
- 切歌后把 `_lastLyricSignature` 置 `-1`，保证新歌歌词即使长度相同也会推一次。
- `status` 用「状态变化 OR 距上次 ≥1s」双条件，避免暂停时永久静默。
- 快照只算一次并复用（`_snapshot()` 内有 `state.current` 等多次访问，缓存成局部变量）。

---

## 4. 平台矩阵与门控

| 平台 | Lazer 现状证据 | 结论 |
| --- | --- | --- |
| **Windows** | 无限制 | ✅ 支持 |
| **Linux** | 无限制 | ✅ 支持 |
| **macOS** | `macos/Runner/{DebugProfile,Release}.entitlements` 均已有 `com.apple.security.network.server = true` | ✅ 支持，零改配置 |
| **Android** | 有 `INTERNET` 权限 | ⚠️ 排除（OBS/挂件场景几乎为零，且 `LanRemoteController` 已按产品定位限定 TV 场景） |
| **iOS** | `NSLocalNetworkUsageDescription` 已存在（为 NAS/电台） | ❌ 排除（后台长时间监听不友好） |
| **Web** | `flutter build web` 在 CI 中运行；`dart:io` 在 web 上编译通过但 `HttpServer` 运行期不可用 | ⚠️ 必须不崩 |

### 三层防护（而不是单纯 `if (!kIsWeb)`）

1. **编译期隔离**：`lib/external_api/external_api.dart` 用条件导出，照抄 `lib/integrations/discord_rpc.dart` 的既有模式：
   ```dart
   export 'external_api_stub.dart' if (dart.library.io) 'external_api_io.dart';
   ```
   `_stub` 里所有方法返回空实现，Web/Android/iOS 走这里。

2. **运行期门控**：`externalApiSupported` getter
   ```dart
   bool get externalApiSupported =>
       !kIsWeb &&
       (isWindows || isLinux || isMacOS);
   ```
   设置页不满足时直接不渲染该项，对齐 `lib/tv/tv_mode.dart` 的写法。

3. **文档显式声明**：`docs/external-api.md` 与设置项副标题写明「仅桌面平台」。

> 将来若要支持 Android，只需把门控打开 + 把 entitlement/权限补齐，不用重写。

---

## 5. 协议设计

### 5.1 HTTP

基础地址：`http://127.0.0.1:<port>/api`，时间单位一律**毫秒**。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/api/info` | 应用版本、WS 在线数 |
| `GET` | `/api/status` | 状态、进度、时长、音量 |
| `GET` | `/api/volume` | 当前音量 0…1 |
| `GET` | `/api/now-playing` | 当前曲目轻量快照 |
| `GET` | `/api/lyrics` | 结构化歌词 |
| `POST` | `/api/play` / `pause` / `stop` | 播放控制 |
| `POST` | `/api/next` / `prev` | 切歌 |
| `POST` | `/api/seek` | body `{"positionMs": 60000}` |
| `POST` | `/api/volume` | body `{"volume": 0.5}` |

控制接口成功返回 `{"ok": true}`；参数非法返回 400；未开启返回 403。

### 5.2 WebSocket

地址：`ws://127.0.0.1:<port>/ws`

**服务端 → 客户端**

| `kind` | 形态 | 时机 |
| --- | --- | --- |
| `hello` | `{"kind":"hello","clients":N}` | 连接建立 |
| `event` | `{"kind":"event","type":"track","data":{"track":{...}}}` | 切歌 |
| `event` | `{"kind":"event","type":"lyric","data":{"source":{...},"lyric":[...]}}` | 歌词加载/偏移变化 |
| `event` | `{"kind":"event","type":"status","data":{...}}` | 状态变化 或 距上次 ≥1s |
| `ack` | `{"kind":"ack","op":"pause"}` | 命令成功 |
| `error` | `{"kind":"error","op":"seek","error":"..."}` | 命令失败 |

**客户端 → 服务端**

```json
{"op": "play"}
{"op": "seek", "positionMs": 60000}
{"op": "setVolume", "volume": 0.5}
```

`op ∈ {play,pause,stop,next,prev,seek,setVolume}`。

> **注意**：`position` 永不主动推送（避免带宽爆炸）。客户端收到 `status` 后按 `sendTimestamp` 自行插值，再用 `GET /api/status` 或下一次 `status` 事件校准。

### 5.3 JSON Schema 示例

#### `GET /api/status`

```json
{
  "state": "playing",
  "position": 73412,
  "duration": 215000,
  "volume": 0.62,
  "speed": 1.0,
  "isFinished": false
}
```

`state ∈ {"idle","loading","playing","paused","stopped"}`。

#### `GET /api/now-playing`

```json
{
  "track": {
    "id": "youtube:video:7MkUDkzsge0",
    "source": "youtube",
    "title": "ももいろの鍵",
    "artists": [
      { "id": "youtube:artist:UCxxxx", "name": "iyowa" }
    ],
    "album": {
      "id": "youtube:album:MPREb_xxx",
      "name": "ももいろの鍵",
      "cover": "https://i.ytimg.com/vi/7MkUDkzsge0/hqdefault.jpg"
    },
    "duration": 215000,
    "cover": "https://i.ytimg.com/vi/7MkUDkzsge0/hqdefault.jpg",
    "coverOriginal": "https://i.ytimg.com/vi/7MkUDkzsge0/maxresdefault.jpg"
  },
  "position": 73412,
  "playing": true,
  "state": "playing",
  "speed": 1.0,
  "lyricOffsetMs": 0,
  "lyricAvailable": true,
  "lyricLineCount": 68,
  "sendTimestamp": 1794655779123
}
```

#### `GET /api/lyrics`

```json
{
  "trackId": "youtube:video:7MkUDkzsge0",
  "source": { "source": "youtube", "format": "lrc" },
  "lyricOffsetMs": 0,
  "lyric": [
    {
      "startTime": 12400,
      "endTime": 15800,
      "text": "ももいろの鍵",
      "translatedLyric": "桃色的钥匙",
      "romanLyric": "momoiro no kagi",
      "words": [
        { "word": "も", "startTime": 12400, "endTime": 12800 },
        { "word": "も", "startTime": 12800, "endTime": 13200 },
        { "word": "い", "startTime": 13200, "endTime": 13500 },
        { "word": "ろ", "startTime": 13500, "endTime": 14100 }
      ]
    }
  ]
}
```

字段缺省约定：`translatedLyric` / `romanLyric` / `words` 缺失即省略（`omitempty` 语义），消费端必须容忍缺失。

#### `GET /api/info`

```json
{
  "name": "Lazer",
  "version": "2.0.200",
  "wsClients": 1
}
```

#### WS 首包序列

```json
{"kind":"hello","clients":1}
{"kind":"event","type":"track","data":{"track":{ ... }}}
{"kind":"event","type":"lyric","data":{"source":{"source":"youtube","format":"lrc"},"lyric":[ ... ]}}
{"kind":"event","type":"status","data":{"state":"playing","position":73412,"duration":215000,"volume":0.62,"speed":1.0,"isFinished":false}}
```

---

## 6. 广播与节流策略

```
每秒 1 个 ticker：
  trackId 变化          → 推 event/track
  lyric hash 变化       → 推 event/lyric
  state 变化 或距上次≥1s → 推 event/status
  position              → 永不主动推
```

歌词 hash 用 `lyrics.length + trackId + lyricOffsetMs` 组合即可，不必真算哈希。

> 参考实现的注释里明确写过「高频事件（position/fft）默认不向外部 WS 推送，避免带宽爆炸」，Lazer 沿用同一策略。

### 6.1 客户端侧插值（为什么 position 不用推）

消费端收到 `status` 后自行推进：

```js
// 收到 event/status
state.position = msg.data.position;
state.duration = msg.data.duration;
state.playing  = msg.data.state === 'playing';
state.tickAt   = performance.now();

// 每帧渲染（或 rAF）
const elapsed = state.playing ? performance.now() - state.tickAt : 0;
const shown   = Math.min(state.position + elapsed, state.duration);
```

校准时机：

| 时机 | 动作 |
| --- | --- |
| WS `event/status` | 覆盖本地 `position` 与 `tickAt` 基准 |
| WS 重连成功 | 立刻 `GET /api/status` 全量对齐 |
| 页面从后台恢复（`visibilitychange`） | 同上 |
| 累计误差 > 500ms（可选） | 同上 |

这样 1Hz 的 `status` 也够用，而进度条是 60fps 平滑的。

### 6.2 WS 连接生命周期

```
open  → 服务端立即发 hello + track + lyric + status（首包三连）
      → 客户端据此渲染首屏，无需额外 REST 请求
send  → 命令（play/pause/...），服务端回 ack 或 error
close → 客户端按固定间隔重连（建议 3s），期间继续用本地插值渲染
error → 立即 close 并进入重连流程
```

服务端侧：`_websockets` 用 `Map<String, WebSocket>`（对齐 `lan_remote` 的 `_server` 模式），`add`/`remove` 时更新 `clients` 计数，发送失败（`WebSocket.add` 抛错或 socket 已关闭）时**主动移除**，避免死连接累积。

---

## 7. 配置与端口

### 7.1 端口范围（不出现任何第三方项目名）

默认 `portMin = 14558`，`portMax = 14568`（与既有生态默认端口相邻，便于复用现成挂件配置）。

```dart
Future<HttpServer> _bindInRange() async {
  Object? last;
  for (var port = portMin; port <= portMax; port++) {
    try {
      return await HttpServer.bind(host, port);
    } on SocketException catch (e) {
      last = e;         // 被占用，试下一个
      continue;
    }
  }
  throw StateError('端口 $portMin–$portMax 均被占用，请在设置中调整端口范围');
}
```

绑定成功后把实际端口暴露给用户（`urls` 列表，对齐 `lan_remote`）。

### 7.1.1 为什么用范围而不是单端口

固定单端口被占用就完全不可用；随机端口（`port: 0`）让消费端每次都要改配置。**范围 + 顺延**则冲突时自动换下一个，仍是可预期区间。顺延后必须在设置页与日志里显示实际端口：

```dart
// 绑定成功后
urls = ['http://127.0.0.1:${server.port}', 'ws://127.0.0.1:${server.port}/ws'];
```

### 7.1.2 端口占用探测的边界情况

- `SocketException` 的 `osError.errorCode` 在 Windows 是 `WSAEADDRINUSE (10048)`，Linux 是 `EADDRINUSE (98)`，**不要按错误码区分**，统一按「绑定失败 → 试下一个」处理，最后一次失败的错误信息才上报。
- 范围非法（`min > max`）直接拒绝保存，不进入绑定流程。
- 绑定成功但 `_disposed` / 开关已关（用户瞬间切换）→ 立刻 `close(force: true)` 并 return（对齐 `lan_remote._start()` 的竞态处理）。

### 7.2 设置项

| 配置 | 类型 | 默认 | 校验 |
| --- | --- | --- | --- |
| 启用外部状态 API | `bool` | `false` | — |
| 启用 WebSocket | `bool` | `false` | 依赖上一项 |
| 端口下限 | `int` | `14558` | `1024 ≤ min ≤ max ≤ 65535` |
| 端口上限 | `int` | `14568` | 同上 |
| 允许局域网访问 | `bool` | `false` | 开启后绑 `0.0.0.0` |

UI 复用设置页既有组件：`_AppSwitchRow`（布尔项）、`_AppSettingRow` + `SpringTextButton`（数值项，弹窗输入照抄 `_editDiscordRpc` 的 `TextField` 写法）。

---

## 8. `allowedOrigin` 白名单（含 7 条测试表）

WS 升级前与 HTTP 请求均走同一判定：

```dart
bool allowedOrigin(String? origin) {
  if (origin == null || origin.isEmpty || origin == 'null') return true; // curl / file:// 无 Origin
  final uri = Uri.tryParse(origin);
  if (uri == null) return false;
  if (uri.scheme == 'file') return true;                                 // file:///path/index.html
  final host = uri.host.toLowerCase();
  return host == '127.0.0.1' || host == '::1' || host == 'localhost';
}
```

| # | 输入 `Origin` | 期望 | 说明 |
| --- | --- | --- | --- |
| 1 | `(缺失)` | ✅ 允许 | `curl` / 非浏览器客户端 |
| 2 | `null` | ✅ 允许 | 字面量 `"null"`，部分浏览器对 `file://` 会发这个 |
| 3 | `file://` | ✅ 允许 | 本地 HTML，OBS 最常见场景 |
| 4 | `file:///D:/OBS/overlay/index.html` | ✅ 允许 | 同上，带完整路径 |
| 5 | `http://127.0.0.1:6161` | ✅ 允许 | 本机起的预览页 |
| 6 | `http://localhost:6161` | ✅ 允许 | 同上 |
| 7 | `https://evil.example` | ❌ 拒绝 | 任意网页，403 |

> 这套 7 条必须原样写进 `test/external_api_test.dart`（对齐 `lan_remote_test.dart` 的 `expect` 风格，参考实现的同名用例即为此形态）。

### 8.1 HTTP 与 WS 的校验差异

| 检查项 | HTTP | WS 升级 |
| --- | --- | --- |
| 总开关 `enabled` | ✅ 403 | ✅ 403 |
| WS 子开关 `wsEnabled` | — | ✅ 403 |
| `allowedOrigin(Origin)` | ✅ 403 | ✅ 403 |
| `OPTIONS` 预检 | ✅ 204 + CORS 头 | — |
| 方法白名单 | ✅ GET/POST | — |
| Token（暂不做） | — | — |

HTTP 统一响应头：

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: Content-Type
Cache-Control: no-store
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
```

> `lan_remote` 额外设了严格 CSP（因为它内置 HTML 页面）；本功能不返回任何 HTML，**不需要** CSP，但保留 `nosniff` / `no-store` / `no-referrer` 三件套。

### 8.2 为什么 `Access-Control-Allow-Origin: *` 是可接受的

1. 默认只绑 `127.0.0.1`，外部主机连不进来。
2. 即便绑了 `0.0.0.0`（用户显式开启局域网），WS 升级仍有 `allowedOrigin` 白名单，任意公网页面拿不到数据。
3. 只读端点（`info/status/now-playing/lyrics`）泄露的是「当前在听什么」，与系统媒体控制（SMTC/MPRIS）暴露的信息同级——后者本来就是任意本地程序可读的。
4. 写端点（`play/pause/...`）需要 POST + 白名单 Origin，跨站表单提交无法通过 Origin 校验。

> 如果维护者更倾向「不开 CORS，要求消费端用 `file://` 或同源页面」，实现上只需删掉三行响应头，不影响其余设计。这是**可协商项**，PR 里可以注明。

---

## 9. 文件落点

### 新增

```
lib/external_api/external_api.dart          # 条件导出（io / stub）
lib/external_api/external_api_io.dart       # controller + HttpServer + WebSocket 升级
lib/external_api/external_api_stub.dart     # 非桌面平台空实现
lib/external_api/external_api_models.dart   # AppState → 协议 JSON 的映射
lib/ui/external_api_settings.dart           # 设置页区块
test/external_api_test.dart                 # 集成测试
docs/external-api.md                        # 协议文档（面向消费端）
```

### 修改

```
lib/main.dart                              # 挂载 controller + ExternalApiScope
lib/ui/settings_page.dart                  # 插入 ExternalApiSettings
assets/l10n/{zh_Hans,zh_Hant,ja,en}.json   # 四语新增同集 key
```

> 当前四份 l10n 各 **1254** 个 key，`tool/check_i18n.py` 在 CI 中强制同集，新增 key 必须四份齐加。

---

## 10. 测试计划

照抄 `test/lan_remote_test.dart` 的结构（真实 loopback、`HttpOverrides.global = null`、`addTearDown` 清理）：

| # | 用例 |
| --- | --- |
| 1 | 默认关闭 → 不监听任何端口 |
| 2 | 开启 → 绑定 `portMin` |
| 3 | `portMin` 被占用 → 自动顺延到 `portMin+1` |
| 4 | 全范围被占用 → `error` 文案含「端口范围均被占用」 |
| 5 | 非法 `Origin` → WS 升级与 HTTP 均 403 |
| 6 | `GET /api/now-playing` → 曲目字段正确 |
| 7 | `POST /api/volume` → `state.volume` 变化 |
| 8 | WS 订阅 → 收到 `hello` + track/lyric/status 三连 |
| 9 | 切歌 → 收到 `event/track` |
| 10 | 关闭开关 → 端口释放，`urls` 清空 |

`allowedOrigin` 的 7 条另做一个纯函数单测。

> 必须 `HttpOverrides.global = null`（否则 Flutter test 的 mock HTTP 会拦掉 loopback），并用 `addTearDown` 按 `client.close(force:true)` → `remote.dispose()` → `state.dispose()` 顺序清理，否则端口残留会让后续用例顺延、掩盖真实断言。用例 3 先在 `portMin` 手动 `HttpServer.bind` 占位再启动 controller；用例 4 建议把测试范围改成两三个端口的窄区间（如 `39xx`），避免真绑 11 个 socket。

---

## 11. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| Web 构建编译失败 | CI 红 | 条件导出 + 运行期门控（§4） |
| `AppState` 每帧 notify 刷爆 WS | CPU / 带宽 | diff + 1s 节流（§6） |
| l10n 四语 key 不同集 | `check_i18n.py` 失败 | 本地先跑 `python tool/check_i18n.py --keys` |
| 端口范围全被占用 | 功能不可用 | 明确错误 + 设置页可调 |
| 与内置局域网遥控器端口冲突 | 两者都启不了 | 各自独立范围与开关；失败时提示用户改范围 |
| 消费端是 `file://` 被 CORS 拦 | 挂件白屏 | 统一 `Access-Control-Allow-Origin: *` + Origin 白名单 |
| 维护者质疑「为何要做服务器」 | PR 被拒 | 正文强调：opt-in、默认关闭、仅 loopback、可 LAN 但需显式开启，与既有局域网遥控器同级 |

---

## 12. PR 策略

### 12.1 交付形态

**单个 PR**，目标分支 `nextgen`（仓库默认分支，非 `main`）。内含上述全部改动 + 测试 + 文档。

### 12.2 PR 正文结构

```markdown
## Why
Lazer 目前没有向外暴露播放状态的方式。系统媒体控制（SMTC/MPRIS/NowPlaying）
只有歌名与播放状态，缺少歌词、精确进度与原始封面，桌面歌词覆盖层与直播挂件
无法据此渲染。

## What
新增应用级外部状态 API（opt-in，默认关闭）：
- HTTP: /api/{info,status,volume,now-playing,lyrics} + 播放控制
- WS: /ws，{kind: hello|event|ack|error}

复用 lib/tv/lan_remote.dart 已确立的 HttpServer/开关/收敛模式，不引入新依赖。

## Compatibility
端点路径、字段名与消息格式遵循主流播放器外部 API 的既有约定，
现有消费端可零改动接入。

## Safety
- 默认关闭；默认仅监听 127.0.0.1
- 局域网需用户显式开启
- Origin 白名单（file:// 与本机回环），拒绝任意网页
- 仅桌面平台（Windows/Linux/macOS）；Web/移动端走 stub

## Tests
test/external_api_test.dart：开关、端口顺延、Origin 白名单 7 条、
状态读取、命令生效、WS 首包与切歌事件、关闭后端口释放。

## Config
端口范围可配置（默认 14558–14568），范围被占用时给出可读错误。
```

### 12.3 首条 comment 内容

正文不点名第三方项目，避免像"为某个 App 定制"；把生态参考放在首条 comment：SPlayer-Next（`docs/api.md`、`docs/socket.md`）、go-musicfox（`internal/externalapi`、`docs/external-api.md`），以及本项目作为消费端示例。

### 12.4 逐条回应维护者可能的质疑

| 预判质疑 | 回应要点 |
| --- | --- |
| 「为什么不在 Lua 插件里做？」 | 插件 VM 刻意禁 `io` / `os` / 端口；放开等于拆掉沙箱。且本需求与音源无关，属应用级能力。 |
| 「会不会是安全风险？」 | 默认关闭 + 默认 loopback + Origin 白名单 + 无 LAN 除非显式开启；与既有局域网遥控器同一安全基线。 |
| 「为何要 CORS `*`？」 | 消费端常是 `file://` 本地 HTML；若维护者偏好更严格，可删该头，功能不受影响（§8.2 末尾）。 |
| 「能不能只做 HTTP？」 | WS 是刚需：1.2s 轮询在切歌/歌词加载时有可见延迟，且频繁轮询更浪费。但可拆成两个 PR 交付（§12.5）。 |
| 「为什么默认端口是这个区间？」 | 与既有消费端生态默认值相邻，便于用户复用现有配置；且范围设计保证冲突可自愈。 |
| 「维护成本？」 | 无新依赖（`dart:io` + SDK 自带 `WebSocketTransformer`），代码集中在 `lib/external_api/`，删除该目录不影响其他功能。 |

### 12.5 备选交付形态（若维护者要求缩小范围）

| 形态 | 内容 | 适用 |
| --- | --- | --- |
| 单 PR（默认） | HTTP + WS + 设置页 + 测试 + 文档 | 一次做完 |
| 拆两 PR | PR1 = HTTP + 设置页 + 测试；PR2 = WS + 节流 | 维护者希望先小步合并 |
| 只读版 | 移除全部 `POST` 控制端点 | 维护者担心写操作风险 |

无论哪种形态，**协议字段保持不变**，消费端无需区分。

---

## 13. 尚未定稿的细节

| 项 | 当前倾向 | 备注 |
| --- | --- | --- |
| 默认端口范围 | `14558–14568` | 与既有生态默认值相邻，便于复用配置 |
| `speed` 字段 | 固定 `1.0` | Lazer 暂无变速播放，先给常量 |
| `coverOriginal` | 有则给，无则省略 | YouTube 走 `maxresdefault`，本地文件可能没有 |
| 歌词 `format` | `"lrc"` / `"word"` | 逐字存在时给 `"word"` |
| 是否广播 `isFinished` 事件 | 先不单独广播 | 状态里带即可 |
| WS 是否需鉴权 token | 暂不需要 | 依赖 loopback + Origin 白名单；若维护者要求再加 |

---

## 14. 执行顺序（实现阶段用）

1. **A** `external_api_models` + `allowedOrigin` + 单测（纯函数，最快见效）
2. **B** `external_api_io` controller：端口范围绑定、开关、HTTP 路由、测试 1–7
3. **C** WS 升级 + ticker 节流 + 测试 8–10
4. **D** 设置页 + i18n ×4 + `docs/external-api.md`
5. **E** 本地全量验证：`flutter analyze` / `flutter test` / `python tool/check_i18n.py`
6. **F** 开 PR + 首条 comment

---

## 15. 验收清单（实现完成后逐项打勾）

**功能**：默认关闭时无新增监听端口 · 开启后设置页显示 HTTP 与 WS 两条 URL · `GET /api/now-playing` 返回正确 JSON · `POST /api/pause` 生效并回 `{"ok":true}` · overlay 用 `file://` 打开可显示曲目/封面/进度/歌词 · WS 断线自动重连 · 切歌 1s 内更新 · 歌词加载后无需刷新即可显示。

**边界**：`portMin` 占用时自动顺延且设置页显示实际端口 · 全范围占用时错误文案可读无堆栈 · 关闭开关后端口立即释放 · 非法 Origin 返回 403 · 暂停时 `status` 仍按 ≥1s 推送。

**工程**：`flutter analyze` 无告警 · `flutter test` 全绿（含新增 10+ 用例）· `python tool/check_i18n.py` 通过 · `flutter build web` 不因 `dart:io` 失败 · Android/iOS 构建走 stub 不受影响。

**文档**：`docs/external-api.md` 含完整端点表与 JSON 示例 · PR 正文与首条 comment 按 §12.2 / §12.3 填写 · 设置页文案注明「仅桌面平台、默认关闭」。

---

*本文档为规划稿，实现细节以 PR 内容为准。*
