# 用于Lua 的 splayer-next 兼容协议格式的 ws服务端桥接lua插件
(`splayer-next-compatible-ws-server-bridge`)

[![Release](https://img.shields.io/github/v/release/VincentZyu233/splayer-next-compatible-ws-server-bridge?style=flat-square)](https://github.com/VincentZyu233/splayer-next-compatible-ws-server-bridge/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)

专为 **Lazer** 打造的外部 WebSocket 广播与双向控制插件。兼容 **SPlayer-Next** 的外部 API 协议格式，让基于 SPlayer-Next 协议的 OBS 推流挂件、桌面歌词和外部工具能够开箱即用无缝接入 Lazer。

---

## 🎯 功能特性

- **SPlayer-Next 外部 API 协议兼容**：
  - 监听本地端口：`14558`
  - WebSocket 广播端点：`ws://127.0.0.1:14558/ws`
- **实时事件广播**：
  - 歌曲切换事件：`kind: "event", type: "track"`（歌曲名、歌手列表、封面图、总时长等）
  - 逐行/时序歌词广播：`kind: "event", type: "lyric"`（主歌词、翻译歌词、罗马音歌词）
  - 播放状态同步：`kind: "event", type: "status"`（播放中/暂停、播放进度毫秒、音量等）
- **双向控制支持**：
  - 支持外部工具通过 `control` 指令对 Lazer 进行播放、暂停、切歌、跳转进度和调整音量。
- **与 OBS 挂件完美适配**：
  - 无缝兼容 [`splayer-status-html-overlay-for-obs`](https://github.com/VincentZyu233/splayer-status-html-overlay-for-obs)。

---

## 🚀 安装与使用

### 1. 自动安装（推荐）
在 Lazer 客户端内打开 **设置 -> 插件管理 -> 从插件源安装**，搜索 `splayer` 或 `OBS`，点击安装即可。

### 2. 手动安装
1. 从 [Releases](https://github.com/VincentZyu233/splayer-next-compatible-ws-server-bridge/releases) 下载最新的 `splayer-next-compatible-ws-server-bridge.zip`。
2. 打开 Lazer，进入 **插件管理 -> 导入本地插件**，选择下载的 ZIP 压缩包。
3. 允许插件使用 `WebSocket 服务端` 权限（`127.0.0.1:14558`）。
4. 插件启用后，将在本地监听 `ws://127.0.0.1:14558/ws`。

---

## 📺 OBS 挂件对接方法

1. 下载或打开你的 OBS HTML 挂件（如 `splayer-status-html-overlay-for-obs/index.html`）。
2. 在 OBS 中添加一个 **浏览器源 (Browser Source)**，URL 指向挂件的 `index.html`。
3. 挂件将自动连接至 `ws://127.0.0.1:14558/ws`。
4. 在 Lazer 中播放任意歌曲，OBS 画面中的挂件将立即同步显示专辑封面、歌曲信息、进度条以及滚动歌词！

---

## 📜 许可证

本项目采用 [MIT License](LICENSE) 开源。
