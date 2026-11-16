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

-- 内部缓存当前播放状态，供新连入挂件即时同步
local state = {
  listening = false,
  port = DEFAULT_PORT,
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
    -- 首次收到事件时，若未启动服务则自动尝试拉起
    if not state.listening then
      start_server()
    end

    local event_type = args.type
    local event_data = args.data or {}

    if event_type == "track" then
      local formatted = format_track_payload(event_data)
      state.current_track = formatted
      broadcast("event", "track", formatted or {})
      return true
    elseif event_type == "lyric" then
      local payload = format_lyric_payload(event_data)
      state.current_lyric = payload
      broadcast("event", "lyric", payload)
      return true
    elseif event_type == "status" then
      state.current_status.state = event_data.state or state.current_status.state
      state.current_status.position = math.floor(tonumber(event_data.position or 0) or 0)
      state.current_status.duration = math.floor(tonumber(event_data.duration or 0) or 0)
      if event_data.volume ~= nil then
        state.current_status.volume = tonumber(event_data.volume)
      end
      broadcast("event", "status", state.current_status)
      return true
    end

    return false
  end

  -- 2. 接收外部控制指令（Lua -> Dart）
  if operation == "control" then
    local ok, res = pcall(function()
      return host.player_control(args)
    end)
    return ok and res or false
  end

  -- 3. 服务端管理与手动拉起接口
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
      track = state.current_track,
      playback = state.current_status,
    }
  end

  return nil
end

-- 模块加载时尝试注册并拉起服务
pcall(function()
  -- 注册设置项
  if host.add_setting then
    host.add_setting({
      id = "splayer_ws_enabled",
      name = "启用 OBS / SPlayer WebSocket 广播",
      description = "在 ws://127.0.0.1:14558/ws 实时广播播放状态与歌词",
      type = "boolean",
      default = true,
    })
  end

  -- 注册播放器菜单快捷项
  if host.add_player_menu_item then
    host.add_player_menu_item({
      id = "splayer_ws_restart",
      title = "重启 OBS 广播服务 (ws://127.0.0.1:14558/ws)",
      command = "restart_ws",
    })
  end

  start_server()
end)

return plugin
