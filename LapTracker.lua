-- ═══════════════════════════════════════════════════════════════════════════════
-- LapTracker.lua  —  CSP Lua App for Assetto Corsa
-- Tracks lap times of selected players -> sends data to Google Sheets
-- Requires: Custom Shaders Patch (CSP) with web.post support
-- ═══════════════════════════════════════════════════════════════════════════════

local DEFAULT_WEBHOOK_URL = ''
-- Optional: leave empty to hide the "Open Sheet" button.
-- This keeps the app independent from scripts.google.
local DEFAULT_SHEET_URL = ''

-- Persistent storage (saved between sessions)
local store = ac.storage({
  webhookUrl  = DEFAULT_WEBHOOK_URL,   -- Google Apps Script webhook URL
  sheetUrl    = DEFAULT_SHEET_URL,     -- Google Sheets URL (optional)
  appEnabled  = true,                  -- Tracking enabled/disabled
  playersList = '',   -- comma-separated player list
})

-- App state
local trackedSet    = {}   -- { [lower(name)] = true }  -- fast lookup
local trackedList   = {}   -- { "Name1", "Name2", ... } -- display list
local prevLapMs     = {}   -- { [carIndex] = lastSeenLapTimeMs }
local prevConnected = {}   -- { [carIndex] = bool }
local activityLog   = {}   -- recent event log (max 20)
local showLog       = false
local manualInput   = ''
local sim           = ac.getSim()

-- Utilities

-- Add an entry to the log
local function addLog(msg)
  table.insert(activityLog, 1, os.date('%H:%M:%S') .. '  ' .. msg)
  if #activityLog > 20 then table.remove(activityLog) end
  ac.log('[LapTracker] ' .. msg)
end

-- Milliseconds -> "M:SS.mmm"
local function msToTime(ms)
  return string.format('%d:%02d.%03d',
    math.floor(ms / 60000),
    math.floor(ms % 60000 / 1000),
    ms % 1000)
end

-- Escape special characters for JSON strings
local function jsonEscape(s)
  return (s or ''):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
end

-- Normalize URL to a safe string (storage can sometimes contain boolean false)
local function normalizeUrl(url)
  if type(url) ~= 'string' then return '' end
  return url:match('^%s*(.-)%s*$')
end

-- Validate URL: web.post accepts only http/https
local function hasRecognizedProtocol(url)
  local normalized = normalizeUrl(url):lower()
  return normalized:find('^https?://') ~= nil
end

-- Open URL in external browser if available in current CSP version
local function openExternalUrl(url)
  local normalized = normalizeUrl(url)
  if normalized == '' or not hasRecognizedProtocol(normalized) then
    addLog('⚠ Некорректный URL таблицы')
    return
  end

  local opened = false

  if type(os) == 'table' and type(os.openURL) == 'function' then
    opened = pcall(os.openURL, normalized)
  elseif type(ac) == 'table' and type(ac.openURL) == 'function' then
    opened = pcall(ac.openURL, normalized)
  end

  if opened then
    addLog('Открыта таблица: ' .. normalized)
  else
    addLog('⚠ Не удалось открыть URL таблицы')
  end
end

-- Normalize stored values on app startup
store.webhookUrl = normalizeUrl(store.webhookUrl)
local normalizedDefaultWebhook = normalizeUrl(DEFAULT_WEBHOOK_URL)
if normalizedDefaultWebhook ~= '' then
  -- Use URL from file as source of truth to avoid stale storage values.
  store.webhookUrl = normalizedDefaultWebhook
elseif store.webhookUrl == '' then
  -- If file default is empty, at least avoid nil/false.
  store.webhookUrl = ''
end

store.sheetUrl = normalizeUrl(store.sheetUrl)
if store.sheetUrl == '' and DEFAULT_SHEET_URL ~= '' then
  store.sheetUrl = DEFAULT_SHEET_URL
end

if type(store.appEnabled) ~= 'boolean' then
  store.appEnabled = true
end

-- Player list management

local function reloadList()
  trackedSet  = {}
  trackedList = {}
  local raw = store.playersList or ''
  -- Parse comma-separated names
  for name in (raw .. ','):gmatch('([^,]*),') do
    name = name:match('^%s*(.-)%s*$') -- trim
    if name ~= '' then
      trackedList[#trackedList + 1] = name
      trackedSet[name:lower()]      = true
    end
  end
end

local function saveList()
  store.playersList = table.concat(trackedList, ',')
end

local function addPlayer(name)
  name = (name or ''):match('^%s*(.-)%s*$')
  if name == '' then return end
  if trackedSet[name:lower()] then return end  -- already in list
  trackedList[#trackedList + 1] = name
  trackedSet[name:lower()]      = true
  saveList()
end

local function removePlayer(idx)
  if not trackedList[idx] then return end
  trackedSet[trackedList[idx]:lower()] = nil
  table.remove(trackedList, idx)
  saveList()
end

-- Initial list load
reloadList()

-- Send lap to Google Sheets

local function sendLap(nickname, carModel, laptime, track)
  local url = normalizeUrl(store.webhookUrl)
  if url == '' then
    url = DEFAULT_WEBHOOK_URL
    store.webhookUrl = url
  end
  if url == '' then
    addLog('⚠ Webhook URL не задан — круг не отправлен')
    return
  end

  if not hasRecognizedProtocol(url) then
    addLog('⚠ The URL does not use a recognized protocol')
    return
  end

  local body = string.format(
    '{"nickname":"%s","car":"%s","laptime":"%s","track":"%s"}',
    jsonEscape(nickname),
    jsonEscape(carModel),
    jsonEscape(laptime),
    jsonEscape(track)
  )

  -- web.post is a built-in CSP Lua function (requires CSP)
  -- If you get "attempt to call nil", try ac.web.post(...)
  web.post(url, body, function(err, res)
    local errText = err and tostring(err) or ''
    local statusCode = (type(res) == 'table') and (res.status or res.statusCode) or nil
    local responseBody = (type(res) == 'table') and (res.body or res.response or '') or ''
    local hasOkBody = type(responseBody) == 'string' and responseBody:find('"status"%s*:%s*"ok"') ~= nil
    local isHttpOk = type(statusCode) == 'number' and statusCode >= 200 and statusCode < 300
    local sent = hasOkBody or isHttpOk

    if sent then
      local msg = '✓ ' .. nickname .. '  |  ' .. carModel .. '  |  ' .. laptime .. '  |  отправлено в таблицу'
      addLog(msg)
      local okToast = pcall(ui.toast, ui.Icons.Confirm, nickname .. '  —  ' .. laptime)
      if not okToast then
        -- UI handle can be unavailable in async callbacks; send result is unaffected.
      end
      return
    end

    if errText ~= '' then
      addLog('✗ ' .. nickname .. ': ' .. errText)
    else
      local debugStatus = statusCode and tostring(statusCode) or 'n/a'
      local debugBody = (type(responseBody) == 'string' and responseBody ~= '') and responseBody or 'empty'
      if #debugBody > 120 then debugBody = debugBody:sub(1, 120) .. '...' end
      addLog('✗ ' .. nickname .. ': ошибка отправки (status=' .. debugStatus .. ', body=' .. debugBody .. ')')
    end
  end)
end

-- Main loop - lap tracking
function script.update(dt)
  if not store.appEnabled then
    -- In OFF mode, sync state only so missed laps are not sent retroactively.
    for i = 0, sim.carsCount - 1 do
      local car = ac.getCar(i)
      if car and car.isConnected then
        prevLapMs[i] = car.previousLapTimeMs
        prevConnected[i] = true
      else
        prevLapMs[i] = nil
        prevConnected[i] = false
      end
    end
    return
  end

  local track = ac.getTrackID() or 'unknown'
  local n     = sim.carsCount

  for i = 0, n - 1 do
    local car = ac.getCar(i)
    if not car then goto continue end

    -- Slot is empty - reset cached data
    if not car.isConnected then
      prevLapMs[i]     = nil
      prevConnected[i] = false
      goto continue
    end

    local lapMs = car.previousLapTimeMs

    -- First time seeing this car: if a valid lap already exists, send it once.
    -- This prevents missing the first valid lap in a session.
    if not prevConnected[i] then
      prevLapMs[i]     = lapMs
      prevConnected[i] = true
      if lapMs > 0 then
        local name = ac.getDriverName(i)
        if trackedSet[name:lower()] then
          sendLap(name, ac.getCarID(i), msToTime(lapMs), track)
        end
      end
      goto continue
    end

    -- Lap time changed and is valid -> lap completed
    if lapMs > 0 and lapMs ~= prevLapMs[i] then
      prevLapMs[i] = lapMs
      local name = ac.getDriverName(i)
      -- Check if this player is tracked
      if trackedSet[name:lower()] then
        sendLap(name, ac.getCarID(i), msToTime(lapMs), track)
      end
    end

    ::continue::
  end
end

-- UI
function script.windowMain(dt)
  ui.pushFont(ui.Font.Small)
  local W = ui.availableSpaceX()

  -- Status indicator
  local currentUrl = normalizeUrl(store.webhookUrl)
  if currentUrl == '' then
    currentUrl = DEFAULT_WEBHOOK_URL
    store.webhookUrl = currentUrl
  end
  local hasUrl = currentUrl ~= ''
  local hasValidProtocol = hasRecognizedProtocol(currentUrl)
  local statusText = hasUrl and (hasValidProtocol and '● Webhook задан' or '● The URL does not use a recognized protocol') or '● Webhook не задан'
  if not store.appEnabled then
    statusText = '● OFF'
  end

  ui.pushStyleColor(ui.StyleColor.Text,
    (store.appEnabled and hasUrl and hasValidProtocol) and rgbm(0.3, 0.9, 0.3, 1) or rgbm(1.0, 0.45, 0.2, 1))
  ui.text(statusText)
  ui.popStyleColor()

  ui.sameLine(W - 44)
  if store.appEnabled then
    ui.pushStyleColor(ui.StyleColor.Button, rgbm(0.75, 0.22, 0.22, 1))
    ui.pushStyleColor(ui.StyleColor.ButtonHovered, rgbm(0.86, 0.28, 0.28, 1))
    ui.pushStyleColor(ui.StyleColor.ButtonActive, rgbm(0.65, 0.18, 0.18, 1))
    if ui.button('OFF##toggle', vec2(44, 0)) then
      store.appEnabled = false
      addLog('Трекинг выключен (OFF)')
    end
    ui.popStyleColor(3)
  else
    ui.pushStyleColor(ui.StyleColor.Button, rgbm(0.22, 0.62, 0.22, 1))
    ui.pushStyleColor(ui.StyleColor.ButtonHovered, rgbm(0.28, 0.73, 0.28, 1))
    ui.pushStyleColor(ui.StyleColor.ButtonActive, rgbm(0.18, 0.52, 0.18, 1))
    if ui.button('ON##toggle', vec2(44, 0)) then
      store.appEnabled = true
      addLog('Трекинг включен (ON)')
    end
    ui.popStyleColor(3)
  end

  local currentSheetUrl = normalizeUrl(store.sheetUrl)
  if currentSheetUrl ~= '' and hasRecognizedProtocol(currentSheetUrl) then
    if ui.button('Открыть таблицу', vec2(W, 0)) then
      openExternalUrl(currentSheetUrl)
    end
  else
    ui.textDisabled('Таблица не задана в файле LapTracker.lua')
  end

  ui.offsetCursorY(6)
  ui.separator()
  ui.offsetCursorY(4)

  -- Players in current session
  ui.header('Игроки в текущей сессии:')
  local anyInSession = false

  for i = 0, sim.carsCount - 1 do
    local car = ac.getCar(i)
    if car and car.isConnected then
      anyInSession    = true
      local name      = ac.getDriverName(i)
      local isTracked = trackedSet[name:lower()]

      if isTracked then
        -- Green - already tracked
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.3, 0.9, 0.3, 1))
        ui.text('● ' .. name)
        ui.popStyleColor()
        ui.sameLine(W - 58)
        if ui.button('Убрать##r' .. i) then
          for j = #trackedList, 1, -1 do
            if trackedList[j]:lower() == name:lower() then
              removePlayer(j); break
            end
          end
        end
      else
        -- Gray - not tracked
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.65, 0.65, 0.65, 1))
        ui.text('○ ' .. name)
        ui.popStyleColor()
        ui.sameLine(W - 72)
        if ui.button('+ Следить##a' .. i) then
          addPlayer(name)
        end
      end
    end
  end

  if not anyInSession then
    ui.textDisabled('  Нет игроков в сессии')
  end

  ui.offsetCursorY(6)
  ui.separator()
  ui.offsetCursorY(4)

  -- Tracked list
  ui.header('Отслеживаются (' .. #trackedList .. '):')

  if #trackedList == 0 then
    ui.textDisabled('  Список пуст — добавьте игроков выше')
  else
    -- Iterate in reverse so deletion does not break indices
    for i = #trackedList, 1, -1 do
      local name = trackedList[i]
      ui.text(name)
      ui.sameLine(W - 18)
      if ui.button('×##d' .. i) then
        removePlayer(i)
      end
    end
  end

  ui.offsetCursorY(6)
  ui.separator()
  ui.offsetCursorY(4)

  -- Add manually
  ui.header('Добавить игрока вручную:')
  ui.setNextItemWidth(W - 82)
  local manOk, manNew = ui.inputText('##manual', manualInput)
  if manOk then manualInput = manNew end
  ui.sameLine(0, 4)
  if ui.button('Добавить') then
    if manualInput ~= '' then
      addPlayer(manualInput)
      manualInput = ''
    end
  end

  ui.offsetCursorY(6)
  ui.separator()
  ui.offsetCursorY(4)

  -- Event log
  if ui.button((showLog and '▲' or '▼') ..
               '  Лог  (' .. #activityLog .. ')', vec2(W, 0)) then
    showLog = not showLog
  end

  if showLog then
    ui.offsetCursorY(2)
    if #activityLog == 0 then
      ui.textDisabled('  Пусто')
    else
      ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.65, 0.65, 0.65, 1))
      for _, line in ipairs(activityLog) do
        ui.textWrapped(line)
      end
      ui.popStyleColor()
    end
  end

  ui.popFont()
end