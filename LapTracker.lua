-- ═══════════════════════════════════════════════════════════════════════════════
-- LapTracker.lua  —  CSP Lua App для Assetto Corsa
-- Отслеживает время кругов выбранных игроков → отправляет в Google Sheets
-- Требует: Custom Shaders Patch (CSP) с поддержкой web.post
-- ═══════════════════════════════════════════════════════════════════════════════

local DEFAULT_WEBHOOK_URL = ''
-- Необязательно: можно оставить пустым, тогда кнопка открытия таблицы будет скрыта.
-- Это делает приложение независимым от файла scripts.google.
local DEFAULT_SHEET_URL = ''
local APP_VERSION = 15

-- Настройте ссылки на GitHub-репозиторий для проверки обновлений.
-- UPDATE_VERSION_URL: raw-файл с версией (поддерживается JSON, число или manifest.ini с "VERSION = ...")
local UPDATE_VERSION_URL = 'https://raw.githubusercontent.com/OutTuna/LapTracker/main/manifest.ini'
local UPDATE_RELEASES_URL = 'https://github.com/OutTuna/LapTracker/releases'
local AUTO_OPEN_RELEASES_ON_UPDATE = true

-- Постоянное хранилище (сохраняется между сессиями)
local store = ac.storage({
  webhookUrl  = DEFAULT_WEBHOOK_URL,   -- URL вебхука Google Apps Script
  sheetUrl    = DEFAULT_SHEET_URL,     -- URL Google Sheets (опционально)
  appEnabled  = true,                  -- Вкл/выкл трекинга
  appLanguage = 'ru',                  -- Язык интерфейса: ru/en
  playersList = '',   -- список игроков через запятую
})

-- Состояние приложения
local trackedSet    = {}   -- { [lower(name)] = true }  — быстрая проверка
local trackedList   = {}   -- { "Name1", "Name2", ... } — для отображения
local prevLapMs     = {}   -- { [carIndex] = lastSeenLapTimeMs }
local prevConnected = {}   -- { [carIndex] = bool }
local activityLog   = {}   -- лог последних событий (макс. 20)
local showLog       = false
local manualInput   = ''
local sim           = ac.getSim()
local updateState   = {
  checked   = false,
  checking  = false,
  available = false,
  latest    = nil,
  error     = nil,
}
local didAutoUpdateCheck = false
local didAutoOpenReleasePage = false

local I18N = {
  ru = {
    ui_status_webhook_ok = '● Webhook задан',
    ui_status_protocol_bad = '● Некорректный протокол URL',
    ui_status_webhook_missing = '● Webhook не задан',
    ui_status_off = '● OFF',
    ui_btn_lang = 'Язык: %s',
    ui_btn_open_sheet = 'Открыть таблицу',
    ui_sheet_not_set = 'Таблица не задана в файле LapTracker.lua',
    ui_btn_check_update = 'Проверить обновление',
    ui_btn_checking_update = 'Проверка обновления...',
    ui_version_prefix = 'Ваша версия: v%s | ',
    ui_update_checking = 'Идет проверка...',
    ui_update_required = 'Обновление требуется (v%s)',
    ui_update_not_required = 'Обновление не требуется',
    ui_update_failed = 'Не удалось проверить',
    ui_btn_open_release = 'Открыть страницу обновления',
    ui_release_url_missing = 'Не задан UPDATE_RELEASES_URL',
    ui_players_header = 'Игроки в текущей сессии:',
    ui_btn_remove = 'Убрать',
    ui_btn_follow = '+ Следить',
    ui_no_players = '  Нет игроков в сессии',
    ui_tracked_header = 'Отслеживаются (%d):',
    ui_tracked_empty = '  Список пуст — добавьте игроков выше',
    ui_manual_add_header = 'Добавить игрока вручную:',
    ui_btn_add = 'Добавить',
    ui_log_header = '  Лог  (%d)',
    ui_log_empty = '  Пусто',
    log_bad_sheet_url = '⚠ Некорректный URL таблицы',
    log_url_opened = 'Открыт URL: %s',
    log_url_open_fail = '⚠ Не удалось открыть URL',
    log_handle_error = 'Временная ошибка сетевого запроса. Повторите попытку через пару секунд.',
    log_default_webhook_bad = '⚠ DEFAULT_WEBHOOK_URL пуст или некорректен',
    log_webhook_reset_reason = 'Webhook сброшен на DEFAULT_WEBHOOK_URL (%s)',
    log_webhook_reset = 'Webhook сброшен на DEFAULT_WEBHOOK_URL',
    log_update_url_missing = 'URL проверки обновления не настроен',
    log_update_check_error = '⚠ Ошибка проверки обновления: %s',
    log_update_bad_response = '⚠ Обновление: некорректный ответ сервера',
    log_update_available = 'Доступно обновление: v%s (текущая v%s)',
    log_update_actual = 'Установлена актуальная версия: v%s',
    log_auto_open_release = 'Автообновление: открываю страницу релиза',
    log_webhook_missing = '⚠ Webhook URL не задан — круг не отправлен',
    log_protocol_error = '⚠ Некорректный протокол URL',
    log_webhook_is_sheet = '⚠ Webhook URL указывает на таблицу, нужен URL веб-приложения Apps Script (.../exec)',
    log_webhook_format_hint = '⚠ Проверьте Webhook URL: обычно нужен Apps Script URL формата .../macros/s/.../exec',
    log_sent = '✓ %s  |  %s  |  %s  |  отправлено в таблицу',
    log_send_404 = '✗ %s: webhook не найден (404). Обновите URL деплоя Apps Script (.../exec)',
    log_send_html = '✗ %s: сервер вернул HTML вместо JSON. Проверьте, что Webhook URL ведет на Apps Script /exec',
    log_send_error = '✗ %s: ошибка отправки (status=%s, body=%s)',
    log_tracking_off = 'Трекинг выключен (OFF)',
    log_tracking_on = 'Трекинг включен (ON)',
  },
  en = {
    ui_status_webhook_ok = '● Webhook configured',
    ui_status_protocol_bad = '● Invalid URL protocol',
    ui_status_webhook_missing = '● Webhook is missing',
    ui_status_off = '● OFF',
    ui_btn_lang = 'Language: %s',
    ui_btn_open_sheet = 'Open Sheet',
    ui_sheet_not_set = 'Sheet URL is not set in LapTracker.lua',
    ui_btn_check_update = 'Check for Updates',
    ui_btn_checking_update = 'Checking for updates...',
    ui_version_prefix = 'Your version: v%s | ',
    ui_update_checking = 'Checking...',
    ui_update_required = 'Update required (v%s)',
    ui_update_not_required = 'No update required',
    ui_update_failed = 'Check failed',
    ui_btn_open_release = 'Open Update Page',
    ui_release_url_missing = 'UPDATE_RELEASES_URL is not set',
    ui_players_header = 'Players in current session:',
    ui_btn_remove = 'Remove',
    ui_btn_follow = '+ Follow',
    ui_no_players = '  No players in session',
    ui_tracked_header = 'Tracked (%d):',
    ui_tracked_empty = '  List is empty — add players above',
    ui_manual_add_header = 'Add player manually:',
    ui_btn_add = 'Add',
    ui_log_header = '  Log  (%d)',
    ui_log_empty = '  Empty',
    log_bad_sheet_url = '⚠ Invalid sheet URL',
    log_url_opened = 'Opened URL: %s',
    log_url_open_fail = '⚠ Failed to open URL',
    log_handle_error = 'Temporary network request error. Please retry in a few seconds.',
    log_default_webhook_bad = '⚠ DEFAULT_WEBHOOK_URL is empty or invalid',
    log_webhook_reset_reason = 'Webhook reset to DEFAULT_WEBHOOK_URL (%s)',
    log_webhook_reset = 'Webhook reset to DEFAULT_WEBHOOK_URL',
    log_update_url_missing = 'Update check URL is not configured',
    log_update_check_error = '⚠ Update check error: %s',
    log_update_bad_response = '⚠ Update check: invalid server response',
    log_update_available = 'Update available: v%s (current v%s)',
    log_update_actual = 'Current version is up to date: v%s',
    log_auto_open_release = 'Auto-update: opening release page',
    log_webhook_missing = '⚠ Webhook URL is not set — lap was not sent',
    log_protocol_error = '⚠ The URL does not use a recognized protocol',
    log_webhook_is_sheet = '⚠ Webhook URL points to a sheet, expected Apps Script Web App URL (.../exec)',
    log_webhook_format_hint = '⚠ Check Webhook URL: expected Apps Script format .../macros/s/.../exec',
    log_sent = '✓ %s  |  %s  |  %s  |  sent to sheet',
    log_send_404 = '✗ %s: webhook not found (404). Update Apps Script deployment URL (.../exec)',
    log_send_html = '✗ %s: server returned HTML instead of JSON. Check that Webhook URL points to Apps Script /exec',
    log_send_error = '✗ %s: send error (status=%s, body=%s)',
    log_tracking_off = 'Tracking disabled (OFF)',
    log_tracking_on = 'Tracking enabled (ON)',
  }
}

local function lang()
  return store.appLanguage == 'en' and 'en' or 'ru'
end

local function tr(key)
  local v = I18N[lang()][key]
  if v == nil then return key end
  return v
end

local function trf(key, ...)
  return string.format(tr(key), ...)
end

-- Утилиты

-- Добавить запись в лог
local function addLog(msg)
  table.insert(activityLog, 1, os.date('%H:%M:%S') .. '  ' .. msg)
  if #activityLog > 20 then table.remove(activityLog) end
  ac.log('[LapTracker] ' .. msg)
end

local function normalizeRequestError(errText)
  local text = tostring(errText or '')
  local lower = text:lower()

  if lower:find('handle', 1, true) then
    return tr('log_handle_error')
  end

  return text
end

-- Миллисекунды → "M:SS.mmm"
local function msToTime(ms)
  return string.format('%d:%02d.%03d',
    math.floor(ms / 60000),
    math.floor(ms % 60000 / 1000),
    ms % 1000)
end

-- Экранировать спецсимволы для JSON-строки
local function jsonEscape(s)
  return (s or ''):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
end

-- Привести URL к безопасной строке (в storage иногда попадает boolean false)
local function normalizeUrl(url)
  if type(url) ~= 'string' then return '' end
  return url:match('^%s*(.-)%s*$')
end

-- Проверка URL: web.post принимает только http/https
local function hasRecognizedProtocol(url)
  local normalized = normalizeUrl(url):lower()
  return normalized:find('^https?://') ~= nil
end

local function isGoogleSheetUrl(url)
  local normalized = normalizeUrl(url):lower()
  return normalized:find('^https?://docs%.google%.com/spreadsheets/') ~= nil
end

local function isAppsScriptExecUrl(url)
  local normalized = normalizeUrl(url):lower()
  return normalized:find('^https?://script%.google%.com/macros/s/.+/exec') ~= nil
end

-- Открыть URL во внешнем браузере, если функция доступна в текущей версии CSP
local function openExternalUrl(url)
  local normalized = normalizeUrl(url)
  if normalized == '' or not hasRecognizedProtocol(normalized) then
    addLog(tr('log_bad_sheet_url'))
    return
  end

  local opened = false

  if type(os) == 'table' and type(os.openURL) == 'function' then
    opened = pcall(os.openURL, normalized)
  elseif type(ac) == 'table' and type(ac.openURL) == 'function' then
    opened = pcall(ac.openURL, normalized)
  end

  if opened then
    addLog(trf('log_url_opened', normalized))
  else
    addLog(tr('log_url_open_fail'))
  end
end

-- Вытащить номер версии из строки/JSON, например "16" или {"version":"16"}
local function parseRemoteVersion(text)
  if type(text) ~= 'string' then return nil end
  local fromManifest = text:match('[\r\n]%s*VERSION%s*=%s*([%d%.]+)') or text:match('^%s*VERSION%s*=%s*([%d%.]+)')
  if fromManifest then
    local parsedManifest = tonumber(fromManifest)
    if parsedManifest then return parsedManifest end
  end
  local fromJson = text:match('"version"%s*:%s*"?(%d+)"?')
  if fromJson then return tonumber(fromJson) end
  local trimmed = text:match('^%s*(.-)%s*$')
  local fromPlain = trimmed:match('^(%d+)$')
  if fromPlain then return tonumber(fromPlain) end
  return nil
end

local function resetWebhookToDefault(reason)
  local fallback = normalizeUrl(DEFAULT_WEBHOOK_URL)
  if fallback == '' or not hasRecognizedProtocol(fallback) then
    addLog(tr('log_default_webhook_bad'))
    return false
  end

  if normalizeUrl(store.webhookUrl) ~= fallback then
    store.webhookUrl = fallback
    if reason and reason ~= '' then
      addLog(trf('log_webhook_reset_reason', reason))
    else
      addLog(tr('log_webhook_reset'))
    end
  end

  return true
end

local function checkForUpdates()
  if updateState.checking then return end

  local versionUrl = normalizeUrl(UPDATE_VERSION_URL)
  if versionUrl == '' or not hasRecognizedProtocol(versionUrl) then
    updateState.checked = true
    updateState.available = false
    updateState.latest = nil
    updateState.error = tr('log_update_url_missing')
    return
  end

  updateState.checked = false
  updateState.checking = true
  updateState.available = false
  updateState.latest = nil
  updateState.error = nil

  web.get(versionUrl, function(err, res)
    updateState.checking = false
    updateState.checked = true

    local errText = err and tostring(err) or ''
    if errText ~= '' then
      updateState.available = false
      updateState.latest = nil
      local normalizedErr = normalizeRequestError(errText)
      updateState.error = normalizedErr
      addLog(trf('log_update_check_error', normalizedErr))
      return
    end

    local statusCode = (type(res) == 'table') and (res.status or res.statusCode) or nil
    if type(statusCode) == 'number' and (statusCode < 200 or statusCode >= 300) then
      updateState.available = false
      updateState.latest = nil
      updateState.error = 'HTTP ' .. tostring(statusCode)
      addLog(trf('log_update_check_error', 'HTTP ' .. tostring(statusCode)))
      return
    end

    local responseBody = (type(res) == 'table') and (res.body or res.response or '') or ''
    local remoteVersion = parseRemoteVersion(responseBody)
    if not remoteVersion then
      updateState.available = false
      updateState.latest = nil
      updateState.error = tr('log_update_bad_response')
      addLog(tr('log_update_bad_response'))
      return
    end

    updateState.latest = remoteVersion
    updateState.available = remoteVersion > APP_VERSION

    if updateState.available then
      addLog(trf('log_update_available', tostring(remoteVersion), tostring(APP_VERSION)))

      local releasesUrl = normalizeUrl(UPDATE_RELEASES_URL)
      if AUTO_OPEN_RELEASES_ON_UPDATE and not didAutoOpenReleasePage and releasesUrl ~= '' and hasRecognizedProtocol(releasesUrl) then
        didAutoOpenReleasePage = true
        addLog(tr('log_auto_open_release'))
        openExternalUrl(releasesUrl)
      end
    else
      addLog(trf('log_update_actual', tostring(APP_VERSION)))
    end
  end)
end

-- Нормализация сохранённого значения при старте приложения
store.webhookUrl = normalizeUrl(store.webhookUrl)
local normalizedDefaultWebhook = normalizeUrl(DEFAULT_WEBHOOK_URL)
if store.webhookUrl == '' and normalizedDefaultWebhook ~= '' then
  -- Заполняем из дефолта только при первом запуске, чтобы обновления кода не затирали локальный ключ.
  store.webhookUrl = normalizedDefaultWebhook
elseif store.webhookUrl == '' then
  -- Если оба значения пустые, хотя бы не оставляем nil/false.
  store.webhookUrl = ''
end

store.sheetUrl = normalizeUrl(store.sheetUrl)
if store.sheetUrl == '' and DEFAULT_SHEET_URL ~= '' then
  store.sheetUrl = DEFAULT_SHEET_URL
end

if type(store.appEnabled) ~= 'boolean' then
  store.appEnabled = true
end

if store.appLanguage ~= 'ru' and store.appLanguage ~= 'en' then
  store.appLanguage = 'ru'
end

if store.appEnabled then
  resetWebhookToDefault('авто при старте')
end

-- Управление списком игроков

local function reloadList()
  trackedSet  = {}
  trackedList = {}
  local raw = store.playersList or ''
  -- парсим имена через запятую
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
  if trackedSet[name:lower()] then return end  -- уже есть
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

-- Начальная загрузка списка
reloadList()

-- Отправка круга в Google Sheets

local function sendLap(nickname, carModel, laptime, track)
  local url = normalizeUrl(store.webhookUrl)
  if url == '' then
    url = DEFAULT_WEBHOOK_URL
    store.webhookUrl = url
  end
  if url == '' then
    addLog(tr('log_webhook_missing'))
    return
  end

  if not hasRecognizedProtocol(url) then
    addLog(tr('log_protocol_error'))
    return
  end

  if isGoogleSheetUrl(url) then
    addLog(tr('log_webhook_is_sheet'))
    return
  end

  if not isAppsScriptExecUrl(url) then
    addLog(tr('log_webhook_format_hint'))
  end

  local body = string.format(
    '{"nickname":"%s","car":"%s","laptime":"%s","track":"%s","appVersion":"%s"}',
    jsonEscape(nickname),
    jsonEscape(carModel),
    jsonEscape(laptime),
    jsonEscape(track),
    jsonEscape(tostring(APP_VERSION))
  )

  -- web.post — встроенная функция CSP Lua (требует CSP)
  -- Если выдаёт ошибку "attempt to call nil", попробуй ac.web.post(...)
  web.post(url, body, function(err, res)
    local errText = err and tostring(err) or ''
    local statusCode = (type(res) == 'table') and (res.status or res.statusCode) or nil
    local responseBody = (type(res) == 'table') and (res.body or res.response or '') or ''
    local hasOkBody = type(responseBody) == 'string' and responseBody:find('"status"%s*:%s*"ok"') ~= nil
    local isHttpOk = type(statusCode) == 'number' and statusCode >= 200 and statusCode < 300
    local sent = hasOkBody or isHttpOk

    if sent then
      local msg = trf('log_sent', nickname, carModel, laptime)
      addLog(msg)
      return
    end

    if errText ~= '' then
      addLog('✗ ' .. nickname .. ': ' .. normalizeRequestError(errText))
    else
      local debugStatus = statusCode and tostring(statusCode) or 'n/a'
      local debugBody = (type(responseBody) == 'string' and responseBody ~= '') and responseBody or 'empty'
      local bodyLower = (type(responseBody) == 'string') and responseBody:lower() or ''
      if #debugBody > 120 then debugBody = debugBody:sub(1, 120) .. '...' end

      if statusCode == 404 then
        addLog(trf('log_send_404', nickname))
      elseif bodyLower:find('<!doctype html', 1, true) or bodyLower:find('<html', 1, true) then
        addLog(trf('log_send_html', nickname))
      else
        addLog(trf('log_send_error', nickname, debugStatus, debugBody))
      end
    end
  end)
end

-- Основной цикл — отслеживание кругов
function script.update(dt)
  if not didAutoUpdateCheck then
    didAutoUpdateCheck = true
    checkForUpdates()
  end

  if not store.appEnabled then
    -- В режиме OFF просто синхронизируем состояние, чтобы после включения
    -- не отправлять пропущенные круги задним числом.
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

    -- Слот свободен — сбросить данные
    if not car.isConnected then
      prevLapMs[i]     = nil
      prevConnected[i] = false
      goto continue
    end

    local lapMs = car.previousLapTimeMs

    -- Первый раз видим машину: если уже есть валидный круг, отправим его один раз.
    -- Это устраняет кейс, когда первый круг в игре не попадал в отчёт.
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

    -- Время круга изменилось и оно валидное → круг завершён
    if lapMs > 0 and lapMs ~= prevLapMs[i] then
      prevLapMs[i] = lapMs
      local name = ac.getDriverName(i)
      -- Проверяем, отслеживается ли этот игрок
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

  -- Индикатор статуса
  local currentUrl = normalizeUrl(store.webhookUrl)
  if currentUrl == '' then
    currentUrl = DEFAULT_WEBHOOK_URL
    store.webhookUrl = currentUrl
  end
  local hasUrl = currentUrl ~= ''
  local hasValidProtocol = hasRecognizedProtocol(currentUrl)
  local statusText = hasUrl and (hasValidProtocol and tr('ui_status_webhook_ok') or tr('ui_status_protocol_bad')) or tr('ui_status_webhook_missing')
  if not store.appEnabled then
    statusText = tr('ui_status_off')
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
      addLog(tr('log_tracking_off'))
    end
    ui.popStyleColor(3)
  else
    ui.pushStyleColor(ui.StyleColor.Button, rgbm(0.22, 0.62, 0.22, 1))
    ui.pushStyleColor(ui.StyleColor.ButtonHovered, rgbm(0.28, 0.73, 0.28, 1))
    ui.pushStyleColor(ui.StyleColor.ButtonActive, rgbm(0.18, 0.52, 0.18, 1))
    if ui.button('ON##toggle', vec2(44, 0)) then
      store.appEnabled = true
      resetWebhookToDefault('авто при включении')
      addLog(tr('log_tracking_on'))
    end
    ui.popStyleColor(3)
  end

  if ui.button(trf('ui_btn_lang', string.upper(lang())), vec2(W, 0)) then
    store.appLanguage = (lang() == 'ru') and 'en' or 'ru'
  end

  local currentSheetUrl = normalizeUrl(store.sheetUrl)
  if currentSheetUrl ~= '' and hasRecognizedProtocol(currentSheetUrl) then
    if ui.button(tr('ui_btn_open_sheet'), vec2(W, 0)) then
      openExternalUrl(currentSheetUrl)
    end
  else
    ui.textDisabled(tr('ui_sheet_not_set'))
  end

  ui.offsetCursorY(4)
  if ui.button(updateState.checking and tr('ui_btn_checking_update') or tr('ui_btn_check_update'), vec2(W, 0)) then
    checkForUpdates()
  end

  local updateSummary = trf('ui_version_prefix', tostring(APP_VERSION))
  if updateState.checking then
    updateSummary = updateSummary .. tr('ui_update_checking')
  elseif updateState.available then
    updateSummary = updateSummary .. trf('ui_update_required', tostring(updateState.latest))
  elseif updateState.checked and not updateState.error then
    updateSummary = updateSummary .. tr('ui_update_not_required')
  else
    updateSummary = updateSummary .. tr('ui_update_failed')
  end

  if updateState.available then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.95, 0.83, 0.35, 1))
    ui.text(updateSummary)
    ui.popStyleColor()
  elseif updateState.error then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1.0, 0.45, 0.2, 1))
    ui.text(updateSummary)
    ui.popStyleColor()
  else
    ui.textDisabled(updateSummary)
  end

  if updateState.available then
    local releasesUrl = normalizeUrl(UPDATE_RELEASES_URL)
    if releasesUrl ~= '' and hasRecognizedProtocol(releasesUrl) then
      if ui.button(tr('ui_btn_open_release'), vec2(W, 0)) then
        openExternalUrl(releasesUrl)
      end
    else
      ui.textDisabled(tr('ui_release_url_missing'))
    end
  end

  ui.offsetCursorY(6)
  ui.separator()
  ui.offsetCursorY(4)

  --  Игроки в сессии
  ui.header(tr('ui_players_header'))
  local anyInSession = false

  for i = 0, sim.carsCount - 1 do
    local car = ac.getCar(i)
    if car and car.isConnected then
      anyInSession    = true
      local name      = ac.getDriverName(i)
      local isTracked = trackedSet[name:lower()]

      if isTracked then
        -- Зелёный — уже отслеживается
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.3, 0.9, 0.3, 1))
        ui.text('● ' .. name)
        ui.popStyleColor()
        ui.sameLine(W - 58)
        if ui.button(tr('ui_btn_remove') .. '##r' .. i) then
          for j = #trackedList, 1, -1 do
            if trackedList[j]:lower() == name:lower() then
              removePlayer(j); break
            end
          end
        end
      else
        -- Серый — не отслеживается
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.65, 0.65, 0.65, 1))
        ui.text('○ ' .. name)
        ui.popStyleColor()
        ui.sameLine(W - 72)
        if ui.button(tr('ui_btn_follow') .. '##a' .. i) then
          addPlayer(name)
        end
      end
    end
  end

  if not anyInSession then
    ui.textDisabled(tr('ui_no_players'))
  end

  ui.offsetCursorY(6)
  ui.separator()
  ui.offsetCursorY(4)

  -- Список отслеживаемых
  ui.header(trf('ui_tracked_header', #trackedList))

  if #trackedList == 0 then
    ui.textDisabled(tr('ui_tracked_empty'))
  else
    -- Перебираем в обратном порядке, чтобы удаление не ломало индексы
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

  -- Добавить вручную
  ui.header(tr('ui_manual_add_header'))
  ui.setNextItemWidth(W - 82)
  local manOk, manNew = ui.inputText('##manual', manualInput)
  if manOk then manualInput = manNew end
  ui.sameLine(0, 4)
  if ui.button(tr('ui_btn_add')) then
    if manualInput ~= '' then
      addPlayer(manualInput)
      manualInput = ''
    end
  end

  ui.offsetCursorY(6)
  ui.separator()
  ui.offsetCursorY(4)

  -- Лог событий
  if ui.button((showLog and '▲' or '▼') .. trf('ui_log_header', #activityLog), vec2(W, 0)) then
    showLog = not showLog
  end

  if showLog then
    ui.offsetCursorY(2)
    if #activityLog == 0 then
      ui.textDisabled(tr('ui_log_empty'))
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