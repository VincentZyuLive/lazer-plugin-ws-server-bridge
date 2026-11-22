--[[
  lazer-plugin-ws-server-bridge (lazer.ws.bridge)
  专为 Lazer 打造的外部 WebSocket 服务端状态广播与双向控制桥接插件

  对标 SPlayer-Next 外部 API 规范与官方实现源头：
  - 双向通道与控制指令规范 (ws.ts)：
    https://github.com/SPlayer-Dev/SPlayer-Next/blob/9d3ca78f107b7cbe28b1ef7ce9041de9bad55531/electron/main/server/ws.ts#L1-L11
  - 广播事件数据封包格式 (broadcast.ts)：
    https://github.com/SPlayer-Dev/SPlayer-Next/blob/9d3ca78f107b7cbe28b1ef7ce9041de9bad55531/electron/main/server/broadcast.ts#L32-L45

  数据与服务契约：
  - 默认监听端口：14558
  - WebSocket 服务端端点：ws://127.0.0.1:14558/ws
  - 下行广播格式：{ "kind": "event", "type": "track"|"lyric"|"status", "data": ... }
  - 上行控制格式：{ "op": "play"|"pause"|"stop"|"toggle"|"next"|"prev"|"seek"|"volume", ... }
--]]

local plugin = {}

local SERVER_ID = "splayer_next_ws_server"
local DEFAULT_PORT = 14558
local WS_PATH = "/ws"

-- 内部缓存当前播放状态与行为配置，供新连入挂件即时同步
local state = {
  listening = false,
  port = DEFAULT_PORT,
  enabled = true,
  broadcast_track = true,
  broadcast_lyric = true,
  broadcast_status = false, -- 默认关闭每秒高频心跳，避免不必要的轮询唤醒；切歌与歌词依然即时推送
  current_track = nil,
  current_lyric = nil,
  current_status = {
    state = "paused",
    position = 0,
    duration = 0,
    volume = 1.0,
  },
}

--- 格式化 SPlayer-Next 规范的曲目 payload
local function format_track_payload(raw)
  if not raw or type(raw) ~= "table" then
    return nil
  end

  local artists = {}
  if type(raw.artists) == "table" then
    for _, a in ipairs(raw.artists) do
      if type(a) == "table" and a.name then
        table.insert(artists, a.name)
      elseif type(a) == "string" then
        table.insert(artists, a)
      end
    end
  end

  local artist_str = raw.artist or (#artists > 0 and table.concat(artists, ", ") or "")
  local title_str = raw.title or raw.name or ""
  local cover_str = raw.cover or raw.coverOriginal or raw.coverUrl or raw.picUrl or raw.artwork or ""

  return {
    id = tostring(raw.id or ""),
    name = title_str,
    title = title_str,
    artist = artist_str,
    artists = artists,
    album = raw.album or raw.albumName or "",
    cover = cover_str,
    coverOriginal = cover_str,
    coverUrl = cover_str,
    picUrl = cover_str,
    duration = math.floor(tonumber(raw.duration or raw.durationMs or 0) or 0),
  }
end

--- 格式化 SPlayer-Next 规范的歌词行 payload
local function format_lyric_payload(raw)
  if not raw or type(raw) ~= "table" then
    return { lyric = {} }
  end

  local raw_lines = raw.lines or raw.lyric or raw
  if type(raw_lines) ~= "table" then
    return { lyric = {} }
  end

  local formatted_lines = {}
  local count = #raw_lines
  for i = 1, count do
    local line = raw_lines[i]
    if type(line) == "table" then
      local start_time = math.floor(tonumber(line.startTime or line.time or 0) or 0)
      local end_time = tonumber(line.endTime or 0)
      if not end_time or end_time <= start_time then
        local next_line = raw_lines[i + 1]
        if type(next_line) == "table" then
          local next_start = tonumber(next_line.startTime or next_line.time)
          if next_start and next_start > start_time then
            end_time = math.floor(next_start)
          else
            end_time = start_time + 4000
          end
        else
          end_time = start_time + 4000
        end
      else
        end_time = math.floor(end_time)
      end

      local text_str = tostring(line.text or line.content or "")
      local trans_str = tostring(line.translatedLyric or line.tlyric or line.translation or "")
      local roman_str = tostring(line.romanLyric or line.rlyric or line.romanization or line.romaji or "")

      local item = {
        startTime = start_time,
        endTime = end_time,
        text = text_str,
      }
      if trans_str ~= "" then
        item.translatedLyric = trans_str
      end
      if roman_str ~= "" then
        item.romanLyric = roman_str
      end

      if type(line.words) == "table" then
        item.words = line.words
      end

      table.insert(formatted_lines, item)
    end
  end

  return {
    source = raw.source or { format = "lrc", source = "online" },
    lyric = formatted_lines,
    pureMusic = raw.pureMusic or false,
  }
end

--- 广播消息给所有连接的客户端
local function broadcast(kind, event_type, data)
  if not state.listening then
    return
  end

  local message = {
    kind = kind or "event",
    type = event_type,
    data = data,
  }

  pcall(function()
    local encoded = host.json_encode(message)
    host.websocket_server({
      id = SERVER_ID,
      operation = "broadcast",
      data = encoded,
    })
  end)
end

--- 启动 WebSocket 服务端
local function start_server()
  if state.listening then
    return true
  end

  local ok, res = pcall(function()
    return host.websocket_server({
      id = SERVER_ID,
      operation = "listen",
      host = "127.0.0.1",
      port = state.port,
      path = WS_PATH,
    })
  end)

  if ok and res then
    state.listening = true
    return true
  else
    state.listening = false
    return false, res
  end
end

--- 停止 WebSocket 服务端
local function stop_server()
  if not state.listening then
    return true
  end

  pcall(function()
    host.websocket_server({
      id = SERVER_ID,
      operation = "close",
    })
  end)

  state.listening = false
  return true
end

--- 插件主入口响应
function plugin.call(operation, args)
  args = args or {}

  -- 1. 播放器事件下行通知 (来自 Lazer 宿主)
  if operation == "player_event" then
    if not state.enabled then
      return false
    end

    -- 首次收到事件时，若未启动服务则自动尝试拉起
    if not state.listening then
      start_server()
    end

    local event_type = args.type
    local event_data = args.data or {}

    if event_type == "track" then
      local formatted = format_track_payload(event_data)
      state.current_track = formatted

      -- 切歌时立即重置当前歌词并广播空歌词清屏，防止下游挂件残留上一首的歌词
      state.current_lyric = {
        source = { format = "lrc", source = "online" },
        lyric = {},
        pureMusic = false,
      }

      if state.broadcast_track then
        broadcast("event", "track", formatted or {})
      end
      if state.broadcast_lyric then
        broadcast("event", "lyric", state.current_lyric)
      end
      return true
    elseif event_type == "lyric" then
      local payload = format_lyric_payload(event_data)
      state.current_lyric = payload
      if state.broadcast_lyric then
        broadcast("event", "lyric", payload)
      end
      return true
    elseif event_type == "status" then
      state.current_status.state = event_data.state or state.current_status.state
      state.current_status.position = math.floor(tonumber(event_data.position or 0) or 0)
      state.current_status.duration = math.floor(tonumber(event_data.duration or 0) or 0)
      if event_data.volume ~= nil then
        state.current_status.volume = tonumber(event_data.volume)
      end
      if state.broadcast_status then
        broadcast("event", "status", state.current_status)
      end
      return true
    end

    return false
  end

  -- 2. 响应宿主设置变更（host.add_setting）
  if operation == "setting_changed" then
    local id = args.id
    local val = args.value
    if id == "splayer_ws_enabled" then
      state.enabled = (val == true)
      if state.enabled then
        start_server()
      else
        stop_server()
      end
    elseif id == "splayer_ws_broadcast_track" then
      state.broadcast_track = (val == true)
    elseif id == "splayer_ws_broadcast_lyric" then
      state.broadcast_lyric = (val == true)
    elseif id == "splayer_ws_broadcast_status" then
      state.broadcast_status = (val == true)
    end
    return true
  end

  -- 3. 响应插件页面控件交互（host.add_page 按钮点击等）
  if operation == "page_event" then
    if args.id == "restart_service" then
      stop_server()
      start_server()
      return true
    end
    return true
  end

  -- 4. 响应播放器菜单快捷点击
  if operation == "player_menu" then
    if args.id == "splayer_ws_restart" then
      stop_server()
      start_server()
      return true
    end
    return true
  end

  -- 5. 接收外部控制指令（Lua -> Dart）
  if operation == "control" then
    local ok, res = pcall(function()
      return host.player_control(args)
    end)
    return ok and res or false
  end

  -- 6. 服务端管理与手动拉起接口
  if operation == "start" then
    return start_server()
  end

  if operation == "stop" then
    return stop_server()
  end

  if operation == "status" then
    return {
      listening = state.listening,
      port = state.port,
      path = WS_PATH,
      url = string.format("ws://127.0.0.1:%d%s", state.port, WS_PATH),
      enabled = state.enabled,
      broadcast_track = state.broadcast_track,
      broadcast_lyric = state.broadcast_lyric,
      broadcast_status = state.broadcast_status,
      track = state.current_track,
      playback = state.current_status,
    }
  end

  return nil
end

-- 模块加载时尝试注册设置、页面与快捷项
pcall(function()
  -- 注册精细化设置开关 (Lazer 宿主原生 UI 渲染)
  if host.add_setting then
    host.add_setting({
      id = "splayer_ws_enabled",
      title = "启用 OBS / SPlayer WebSocket 广播服务",
      subtitle = "在 ws://127.0.0.1:14558/ws 本地端口监听连接并接收外部控制",
      type = "toggle",
      default = true,
    })
    host.add_setting({
      id = "splayer_ws_broadcast_track",
      title = "广播切歌数据 (Track)",
      subtitle = "切歌时向 OBS / 外部挂件推送歌曲标题、歌手与专辑封面",
      type = "toggle",
      default = true,
    })
    host.add_setting({
      id = "splayer_ws_broadcast_lyric",
      title = "广播歌词数据 (Lyric)",
      subtitle = "歌曲包含歌词时向外部挂件推送逐行与翻译歌词",
      type = "toggle",
      default = true,
    })
    host.add_setting({
      id = "splayer_ws_broadcast_status",
      title = "广播高频播放进度心跳 (Status)",
      subtitle = "每秒向挂件推送播放进度与音量（若仅需歌词与曲名，建议关闭以节省能耗）",
      type = "toggle",
      default = false,
    })
  end

  -- 注册原生插件声明与展示面板 (host.add_page)
  if host.add_page then
    host.add_page({
      id = "ws_bridge_panel",
      title = "OBS / SPlayer 外部桥接面板",
      subtitle = "本地服务状态监控、接入指引与隐私声明",
      icon = "sensors",
      elements = {
        { type = "section", title = "使用声明与公告" },
        {
          type = "text",
          text = "本插件仅在本地环回地址 (127.0.0.1:14558) 开启 WebSocket 服务，专供本机 OBS 浏览器源或第三方悬浮歌词挂件读取播放信息，绝不会向任何公网服务器上传您的播放历史或账号凭据。\n\n如需降低后台负载与电量消耗，可在插件设置中关闭「高频播放进度心跳」，挂件仍可正常接收切歌与歌词推送。",
        },
        { type = "divider" },
        { type = "section", title = "OBS 挂件连接信息" },
        {
          type = "text",
          text = "• 服务端连接地址：ws://127.0.0.1:14558/ws\n• 协议规范：兼容 SPlayer-Next 外部 API 规范\n• 双向控制：支持外部挂件发送播放、暂停、切歌、音量调节",
        },
        {
          type = "button",
          id = "restart_service",
          title = "重启本地 WebSocket 服务",
          icon = "refresh",
        },
      },
    })
  end

  -- 注册播放器菜单快捷项
  if host.add_player_menu_item then
    host.add_player_menu_item({
      id = "splayer_ws_restart",
      label = "重启 OBS 广播服务 (14558 端口)",
      icon = "refresh",
    })
  end

  start_server()
end)

return plugin
