# AptvMerge 项目交接文档

更新时间：2026-06-20  
项目路径：`/Users/lpp/Desktop/Xcode/AptvMerge`  
最新提交：以 `git log -1 --oneline` 为准  
当前状态：App 可构建，可本机运行，可打包给其他 Mac 使用。启动后先进入双源同步校准，确认合并后再输出本机 HLS。

## 给新对话的开场提示

如果要在新 Codex 对话里无缝继续，可以直接发送下面这段：

```text
请先阅读 /Users/lpp/Desktop/Xcode/AptvMerge/HANDOFF.md，然后继续维护 AptvMerge 项目。项目是一个 macOS SwiftUI App，用于把一个直播视频源和一个解说音频源合流成本机 HLS 链接，并支持自定义源、时差设置、内置播放、日志面板和打包分发。请遵守文档里的现状、构建命令、日志路径和注意事项，不要随意回滚未确认的功能。
```

## 项目目标

AptvMerge 是一个本机直播源合流 App：

- 输入一个视频直播源和一个音频/解说直播源。
- 输出一个本机 HLS 链接，默认类似 `http://本机局域网IP:8080/index.m3u8`，可给 APTV、Apple TV 或其他局域网播放器打开。
- App 内也提供内置播放预览，预览地址为 `http://127.0.0.1:8080/preview/index.m3u8`。
- 支持手动添加/编辑/删除视频源和音频源。
- 启动后先进入“双源校准”阶段，不立即合流：
  - 中间区域并排播放视频源画面和音频源画面。
  - 音频源即使主要用于取解说音频，也会先显示它自带的视频画面，便于人工对齐。
  - 两个预览窗口可分别设置非负延迟。
  - 每次点击“启动/重新校准”都会从 `0s / 0s` 开始，不沿用上一次校准或合流留下的时差。
  - 点击“确认合并”后，App 会用 `视频源窗口延迟 - 音频源窗口延迟` 换算成最终合流时差。
  - 校准预览不要直接用 AVPlayer 播远端 IPTV/TS 源；当前由 `CalibrationPreviewService.swift` 先把两路源转成本机 fMP4 HLS，再给 AVPlayer 播放。
- 支持设置/应用合流时差：
  - `0`：零时差，跳过缓存层，直接合流。
  - 正数：视频延后，使用视频缓存层。同为正数模式下应用新时差时，会保留视频缓存、音频中继和 HTTP 服务，只短暂重启 reader/merge/preview。
  - 负数：音频延后，使用音频中继 + FFmpeg `adelay` 轻量偏移，应用新时差会短暂重启合流/预览进程。
- 支持隐藏/显示输出链接，避免截图泄露局域网地址。
- 支持右侧日志面板打开/收起，默认打开。

## 当前 UI 状态

主界面在 `AptvMerge/ContentView.swift`。

布局是固定三栏，不再使用 `HSplitView`：

- 左侧源列表：`sidebarWidth = 340`
- 中间控制/播放区域：`controlPanelWidth = 900`
- 右侧日志区域：`logPanelWidth = 400`
- 日志打开时窗口宽度：`340 + 900 + 400 = 1640`
- 日志收起时窗口宽度：`340 + 900 = 1240`

注意：

- 用户非常在意日志收起后的布局：收起日志时，左侧和中间宽度必须保持不变，右侧日志区域直接消失，不要留下空白，也不要让中间区域自动占满。
- 当前做法是在 `toggleLogPanel()` 中切换 `isLogPanelVisible`，并通过 `NSWindow` 设置窗口宽度和 `minSize/maxSize`。
- 如果后续再改日志布局，优先保持“固定宽度 + 调整窗口宽度”的模型，不要改回 `HSplitView`。

## 主要文件

```text
/Users/lpp/Desktop/Xcode/AptvMerge
├── AptvMerge.xcodeproj
├── AptvMerge/
│   ├── AptvMergeApp.swift
│   ├── AppModel.swift
│   ├── CalibrationPreviewService.swift
│   ├── ContentView.swift
│   ├── InAppPlayerView.swift
│   ├── MergeService.swift
│   ├── SourceEditorView.swift
│   ├── StreamSource.swift
│   └── Assets.xcassets/AppIcon.appiconset/
├── Info.plist
├── HANDOFF.md
└── dist/
    ├── AptvMerge.app
    └── AptvMerge.zip
```

### `StreamSource.swift`

定义直播源数据结构和默认源。

当前默认源：

- 视频源：
  - `TSN-4K`
  - `TSN-1080P`
- 音频源：
  - `咪咕解说`
  - `央视解说`

源列表持久化位置：

```text
~/Library/Application Support/AptvMerge/sources.json
```

重要行为：

- 默认源也允许删除。
- 如果 `sources.json` 已存在，修改 `StreamSource.defaults` 不会自动覆盖用户已有源。
- 需要恢复默认源时，可以删除 `sources.json`，App 下次启动会重新生成默认源。

### `AppModel.swift`

负责 UI 状态、源保存、服务启动/停止、日志持久化。

关键状态：

- `sources`
- `selectedVideoID`
- `selectedAudioID`
- `delaySeconds`
- `videoPreviewDelaySeconds`
- `audioPreviewDelaySeconds`
- `videoCalibrationPreviewURL`
- `audioCalibrationPreviewURL`
- `phase`
- `isStarting`
- `isRunning`
- `statusText`
- `outputURL`
- `previewURL`
- `isOutputURLVisible`
- `logs`

启动流程：

- 顶部“启动”按钮现在先进入校准阶段，不直接调用 `MergeService.start(...)` 合流。
- 校准阶段由 `CalibrationPreviewService.start(...)` 启动两路 FFmpeg 本机预览。
- 每次进入校准都会强制把 `delaySeconds`、`videoPreviewDelaySeconds`、`audioPreviewDelaySeconds` 设为 `0`。
- “确认合并”调用 `confirmMerge()`，把两个预览窗口延迟换算成 `delaySeconds` 后再启动合流。
- 确认合并后校准面板会消失，音频源的视频画面关闭，只保留合并后的内置播放预览。

日志规则：

- 每次启动都会清空 UI 日志。
- 每次启动都会重置 `current.log`，保证本次启动日志不会和旧日志混在一起。
- 同时保存一份带时间戳的 session 日志。

日志文件位置：

```text
~/Library/Application Support/AptvMerge/logs/current.log
~/Library/Application Support/AptvMerge/logs/session-YYYYMMDD-HHMMSS.log
```

后续排查问题时，优先直接读取：

```bash
tail -n 200 "$HOME/Library/Application Support/AptvMerge/logs/current.log"
```

### `MergeService.swift`

这是合流核心，负责启动和管理多个进程：

- Python HTTP 服务：把本机 HLS 目录发布到 `0.0.0.0:8080`。
- FFmpeg 直接合流进程。
- FFmpeg 视频缓存进程。
- FFmpeg 音频中继进程。
- Python 延迟 playlist reader。
- FFmpeg 内置播放预览转封装进程。

启动就绪判断：

- 主输出 `hls/index.m3u8` 不再只看文件是否存在；现在至少等到 3 个媒体分片进入 playlist，才认为 `HLS 输出就绪`。
- 内置预览 `hls/preview/index.m3u8` 也至少等到 3 个媒体分片，才认为 `内置播放流就绪`。
- 音频中继 `audio-relay/index.m3u8` 至少等到 2 个媒体分片，才认为 `音频中继就绪`。
- 这样会让启动多等几秒，但可以避免播放器启动后约 3 秒在第一次 HLS 分片衔接处固定卡一下。

运行目录：

```text
~/Library/Application Support/AptvMerge/Runtime/
├── hls/
│   ├── index.m3u8
│   ├── seg_*.ts
│   └── preview/
│       ├── index.m3u8
│       ├── init.mp4
│       └── prev_*.m4s
├── video-buffer/
│   ├── index.m3u8
│   └── vid_*.ts
├── audio-relay/
│   ├── index.m3u8
│   └── aud_*.ts
└── delay.txt
```

核心输出：

- 给外部播放器/APTV 用：`http://局域网IP:8080/index.m3u8`
- 给 App 内置播放器用：`http://127.0.0.1:8080/preview/index.m3u8`

FFmpeg 路径查找顺序：

```text
/opt/homebrew/bin/ffmpeg
/usr/local/bin/ffmpeg
/opt/local/bin/ffmpeg
```

### `CalibrationPreviewService.swift`

负责“双源校准”阶段的临时预览，不做合流。

流程：

- 使用 Python HTTP 服务把校准目录发布到 `127.0.0.1:8081`。
- 启动两个 FFmpeg 进程：
  - `cal-video`：把视频源转为 `Calibration/video/index.m3u8`。
  - `cal-audio`：把音频源自带的视频/音频转为 `Calibration/audio/index.m3u8`。
- 两路都输出 fMP4 HLS，供 macOS `AVPlayer` 播放。
- `AppModel.confirmMerge()` 会先停止校准预览，再启动真正合流；这样确认合并后音频源视频画面会关闭，只取音频参与合并。

运行目录：

```text
~/Library/Application Support/AptvMerge/Calibration/
├── video/
│   ├── index.m3u8
│   ├── init.mp4
│   └── seg_*.m4s
└── audio/
    ├── index.m3u8
    ├── init.mp4
    └── seg_*.m4s
```

Python 路径查找顺序：

```text
/usr/bin/python3
/opt/homebrew/bin/python3
/usr/local/bin/python3
```

本机 IP 获取方式：

```bash
ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo 127.0.0.1
```

### `InAppPlayerView.swift`

App 内置播放区域，使用 `AVPlayerView`。

注意：

- 内置播放器不直接播放局域网 IP，而是把 host 改成 `127.0.0.1`，避免本机访问自己的局域网地址出现奇怪问题。
- 主输出是 MPEG-TS HLS；内置预览由 `startPreviewStream()` 转成 fMP4 HLS，并设置 `-tag:v hvc1`，用于改善 macOS AVPlayer 对 HEVC 的兼容性。
- 如果外部播放器正常但内置播放器无画面，优先检查 `preview/index.m3u8` 和 `preview` 进程日志。

### `SourceEditorView.swift`

新增/编辑源的弹窗。

字段：

- 类型：视频源/音频源。
- 名称。
- URL。
- User-Agent，可选，部分音频源需要。

内置源编辑时类型不可改，但名称、URL、User-Agent 可以改。

## 时差模式说明

### 0 秒：直接合流

调用 `startDirectMerge(video:audio:)`。

特点：

- 不启动视频缓存层。
- 延迟最低。
- 如果两个源天然同步，这是最稳的方式。

### 正数：视频延后

例：`30` 表示视频延后 30 秒。

当前流程：

1. `startVideoBuffer(video:)` 只缓存视频，输出到 `video-buffer/index.m3u8`。
2. `waitForBuffer(delaySeconds:)` 等视频缓存达到目标秒数。
3. `startAudioRelay(audio:)` 把音频源稳定转为短 HLS，输出到 `audio-relay/index.m3u8`。
4. `startBufferedVideoMerge(delaySeconds:)` 启动 Python `delayedReaderScript`，从 `video-buffer/vid_*.ts` 中按目标时差选择旧分片，并通过 `stdout` 管道直接喂给 FFmpeg。
5. FFmpeg 用 `pipe:0` 读取延后后的视频 TS，同时读取 `audio-relay/index.m3u8`，映射 `0:v:0` + `1:a:0`，视频 `copy`，音频 AAC + `aresample=async=1:first_pts=0`，输出主 HLS。

优点：

- 正数模式内应用新时差时，`updateDelay()` 会调用 `restartBufferedVideoMerge(delaySeconds:)`，只重启 reader/merge/preview，不重启视频缓存层、音频中继和 HTTP 服务。
- 适合“音频比视频慢，只能把视频放慢”的场景。

注意：

- 旧方案曾用 `delayedPlaylistScript` 生成 `video-buffer/delayed.m3u8` 给 FFmpeg 读取；设置 15/30 秒视频延后时，日志会出现 `Resumed reading ... after a lag`，表现为音频一卡一卡，应用时差也不明显。当前已改为 Python reader 管道喂 FFmpeg，避免 FFmpeg HLS demuxer 追读延后 playlist。
- 之前曾出现 30 秒视频延后卡顿、音频中断、源内音频混入等问题。后续排查请先看日志文件，不要靠截图猜。
- 日志里如果有 FFmpeg 网络错误、`Stream ends prematurely`、`Packet corrupt`、`PES packet size mismatch`，通常和直播源网络/协议有关，不一定是 App UI 问题。

### 负数：音频延后

例：`-2` 表示音频延后 2 秒。

当前流程：

- `startAudioRelay(audio:)` 先把远端音频源稳定中继为 `audio-relay/index.m3u8`。
- `startAudioRelayOffsetMerge(video:delaySeconds:)` 读取视频源和音频中继。
- 使用 FFmpeg `-filter:a adelay=毫秒:all=1,aresample=async=1:first_pts=0`。
- 视频 `copy`，音频转 AAC。

注意：

- 负数模式使用音频中继稳定远端解说源，再在合流阶段用 `adelay` 做偏移，压力比视频缓存小，但动态调整需要短暂重启合流/预览进程。

## 日志策略

为了避免 UI 日志刷屏，当前 FFmpeg 大多使用：

```text
-loglevel warning
-nostats
```

仍可能出现的日志：

- 重要 FFmpeg warning/error。
- 进程退出。
- 启动/就绪状态。
- 缓存进度，每 5 秒一条。
- Python 延迟 reader 的启动信息。

已经不希望持续输出的内容：

- `frame=... fps=... speed=...` 这种 FFmpeg 统计行。
- 频繁的延迟 reader 调整行。
- 已知无害的 FFmpeg 探测/解码刷屏 warning：
  - `Skipping invalid undecodable NALU`
  - `non-existing PPS`
  - `no frame!`
  - `Last message repeated`
  - `Stream HEVC is not hvc1`
  - `mime type is not rfc8216 compliant`
- 音频中继 `[audio]` 的正常短断重连噪声：
  - `Stream ends prematurely`
  - `Will reconnect`
  - `PES packet size mismatch`
  - `Packet corrupt`

这些被过滤的 warning 多数来自直播源启动探测阶段。例如“央视解说”源实际带有一条坏/不完整的视频轨，虽然 App 只映射它的音频，但 FFmpeg 仍会在探测时反复报告 H264 PPS/no frame 警告。`[audio]` 的 `Stream ends prematurely` / `Will reconnect` 通常表示远端 HTTP 音频源短连接或 EOF 后立刻重连，只要播放没有中断、音频中继没有退出，就属于中继层兜住的噪声。过滤只影响 App 日志展示和日志文件，不改变 FFmpeg 合流行为。

如果又出现刷屏，优先检查：

- `attachLogging(to:name:)`
- FFmpeg 参数是否遗漏 `-nostats`
- Python 脚本是否有循环 `print`
- `shouldSuppressFFmpegLogLine(_:processName:)` 的过滤规则是否需要补充。

## 构建和打包命令

项目根目录：

```bash
cd /Users/lpp/Desktop/Xcode/AptvMerge
```

Debug 构建：

```bash
xcodebuild -project AptvMerge.xcodeproj -scheme AptvMerge -configuration Debug -destination 'platform=macOS' build
```

Release 构建：

```bash
xcodebuild -project AptvMerge.xcodeproj -scheme AptvMerge -configuration Release -destination 'generic/platform=macOS' build
```

重新打包并打开 App：

```bash
cd /Users/lpp/Desktop/Xcode/AptvMerge
osascript -e 'tell application "AptvMerge" to quit' 2>/dev/null || true
pkill -f '/AptvMerge.app/Contents/MacOS/AptvMerge' 2>/dev/null || true
xcodebuild -project AptvMerge.xcodeproj -scheme AptvMerge -configuration Release -destination 'generic/platform=macOS' build
rm -rf dist/AptvMerge.app dist/AptvMerge.zip
mkdir -p dist
release_app=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Release/AptvMerge.app' -type d -print -quit)
ditto "$release_app" dist/AptvMerge.app
ditto -c -k --sequesterRsrc --keepParent dist/AptvMerge.app dist/AptvMerge.zip
open /Users/lpp/Desktop/Xcode/AptvMerge/dist/AptvMerge.app
```

当前 `.gitignore` 忽略：

```text
dist/
xcuserdata/
*.xcuserstate
```

所以 `dist/AptvMerge.app` 和 `dist/AptvMerge.zip` 是本地打包产物，不进 git。

## 运行依赖

必须：

- macOS。
- Xcode。
- FFmpeg。
- Python 3。

推荐安装 FFmpeg：

```bash
brew install ffmpeg
```

FFmpeg 必须位于以下路径之一：

```text
/opt/homebrew/bin/ffmpeg
/usr/local/bin/ffmpeg
/opt/local/bin/ffmpeg
```

如果朋友的 Intel Mac 播放卡顿：

- 先确认是否选择了 4K 源。
- Intel Mac 对 4K/HEVC 预览压力更高。
- 外部播放端、App 内置预览、合流服务本身是三个不同负载点。
- 优先测试 1080P 源。
- 再看 `current.log` 判断是源网络、FFmpeg 进程、还是播放器解码问题。

## 局域网访问

App 启动后底部输出链接类似：

```text
http://192.168.50.135:8080/index.m3u8
```

同一局域网内的 Apple TV/APTV 理论上可以打开。

排查方向：

- Mac 和 Apple TV 是否在同一局域网。
- macOS 防火墙是否阻止 Python HTTP server。
- App 是否显示“运行中”。
- `~/Library/Application Support/AptvMerge/Runtime/hls/index.m3u8` 是否存在且持续更新。
- 浏览器能否打开 `http://127.0.0.1:8080/index.m3u8`。
- 局域网设备能否访问 `http://Mac局域网IP:8080/index.m3u8`。

## 已做过的重要决策

1. 不再只做命令行脚本，已经转成 macOS SwiftUI App。
2. 不把日志嵌在中间内容里，日志是右侧独立面板。
3. 日志默认打开。
4. 收起日志不能让中间自动占满，也不能留空；通过固定三栏宽度和调整窗口宽度实现。
5. 输出链接默认隐藏，可点眼睛按钮显示。
6. 启动按钮有“启动中/重启中”状态，等待 HLS 输出至少 3 个分片、内置预览至少 3 个分片后才进入运行中，避免启动后约 3 秒第一次分片衔接卡顿。
7. 每次启动新建日志，`current.log` 只保留本次启动日志。
8. 内置播放通过预览 HLS 实现，而不是直接播放主输出。
9. 最新图标已经加入 `Assets.xcassets/AppIcon.appiconset`。
10. App 版本当前显示为 `v1.1`。

## 常见问题和处理方式

### 启动失败

先读日志：

```bash
tail -n 200 "$HOME/Library/Application Support/AptvMerge/logs/current.log"
```

常见原因：

- FFmpeg 不在查找路径。
- 直播源无法访问。
- 端口 8080 被占用。
- 视频/音频源没有选中。

检查 8080：

```bash
lsof -i :8080
```

### 外部播放器正常，内置播放没画面

检查：

```bash
ls -la "$HOME/Library/Application Support/AptvMerge/Runtime/hls/preview"
tail -n 200 "$HOME/Library/Application Support/AptvMerge/logs/current.log"
```

可能原因：

- AVPlayer 对当前编码/封装兼容性差。
- `preview` FFmpeg 进程没输出 fMP4 HLS。
- HEVC tag 或音频 bitstream filter 需要调整。

### 设置视频延后后卡顿

先判断是源网络还是延迟管线：

```bash
tail -n 300 "$HOME/Library/Application Support/AptvMerge/logs/current.log"
```

重点看：

- `buffer` 进程是否持续输出错误。
- `audio` 中继是否断流。
- `merge` 是否出现 corrupt packet。
- `merge` 是否出现 `Resumed reading ... after a lag`。如果出现，说明 FFmpeg 输入端在追读/掉队，优先检查是否又退回了旧的 delayed playlist 方案。
- `reader` 是否频繁退出或报找不到 `vid_*.ts`。

### 日志刷屏

优先检查：

- FFmpeg 参数是否仍带 `-nostats`。
- Python 脚本是否频繁 `print`。
- `attachLogging` 是否过滤了不必要输出。
- 如果刷屏内容是 `non-existing PPS`、`no frame!`、`Skipping invalid undecodable NALU`，通常是源流探测 warning；当前应由 `shouldSuppressFFmpegLogLine(_:processName:)` 过滤，不应再出现在 UI 日志里。
- 如果刷屏内容是 `[audio] Stream ends prematurely` 或 `[audio] Will reconnect`，通常是音频中继拉远端源时的短断重连；当前应只在 `[audio]` 进程中过滤，主合流 `[merge]` 的同类网络错误仍要保留。

### 启动后约 3 秒固定卡一下

这个问题的原因大概率是 HLS 就绪判断太早：旧逻辑只要 `index.m3u8` 非空就显示运行中，播放器可能只拿到第 1 个 4 秒分片，播到第一次分片衔接处时缓存不够厚就会顿一下。

当前修复：

- `waitForOutputPlaylist()` 等主输出至少 3 个媒体分片。
- `waitForPreviewPlaylist()` 等内置预览至少 3 个媒体分片。
- `waitForAudioRelayPlaylist()` 等音频中继至少 2 个媒体分片。

### 播放中应用时差后服务退出

曾出现过：播放中把音频延后从 4 秒改到 2 秒，日志显示：

- `应用新时差`
- `HTTP 服务已启动`
- 旧 `[http]`、`[audio]`、`[merge]` 进程随后退出
- `[preview] HTTP error 404 File not found`
- `应用时差失败: 合流进程提前退出`

第一层根因是旧 `stop()` 只发送 terminate，不等待旧进程完全退出。`start()` 随即清空 HLS 目录并启动新流程，旧 preview/merge/http 仍可能在读旧分片，导致读到已被清掉的 segment，触发 404 和退出。

第二层根因是：同为“音频延后模式”时，不应该整套 `start()`。从音频延后 4 秒改到 2 秒时，HTTP 服务和音频中继本来可以继续复用，只需要重启最终 `merge` 和 `preview`。整套重启会让旧播放器、旧预览、新 HLS 目录互相撞车。

当前修复：

- `stop()` 会 `await stopProcess(...)`，等待旧子进程真正退出后再清理目录。
- 主动停止的旧进程会记录到 `ignoredTerminationPIDs`，防止旧 termination handler 在新启动后误报服务停止。
- 同为音频延后模式时，`updateDelay` 调用 `restartAudioRelayOffsetMerge(...)`，只停止 `previewProcess` 和 `mergeProcess`，保留 `httpProcess` 和 `audioRelayProcess`。
- `applyDelayChange()` 会设置 `isStarting = true` 和 `statusText = "应用时差中"`，避免用户在重启过程中误以为服务已经稳定运行。

如果仍卡，先读取：

```bash
tail -n 300 "$HOME/Library/Application Support/AptvMerge/logs/current.log"
```

再检查 `Runtime/hls/index.m3u8` 和 `Runtime/hls/preview/index.m3u8` 是否持续刷新。

### 源列表想恢复默认

关闭 App 后执行：

```bash
rm "$HOME/Library/Application Support/AptvMerge/sources.json"
```

再打开 App。

## Git 约定

当前最新提交：

```text
3b4f822 Refine logging panel and app packaging
```

提交前建议：

```bash
cd /Users/lpp/Desktop/Xcode/AptvMerge
git status --short
xcodebuild -project AptvMerge.xcodeproj -scheme AptvMerge -configuration Debug -destination 'platform=macOS' build
git add <需要提交的源码和资源>
git commit -m "<清晰描述>"
```

不要提交：

- `dist/`
- `xcuserdata/`
- `.DS_Store`
- DerivedData
- 用户本机日志和 Runtime 目录

## 下一步可做事项

这些不是必须做，但后续可能会继续：

- 增加“打开日志文件”按钮，直接在 Finder 或 Console 中打开 `current.log`。
- 增加端口设置，不固定 8080。
- 增加 FFmpeg 路径检测和安装提示。
- 增加源可用性测试按钮。
- 增加“重置默认源”按钮。
- 增加日志级别选项：简洁/诊断。
- 优化 Intel Mac 上的内置预览性能，必要时允许关闭内置预览转码。
- 对视频延后大秒数模式继续做稳定性测试，尤其是 15 秒、30 秒以及播放过程中应用新时差。

## 重要提醒

- 用户非常关注实际播放流畅度和 UI 行为。每次改合流逻辑后，除了构建通过，还应尽量让用户实际播放验证。
- 用户已经明确表示：如果下次播放有问题，可以不截图，直接读取本地日志文件。
- 不要把问题简单归因于电脑性能，先看源、日志、FFmpeg 输出和延迟模式。
- 不要随意回滚到旧版本；如果要回滚，先确认目标 commit 或目标功能状态。
- 修改 UI 时注意不要引入文字溢出、控件挤压和日志区域抢占中间区域的问题。
