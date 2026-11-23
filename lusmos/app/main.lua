-- lusmOS 4 :: launcher
-- Interface principal do sistema. Quando o usuario escolhe um jogo ou ferramenta,
-- escreve o comando em /tmp/lusmos_next e fecha; o lusmos.sh executa e reabre o launcher.

-- O compilador JIT do LuaJIT tem falhas conhecidas em ARM 32 bits (RK3326): gerava
-- erros sem sentido e derrubava o lusmOS. O interpretador e rapido o bastante para a interface.
if jit then jit.off(); jit.flush() end

local data = require("data")
local U = require("ui")
local lg = love.graphics

local VERSION = "4"              -- versao mostrada na tela
local BUILD = "4-2026.11.23b"    -- numero interno (so aparece no registro de erros)
local NEXT_FILE = os.getenv("LUSMOS_NEXT") or "/tmp/lusmos_next"
local STATE_FILE = "/tmp/lusmos_state.lua"
local CACHE_FILE = "/tmp/lusmos_counts.lua"

local app = {
  t = 0,
  screen = nil,   -- tela atual (tabela com update/draw/press)
  stack = {},
  toast = nil,
  toastT = 0,
}

_G.__lusmos_app = app
local hwSave = 0 -- tempo para gravar brilho/volume no config

-- ================================================================ navegacao entre telas
local Screens = {}
_G.__lusmos_screens = Screens

local function push(name, arg)
  if app.screen then app.stack[#app.stack + 1] = app.screen end
  local s = Screens[name](arg)
  s.name = name
  app.screen = s
end

local function replace(name, arg)
  local s = Screens[name](arg)
  s.name = name
  app.screen = s
end

local function pop()
  if #app.stack > 0 then
    app.screen = table.remove(app.stack)
    if app.screen.resume then app.screen:resume() end
  end
end

local function goHome()
  app.stack = {}
  if not Screens["home_" .. tostring(data.config.layout)] then data.config.layout = "grade" end
  replace("home_" .. data.config.layout)
end

local function toast(msg)
  app.toast = U.safe(msg)
  app.toastT = 2.4
end

-- ================================================================ protecao contra erros
-- Um erro numa tela nao fecha mais o lusmOS: fica registrado em /tmp/lusmos_error.log
-- e a interface volta para a Home. So se a Home errar varias vezes seguidas aparece
-- a tela de erro, com as opcoes de tentar de novo, reiniciar ou desligar.
local errs = { n = 0, t = 0 }
local function logError(where, err)
  -- tambem vai para a EASYROMS, para dar para ler no PC
  for _, path in ipairs({ "/tmp/lusmos_error.log", data.ROOT_ROMS .. "/lusmos-erros.txt" }) do
    local f = io.open(path, "a")
    if f then
      f:write(os.date("%d/%m %H:%M:%S"), " lusmOS ", BUILD, " [", where, "] ", tostring(err), "\n\n")
      f:close()
    end
  end
end

local function safeCall(where, fn, ...)
  local ok, err = xpcall(fn, debug.traceback, ...)
  if ok then return true end
  logError(where, err)
  -- desfaz o que o desenho interrompido deixou ligado (recorte, cor, transformacao)
  pcall(function() lg.setScissor(); lg.origin(); lg.setColor(1, 1, 1, 1); lg.setLineWidth(1) end)
  errs.n = errs.n + 1
  errs.t = 3
  local wasHome = app.screen and app.screen.name and app.screen.name:match("^home_")
  if errs.n >= 4 or (wasHome and errs.n >= 3) then
    app.stack = {}
    app.screen = Screens.crash({ err = err })
    app.screen.name = "crash"
  elseif app.screen and app.screen.name ~= "crash" then
    app.stack = {}
    local ok2 = pcall(function() replace("home_" .. data.config.layout) end)
    if not ok2 then app.screen = Screens.crash({ err = err }); app.screen.name = "crash" end
    app.toast = "Ops, algo deu errado nessa tela"
    app.toastT = 2.4
  end
  return false
end

-- ================================================================ saida para executar algo
local function writeNext(kind, cmd)
  local f = io.open(NEXT_FILE, "w")
  if f then
    f:write(kind, "\n", cmd or "", "\n")
    f:close()
  end
end

local function saveUIState()
  local s = app.screen
  local games = nil
  local all = {}
  for _, sc in ipairs(app.stack) do all[#all + 1] = sc end
  all[#all + 1] = app.screen
  for _, sc in ipairs(all) do
    if sc.name and sc.name:match("^home_") then s = sc end
    if sc.name == "games" then games = sc end
  end
  local f = io.open(STATE_FILE, "w")
  if not f then return end
  local parts = {
    "layout=" .. string.format("%q", data.config.layout),
    "sel=" .. tostring(s and s.sel or 1),
    "cat=" .. tostring(s and s.cat or 1),
    "tab=" .. tostring(s and s.tab or 1),
  }
  if s and s.sub and s.sub.sysname then
    parts[#parts + 1] = "subsys=" .. string.format("%q", s.sub.sysname)
    parts[#parts + 1] = "subback=" .. tostring(s.sub.back or 1)
  end
  if games then
    parts[#parts + 1] = "gsel=" .. tostring(games.sel or 1)
    parts[#parts + 1] = "gtitle=" .. string.format("%q", games.title or "")
    if games.arg.system then parts[#parts + 1] = "gsys=" .. string.format("%q", games.arg.system.name) end
    if games.arg.favorites then parts[#parts + 1] = "gfav=true" end
    if games.arg.recents then parts[#parts + 1] = "grec=true" end
    if games.arg.all then parts[#parts + 1] = "gall=true" end
  end
  f:write("return {", table.concat(parts, ","), "}")
  f:close()
end

local function quitWith(kind, cmd)
  if hwSave > 0 then hwSave = 0; data.saveConfig() end
  saveUIState()
  writeNext(kind, cmd)
  love.event.quit(0)
end

local function resetAndReboot()
  hwSave = 0
  data.resetConfig()
  os.remove(STATE_FILE)
  writeNext("reboot")
  love.event.quit(0)
end

local function runTool(script)
  quitWith("tool", data.optionsCommand(script))
end

local function launchGame(game)
  if game.zipped then push("prepare", { game = game }) else push("launch", game) end
end

-- ================================================================ leitura das listas em segundo plano
-- Cada sistema e lido numa corrotina, um pedaco por quadro, para a tela nunca congelar.
local bg = { queue = {}, cur = nil, paused = {} }

local function bgEnqueue(sys, front)
  if not sys or sys.games or (sys.count or 0) == 0 then return end
  if bg.cur and bg.cur.sys == sys then return end
  if front and bg.cur then
    -- pausa o que estava lendo e passa este na frente
    bg.paused[bg.cur.sys] = bg.cur.co
    table.insert(bg.queue, 1, bg.cur.sys)
    bg.cur = nil
  end
  for i, q in ipairs(bg.queue) do
    if q == sys then
      if front then table.remove(bg.queue, i); table.insert(bg.queue, 1, sys) end
      return
    end
  end
  if front then table.insert(bg.queue, 1, sys) else bg.queue[#bg.queue + 1] = sys end
end

local function bgEnqueueAll()
  for _, sys in ipairs(data.systems) do bgEnqueue(sys) end
end

local function bgUpdate(budget)
  local t0 = love.timer.getTime()
  repeat
    if not bg.cur then
      local sys = table.remove(bg.queue, 1)
      while sys and sys.games do sys = table.remove(bg.queue, 1) end
      if not sys then return end
      local co = bg.paused[sys]
      bg.paused[sys] = nil
      if not co then co = coroutine.create(function() data.scanSystem(sys, coroutine.yield) end) end
      bg.cur = { sys = sys, co = co }
    end
    local ok, err = coroutine.resume(bg.cur.co)
    if not ok then
      local f = io.open("/tmp/lusmos.log", "a")
      if f then f:write("erro lendo ", tostring(bg.cur.sys.name), ": ", tostring(err), "\n"); f:close() end
      bg.cur.sys.games = bg.cur.sys.games or {}
      bg.cur = nil
    elseif coroutine.status(bg.cur.co) == "dead" then
      bg.cur = nil
    end
  until love.timer.getTime() - t0 > budget
end

local function scannedCount()
  local done, total = 0, 0
  for _, sys in ipairs(data.systems) do
    if (sys.count or 0) > 0 then
      total = total + 1
      if sys.games then done = done + 1 end
    end
  end
  return done, total
end

-- indicador de carregamento
local function spinner(cx, cy, r, label)
  local a = app.t * 5
  for i = 0, 7 do
    U.circle(cx + math.cos(a + i * 0.785) * r, cy + math.sin(a + i * 0.785) * r, 2.6, U.c.accent, (i + 1) / 8)
  end
  if label then U.text(label, cx + r + 14, cy - 10, U.font("m", 14), U.c.text2) end
end

-- ================================================================ sons de navegacao
local sounds = {}
local function loadSounds()
  if not (love.audio and love.audio.newSource) then return end
  for _, n in ipairs({ "move", "confirm", "back" }) do
    local ok, src = pcall(love.audio.newSource, "sounds/" .. n .. ".wav", "static")
    if ok and src then
      src:setVolume(n == "move" and 0.45 or 0.6)
      sounds[n] = src
    end
  end
end

local function sfx(n)
  if data.config.navSounds == false then return end
  local src = sounds[n]
  if src then
    src:stop()
    src:play()
  end
end

-- ================================================================ barrinha de volume / brilho na tela
local osd = { kind = nil, value = 0, t = 0 }
local function showOSD(kind, value)
  if not value then return end
  osd.kind, osd.value, osd.t = kind, value, 1.6
end

local watch = { t = 0, vt = 0, bright = nil, vol = nil }

-- brilho e volume ficam salvos (gravados 1,5 s depois da ultima mudanca)
local function rememberHW(kind, value)
  if not value then return end
  if kind == "volume" then data.config.volume = value else data.config.brightness = value end
  hwSave = 1.5
end

-- no primeiro launcher depois de ligar, volta o brilho e o volume que o usuario deixou
local function restoreHW()
  local mark = "/tmp/lusmos_booted"
  local f = io.open(mark, "r")
  if f then f:close() return end
  f = io.open(mark, "w")
  if f then f:write("1"); f:close() end
  if data.config.brightness then data.setBrightness(data.config.brightness) end
  if data.config.volume then data.setVolume(data.config.volume) end
end

local function changeVolume(d)
  local v = data.volPct or data.getVolume() or 50
  local nv = math.max(0, math.min(100, v + d))
  data.setVolume(nv)
  watch.vol = nv
  rememberHW("volume", nv)
  showOSD("volume", nv)
end

local function changeBrightness(d)
  local v = data.brightnessPct() or 50
  local nv = data.setBrightness(math.max(1, math.min(100, v + d)))
  watch.bright = nv
  rememberHW("brightness", nv)
  showOSD("brightness", nv)
end

-- percebe mudancas feitas fora do lusmOS (atalhos do sistema)
local function watchHardware(dt)
  watch.t = watch.t + dt
  watch.vt = watch.vt + dt
  if watch.t > 0.25 then
    watch.t = 0
    local b = data.brightnessPct()
    if b and watch.bright and b ~= watch.bright then showOSD("brightness", b); rememberHW("brightness", b) end
    watch.bright = b
  end
  if watch.vt > 1.0 then
    watch.vt = 0
    local v = data.getVolume()
    if v and watch.vol and v ~= watch.vol then showOSD("volume", v); rememberHW("volume", v) end
    if v then watch.vol = v; data.volPct = v end
  end
end

local function drawOSD()
  if osd.t <= 0 or not osd.kind then return end
  local a = math.min(1, osd.t * 4)
  local w, h = 260, 46
  local x, y = 320 - w / 2, 18
  U.rect(x, y, w, h, 23, U.c.card, 0.96 * a)
  U.rectLine(x, y, w, h, 23, U.c.line2, 1.5, a)
  local ix, iy = x + 18, y + 13
  U.set(U.c.text, a)
  if osd.kind == "volume" then
    lg.polygon("fill", ix, iy + 6, ix + 6, iy + 6, ix + 13, iy, ix + 13, iy + 20, ix + 6, iy + 14, ix, iy + 14)
    lg.setLineWidth(2)
    if osd.value > 0 then lg.arc("line", "open", ix + 14, iy + 10, 6, -0.9, 0.9, 10) end
    if osd.value > 50 then lg.arc("line", "open", ix + 14, iy + 10, 11, -0.9, 0.9, 12) end
    if osd.value == 0 then
      lg.line(ix + 17, iy + 5, ix + 25, iy + 15)
      lg.line(ix + 25, iy + 5, ix + 17, iy + 15)
    end
  else
    lg.circle("fill", ix + 11, iy + 10, 5, 16)
    lg.setLineWidth(2)
    for i = 0, 7 do
      local an = i * math.pi / 4
      lg.line(ix + 11 + math.cos(an) * 8, iy + 10 + math.sin(an) * 8, ix + 11 + math.cos(an) * 11, iy + 10 + math.sin(an) * 11)
    end
  end
  lg.setLineWidth(1)
  local bx, bw = x + 52, 140
  U.rect(bx, y + 20, bw, 6, 3, U.c.line2, a)
  U.gradientBar(bx, y + 20, bw * osd.value / 100, 6, U.c.accent, U.c.accent2, a)
  U.text(osd.value .. "%", x + 200, y + 12, U.font("m", 15), U.c.text, a, 44, "right")
end

-- ================================================================ entrada (controle + teclado)
local REPEAT_DELAY, REPEAT_RATE = 0.32, 0.075
local held = {}
local axisState = { x = 0, y = 0 }

local function swapAB(b)
  if data.config.swapAB then
    if b == "a" then return "b" elseif b == "b" then return "a" end
  end
  return b
end

local function press(b)
  local sc = app.screen
  if sc and not sc.noSound then
    pcall(function()
      if b == "up" or b == "down" or b == "left" or b == "right" or b == "l1" or b == "r1" or b == "l2" or b == "r2" then sfx("move")
      elseif b == "a" or b == "start" then sfx("confirm")
      elseif b == "b" then sfx("back") end
    end)
  end
  if sc and sc.press then safeCall("tecla " .. tostring(b) .. " em " .. tostring(sc.name), sc.press, sc, b) end
end

local function startHold(b)
  held[b] = REPEAT_DELAY
  press(b)
end

local DIRS = { up = true, down = true, left = true, right = true }

local gpmap = {
  dpup = "up", dpdown = "down", dpleft = "left", dpright = "right",
  a = "a", b = "b", x = "x", y = "y",
  leftshoulder = "l1", rightshoulder = "r1", back = "select", start = "start", guide = "guide",
}

app.fnHeld = false
function love.gamepadpressed(js, button)
  local b = gpmap[button]
  if not b then return end
  if b == "guide" then app.fnHeld = true end
  if b == "x" and app.fnHeld then
    safeCall("pesquisa", openSearch)
    return
  end
  b = swapAB(b)
  if app.screen and app.screen.raw then app.screen:raw(b, true) end
  if DIRS[b] then startHold(b) else press(b) end
end

function love.gamepadreleased(js, button)
  local b = gpmap[button]
  if not b then return end
  if b == "guide" then app.fnHeld = false end
  b = swapAB(b)
  if app.screen and app.screen.raw then app.screen:raw(b, false) end
  held[b] = nil
end

function love.gamepadaxis(js, axis, value)
  if app.screen and app.screen.axis then app.screen:axis(axis, value) end
  if axis == "triggerleft" or axis == "triggerright" then
    local b = axis == "triggerleft" and "l2" or "r2"
    if value > 0.6 and not held[b] then held[b] = 99; press(b) elseif value < 0.3 then held[b] = nil end
    return
  end
  if axis ~= "leftx" and axis ~= "lefty" then return end
  local k = axis == "leftx" and "x" or "y"
  local v = 0
  if value > 0.6 then v = 1 elseif value < -0.6 then v = -1 end
  if math.abs(value) < 0.35 then v = 0 elseif v == 0 then return end
  if v ~= axisState[k] then
    local neg, pos = (k == "x") and "left" or "up", (k == "x") and "right" or "down"
    held[neg], held[pos] = nil, nil
    axisState[k] = v
    if v == -1 then startHold(neg) elseif v == 1 then startHold(pos) end
  end
end

local keymap = {
  up = "up", down = "down", left = "left", right = "right",
  ["return"] = "a", z = "a", x = "b", backspace = "b", escape = "b", c = "x", v = "y",
  q = "l1", w = "r1", a = "l2", s = "r2", rshift = "select", tab = "select", space = "start",
}
app.lastRaw = ""
local VOLKEYS = { volumeup = 1, volumedown = -1 }
function love.keypressed(k)
  app.lastRaw = "tecla " .. tostring(k)
  if VOLKEYS[k] then
    changeVolume(VOLKEYS[k])
    held["vol:" .. k] = REPEAT_DELAY
    return
  end
  if k == "f" and not (app.screen and app.screen.name == "keyboard") then safeCall("pesquisa", openSearch); return end
  local b = keymap[k]
  if not b then return end
  if app.screen and app.screen.raw then app.screen:raw(b, true) end
  if DIRS[b] then startHold(b) else press(b) end
end
function love.joystickpressed(js, button)
  app.lastRaw = "botão #" .. tostring(button)
end

function love.keyreleased(k)
  held["vol:" .. k] = nil
  local b = keymap[k]
  if b then
    held[b] = nil
    if app.screen and app.screen.raw then app.screen:raw(b, false) end
  end
end

app.holdT = 0
local function updateRepeat(dt)
  if held.left or held.right then app.holdT = app.holdT + dt else app.holdT = 0 end
  for b, t in pairs(held) do
    local vk = type(b) == "string" and b:match("^vol:(.+)$")
    if vk then
      t = t - dt
      if t <= 0 then changeVolume(VOLKEYS[vk]); t = 0.06 end
      held[b] = t
    elseif DIRS[b] then
      t = t - dt
      if t <= 0 then
        press(b)
        t = REPEAT_RATE
      end
      held[b] = t
    end
  end
end

-- ================================================================ pesquisa de jogos (FN + X ou atalho)
local lastSearch = ""
function openSearch(value)
  if app.screen and app.screen.name == "keyboard" then return end
  bgEnqueueAll()
  push("keyboard", { title = "Pesquisar jogos", sub = "Digite parte do nome. Acentos e maiúsculas não importam.",
    value = value or lastSearch,
    onDone = function(txt)
      txt = (txt or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if txt == "" then return end
      lastSearch = txt
      push("games", { title = "Pesquisa: " .. txt, search = txt })
    end })
end

-- ================================================================ itens (jogo / sistema / atalho)
local function gameItem(g)
  return {
    kind = "game", game = g, title = g.name, system = g.system, color = g.system.color,
    image = g.image, sysImage = g.system.image, initials = U.initials(g.name), badge = g.system.short,
  }
end

local function systemItem(sys)
  return {
    kind = "system", sys = sys, title = sys.fullname or sys.name, color = sys.color,
    initials = sys.short, image = sys.image, fill = true, count = sys.count,
  }
end

local function since(t)
  if not t then return nil end
  local d = os.time() - t
  if d < 60 then return "agora há pouco" end
  if d < 3600 then return "há " .. math.floor(d / 60) .. " min" end
  if d < 86400 then return "há " .. math.floor(d / 3600) .. " h" end
  local days = math.floor(d / 86400)
  if days == 1 then return "ontem" end
  if days < 30 then return "há " .. days .. " dias" end
  return "há " .. math.floor(days / 30) .. " meses"
end

local function nonEmptySystems()
  local out = {}
  for _, s in ipairs(data.systems) do
    if s.count > 0 or data.config.showEmpty then out[#out + 1] = s end
  end
  return out
end

local function openItem(item)
  if item.kind == "game" then
    launchGame(item.game)
  elseif item.kind == "system" then
    push("games", { title = item.sys.fullname or item.sys.name, system = item.sys })
  elseif item.kind == "library" then
    push("systems")
  elseif item.action then
    item.action()
  end
end

-- ================================================================ menus modais
local function powerMenu()
  push("menu", {
    title = "Energia",
    items = {
      { label = "Desligar", act = function() quitWith("poweroff") end },
      { label = "Reiniciar", act = function() quitWith("reboot") end },
      { label = "Suspender", act = function() pop(); os.execute("sudo systemctl suspend >/dev/null 2>&1 &") end },
      { label = "Cancelar", act = function() pop() end },
    },
  })
end

local function gameMenu(game)
  local items = {
    { label = "Jogar", act = function() pop(); launchGame(game) end },
    { label = data.isFav(game) and "Remover dos favoritos" or "Adicionar aos favoritos",
      act = function() data.toggleFav(game); pop(); toast(data.isFav(game) and "Adicionado aos favoritos" or "Removido dos favoritos") end },
    { label = "Coleções…", act = function() pop(); push("collpick", { game = game }) end },
  }
  if #data.coreChoices(game.system) > 1 then
    items[#items + 1] = { label = "Emulador deste jogo…", act = function() pop(); push("coregame", { game = game }) end }
  end
  items[#items + 1] = { label = "Editar nome", act = function()
    pop()
    push("keyboard", { title = "Nome do jogo", sub = "Deixe vazio para voltar ao nome original.", value = game.name,
      onDone = function(txt) data.renameGame(game, txt); toast("Nome salvo") end })
  end }
  items[#items + 1] = { label = game.hidden and "Mostrar este jogo de novo" or "Esconder este jogo",
    act = function()
      pop()
      data.setHidden(game, not game.hidden)
      toast(game.hidden and "Jogo escondido · Ajustes > Emulação mostra de novo" or "Jogo visível de novo")
      if app.screen and app.screen.resume then app.screen:resume() end
    end }
  items[#items + 1] = { label = "Ver todos os jogos de " .. (game.system.fullname or game.system.name),
    act = function() pop(); push("games", { title = game.system.fullname, system = game.system }) end }
  items[#items + 1] = { label = "Cancelar", act = function() pop() end }
  push("menu", { title = game.name, items = items })
end

local function runES()
  quitWith("tool", "/opt/lusmos/es-app.sh")
end

-- ================================================================ animacao do lusmOS (a mesma do boot)
local introImg = {}
local function loadIntroImages()
  for _, n in ipairs({ "glow", "mark", "wordmark", "final" }) do
    local ok, img = pcall(lg.newImage, "img/" .. n .. ".png")
    if ok then introImg[n] = img end
  end
end

local INTRO_LEN = 4.2
local BLUE, PURPLE, LIGHT = U.hex("#6C8CFF"), U.hex("#A774FF"), U.hex("#C9D4FF")
local function clamp01(v) return math.max(0, math.min(1, v)) end

-- desenha o quadro da animacao no tempo t (segundos)
local function drawIntro(t)
  U.rect(0, 0, 640, 480, 0, U.hex("#07080C"))
  local appear = clamp01(t / 0.6)
  if introImg.glow then
    lg.setColor(1, 1, 1, (0.6 + 0.4 * math.sin(t * 2.2)) * appear)
    lg.draw(introImg.glow, 0, 0)
  end
  local p = clamp01(t / 0.55)
  local scale = 0.4 + 0.6 * (1 - (1 - p) ^ 3) + 0.06 * math.sin(p * math.pi)
  local size = 96 * scale
  if introImg.mark then
    lg.setColor(1, 1, 1, appear)
    lg.draw(introImg.mark, 320 - size / 2, 190 - size / 2, 0, size / 192, size / 192)
  else
    U.logo(320 - size / 2, 190 - size / 2, size, appear)
  end
  if t > 0.3 then
    local ok = clamp01((t - 0.3) / 0.4)
    U.set(U.mix(U.hex("#07080C"), BLUE, 0.35 * ok))
    lg.setLineWidth(2)
    lg.circle("line", 320, 190, 66, 48)
    lg.setLineWidth(1)
    local ang = t * 2.6
    U.circle(320 + 66 * math.sin(ang), 190 - 66 * math.cos(ang), 5, LIGHT, ok)
  end
  local wt = clamp01((t - 0.7) / 0.5)
  if wt > 0 and introImg.wordmark then
    lg.setColor(1, 1, 1, wt)
    lg.draw(introImg.wordmark, 0, 282 + 12 * (1 - wt))
  end
  if t > 0.9 then
    local bk = clamp01((t - 0.9) / 0.3)
    U.rect(230, 358, 180, 4, 2, U.hex("#1A1E2A"), bk)
    local bt = clamp01((t - 1.0) / (INTRO_LEN - 1.4))
    U.gradientBar(230, 358, 180 * bt, 4, BLUE, PURPLE, bk)
    U.text("Carregando sua biblioteca…", 120, 374, U.font("r", 14), U.hex("#9AA3B2"), bk, 400, "center")
  end
end

-- ultimo quadro da animacao (igual ao fim do video de boot), com o pontinho girando
local function drawFinal()
  if introImg.final then
    lg.setColor(1, 1, 1, 1)
    lg.draw(introImg.final, 0, 0)
    local ang = app.t * 2.6
    U.circle(320 + 66 * math.sin(ang), 190 - 66 * math.cos(ang), 5, LIGHT, 1)
  else
    drawIntro(INTRO_LEN)
  end
end

-- ================================================================ tela: carregando
-- modo "boot": logo parado (continua o video de boot, que termina igual)
-- modo "anim": toca a animacao (ao voltar de um jogo, se estiver ligada nos Ajustes)
-- modo "plain": so o fundo (ao voltar de um jogo com a animacao desligada)
local function readState()
  local f = io.open(STATE_FILE, "r")
  if not f then return nil end
  local txt = f:read("*a"); f:close()
  os.remove(STATE_FILE)
  local fn = loadstring(txt)
  local ok, st = pcall(fn or function() end)
  if ok and type(st) == "table" then return st end
  return nil
end

local function restoreState(st)
  if not st or st.layout ~= data.config.layout then return end
  if app.screen.restore then app.screen:restore(st) end
  if st.gsys or st.gfav or st.grec or st.gall then
    local arg = { title = st.gtitle, restoreSel = st.gsel }
    if st.gsys then arg.system = data.byName[st.gsys] end
    if st.gfav then arg.favorites = true end
    if st.grec then arg.recents = true end
    if st.gall then arg.all = true end
    if arg.system or arg.favorites or arg.recents or arg.all then
      if arg.system then arg.title = arg.system.fullname or arg.system.name end
      push("games", arg)
    end
  end
end

Screens.loading = function(arg)
  local s = { progress = 0, t = 0, mode = (arg and arg.mode) or "boot", state = arg and arg.state }
  s.co = coroutine.create(function()
    data.loadESSettings()
    data.loadSystems()
    local cached = nil
    local cf = io.open(CACHE_FILE, "r")
    if cf then
      local txt = cf:read("*a"); cf:close()
      local fn = loadstring(txt)
      if fn then local ok, t = pcall(fn); if ok then cached = t end end
    end
    local n = #data.systems
    for i, sys in ipairs(data.systems) do
      if cached and cached[sys.name] then
        sys.count = cached[sys.name]
      else
        data.countSystem(sys)
      end
      s.progress = i / math.max(1, n)
      if not cached or i % 20 == 0 then coroutine.yield() end
    end
    local out = { "return {" }
    for _, sys in ipairs(data.systems) do out[#out + 1] = string.format("[%q]=%d,", sys.name, sys.count) end
    out[#out + 1] = "}"
    local wf = io.open(CACHE_FILE, "w")
    if wf then wf:write(table.concat(out)); wf:close() end
    coroutine.yield()
    data.recentGames(12)
  end)
  function s:press(b)
    if self.mode == "anim" then self.skip = true end
  end
  function s:update(dt)
    self.t = self.t + dt
    if coroutine.status(self.co) ~= "dead" then
      local ok, err = coroutine.resume(self.co)
      if not ok then error(err) end
      return
    end
    if self.mode == "anim" and self.t < INTRO_LEN + 0.25 and not self.skip then return end
    if os.getenv("LUSMOS_RECOVERY") and not app.recoveryShown then
      app.recoveryShown = true
      app.stack = {}
      replace("recovery")
      return
    end
    goHome()
    bgEnqueueAll()
    restoreState(self.state)
    -- procura atualizacao do lusmOS uma vez por boot (em segundo plano, se tiver Wi-Fi)
    app.updWatch = data.config.autoUpdate ~= false
  end
  function s:draw()
    if self.mode == "anim" then
      drawIntro(math.min(self.t, INTRO_LEN))
    elseif self.mode == "plain" then
      U.rect(0, 0, 640, 480, 0, data.config.layout == "cruz" and U.hex("#0F1220") or U.c.bg2)
    else
      drawFinal()
    end
  end
  return s
end

-- ================================================================ fonte de itens da home
-- Grade: so os videogames (os jogos ficam dentro de cada um)
local function gradeItems()
  local items = {}
  for _, sys in ipairs(nonEmptySystems()) do items[#items + 1] = systemItem(sys) end
  return items
end

local function homeItems(limit)
  local items = {}
  for _, g in ipairs(data.recentGames(limit or 10)) do items[#items + 1] = gameItem(g) end
  if #items < 4 then
    -- sem historico ainda: mostra os sistemas com jogos
    for _, sys in ipairs(nonEmptySystems()) do
      items[#items + 1] = systemItem(sys)
      if #items >= 10 then break end
    end
  end
  items[#items + 1] = { kind = "library", title = "Biblioteca completa", color = U.c.line2, initials = "+", isLibrary = true }
  return items
end

local function itemSubtitle(item)
  if item.kind == "game" then
    local w = since(item.game.lastTime)
    return (item.system.fullname or item.system.name) .. (w and (" · jogado " .. w) or "")
  elseif item.kind == "system" then
    return item.count .. " jogos"
  end
  return "Todos os sistemas e jogos"
end

-- ================================================================ HOME: GRADE
Screens.home_grade = function()
  local s = { sel = 1, row = 1, col = 1, items = gradeItems(), shift = 0 }
  s.buttons = {
    { icon = "list", label = "Todos", color = U.hex("#7FD8E8"), act = function() push("games", { title = "Todos os jogos", all = true }) end },
    { icon = "search", label = "Pesquisar", color = U.hex("#F2F4F8"), act = function() openSearch() end },
    { icon = "clock", label = "Recentes", color = U.hex("#8FA8FF"), act = function() push("games", { title = "Jogados recentemente", recents = true }) end },
    { icon = "star", label = "Coleções", color = U.hex("#FFC870"), act = function() push("collections") end },
    { icon = "tools", label = "Ferramentas", color = U.hex("#6FD6A3"), act = function() push("settings", { cat = 5 }) end },
    { icon = "wifi", label = "Wi-Fi", color = U.hex("#C2A1FF"), act = function() push("wifi") end },
    { icon = "gear", label = "Ajustes", color = U.c.text2, act = function() push("settings") end },
    { icon = "power", label = "Energia", color = U.c.text2, act = powerMenu },
  }
  function s:restore(st) self.sel = math.min(st.sel or 1, #self.items) end
  function s:resume() self.items = gradeItems(); self.sel = math.max(1, math.min(self.sel, #self.items)) end
  function s:press(b)
    if self.row == 1 then
      if b == "left" then self.sel = math.max(1, self.sel - 1)
      elseif b == "right" then self.sel = math.min(#self.items, self.sel + 1)
      elseif b == "down" then self.row = 2
      elseif b == "a" then if self.items[self.sel] then openItem(self.items[self.sel]) end
      elseif b == "y" or b == "x" then
        local it = self.items[self.sel]
        if it.kind == "game" then gameMenu(it.game) end
      end
    else
      if b == "left" then self.col = math.max(1, self.col - 1)
      elseif b == "right" then self.col = math.min(#self.buttons, self.col + 1)
      elseif b == "up" then self.row = 1
      elseif b == "a" then self.buttons[self.col].act()
      end
    end
    if b == "start" then push("settings") elseif b == "select" then push("systems") end
  end
  function s:update(dt)
    local target = math.max(0, math.min(self.sel - 2, #self.items - 3)) * 164
    self.shift = self.shift + (target - self.shift) * math.min(1, dt * 14)
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg2)
    -- topo
    U.circle(52, 36, 20, U.c.accent2)
    U.text(data.config.initial or "L", 32, 25, U.font("b", 17), U.c.bg2, 1, 40, "center")
    U.drawStatus(608, 26, U.c.text2)
    -- titulo do item selecionado
    local it = self.items[self.sel]
    if it then
      local tf = U.font("m", 17)
      U.text(it.title, 32, 76, tf, self.row == 1 and U.c.accent or U.c.muted, 1, 440)
      if it.count then
        U.text(it.count .. " jogos", 32 + math.min(440, tf:getWidth(U.fit(tf, it.title, 440))) + 12, 79, U.font("r", 13), U.c.muted)
      end
    end
    -- fila de blocos
    lg.setScissor(0, 100, 640, 168)
    for i, item in ipairs(self.items) do
      local x = 32 + (i - 1) * 164 - self.shift
      if x > -160 and x < 660 then
        local y = 110
        if i == self.sel and self.row == 1 then
          local pulse = 0.5 + 0.5 * math.sin(app.t * 4)
          U.rect(x - 6, y - 6, 162, 162, 12, U.mix(U.c.accent, U.c.accent2, pulse))
          U.rect(x - 3, y - 3, 156, 156, 9, U.c.bg2)
        end
        if item.isLibrary then
          U.rect(x, y, 150, 150, 8, U.c.line)
          U.icon("plus", x + 51, y + 40, 48, U.c.text2)
          U.text("Biblioteca", x, y + 102, U.font("m", 14), U.c.text2, 1, 150, "center")
        else
          U.tile(x, y, 150, item, 1, 8)
        end
      end
    end
    lg.setScissor()
    -- botoes redondos
    local n = #self.buttons
    local gap = n > 7 and 72 or (n > 6 and 78 or 82)
    local x0 = 320 - (n - 1) * gap / 2
    for i, btn in ipairs(self.buttons) do
      local cx = x0 + (i - 1) * gap
      local focus = self.row == 2 and self.col == i
      local r = n > 7 and 25 or 27
      if focus then U.circle(cx, 322, r + 4, U.c.accent) end
      U.circle(cx, 322, r, U.hex("#1E2330"))
      U.icon(btn.icon, cx - 11, 311, 22, btn.color)
      U.text(btn.label, cx - 40, 356, U.font(focus and "m" or "r", n > 7 and 11 or 12), focus and U.c.text or U.c.text2, 1, 80, "center")
    end
    -- rodape
    U.rect(32, 428, 576, 1, 0, U.c.line2)
    U.text("lusm", 32, 440, U.font("m", 13), U.c.text)
    U.text("OS 4", 32 + U.font("m", 13):getWidth("lusm"), 440, U.font("m", 13), U.c.accent2)
    if self.row == 1 then
      U.hints({ { "A", "Abrir" }, { "START", "Ajustes" } }, 608, 440, U.c.bg2, U.c.text)
    else
      U.hints({ { "A", "Abrir" }, { "CIMA", "Jogos" } }, 608, 440, U.c.bg2, U.c.text)
    end
  end
  return s
end

-- ================================================================ HOME: CRUZ
local function cruzCategories()
  local cats = {}
  cats[#cats + 1] = { name = "Ajustes", icon = "sliders", build = function()
    return {
      { title = "Todos os ajustes", sub = "Aparência, tela, rede, emulação, sistema", ic = "AJ", action = function() push("settings") end },
      { title = "Layout da Home", sub = "Grade · Cruz · Vitrine · Metrô", ic = "UI", action = function() push("layout") end },
      { title = "Ferramentas", sub = "PortMaster, arquivos, backup e informações", ic = "FER", action = function() push("settings", { cat = 5 }) end },
      { title = "Teste de controles", sub = "Confira botões e analógicos", ic = "JOY", action = function() push("padtest") end },
      { title = "Energia", sub = "Desligar, reiniciar ou suspender", ic = "PWR", action = powerMenu },
    }
  end }
  cats[#cats + 1] = { name = "Jogos", icon = "gamepad", build = function()
    local out = {}
    out[1] = { title = "Todos os jogos", sub = data.totalGames() .. " jogos instalados, de A a Z", ic = "A-Z",
      action = function() push("games", { title = "Todos os jogos", all = true }) end }
    out[2] = { title = "Pesquisar jogos", sub = "Digite o nome · atalho FN + X", ic = "BUS", action = function() openSearch() end }
    out[3] = { title = "Coleções", sub = "Favoritos e suas listas de jogos", ic = "COL", action = function() push("collections") end }
    for _, g in ipairs(data.recentGames(15)) do
      local it = gameItem(g)
      it.sub = (g.system.fullname or g.system.name) .. (since(g.lastTime) and (" · " .. since(g.lastTime)) or "")
      out[#out + 1] = it
    end
    if #out == 3 then out[4] = { title = "Nenhum jogo recente ainda", sub = "Os jogos que você abrir aparecem aqui", ic = "—" } end
    return out
  end }
  cats[#cats + 1] = { name = "Sistemas", icon = "grid", build = function()
    local out = {}
    for _, sys in ipairs(nonEmptySystems()) do
      local it = systemItem(sys)
      it.sub = sys.count .. " jogos"
      out[#out + 1] = it
    end
    return out
  end }
  cats[#cats + 1] = { name = "Favoritos", icon = "star", build = function()
    if not data.allScanned() then
      bgEnqueueAll()
      local done, total = scannedCount()
      return { loading = true, { title = "Carregando favoritos…", sub = done .. " de " .. total .. " sistemas lidos", ic = "…" } }
    end
    local out = {}
    for _, g in ipairs(data.favoriteGames()) do
      local it = gameItem(g)
      it.sub = g.system.fullname or g.system.name
      out[#out + 1] = it
    end
    if #out == 0 then out[1] = { title = "Nenhum favorito ainda", sub = "Aperte Y em um jogo para favoritar", ic = "—" } end
    return out
  end }
  cats[#cats + 1] = { name = "Rede", icon = "globe", build = function()
    local w = data.wifi()
    return {
      { title = "Wi-Fi", sub = (w == nil and "Adaptador não conectado") or (w and ("Conectado" .. ((data.wifiName() and (" · " .. data.wifiName())) or "")) or "Desconectado"), ic = "WIFI",
        action = function() push("wifi") end },
      { title = "Informações do sistema", sub = "IP, armazenamento e bateria", ic = "INFO", action = function() push("info") end },
    }
  end }
  return cats
end

Screens.home_cruz = function()
  local s = { cat = 2, sel = 1, cats = cruzCategories(), lists = {}, sub = nil, rowX = 0, listY = 0 }
  function s:list()
    if self.sub then return self.sub.items end
    local c = self.cats[self.cat]
    local l = self.lists[self.cat]
    if not l then
      l = c.build()
      if not l.loading then self.lists[self.cat] = l end
    end
    return l
  end
  function s:openSystem(it)
    local items = {}
    for _, g in ipairs(it.sys.games or {}) do
      local gi = gameItem(g)
      gi.sub = g.folder and ("Pasta " .. g.folder) or (g.year or it.sys.fullname)
      items[#items + 1] = gi
    end
    if #items == 0 then toast("Nenhum jogo nesse sistema") return end
    self.sub = { items = items, title = it.title, back = self.sel, sysname = it.sys.name }
    self.sel = 1
  end
  function s:restore(st)
    self.cat = math.max(1, math.min(st.cat or 2, #self.cats))
    if st.subsys and data.byName[st.subsys] then
      local sys = data.byName[st.subsys]
      self.sel = st.subback or 1
      self.pending = systemItem(sys)
      self.pendingSel = st.sel
      bgEnqueue(sys, true)
      return
    end
    self.sel = math.max(1, math.min(st.sel or 1, #self:list()))
  end
  function s:resume() self.lists = {}; if self.sub then return end; self.sel = math.min(self.sel, #self:list()) end
  function s:press(b)
    if self.pending then
      if b == "b" then self.pending = nil end
      return
    end
    local list = self:list()
    if b == "left" and not self.sub then
      if self.cat > 1 then self.cat = self.cat - 1; self.sel = 1 end
    elseif b == "right" and not self.sub then
      if self.cat < #self.cats then self.cat = self.cat + 1; self.sel = 1 end
    elseif b == "up" then self.sel = math.max(1, self.sel - 1)
    elseif b == "down" then self.sel = math.min(#list, self.sel + 1)
    elseif b == "l1" then self.sel = math.max(1, self.sel - 8)
    elseif b == "r1" then self.sel = math.min(#list, self.sel + 8)
    elseif b == "a" then
      local it = list[self.sel]
      if not it then return end
      if it.kind == "system" then
        if it.sys.games then
          self:openSystem(it)
        else
          self.pending = it
          bgEnqueue(it.sys, true)
        end
      elseif it.kind == "game" then launchGame(it.game)
      elseif it.action then it.action() end
    elseif b == "b" and self.sub then
      self.sel = self.sub.back
      self.sub = nil
    elseif b == "y" or b == "x" then
      local it = list[self.sel]
      if it and it.kind == "game" then gameMenu(it.game) end
    elseif b == "start" then push("settings")
    end
  end
  function s:update(dt)
    if self.pending and self.pending.sys.games then
      local it = self.pending
      self.pending = nil
      self:openSystem(it)
      if self.pendingSel and self.sub then
        self.sel = math.max(1, math.min(self.pendingSel, #self.sub.items))
        self.listY = -(self.sel - 1) * 54
      end
      self.pendingSel = nil
    end
    app.waiting = self.pending ~= nil or (self:list().loading == true)
    local targetX = 110 - (self.cat - 1) * 110
    self.rowX = self.rowX + (targetX - self.rowX) * math.min(1, dt * 12)
    local targetY = -(self.sel - 1) * 54
    self.listY = self.listY + (targetY - self.listY) * math.min(1, dt * 14)
  end
  -- as ondas reaproveitam a mesma malha (so os vertices mudam), sem criar objetos a cada quadro
  local meshes, wpts, wverts = {}, {}, {}
  local function wave(idx, yBase, amp, len, speed, phase, col, alphaFill, alphaLine)
    local pts = wpts[idx] or {}
    local verts = wverts[idx] or {}
    wpts[idx], wverts[idx] = pts, verts
    local k = 0
    for i = 0, 64 do
      local x = i * 10
      local y = yBase + math.sin(x / len + app.t * speed + phase) * amp + math.sin(x / (len * 0.47) + app.t * speed * 0.6) * amp * 0.35
      pts[i * 2 + 1] = x; pts[i * 2 + 2] = y
      k = k + 1
      local v = verts[k] or {}
      v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8] = x, y, 0, 0, col[1], col[2], col[3], alphaFill
      verts[k] = v
      k = k + 1
      local w = verts[k] or {}
      w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8] = x, 480, 0, 0, col[1], col[2], col[3], alphaFill
      verts[k] = w
    end
    local mesh = meshes[idx]
    if not mesh then
      mesh = lg.newMesh(verts, "strip", "stream")
      meshes[idx] = mesh
    elseif mesh.setVertices then
      mesh:setVertices(verts)
    end
    lg.setColor(1, 1, 1, 1)
    lg.draw(mesh)
    U.set(col, alphaLine)
    lg.setLineWidth(1.5)
    lg.line(pts)
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.hex("#0F1220"))
    wave(1, 300, 22, 70, 0.5, 0, U.c.accent, 0.10, 0.45)
    wave(2, 350, 16, 90, -0.35, 2, U.c.accent2, 0.09, 0.25)
    -- topo
    U.text("lusm", 24, 14, U.font("m", 14), U.c.text)
    U.text("OS 4", 24 + U.font("m", 14):getWidth("lusm"), 14, U.font("m", 14), U.c.accent2)
    U.text(os.date("%d/%m"), 400, 14, U.font("r", 14), U.c.text2, 1, 80, "right")
    U.drawStatus(616, 13, U.c.text2)
    -- categorias
    for i, c in ipairs(self.cats) do
      local x = self.rowX + (i - 1) * 110
      local on = i == self.cat
      local col = on and U.c.text or U.c.dim
      local a = (self.sub and not on) and 0.25 or 1
      U.icon(c.icon, x + 55 - 19, 70, 38, col, a)
      if on or not self.sub then
        U.text(on and self.sub and self.sub.title or c.name, x - 20, 116, U.font(on and "m" or "r", 14), col, a, 150, "center")
      end
    end
    -- itens
    local list = self:list()
    lg.setScissor(0, 150, 640, 280)
    local y = 160 + self.listY
    for i, it in ipairs(list) do
      local on = i == self.sel
      local size = on and 58 or 44
      if y > 100 and y < 460 then
        local x = 145
        if on then
          U.rectLine(x - 3, y - 3, size + 6, size + 6, 12, U.c.text, 2.5)
        end
        U.tile(x, y, size, it.kind and it or { color = U.hex("#2A3042"), initials = it.ic }, 1, 10)
        local tx = x + size + 14
        if on then
          U.text(it.title, tx, y + 6, U.font("m", 19), U.c.text, 1, 600 - tx)
          U.text(it.sub or itemSubtitle(it), tx, y + 33, U.font("r", 12), U.hex("#A9B0C0"), 1, 600 - tx)
        else
          U.text(it.title, tx, y + 11, U.font("r", 15), U.c.dim, 1, 600 - tx)
        end
      end
      y = y + (on and 70 or 54)
    end
    lg.setScissor()
    if self.pending then
      U.rect(170, 214, 300, 60, 16, U.c.card, 0.97)
      U.rectLine(170, 214, 300, 60, 16, U.c.accent, 1.5)
      spinner(206, 244, 12, "Abrindo " .. (self.pending.sys.fullname or self.pending.sys.name) .. "…")
    end
    local h = self.sub and { { "A", "Jogar" }, { "Y", "Opções" }, { "B", "Voltar" } } or { { "A", "Abrir" }, { "‹ ›", "Categorias" }, { "START", "Ajustes" } }
    U.hints(h, 616, 450, U.hex("#0F1220"), U.c.text)
  end
  return s
end

-- ================================================================ HOME: VITRINE
Screens.home_vitrine = function()
  local s = { tab = 1, sel = 1, tabs = { "Jogos", "Todos", "Sistemas", "Favoritos" }, lists = {}, bg = nil }
  function s:list()
    if not self.lists[self.tab] then
      local out = {}
      if self.tab == 1 then
        for _, g in ipairs(data.recentGames(12)) do out[#out + 1] = gameItem(g) end
        if #out == 0 then
          for _, sys in ipairs(nonEmptySystems()) do out[#out + 1] = systemItem(sys) end
        end
      elseif self.tab == 2 then
        if not data.allScanned() then
          bgEnqueueAll()
          app.waiting = true
          return {}
        end
        for _, g in ipairs(data.allGames()) do out[#out + 1] = gameItem(g) end
      elseif self.tab == 3 then
        for _, sys in ipairs(nonEmptySystems()) do out[#out + 1] = systemItem(sys) end
      else
        if not data.allScanned() then
          bgEnqueueAll()
          app.waiting = true
          return {}
        end
        for _, g in ipairs(data.favoriteGames()) do out[#out + 1] = gameItem(g) end
      end
      self.lists[self.tab] = out
    end
    return self.lists[self.tab]
  end
  function s:restore(st)
    self.tab = math.max(1, math.min(st.tab or 1, #self.tabs))
    self.sel = math.max(1, math.min(st.sel or 1, math.max(1, #self:list())))
  end
  function s:resume() self.lists = {}; self.sel = math.max(1, math.min(self.sel, #self:list())) end
  function s:press(b)
    local list = self:list()
    if b == "left" then self.sel = math.max(1, self.sel - 1)
    elseif b == "right" then self.sel = math.min(math.max(1, #list), self.sel + 1)
    elseif b == "l1" then self.tab = (self.tab - 2) % #self.tabs + 1; self.sel = 1
    elseif b == "r1" then self.tab = self.tab % #self.tabs + 1; self.sel = 1
    elseif b == "a" then if list[self.sel] then openItem(list[self.sel]) end
    elseif b == "y" or b == "x" then
      local it = list[self.sel]
      if it and it.kind == "game" then gameMenu(it.game) end
    elseif b == "start" then push("settings")
    elseif b == "select" then powerMenu()
    end
  end
  function s:update(dt)
    local it = self:list()[self.sel]
    local target = it and U.mix(it.color, U.c.black, 0.15) or U.c.bg
    if not self.bg then self.bg = target end
    self.bg = U.mix(self.bg, target, math.min(1, dt * 5))
  end
  function s:draw()
    local list = self:list()
    local it = list[self.sel]
    U.rect(0, 0, 640, 480, 0, self.bg or U.c.bg)
    U.circle(560, 220, 190, U.c.white, 0.07)
    U.circle(500, 240, 100, U.c.white, 0.06)
    if it then
      local img = it.image and U.cover(it.image)
      if img then
        local iw, ih = img:getDimensions()
        local sc = math.min(196 / iw, 140 / ih)
        lg.setColor(1, 1, 1, 0.95)
        lg.draw(img, 616 - iw * sc, 154 + (140 - ih * sc) / 2, 0, sc, sc)
      else
        local sysimg = it.sysImage and U.cover(it.sysImage)
        if sysimg and it.kind == "game" then
          U.tile(470, 150, 146, it, 1, 14)
        else
          local bf = U.font("b", 150)
          U.text(it.initials or "", 620 - bf:getWidth(it.initials or ""), 120, bf, U.c.white, 0.13)
        end
      end
    end
    -- escurece embaixo para leitura
    for i = 0, 27 do
      U.set(U.c.black, (i / 27) * 0.92)
      lg.rectangle("fill", 0, 200 + i * 10, 640, 10)
    end
    -- abas
    local x = 24
    for i, t in ipairs(self.tabs) do
      local on = i == self.tab
      local f = U.font(on and "m" or "r", 16)
      U.text(t, x, 12, f, U.c.white, on and 1 or 0.75)
      if on then U.rect(x, 38, f:getWidth(t), 2, 1, U.c.white) end
      x = x + f:getWidth(t) + 22
    end
    U.drawStatus(616, 13, U.c.white)
    -- cards
    local cx = 24
    lg.setScissor(0, 50, 640, 120)
    local first = math.max(1, self.sel - 4)
    for i = first, #list do
      local item = list[i]
      local on = i == self.sel
      local size = on and 92 or 60
      if on then U.rectLine(cx - 4, 56, size + 8, size + 8, 15, U.c.white, 3) end
      U.tile(cx, 60, size, item, on and 1 or 0.85, 12)
      cx = cx + size + 10
      if cx > 640 then break end
    end
    lg.setScissor()
    if not it then
      if (self.tab == 2 or self.tab == 4) and not data.allScanned() then
        local done, total = scannedCount()
        spinner(40, 310, 12, (self.tab == 2 and "Lendo todos os jogos… " or "Carregando favoritos… ") .. done .. " de " .. total)
      else
      U.text("Nada por aqui ainda", 24, 300, U.font("m", 20), U.c.white)
      U.text(self.tab == 4 and "Aperte Y em um jogo para favoritar." or "Abra um jogo pela aba Sistemas.", 24, 330, U.font("r", 14), U.c.text2)
      end
    else
      -- informacoes
      local badge = it.kind == "game" and (it.system.fullname or it.system.name) or (it.kind == "system" and "Sistema" or "")
      local bf = U.font("m", 11)
      U.rect(24, 262, bf:getWidth(U.upper(badge)) + 18, 20, 10, U.c.white, 0.16)
      U.text(U.upper(badge), 33, 264, bf, U.c.white)
      U.text(it.title, 24, 288, U.font("b", 28), U.c.white, 1, 400)
      U.text(itemSubtitle(it), 24, 328, U.font("r", 14), U.hex("#D5DAE3"), 1, 400)
      -- botao jogar
      local label = it.kind == "game" and "Jogar" or "Abrir"
      U.rect(24, 362, 128, 42, 21, U.c.white)
      U.icon("play", 46, 375, 16, U.c.black)
      U.text(label, 70, 372, U.font("m", 16), U.c.black)
      if it.kind == "game" then
        U.circle(182, 383, 21, U.c.white, 0.16)
        U.icon(data.isFav(it.game) and "starfill" or "star", 172, 373, 20, U.c.white)
        U.circle(230, 383, 21, U.c.white, 0.16)
        U.icon("dots", 220, 373, 20, U.c.white)
        -- painel lateral
        U.rect(446, 300, 170, 104, 14, U.c.white, 0.10)
        U.text("Último acesso", 458, 312, U.font("r", 12), U.hex("#D5DAE3"))
        U.text(since(it.game.lastTime) or "nunca jogado", 458, 330, U.font("m", 15), U.c.white, 1, 150)
        U.text(it.game.developer or (it.game.year and ("Lançamento " .. it.game.year)) or it.system.short, 458, 356, U.font("r", 12), U.hex("#D5DAE3"), 1, 150)
        U.gradientBar(458, 382, 146, 5, U.c.accent, U.c.accent2)
      end
    end
    U.hints({ { "A", it and it.kind == "game" and "Jogar" or "Abrir" }, { "Y", "Opções" }, { "L/R", "Abas" } }, 616, 450, U.c.black, U.c.white)
  end
  return s
end

-- ================================================================ HOME: METRO
-- Abas em minusculas no topo e blocos quadrados, largos e grandes numa grade que
-- rola para o lado. LB/RB (ou passar da borda) troca de aba.
local MT = { U = 146, G = 8, X0 = 24, Y0 = 104 }
MT.STEP = MT.U + MT.G
local function mtSize(w) return w * MT.U + (w - 1) * MT.G end

local function metroPivots()
  local P = {}
  local function tile(col, row, w, h, t) t.col, t.row, t.w, t.h = col, row, w, h; return t end
  -- inicio
  P[#P + 1] = { name = "início", build = function()
    local T = {}
    local rec = data.recentGames(4)
    T[#T + 1] = tile(0, 0, 2, 2, { label = "todos os jogos", sub = "lista de A a Z", big = data.totalGames() .. "",
      icon = "list", color = U.c.accent, mosaic = true, act = function() push("games", { title = "Todos os jogos", all = true }) end })
    for i = 1, 4 do
      if rec[i] then T[#T + 1] = tile(2 + math.floor((i - 1) / 2), (i - 1) % 2, 1, 1, { game = rec[i] }) end
    end
    local c = #rec > 2 and 4 or (#rec > 0 and 3 or 2)
    T[#T + 1] = tile(c, 0, 2, 1, { label = "recentes", sub = #rec > 0 and ("último: " .. rec[1].name) or "nenhum jogo ainda", icon = "clock", color = U.hex("#3E8E7E"),
      act = function() push("games", { title = "Jogados recentemente", recents = true }) end })
    T[#T + 1] = tile(c, 1, 1, 1, { label = "coleções", sub = "favoritos e listas", icon = "star", color = U.hex("#C98A1B"),
      act = function() push("collections") end })
    T[#T + 1] = tile(c + 1, 1, 1, 1, { label = "consoles", icon = "grid", color = U.c.accent2,
      act = function() push("systems") end })
    return T
  end }
  -- jogos: atalhos + todos os jogos de A a Z em blocos
  P[#P + 1] = { name = "jogos", build = function()
    local T = {}
    T[#T + 1] = tile(0, 0, 1, 2, { label = "todos os jogos", sub = "lista de A a Z", big = data.totalGames() .. "", icon = "list", color = U.c.accent, mosaic = true,
      act = function() push("games", { title = "Todos os jogos", all = true }) end })
    T[#T + 1] = tile(1, 0, 1, 1, { label = "coleções", sub = "favoritos e listas", icon = "star", color = U.hex("#C98A1B"),
      act = function() push("collections") end })
    T[#T + 1] = tile(1, 1, 1, 1, { label = "pesquisar", sub = "FN + X", icon = "search", color = U.hex("#3E8E7E"),
      act = function() openSearch() end })
    if not data.allScanned() then
      bgEnqueueAll()
      T.loading = true
      return T
    end
    for i, g in ipairs(data.allGames()) do
      T[#T + 1] = tile(2 + math.floor((i - 1) / 2), (i - 1) % 2, 1, 1, { game = g })
    end
    return T
  end }
  -- consoles
  P[#P + 1] = { name = "consoles", build = function()
    local T = {}
    for i, sys in ipairs(nonEmptySystems()) do
      T[#T + 1] = tile(math.floor((i - 1) / 2), (i - 1) % 2, 1, 1, { sys = sys })
    end
    return T
  end }
  -- configuracoes
  P[#P + 1] = { name = "configurações", build = function()
    local w = data.wifi()
    return {
      tile(0, 0, 2, 1, { label = "ajustes", sub = "aparência, tela, som e emulação", icon = "gear", color = U.c.accent, act = function() push("settings") end }),
      tile(0, 1, 1, 1, { label = "layout", icon = "grid", color = U.hex("#3E5BB8"), act = function() push("layout") end }),
      tile(1, 1, 1, 1, { label = "wi-fi", sub = (w == nil and "sem adaptador") or (w and "conectado") or "desconectado", icon = "wifi", color = U.hex("#5A48B0"), act = function() push("wifi") end }),
      tile(2, 0, 1, 1, { label = "ferramentas", icon = "tools", color = U.hex("#2F7D62"), act = function() push("settings", { cat = 5 }) end }),
      tile(2, 1, 1, 1, { label = "controles", icon = "gamepad", color = U.hex("#3A6F9E"), act = function() push("padtest") end }),
      tile(3, 0, 1, 1, { label = "informações", icon = "globe", color = U.hex("#56607A"), act = function() push("info") end }),
      tile(3, 1, 1, 1, { label = "energia", icon = "power", color = U.hex("#8C3A3A"), act = powerMenu }),
    }
  end }
  return P
end

Screens.home_metro = function()
  local s = { tab = 1, sel = {}, scroll = {}, cache = {}, pivots = metroPivots(), hx = 0 }
  function s:tiles(i)
    i = i or self.tab
    local c = self.cache[i]
    if not c or c.loading then
      c = self.pivots[i].build()
      self.cache[i] = c
      if c.loading then app.waiting = true end
    end
    return c
  end
  function s:cur() return self.sel[self.tab] or 1 end
  function s:restore(st)
    self.tab = math.max(1, math.min(st.tab or 1, #self.pivots))
    self.sel[self.tab] = st.sel or 1
  end
  function s:resume() self.cache = {} end
  local function rect(t)
    return MT.X0 + t.col * MT.STEP, MT.Y0 + t.row * MT.STEP, mtSize(t.w), mtSize(t.h)
  end
  local function open(t)
    if t.game then launchGame(t.game)
    elseif t.sys then push("games", { title = t.sys.fullname or t.sys.name, system = t.sys })
    elseif t.act then t.act() end
  end
  -- procura o bloco mais proximo na direcao apertada
  local function nearest(T, from, dx, dy)
    local fx, fy, fw, fh = rect(from)
    local cx, cy = fx + fw / 2, fy + fh / 2
    local best, bestD = nil, math.huge
    -- os blocos ficam em ordem de coluna: so olha uma janela perto do atual
    for _, t in ipairs(T) do
      if math.abs(t.col - from.col) <= 4 then
        local x, y, w, h = rect(t)
        local tx, ty = x + w / 2, y + h / 2
        local ok
        if dx > 0 then ok = x >= fx + fw - 2
        elseif dx < 0 then ok = x + w <= fx + 2
        elseif dy > 0 then ok = y >= fy + fh - 2 and x < fx + fw and x + w > fx
        else ok = y + h <= fy + 2 and x < fx + fw and x + w > fx end
        if ok then
          local d = dx ~= 0 and (math.abs(tx - cx) + math.abs(ty - cy) * 2) or (math.abs(ty - cy) + math.abs(tx - cx) * 2)
          if d < bestD then best, bestD = t, d end
        end
      end
    end
    return best
  end
  local function indexOf(T, t) for i, v in ipairs(T) do if v == t then return i end end return 1 end
  function s:switch(d)
    local n = self.tab + d
    if n < 1 or n > #self.pivots then return end
    self.tab = n
    if d < 0 then
      local T = self:tiles()
      if not self.sel[n] and T and #T > 0 then self.sel[n] = 1 end
    end
  end
  function s:press(b)
    local T = self:tiles()
    local t = T[self:cur()]
    if b == "l1" then self:switch(-1)
    elseif b == "r1" then self:switch(1)
    elseif b == "left" or b == "right" or b == "up" or b == "down" then
      if not t then
        if b == "left" then self:switch(-1) elseif b == "right" then self:switch(1) end
        return
      end
      local dx = (b == "right" and 1) or (b == "left" and -1) or 0
      local dy = (b == "down" and 1) or (b == "up" and -1) or 0
      local nx = nearest(T, t, dx, dy)
      if nx then self.sel[self.tab] = indexOf(T, nx)
      elseif dx ~= 0 then self:switch(dx) end
    elseif b == "a" and t then open(t)
    elseif (b == "y" or b == "x") and t and (t.game or (t.hero and t.game)) then gameMenu(t.game)
    elseif b == "start" then push("settings")
    elseif b == "select" then powerMenu()
    end
  end
  function s:update(dt)
    local T = self:tiles()
    local t = T[self:cur()]
    local target = self.scroll[self.tab] or 0
    if t then
      local x, _, w = rect(t)
      if x - target < MT.X0 then target = x - MT.X0
      elseif x + w - target > 640 - 60 then target = x + w - (640 - 60) end
      if t.col == 0 then target = 0 end
    end
    self.scrollTarget = self.scrollTarget or {}
    self.scrollTarget[self.tab] = target
    local cur = self.scroll[self.tab] or target
    self.scroll[self.tab] = cur + (target - cur) * math.min(1, dt * 14)
    -- cabecalho desliza ate a aba atual
    local hx = 0
    local f = U.font("l", 30)
    for i = 1, self.tab - 1 do hx = hx + f:getWidth(self.pivots[i].name) + 26 end
    self.hx = self.hx + (hx - self.hx) * math.min(1, dt * 12)
  end
  -- desenho de um bloco
  -- capa (ou, sem capa, o icone do console sobre a cor dele)
  local function coverArea(g, x, y, w, h)
    local img = g.image and U.cover(g.image)
    if img then
      U.rect(x, y, w, h, 0, U.hex("#0E1118"))
      U.withClip(x, y, w, h, function() U.drawImage(img, x, y, w, h, "fill", 1, 0, g.image) end)
      return true
    end
    U.rect(x, y, w, h, 0, U.mix(g.system.color or U.c.line, U.hex("#0A0C12"), 0.45))
    local si = g.system.image and U.cover(g.system.image)
    if si then
      local sz = math.min(w, h) * 0.5
      U.drawImage(si, x + (w - sz) / 2, y + (h - 26 - sz) / 2, sz, sz, "fit", 1, 0, g.system.image)
    else
      local bf = U.font("b", math.floor(math.min(w, h) * 0.3))
      local ini = g.system.short or "?"
      U.text(ini, x, y + (h - 26) / 2 - bf:getHeight() / 2, bf, U.c.white, 0.5, w, "center")
    end
    return false
  end
  local function drawTile(t, x, y, w, h, focus)
    if t.hero and t.game then
      local g = t.game
      U.rect(x, y, w, h, 0, U.mix(g.system.color or U.c.line, U.hex("#0A0C12"), 0.55))
      local img = g.image and U.cover(g.image)
      U.withClip(x, y, w, h, function()
        if img then
          U.drawImage(img, x, y, w, h, "fill", 0.35, 0, g.image)
          U.drawImage(img, x + w * 0.4, y + 10, w * 0.58, h - 80, "fit", 1, 0, g.image)
        else
          local si = g.system.image and U.cover(g.system.image)
          if si then U.drawImage(si, x + w * 0.42, y + 16, w * 0.52, h * 0.52, "fit", 0.9, 0, g.system.image) end
        end
        for i = 0, 11 do U.rect(x, y + h - 96 + i * 8, w, 8, 0, U.hex("#05060A"), i / 11 * 0.85) end
      end)
      U.text("continuar · " .. (g.system.fullname or g.system.name), x + 14, y + h - 62, U.font("r", 13), U.c.white, 0.8, w - 28)
      U.text(g.name, x + 14, y + h - 42, U.font("m", 20), U.c.white, 1, w - 28)
      return
    end
    if t.game then
      coverArea(t.game, x, y, w, h)
      U.rect(x, y + h - 26, w, 26, 0, U.hex("#05060A"), 0.8)
      U.text(t.game.name, x + 8, y + h - 22, U.font("r", 12), U.c.white, 1, w - 16)
      return
    end
    if t.sys then
      U.rect(x, y, w, h, 0, U.mix(t.sys.color or U.c.line, U.hex("#0A0C12"), 0.3))
      local img = t.sys.image and U.cover(t.sys.image)
      if img then U.withClip(x, y, w, h, function() U.drawImage(img, x, y, w, h, "fill", 1, 0, t.sys.image) end)
      else
        local bf = U.font("b", 40)
        U.text(t.sys.short or "", x, y + 40, bf, U.c.white, 0.6, w, "center")
      end
      U.rect(x, y + h - 26, w, 26, 0, U.hex("#05060A"), 0.8)
      U.text(t.sys.fullname or t.sys.name, x + 8, y + h - 22, U.font("r", 12), U.c.white, 1, w - 52)
      local cnt = tostring(t.sys.count)
      U.text(cnt, x + w - 8 - U.font("r", 12):getWidth(cnt), y + h - 22, U.font("r", 12), U.c.white, 0.7)
      return
    end
    -- bloco "todos os jogos": mosaico de capas com a cor do lusmOS por cima
    if t.mosaic then
      U.rect(x, y, w, h, 0, U.hex("#10131C"))
      if not s.covers or (#s.covers < 12 and (s.coversT or 0) < app.t) then
        s.covers = data.sampleCovers(12); s.coversT = app.t + 2
      end
      local cols = w > MT.U and 4 or 2
      local cw = w / cols
      local ch = cw * 1.3
      -- so as capas que existem de verdade (as que falham ficam de fora)
      local good = {}
      for _, path in ipairs(s.covers) do
        local img = U.cover(path)
        if img then good[#good + 1] = { img, path } end
      end
      U.withClip(x, y, w, h, function()
        if #good == 0 then
          U.rect(x, y, w, h, 0, U.c.accent)
        else
          local k = 0
          for row = 0, math.ceil(h / ch) do
            for col = 0, cols - 1 do
              k = k + 1
              local g = good[(k - 1) % #good + 1]
              U.drawImage(g[1], x + col * cw + 1, y + row * ch + 1, cw - 2, ch - 2, "fill", 1, 0, g[2])
            end
          end
        end
        -- cor do lusmOS por cima, mais forte embaixo para o texto
        U.rect(x, y, w, h, 0, U.c.accent, 0.30)
        local top = math.floor(y + h * 0.4)
        local bh = math.ceil((y + h - top) / 20)
        for i = 0, 19 do U.rect(x, top + i * bh, w, bh, 0, U.hex("#0A0C18"), i / 19 * 0.88) end
      end)
      U.icon(t.icon, x + 12, y + 12, 30, U.c.white)
      local bf = U.font("l", w > MT.U and 64 or 40)
      U.text(t.big, x + 12, y + h - 44 - bf:getHeight() - 14, bf, U.c.white)
      U.text(t.sub, x + 12, y + h - 44, U.font("r", 11), U.c.white, 0.85, w - 24)
      U.text(t.label, x + 12, y + h - 26, U.font("m", 15), U.c.white, 1, w - 24)
      return
    end
    -- bloco de atalho, cor chapada
    U.rect(x, y, w, h, 0, t.color or U.c.accent)
    if t.icon then U.icon(t.icon, x + 12, y + 12, (w > MT.U and h > MT.U) and 34 or 28, U.c.white) end
    if t.big then
      local bf = U.font("l", (h > MT.U and w > MT.U) and 72 or ((h > MT.U) and 46 or 32))
      local by = (h > MT.U) and (y + h / 2 - bf:getHeight() / 2) or (y + 6)
      U.text(t.big, x + w - 12 - bf:getWidth(t.big), by, bf, U.c.white, 0.92)
    end
    if t.sub then U.text(t.sub, x + 12, y + h - 44, U.font("r", 11), U.c.white, 0.8, w - 24) end
    U.text(t.label, x + 12, y + h - 26, U.font("m", 14), U.c.white, 1, w - 24)
  end
  function s:draw()
    -- fundo escuro com luz suave da cor do sistema
    U.rect(0, 0, 640, 480, 0, U.hex("#0A0C12"))
    U.circle(520, 620, 420, U.c.accent, 0.07)
    U.circle(80, 640, 300, U.c.accent2, 0.06)
    -- topo: perfil e status
    U.circle(588, 30, 14, U.c.accent2)
    U.text(data.config.initial or "L", 574, 20, U.font("b", 13), U.c.white, 1, 28, "center")
    U.drawStatus(564, 21, U.c.text2)
    -- abas
    local f = U.font("l", 30)
    local hx = MT.X0 - self.hx
    for i, p in ipairs(self.pivots) do
      local on = i == self.tab
      U.text(p.name, hx, 46, f, on and U.c.white or U.c.muted, on and 1 or 0.55)
      hx = hx + f:getWidth(p.name) + 26
    end
    -- blocos
    local T = self:tiles()
    local scroll = self.scroll[self.tab] or 0
    local sel = self:cur()
    lg.setScissor(0, MT.Y0 - 8, 640, 2 * MT.STEP + 8)
    for i, t in ipairs(T) do
      local x, y, w, h = rect(t)
      x = x - scroll
      if x + w > -10 and x < 650 then
        local focus = i == sel
        drawTile(t, x, y, w, h, focus)
        if focus then
          U.rectLine(x - 3, y - 3, w + 6, h + 6, 0, U.c.white, 3)
        end
      end
    end
    lg.setScissor()
    if T.loading then
      local done, total = scannedCount()
      spinner(MT.X0 + 2 * MT.STEP + 16, MT.Y0 + 60, 12, "Lendo os consoles… " .. done .. " de " .. total)
    end
    -- rodape
    local t = T[sel]
    local h = { { "A", "Abrir" }, { "L/R", "Abas" } }
    if t and t.game then h[#h + 1] = { "Y", "Opções" } end
    U.hints(h, 616, 440, U.hex("#0A0C12"), U.c.text)
    U.text("lusm", 24, 440, U.font("m", 13), U.c.text)
    U.text("OS 4", 24 + U.font("m", 13):getWidth("lusm"), 440, U.font("m", 13), U.c.accent2)
  end
  return s
end

-- ================================================================ lista de sistemas
Screens.systems = function()
  local s = { sel = 1, list = nonEmptySystems(), scroll = 0 }
  local COLS, TS, RH = 4, 126, 186
  function s:press(b)
    local n = #self.list
    if b == "left" then self.sel = math.max(1, self.sel - 1)
    elseif b == "right" then self.sel = math.min(n, self.sel + 1)
    elseif b == "up" then self.sel = math.max(1, self.sel - COLS)
    elseif b == "down" then self.sel = math.min(n, self.sel + COLS)
    elseif b == "a" and self.list[self.sel] then
      local sys = self.list[self.sel]
      push("games", { title = sys.fullname or sys.name, system = sys })
    elseif b == "b" then pop()
    end
  end
  function s:update(dt)
    local row = math.floor((self.sel - 1) / COLS)
    local target = math.max(0, row - 1) * RH
    self.scroll = self.scroll + (target - self.scroll) * math.min(1, dt * 12)
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.text("Sistemas", 24, 14, U.font("m", 20), U.c.text)
    U.text(#self.list .. " com jogos", 130, 19, U.font("r", 13), U.c.muted)
    U.drawStatus(616, 17, U.c.text2)
    lg.setScissor(0, 52, 640, 380)
    for i, sys in ipairs(self.list) do
      local col = (i - 1) % COLS
      local row = math.floor((i - 1) / COLS)
      local x = 26 + col * 150
      local y = 62 + row * RH - self.scroll
      if y > -RH and y < 440 then
        local on = i == self.sel
        if on then U.rectLine(x - 5, y - 5, TS + 10, TS + 10, 18, U.c.accent, 3) end
        U.tile(x, y, TS, systemItem(sys), 1, 14)
        U.text(sys.fullname or sys.name, x, y + TS + 8, U.font(on and "m" or "r", 13), on and U.c.text or U.c.text2, 1, TS)
        U.text(sys.count .. " jogos", x, y + TS + 27, U.font("r", 12), U.c.muted, 1, TS)
      end
    end
    lg.setScissor()
    U.hints({ { "A", "Abrir" }, { "B", "Voltar" } }, 616, 448)
  end
  return s
end

-- ================================================================ lista de jogos
Screens.games = function(arg)
  local s = { sel = 1, title = arg.title, scroll = 0, list = {}, arg = arg }
  local function ready()
    if arg.recents then return true end
    if arg.favorites or arg.all or arg.search or arg.collection then return data.allScanned() end
    return arg.system.games ~= nil
  end
  local function fill()
    if arg.recents then s.list = data.recentGames(30)
    elseif arg.favorites then s.list = data.favoriteGames()
    elseif arg.all then s.list = data.allGames()
    elseif arg.search then s.list = data.searchGames(arg.search)
    elseif arg.collection then s.list = data.collectionGames(arg.collection)
    else s.list = arg.system.games end
    s.loading = false
    if arg.restoreSel then
      s.sel = math.max(1, math.min(arg.restoreSel, #s.list))
      s.scroll = math.max(0, math.min(s.sel - 6, #s.list - 11)) * 32
      arg.restoreSel = nil
    end
  end
  if ready() then fill() else
    s.loading = true
    if arg.favorites or arg.all or arg.search or arg.collection then bgEnqueueAll() else bgEnqueue(arg.system, true) end
  end
  local multi = arg.favorites or arg.all or arg.recents or arg.search or arg.collection
  function s:resume()
    if arg.favorites and not s.loading then s.list = data.favoriteGames() end
    self.sel = math.max(1, math.min(self.sel, math.max(1, #self.list)))
  end
  local ROWS, RH = 11, 32
  function s:press(b)
    if self.loading then
      if b == "b" then pop() end
      return
    end
    local n = #self.list
    if b == "up" then self.sel = self.sel > 1 and self.sel - 1 or n
    elseif b == "down" then self.sel = self.sel < n and self.sel + 1 or 1
    elseif b == "left" or b == "l1" then self.sel = math.max(1, self.sel - ROWS)
    elseif b == "right" or b == "r1" then self.sel = math.min(n, self.sel + ROWS)
    elseif b == "l2" or b == "r2" then
      -- pula para a proxima letra
      local cur = self.list[self.sel]
      if not cur then return end
      local letter = cur.name:sub(1, 1):upper()
      local step = b == "r2" and 1 or -1
      local i = self.sel
      repeat
        i = i + step
      until i < 1 or i > n or self.list[i].name:sub(1, 1):upper() ~= letter
      self.sel = math.max(1, math.min(n, i))
    elseif b == "a" and self.list[self.sel] then launchGame(self.list[self.sel])
    elseif b == "y" and self.list[self.sel] then
      data.toggleFav(self.list[self.sel])
      toast(data.isFav(self.list[self.sel]) and "Adicionado aos favoritos" or "Removido dos favoritos")
    elseif b == "x" and arg.search then
      pop(); openSearch(arg.search)
    elseif b == "x" and self.list[self.sel] then gameMenu(self.list[self.sel])
    elseif b == "b" then pop()
    end
  end
  function s:update(dt)
    if self.loading then
      app.waiting = true
      if ready() then fill() end
    end
    local target = math.max(0, math.min(self.sel - 6, #self.list - ROWS)) * RH
    self.scroll = self.scroll + (target - self.scroll) * math.min(1, dt * 16)
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.text(self.title, 24, 14, U.font("m", 20), U.c.text, 1, 360)
    U.text(#self.list == 1 and "1 jogo" or (#self.list .. " jogos"), 24, 42, U.font("r", 12), U.c.muted)
    U.drawStatus(616, 17, U.c.text2)
    if self.loading then
      if arg.all or arg.favorites or arg.search or arg.collection then
        local done, total = scannedCount()
        spinner(44, 130, 12, "Lendo os consoles… " .. done .. " de " .. total)
      else
        spinner(44, 130, 12, "Carregando a lista de jogos…")
      end
      U.hints({ { "B", "Voltar" } }, 616, 448)
      return
    end
    if #self.list == 0 then
      if arg.search then
        U.text("Nenhum jogo encontrado.", 24, 120, U.font("m", 17), U.c.text)
        U.text("Tente outra palavra. Acentos e maiúsculas não importam.", 24, 148, U.font("r", 14), U.c.muted)
        U.hints({ { "X", "Pesquisar de novo" }, { "B", "Voltar" } }, 616, 448)
      else
        U.text("Nenhum jogo aqui ainda.", 24, 120, U.font("r", 15), U.c.muted)
        U.hints({ { "B", "Voltar" } }, 616, 448)
      end
      return
    end
    -- lista
    U.rect(16, 66, 344, 372, 14, U.c.panel)
    lg.setScissor(16, 72, 344, 360)
    local first = math.max(1, math.floor(self.scroll / RH))
    for i = first, math.min(#self.list, first + ROWS + 2) do
      local g = self.list[i]
      local y = 74 + (i - 1) * RH - self.scroll
      local on = i == self.sel
      if on then U.rect(22, y, 332, RH - 2, 9, U.c.line); U.rectLine(22, y, 332, RH - 2, 9, U.c.accent, 2) end
      local fav = data.isFav(g)
      local tagw = 0
      if multi then
        local tf = U.font("r", 11)
        local tag = U.fit(tf, g.system.short or g.system.name, 64)
        tagw = tf:getWidth(tag) + 12
        U.text(tag, 346 - tagw + 6, y + 8, tf, on and U.c.accentLight or U.c.muted)
      end
      U.text(g.name, 34, y + 5, U.font(on and "m" or "r", 14), on and U.c.text or U.c.text2, 1, (fav and 280 or 306) - tagw)
      if fav then U.icon("starfill", 322 - tagw, y + 7, 15, U.hex("#FFC870")) end
    end
    lg.setScissor()
    -- detalhe
    local g = self.list[self.sel]
    local item = gameItem(g)
    U.tile(388, 72, 228, item, 1, 14)
    U.text(g.name, 388, 312, U.font("m", 17), U.c.text, 1, 228)
    local meta = g.system.fullname or g.system.name
    if g.year then meta = meta .. " · " .. g.year end
    U.text(meta, 388, 338, U.font("r", 12), U.c.muted, 1, 228)
    if g.developer then U.text(g.developer, 388, 356, U.font("r", 12), U.c.muted, 1, 228) end
    if g.folder then U.text("Pasta: " .. g.folder, 388, 374, U.font("r", 12), U.c.muted, 1, 228) end
    if arg.search then
      U.hints({ { "A", "Jogar" }, { "Y", "Favorito" }, { "X", "Nova pesquisa" }, { "B", "Voltar" } }, 616, 448)
    else
      U.hints({ { "A", "Jogar" }, { "X", "Opções" }, { "Y", "Favorito" }, { "R2", "Letra" }, { "B", "Voltar" } }, 616, 448)
    end
  end
  return s
end

-- ================================================================ tela de entrada no jogo
local TIPS = {
  "FN + Start sai do jogo e volta para o lusmOS.",
  "FN + R2 salva o estado. FN + L2 carrega.",
  "FN + X abre o menu do RetroArch.",
  "Brilho e volume continuam nos atalhos de sempre.",
}
Screens.launch = function(game)
  local s = { t = 0, game = game, item = gameItem(game), tip = TIPS[math.random(#TIPS)], done = false }
  local cmd, emu, core = data.buildCommand(game)
  s.cmd = cmd
  s.core = core and core ~= "" and core or emu
  function s:press(b)
    if b == "b" and not self.done then pop() end
  end
  function s:update(dt)
    self.t = self.t + dt
    if self.t > 1.5 and not self.done then
      self.done = true
      data.pushRecent(self.game)
      quitWith("game", self.cmd)
    end
  end
  function s:draw()
    local t = self.t
    U.rect(0, 0, 640, 480, 0, U.mix(self.item.color, U.c.black, 0.55))
    local deco = (self.item.image and U.cover(self.item.image)) or (self.item.sysImage and U.cover(self.item.sysImage))
    if deco then U.drawImage(deco, 380, 210, 250, 150, "fit", 0.12) end
    local e = 1 - (1 - math.min(1, t / 0.45)) ^ 3
    local size = 150 + 26 * e
    U.rect(28 - 2, 160 - size / 2 - 2, size + 4, size + 4, 18, U.c.white, 0.85 * e)
    U.tile(28, 160 - size / 2, size, self.item, e, 16)
    local tx = 28 + 176 + 26
    local slide = (1 - e) * 16
    local f = U.font("m", 12)
    local blink = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(t * 8))
    U.circle(tx + 4 + slide, 102, 4, U.c.accent, blink)
    U.text("INICIANDO", tx + 16 + slide, 94, f, U.c.accentLight, e)
    U.text(self.game.name, tx + slide, 114, U.font("b", 26), U.c.white, e, 640 - tx - 24)
    U.text((self.game.system.fullname or self.game.system.name) .. (self.core and (" · " .. self.core) or ""), tx + slide, 152, U.font("r", 14), U.hex("#D5DAE3"), e, 640 - tx - 24)
    U.rect(tx, 188, 250, 5, 3, U.c.white, 0.15)
    U.gradientBar(tx, 188, 250 * math.min(1, t / 1.4), 5, U.c.accent, U.c.accent2)
    U.rect(28, 372, 584, 44, 14, U.c.white, 0.08)
    U.rect(40, 384, 50, 20, 6, U.c.accent2)
    U.text("DICA", 40, 386, U.font("b", 11), U.c.white, 1, 50, "center")
    U.text(self.tip, 102, 383, U.font("r", 14), U.c.text, 1, 500)
    U.hints({ { "B", "Cancelar" } }, 612, 448, U.c.black, U.c.white)
  end
  return s
end

-- ================================================================ menu modal
Screens.menu = function(arg)
  local s = { sel = 1, title = arg.title, items = arg.items, under = app.screen }
  function s:press(b)
    if b == "up" then self.sel = math.max(1, self.sel - 1)
    elseif b == "down" then self.sel = math.min(#self.items, self.sel + 1)
    elseif b == "a" then self.items[self.sel].act()
    elseif b == "b" then pop()
    end
  end
  function s:draw()
    if self.under and self.under.draw then self.under:draw() end
    U.rect(0, 0, 640, 480, 0, U.c.black, 0.7)
    local h = 70 + #self.items * 44
    local y0 = 240 - h / 2
    U.rect(150, y0, 340, h, 18, U.c.card)
    U.text(self.title, 172, y0 + 18, U.font("m", 16), U.c.text, 1, 296)
    for i, it in ipairs(self.items) do
      local y = y0 + 54 + (i - 1) * 44
      local on = i == self.sel
      if on then U.rect(162, y, 316, 38, 10, U.c.line); U.rectLine(162, y, 316, 38, 10, U.c.accent, 2) end
      U.text(it.label, 178, y + 8, U.font(on and "m" or "r", 15), on and U.c.text or U.c.text2, 1, 290)
    end
  end
  return s
end

-- ================================================================ escolher layout
Screens.layout = function()
  local order = { "grade", "cruz", "vitrine", "metro" }
  local s = { sel = 1 }
  for i, k in ipairs(order) do if k == data.config.layout then s.sel = i end end
  local info = {
    grade = { "Grade", "Blocos grandes em fila e atalhos redondos." },
    cruz = { "Cruz", "Categorias na horizontal, itens na vertical, ondas no fundo." },
    vitrine = { "Vitrine", "Capa em destaque e fundo que muda com a seleção." },
    metro = { "Metrô", "Abas no topo e blocos grandes e pequenos em grade." },
  }
  function s:press(b)
    if b == "left" then self.sel = math.max(1, self.sel - 1)
    elseif b == "right" then self.sel = math.min(#order, self.sel + 1)
    elseif b == "a" then
      data.config.layout = order[self.sel]
      data.saveConfig()
      goHome()
      toast("Layout " .. info[order[self.sel]][1] .. " aplicado")
    elseif b == "b" then pop()
    end
  end
  local function mini(k, x, y, w, h)
    if k == "grade" then
      U.rect(x, y, w, h, 10, U.c.bg2)
      U.circle(x + 16, y + 16, 7, U.c.accent2)
      local cols = { "#8C2B2B", "#2B3A8C", "#1F6B4A", "#5A2B8C" }
      local bs = math.floor((w - 20) / 4) - 3
      for i = 1, 4 do
        if i == 1 then U.rect(x + 8, y + 30, bs + 4, bs + 4, 7, U.c.accent) end
        U.rect(x + 10 + (i - 1) * (bs + 3), y + 32, bs, bs, 6, U.hex(cols[i]))
      end
      for i = 0, 4 do U.circle(x + w / 2 - 36 + i * 18, y + h - 16, 5, U.c.line2) end
    elseif k == "cruz" then
      U.rect(x, y, w, h, 10, U.hex("#0F1220"))
      U.set(U.c.accent, 0.25)
      lg.rectangle("fill", x, y + h - 30, w, 30, 0, 10)
      local step = (w - 20) / 5
      for i = 0, 4 do
        local sz = i == 1 and 16 or 10
        U.rect(x + 10 + i * step + (step - sz) / 2, y + 22 - sz / 2, sz, sz, 4, i == 1 and U.c.text or U.c.line2)
      end
      for i = 0, 2 do
        U.rect(x + 10 + step + (step - 14) / 2, y + 40 + i * 16, i == 0 and 14 or 10, i == 0 and 14 or 10, 3, U.hex(({ "#8C2B2B", "#2B3A8C", "#1F6B4A" })[i + 1]))
        U.rect(x + 10 + step * 2, y + 44 + i * 16, i == 0 and (w * 0.4) or (w * 0.3), 5, 2, i == 0 and U.c.text or U.c.line2)
      end
    elseif k == "metro" then
      U.rect(x, y, w, h, 10, U.hex("#0A0C12"))
      U.rect(x + 8, y + 9, 26, 5, 2, U.c.white)
      U.rect(x + 40, y + 9, 20, 5, 2, U.c.line2)
      U.rect(x + 66, y + 9, 22, 5, 2, U.c.line2)
      local u = math.min(math.floor((h - 32) / 2) - 2, math.floor((w - 16 - 9) / 4.5))
      U.rect(x + 8, y + 22, u * 2 + 3, u * 2 + 3, 0, U.c.accent)
      U.rect(x + 14 + u * 2, y + 22, u, u, 0, U.hex("#3E8E7E"))
      U.rect(x + 14 + u * 2, y + 25 + u, u, u, 0, U.c.accent2)
      U.rect(x + 17 + u * 3, y + 22, w - 8 - (17 + u * 3), u, 0, U.hex("#C98A1B"))
      U.rect(x + 17 + u * 3, y + 25 + u, u, u, 0, U.hex("#56607A"))
    else
      U.rect(x, y, w, h, 10, U.hex("#2B3A8C"))
      U.withClip(x, y, w, h, function() U.circle(x + w - 20, y + 20, 50, U.c.white, 0.1) end)
      U.rect(x + 10, y + 12, 28, 28, 6, U.c.white)
      for i = 0, 2 do U.rect(x + 44 + i * 22, y + 12, 18, 18, 5, U.c.white, 0.35) end
      U.rect(x + 10, y + h - 40, w * 0.55, 9, 4, U.c.white)
      U.rect(x + 10, y + h - 24, 40, 14, 7, U.c.white)
    end
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.logo(24, 16, 22)
    U.wordmark(54, 14, 17)
    U.drawStatus(616, 17, U.c.text2)
    U.text("AJUSTES · APARÊNCIA", 24, 62, U.font("r", 12), U.c.muted)
    U.text("Escolha o layout da Home", 24, 80, U.font("m", 24), U.c.text)
    U.text("Cada layout muda a navegação inteira, não só as cores.", 24, 114, U.font("r", 14), U.c.muted)
    local cw, gap = 140, 10
    for i, k in ipairs(order) do
      local x = 24 + (i - 1) * (cw + gap)
      local on = i == self.sel
      if on then U.rect(x - 3, 149, cw + 6, 234, 16, U.c.accent) end
      U.rect(x, 152, cw, 228, 14, U.c.card)
      mini(k, x + 8, 160, cw - 16, 96)
      U.text(info[k][1], x + 10, 266, U.font("m", 15), U.c.text)
      if data.config.layout == k then
        local f = U.font("m", 10)
        U.rect(x + cw - 10 - f:getWidth("Ativo") - 12, 268, f:getWidth("Ativo") + 12, 18, 9, U.c.accent2)
        U.text("Ativo", x + cw - 10 - f:getWidth("Ativo") - 6, 270, f, U.c.bg)
      end
      lg.setFont(U.font("r", 12))
      U.set(U.c.muted)
      lg.printf(U.safe(info[k][2]), x + 10, 292, cw - 20)
    end
    U.rect(0, 428, 640, 1, 0, U.c.line)
    U.hints({ { "A", "Aplicar" }, { "B", "Voltar" } }, 616, 446)
  end
  return s
end

-- ================================================================ ajustes
local GOVS = { { nil, "Padrão do sistema" }, { "ondemand", "Equilibrado" }, { "performance", "Desempenho" }, { "powersave", "Economia" } }

local function settingsCategories()
  local cats = {}
  local layoutNames = { grade = "Grade", cruz = "Cruz", vitrine = "Vitrine", metro = "Metrô" }
  cats[#cats + 1] = { name = "Aparência", rows = function()
    return {
      { t = "Layout da Home", sub = "Grade, Cruz, Vitrine ou Metrô", val = layoutNames[data.config.layout], go = function() push("layout") end },
      { t = "Cor de destaque", sub = "Usada em toda a interface", val = U.accents[data.config.accent].name,
        cycle = function(d)
          local idx = 1
          for i, k in ipairs(U.accentOrder) do if k == data.config.accent then idx = i end end
          idx = (idx - 1 + d) % #U.accentOrder + 1
          data.config.accent = U.accentOrder[idx]
          U.applyAccent(data.config.accent)
          data.saveConfig()
        end },
      { t = "Relógio de 24 horas", sub = "Barra superior", toggle = data.config.clock24,
        flip = function() data.config.clock24 = not data.config.clock24; data.saveConfig() end },
      { t = "Mostrar sistemas vazios", sub = "Sistemas sem nenhum jogo", toggle = data.config.showEmpty,
        flip = function() data.config.showEmpty = not data.config.showEmpty; data.saveConfig() end },
      { t = "Inverter A e B", sub = "Para quem prefere confirmar no B", toggle = data.config.swapAB,
        flip = function() data.config.swapAB = not data.config.swapAB; data.saveConfig() end },
      { t = "Animação ao voltar do jogo", sub = "A mesma do boot · qualquer botão pula", toggle = data.config.returnAnim ~= false,
        flip = function() data.config.returnAnim = (data.config.returnAnim == false); data.saveConfig() end },
    }
  end }
  cats[#cats + 1] = { name = "Tela e som", rows = function()
    local br = data.brightnessPct()
    local vol = data.volPct or data.getVolume()
    return {
      { t = "Brilho", val = br and (br .. "%") or "—",
        cycle = function(d) changeBrightness(d * (app.holdT > 1.2 and 3 or 1)) end },
      { t = "Volume", val = vol and (vol .. "%") or "—",
        cycle = function(d) changeVolume(d * (app.holdT > 1.2 and 3 or 1)) end },
      { t = "Sons de navegação", sub = "Clique ao mover, confirmar e voltar", toggle = data.config.navSounds ~= false,
        flip = function() data.config.navSounds = (data.config.navSounds == false); data.saveConfig(); sfx("confirm") end },
    }
  end }
  cats[#cats + 1] = { name = "Rede", rows = function()
    local w = data.wifi()
    local rows = {
      { t = "Wi-Fi", sub = (w == nil and "Adaptador USB não conectado") or (w and "Conectado" or "Desconectado"),
        val = (w and data.wifiName()) or (w == nil and "sem adaptador" or "escolher rede"), go = function() push("wifi") end },
    }
    rows[#rows + 1] = { t = "Endereço IP", sub = "Para transferir arquivos pela rede", val = (data.popen_lines("hostname -I 2>/dev/null")[1] or ""):match("%S+") or "sem rede" }
    return rows
  end }
  cats[#cats + 1] = { name = "Emulação", rows = function()
    local gi = 1
    for i, g in ipairs(GOVS) do if g[1] == data.config.governor then gi = i end end
    return {
      { t = "Perfil de desempenho", sub = "Governador da CPU nos jogos", val = GOVS[gi][2],
        cycle = function(d) gi = (gi - 1 + d) % #GOVS + 1; data.config.governor = GOVS[gi][1]; data.saveConfig() end },
      { t = "Teste de controles", sub = "Botões e analógicos ao vivo", go = function() push("padtest") end },
      { t = "Emulador por sistema", sub = "Escolha o núcleo de cada console", go = function() push("cores") end },
      { t = "Mostrar jogos escondidos", sub = data.hiddenCount() .. " escondido(s) · Y no jogo esconde ou mostra", toggle = data.config.showHidden == true,
        flip = function()
          data.config.showHidden = not data.config.showHidden; data.saveConfig()
          data.rescanAll(); bgEnqueueAll()
        end },
    }
  end }
  cats[#cats + 1] = { name = "Ferramentas", rows = function()
    local rows = {}
    local pm = data.portMaster()
    if data.hasES() then
      rows[#rows + 1] = { t = "EmulationStation", sub = "Capas, coleções e edição · ao sair, volta para o lusmOS", go = runES }
    end
    rows[#rows + 1] = { t = "PortMaster", sub = pm and "Baixe e instale ports" or "Não encontrado no cartão",
      go = pm and function() runTool(pm) end or nil }
    local ui = data.updateInfo()
    rows[#rows + 1] = { t = "Atualizar o lusmOS", sub = (ui and ui.state == "nova") and "Atualização nova disponível" or "Procura a versão nova no GitHub pelo Wi-Fi",
      on = ui and ui.state == "nova", go = function() push("lusmupdate") end }
    rows[#rows + 1] = { t = "Atualizações do sistema base", sub = data.updatePackage() and "Pacote encontrado · pronto para instalar" or "Pacote no cartão, aplicado no boot", go = function() push("updates") end }
    local fm = data.fileManager()
    if fm then rows[#rows + 1] = { t = "Gerenciador de arquivos", sub = "Copiar, mover e apagar", go = function() runTool(fm) end } end
    rows[#rows + 1] = { t = "Fazer backup dos ajustes", sub = "Salva em EASYROMS/backup", go = function()
      local ok, name = data.makeBackup()
      toast(ok and "Backup salvo" or "Não foi possível salvar o backup")
    end }
    rows[#rows + 1] = { t = "Restaurar backup", sub = "Escolha um backup salvo", go = function() push("backups") end }
    rows[#rows + 1] = { t = "Informações do sistema", sub = "IP, armazenamento e bateria", go = function() push("info") end }
    return rows
  end }
  cats[#cats + 1] = { name = "Sistema", rows = function()
    return {
      { t = "Restaurar ajustes padrão", sub = "Mantém favoritos e recentes", go = function()
        push("menu", { title = "Voltar os ajustes ao padrão?", items = {
          { label = "Sim, restaurar", act = function() resetAndReboot() end },
          { label = "Cancelar", act = function() pop() end },
        } })
      end },
      { t = "Procurar atualizações ao ligar", sub = "Com Wi-Fi, avisa quando sair versão nova do lusmOS", toggle = data.config.autoUpdate ~= false,
        flip = function() data.config.autoUpdate = (data.config.autoUpdate == false); data.saveConfig() end },
      { t = "Reiniciar", sub = "", go = function() quitWith("reboot") end },
      { t = "Desligar", sub = "", go = function() quitWith("poweroff") end },
      { t = "Sobre", sub = "Segure A ao ligar: recuperação", val = "lusmOS " .. VERSION },
    }
  end }
  return cats
end

Screens.settings = function(arg)
  local s = { cats = settingsCategories(), cat = (arg and arg.cat) or 1, sel = 1, focus = (arg and arg.cat) and 2 or 1, scroll = 0 }
  function s:rows()
    if not self.cache or self.cacheCat ~= self.cat then
      self.cache = self.cats[self.cat].rows()
      self.cacheCat = self.cat
    end
    return self.cache
  end
  function s:refresh() self.cache = nil end
  function s:resume() self:refresh() end
  function s:press(b)
    local rows = self:rows()
    if self.focus == 1 then
      if b == "up" then self.cat = math.max(1, self.cat - 1); self.sel = 1
      elseif b == "down" then self.cat = math.min(#self.cats, self.cat + 1); self.sel = 1
      elseif b == "right" or b == "a" then self.focus = 2
      elseif b == "b" then pop()
      end
    else
      local r = rows[self.sel]
      if b == "up" then self.sel = math.max(1, self.sel - 1)
      elseif b == "down" then self.sel = math.min(#rows, self.sel + 1)
      elseif b == "b" then self.focus = 1
      elseif b == "left" then
        if r and r.cycle then r.cycle(-1); self:refresh() else self.focus = 1 end
      elseif b == "right" then
        if r and r.cycle then r.cycle(1); self:refresh() end
      elseif b == "a" and r then
        if r.flip then r.flip(); self:refresh()
        elseif r.cycle then r.cycle(1); self:refresh()
        elseif r.go then r.go() end
      end
    end
  end
  function s:update(dt)
    local target = math.max(0, self.sel - 6) * 52
    self.scroll = self.scroll + (target - self.scroll) * math.min(1, dt * 14)
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.logo(20, 14, 22)
    U.text("Ajustes", 52, 13, U.font("m", 19), U.c.text)
    U.drawStatus(620, 15, U.c.text2)
    for i, c in ipairs(self.cats) do
      local y = 54 + (i - 1) * 46
      local on = i == self.cat
      if on then U.rect(20, y, 160, 42, 10, U.c.line) end
      if on and self.focus == 1 then U.rectLine(20, y, 160, 42, 10, U.c.accent, 2) end
      U.circle(36, y + 21, 4, on and U.c.accent or U.hex("#3A4152"))
      U.text(c.name, 50, y + 10, U.font("m", 15), on and U.c.text or U.c.muted)
    end
    U.rect(192, 50, 428, 380, 14, U.c.panel)
    U.text(U.upper(self.cats[self.cat].name), 206, 60, U.font("r", 12), U.c.muted)
    lg.setScissor(192, 82, 428, 344)
    for i, r in ipairs(self:rows()) do
      local y = 84 + (i - 1) * 52 - self.scroll
      local on = self.focus == 2 and i == self.sel
      if on then U.rect(198, y, 416, 48, 10, U.c.line); U.rectLine(198, y, 416, 48, 10, U.c.accent, 2) end
      local tw = (r.val or r.toggle ~= nil) and 250 or 360
      U.text(r.t, 210, (r.sub and r.sub ~= "") and (y + 5) or (y + 14), U.font("m", 15), U.c.text, 1, tw)
      if r.sub and r.sub ~= "" then U.text(r.sub, 210, y + 26, U.font("r", 12), U.c.muted, 1, tw) end
      if r.toggle ~= nil then
        U.rect(556, y + 12, 44, 24, 12, r.toggle and U.c.accent or U.hex("#3A4152"))
        U.circle(r.toggle and 588 or 568, y + 24, 9, U.c.white)
      elseif r.val then
        local f = U.font("r", 14)
        local txt = r.cycle and ("‹ " .. r.val .. " ›") or r.val
        U.text(txt, 420, y + 14, f, r.go and U.c.accentLight or U.c.text, 1, r.go and 164 or 180, "right")
        if r.go then U.icon("chevron", 588, y + 16, 16, U.c.accentLight) end
      elseif r.go then
        U.icon("chevron", 588, y + 16, 16, U.c.text2)
      end
    end
    lg.setScissor()
    U.text("lusmOS " .. VERSION, 20, 448, U.font("r", 12), U.c.muted)
    U.hints({ { "A", "Selecionar" }, { "B", self.focus == 2 and "Categorias" or "Voltar" } }, 620, 446)
  end
  return s
end

-- ================================================================ teste de controles
Screens.padtest = function()
  local s = { pressed = {}, holdB = 0, noSound = true, ax = { leftx = 0, lefty = 0, rightx = 0, righty = 0, triggerleft = 0, triggerright = 0 } }
  function s:raw(b, down) self.pressed[b] = down or nil end
  function s:axis(a, v) self.ax[a] = v end
  function s:press(b) end
  function s:update(dt)
    if self.pressed.b then
      self.holdB = self.holdB + dt
      if self.holdB > 1.2 then pop() end
    else
      self.holdB = 0
    end
    local js = love.joystick.getJoysticks()[1]
    if js and js:isGamepad() then
      for _, a in ipairs({ "leftx", "lefty", "rightx", "righty" }) do self.ax[a] = js:getGamepadAxis(a) end
    end
  end
  local function stick(cx, cy, x, y, label)
    U.circle(cx, cy, 52, U.c.line)
    U.set(U.c.line2); lg.setLineWidth(1)
    lg.line(cx - 52, cy, cx + 52, cy); lg.line(cx, cy - 52, cx, cy + 52)
    U.circle(cx + x * 40, cy + y * 40, 14, U.c.accent)
    U.text(label, cx - 70, cy + 62, U.font("m", 13), U.c.text, 1, 140, "center")
    U.text(string.format("X %+.2f  Y %+.2f", x, y), cx - 70, cy + 80, U.font("r", 12), U.c.muted, 1, 140, "center")
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.text("Teste de controles", 24, 14, U.font("m", 20), U.c.text)
    U.text("Mexa os analógicos: a bolinha tem que ir para o mesmo lado do seu dedo.", 24, 44, U.font("r", 13), U.c.muted, 1, 592)
    stick(180, 180, self.ax.leftx, self.ax.lefty, "Analógico esquerdo")
    stick(460, 180, self.ax.rightx, self.ax.righty, "Analógico direito")
    local btns = { "up", "down", "left", "right", "a", "b", "x", "y", "l1", "r1", "l2", "r2", "select", "start" }
    local names = { up = "Cima", down = "Baixo", left = "Esq", right = "Dir", a = "A", b = "B", x = "X", y = "Y", l1 = "L1", r1 = "R1", l2 = "L2", r2 = "R2", select = "SEL", start = "STA" }
    for i, b in ipairs(btns) do
      local x = 24 + (i - 1) * 42
      local on = self.pressed[b] or (b == "l2" and self.ax.triggerleft > 0.5) or (b == "r2" and self.ax.triggerright > 0.5)
      U.rect(x, 340, 38, 38, 10, on and U.c.accent or U.c.line)
      U.text(names[b], x, 350, U.font("m", 12), on and U.c.bg or U.c.text2, 1, 38, "center")
    end
    U.text("Último sinal: " .. (app.lastRaw ~= "" and app.lastRaw or "aperte qualquer botão"), 24, 396, U.font("r", 13), U.c.muted, 1, 592)
    local hb = math.min(1, self.holdB / 1.2)
    U.text("Segure B para sair", 24, 446, U.font("r", 13), U.c.text2)
    U.rect(160, 453, 120, 5, 3, U.c.line)
    U.gradientBar(160, 453, 120 * hb, 5, U.c.accent, U.c.accent2)
  end
  return s
end

-- ================================================================ tela de erro (ultimo recurso)
Screens.crash = function(arg)
  local s = { sel = 1 }
  function s:press(b)
    if b == "up" then self.sel = math.max(1, self.sel - 1)
    elseif b == "down" then self.sel = math.min(3, self.sel + 1)
    elseif b == "a" then
      if self.sel == 1 then
        errs.n = 0
        app.stack = {}
        replace("home_" .. data.config.layout)
      elseif self.sel == 2 then
        quitWith("reboot")
      else
        quitWith("poweroff")
      end
    end
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.logo(24, 20, 26)
    U.text("Algo deu errado no lusmOS", 24, 70, U.font("m", 22), U.c.text)
    U.text("O erro foi salvo no arquivo lusmos-erros.txt da EASYROMS.", 24, 104, U.font("r", 13), U.c.muted, 1, 592)
    local items = { "Tentar de novo", "Reiniciar", "Desligar" }
    for i, t in ipairs(items) do
      local y = 150 + (i - 1) * 52
      local on = i == self.sel
      U.rect(24, y, 360, 44, 10, on and U.c.line or U.c.panel)
      if on then U.rectLine(24, y, 360, 44, 10, U.c.accent, 2) end
      U.text(t, 40, y + 11, U.font("m", 15), U.c.text)
    end
    U.text(U.fit(U.font("r", 11), tostring(arg.err or ""):gsub("\n.*", ""), 592), 24, 420, U.font("r", 11), U.c.dim)
    U.hints({ { "A", "Escolher" } }, 616, 448)
  end
  return s
end

-- ================================================================ lista simples (usada por varias telas)
-- arg = { title, sub, rows = { {t, sub, val, go} }, empty }
local function simpleList(title, rowsFn, opts)
  opts = opts or {}
  local s = { sel = 1, scroll = 0 }
  function s:rows()
    if not self.cache then self.cache = rowsFn() end
    return self.cache
  end
  function s:resume() self.cache = nil end
  function s:press(b)
    local rows = self:rows()
    if b == "up" then self.sel = math.max(1, self.sel - 1)
    elseif b == "down" then self.sel = math.min(math.max(1, #rows), self.sel + 1)
    elseif b == "b" then if not opts.noBack then pop() end
    elseif b == "a" and rows[self.sel] and rows[self.sel].go then rows[self.sel].go(self)
    end
  end
  function s:update(dt)
    local target = math.max(0, self.sel - 6) * 52
    self.scroll = self.scroll + (target - self.scroll) * math.min(1, dt * 14)
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.logo(20, 14, 22)
    U.text(title, 52, 13, U.font("m", 19), U.c.text)
    U.drawStatus(620, 15, U.c.text2)
    if opts.sub then U.text(opts.sub, 24, 48, U.font("r", 13), U.c.muted, 1, 592) end
    local top = opts.sub and 74 or 54
    local rows = self:rows()
    if #rows == 0 then
      U.text(opts.empty or "Nada por aqui", 24, top + 20, U.font("r", 15), U.c.muted, 1, 592, "center")
    end
    lg.setScissor(0, top, 640, 424 - top)
    for i, r in ipairs(rows) do
      local y = top + 4 + (i - 1) * 52 - self.scroll
      local on = i == self.sel
      U.rect(20, y, 600, 48, 10, on and U.c.line or U.c.panel)
      if on then U.rectLine(20, y, 600, 48, 10, U.c.accent, 2) end
      local tw = r.val and 330 or 520
      U.text(r.t, 36, (r.sub and r.sub ~= "") and (y + 5) or (y + 14), U.font("m", 15), U.c.text, 1, tw)
      if r.sub and r.sub ~= "" then U.text(r.sub, 36, y + 26, U.font("r", 12), U.c.muted, 1, tw) end
      if r.val then U.text(r.val, 380, y + 14, U.font("r", 14), r.on and U.c.accentLight or U.c.text2, 1, r.go and 196 or 224, "right") end
      if r.go then U.icon("chevron", 590, y + 16, 16, on and U.c.accentLight or U.c.text2) end
      if r.on and not r.val then U.circle(590 - (r.go and 18 or 0), y + 24, 4, U.c.accent) end
    end
    lg.setScissor()
    U.rect(0, 428, 640, 1, 0, U.c.line)
    local h = { { "A", opts.aLabel or "Selecionar" } }
    if not opts.noBack then h[#h + 1] = { "B", "Voltar" } end
    U.hints(h, 616, 446)
  end
  return s
end

-- ================================================================ emulador por sistema
Screens.cores = function()
  return simpleList("Emulador por sistema", function()
    local rows = {}
    for _, sys in ipairs(data.systems) do
      local ch = data.coreChoices(sys)
      if #ch > 1 then
        local cur = data.currentCore(sys)
        local label = cur
        for _, c in ipairs(ch) do if (c.emu .. "|" .. c.core) == cur then label = c.label end end
        rows[#rows + 1] = { t = sys.fullname or sys.name, sub = #ch .. " opções", val = label, go = function()
          push("coresys", { sys = sys })
        end }
      end
    end
    return rows
  end, { sub = "Só aparecem os consoles com mais de uma opção.", empty = "Nenhum console com opções" })
end

Screens.coresys = function(arg)
  local sys = arg.sys
  return simpleList(sys.fullname or sys.name, function()
    local cur = data.currentCore(sys)
    local rows = {}
    for _, c in ipairs(data.coreChoices(sys)) do
      local key = c.emu .. "|" .. c.core
      rows[#rows + 1] = { t = c.label, sub = c.emu, on = key == cur, val = key == cur and "em uso" or nil, go = function(scr)
        data.config["core." .. sys.name] = key
        data.saveConfig()
        toast("Núcleo salvo")
        pop()
      end }
    end
    return rows
  end, { sub = "Vale para todos os jogos deste console.", aLabel = "Usar" })
end

-- ================================================================ backups
Screens.backups = function()
  return simpleList("Restaurar backup", function()
    local rows = {}
    for _, b in ipairs(data.listBackups()) do
      local d = b.name:match("(%d%d%d%d%d%d%d%d%-%d%d%d%d)")
      local nice = d and (d:sub(7, 8) .. "/" .. d:sub(5, 6) .. "/" .. d:sub(1, 4) .. " " .. d:sub(10, 11) .. ":" .. d:sub(12, 13)) or b.name
      rows[#rows + 1] = { t = "Backup de " .. nice, sub = b.name, go = function()
        push("menu", { title = "Restaurar este backup?", items = {
          { label = "Sim, restaurar e reiniciar", act = function()
            local ok = data.restoreBackup(b.path)
            if ok then quitWith("reboot") else pop(); toast("Não foi possível restaurar") end
          end },
          { label = "Cancelar", act = function() pop() end },
        } })
      end }
    end
    return rows
  end, { sub = "Backups salvos na pasta backup da EASYROMS.", empty = "Nenhum backup salvo ainda" })
end

-- ================================================================ informacoes do sistema
Screens.info = function()
  local s = { info = data.systemInfo() }
  function s:press(b) if b == "b" or b == "a" then pop() end end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.logo(20, 14, 22)
    U.text("Informações do sistema", 52, 13, U.font("m", 19), U.c.text)
    U.drawStatus(620, 15, U.c.text2)
    local i = self.info
    U.rect(20, 52, 600, 92, 14, U.c.panel)
    U.logo(40, 70, 56)
    U.text("lusmOS " .. VERSION, 112, 70, U.font("m", 24), U.c.text)
    U.text("R36S · RK3326 · tela 640×480", 112, 104, U.font("r", 13), U.c.muted)
    local items = {
      { "Nome na rede", i.host },
      { "Endereço IP", i.ip },
      { "Jogos", i.games .. " em " .. i.systems .. " consoles" },
      { "EASYROMS", (i.romsFree or "—") .. " livres de " .. (i.romsSize or "—") },
      { "Sistema", (i.sysFree or "—") .. " livres de " .. (i.sysSize or "—") },
      { "Bateria", i.battery and (i.battery .. "%" .. (i.charging and " · carregando" or "")) or "—" },
      { "Ligado há", i.uptime },
      { "Kernel", i.kernel },
    }
    for k, it in ipairs(items) do
      local col = (k - 1) % 2
      local row = math.floor((k - 1) / 2)
      local x, y = 20 + col * 304, 156 + row * 64
      U.rect(x, y, 296, 56, 12, U.c.panel)
      U.text(it[1], x + 14, y + 8, U.font("r", 12), U.c.muted)
      U.text(U.safe(tostring(it[2])), x + 14, y + 26, U.font("m", 15), U.c.text, 1, 270)
    end
    U.rect(0, 428, 640, 1, 0, U.c.line)
    U.hints({ { "B", "Voltar" } }, 616, 446)
  end
  return s
end

-- ================================================================ recuperacao (segure A ao ligar)
Screens.recovery = function()
  return simpleList("Recuperação", function()
    return {
      { t = "Iniciar o lusmOS", sub = "Abre a interface normal", go = function() app.stack = {}; goHome(); bgEnqueueAll() end },
      { t = "Wi-Fi", sub = "Conectar a uma rede", go = function() push("wifi") end },
      { t = "Restaurar ajustes padrão", sub = "Layout, cores e opções voltam ao padrão", go = function() resetAndReboot() end },
      { t = "Restaurar backup", sub = "Usa um backup da pasta EASYROMS/backup", go = function() push("backups") end },
      { t = "Teste de controles", sub = "Botões e analógicos ao vivo", go = function() push("padtest") end },
      { t = "Informações do sistema", sub = "IP, armazenamento e bateria", go = function() push("info") end },
      { t = "Reiniciar", sub = "", go = function() quitWith("reboot") end },
      { t = "Desligar", sub = "", go = function() quitWith("poweroff") end },
    }
  end, { sub = "lusmOS " .. VERSION .. " · modo de recuperação", noBack = true })
end

-- ================================================================ atualizar o lusmOS (GitHub)
-- "4-2026.11.23a" -> "de 23/11/2026"
local function fmtVer(v)
  local y, m, d, x = (v or ""):match("(%d%d%d%d)%.(%d%d)%.(%d%d)(%a*)")
  if not y then return v or "?" end
  return "de " .. d .. "/" .. m .. "/" .. y .. ((x ~= "" and x ~= "a") and (" (" .. x .. ")") or "")
end

Screens.lusmupdate = function()
  local s = { t = 0, phase = "check" }
  if not data.wifi() then s.phase = "offline" else data.startUpdateCheck() end
  function s:update(dt)
    self.t = self.t + dt
    if self.phase == "check" then
      local info = data.updateInfo()
      if info then self.info = info; self.phase = info.state end
      if self.t > 25 and not info then self.phase = "erro" end
    elseif self.phase == "installing" then
      self.prog = data.updateProgress() or self.prog
      if self.prog and self.prog:match("^ERRO") then self.phase = "falhou" end
    end
  end
  function s:press(b)
    if self.phase == "installing" then return end
    if b == "b" then pop()
    elseif b == "a" then
      if self.phase == "nova" then
        self.phase = "installing"; self.prog = "Começando…"
        data.startUpdateInstall()
      elseif self.phase == "erro" or self.phase == "falhou" then
        self.phase = "check"; self.t = 0; data.startUpdateCheck()
      elseif self.phase == "offline" then push("wifi")
      end
    end
  end
  function s:resume()
    if self.phase == "offline" and data.wifi() then self.phase = "check"; self.t = 0; data.startUpdateCheck() end
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.logo(20, 14, 22)
    U.text("Atualizar o lusmOS", 52, 13, U.font("m", 19), U.c.text)
    U.drawStatus(620, 15, U.c.text2)
    U.rect(20, 56, 600, 150, 14, U.c.panel)
    U.text("Versão instalada", 40, 72, U.font("r", 13), U.c.muted)
    U.text("lusmOS " .. VERSION, 40, 92, U.font("m", 18), U.c.text)
    U.text("atualização " .. fmtVer(BUILD), 40 + U.font("m", 18):getWidth("lusmOS " .. VERSION) + 10, 97, U.font("r", 13), U.c.muted)
    local ph = self.phase
    local title, sub, icon, col = "", "", "download", U.c.accent
    if ph == "check" then
      spinner(44, 148, 12, "Procurando no GitHub…")
    elseif ph == "offline" then
      title, sub, icon, col = "Sem Wi-Fi", "Conecte numa rede para procurar a versão nova.", "wifi", U.c.muted
    elseif ph == "atual" then
      title, sub, icon, col = "Você já está na versão mais nova", "Nenhuma atualização disponível.", "check", U.c.accent2
    elseif ph == "nova" then
      title, sub = "Atualização nova " .. fmtVer(self.info.version), self.info.notes or ""
    elseif ph == "erro" then
      title, sub, icon, col = "Não deu para falar com o GitHub", "Confira o Wi-Fi e tente de novo.", "wifi", U.hex("#E06C75")
    elseif ph == "installing" then
      local p = self.prog or ""
      if p:match("^PRONTO") then
        title, sub, icon, col = "Atualizado!", "O lusmOS vai reabrir na versão nova.", "check", U.c.accent2
      else
        spinner(44, 148, 12, p)
        U.text("Não desligue o console.", 40, 176, U.font("r", 13), U.c.muted)
      end
    elseif ph == "falhou" then
      title, sub, icon, col = "A atualização não foi instalada", (self.prog or ""):gsub("^ERRO: ", ""), "wifi", U.hex("#E06C75")
    end
    if title ~= "" then
      U.icon(icon, 40, 136, 26, col)
      U.text(title, 78, 132, U.font("m", 16), U.c.text, 1, 520)
      U.text(sub, 78, 156, U.font("r", 13), U.c.muted, 1, 520)
    end
    U.text("As atualizações vêm de " .. data.REPO_URL, 24, 222, U.font("r", 12), U.c.muted)
    U.text("Seus jogos, saves, favoritos e ajustes continuam como estão.", 24, 242, U.font("r", 12), U.c.muted)
    U.rect(0, 428, 640, 1, 0, U.c.line)
    local h = {}
    if ph == "nova" then h[#h + 1] = { "A", "Atualizar agora" }
    elseif ph == "erro" or ph == "falhou" then h[#h + 1] = { "A", "Tentar de novo" }
    elseif ph == "offline" then h[#h + 1] = { "A", "Abrir Wi-Fi" } end
    if ph ~= "installing" then h[#h + 1] = { "B", "Voltar" } end
    U.hints(h, 616, 446)
  end
  return s
end

-- ================================================================ atualizacoes do sistema
Screens.updates = function()
  local s = { pkg = data.updatePackage() }
  function s:press(b)
    if b == "b" then pop()
    elseif b == "a" and self.pkg then
      push("menu", { title = "Instalar a atualização agora?", items = {
        { label = "Sim, reiniciar e instalar", act = function() quitWith("reboot") end },
        { label = "Cancelar", act = function() pop() end },
      } })
    end
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.logo(20, 14, 22)
    U.text("Atualizações do sistema base", 52, 13, U.font("m", 19), U.c.text)
    U.drawStatus(620, 15, U.c.text2)
    U.rect(20, 56, 600, 112, 14, U.c.panel)
    if self.pkg then
      U.icon("check", 40, 76, 28, U.c.accent2)
      U.text("Pacote de atualização encontrado", 82, 72, U.font("m", 17), U.c.text)
      U.text(self.pkg:match("([^/]+)$"), 82, 98, U.font("r", 13), U.c.muted, 1, 520)
      U.text("Ao reiniciar, a atualização é instalada e o console desliga sozinho.", 40, 128, U.font("r", 13), U.c.text2, 1, 560)
    else
      U.icon("download", 40, 76, 28, U.c.accent)
      U.text("Nenhum pacote no cartão", 82, 72, U.font("m", 17), U.c.text)
      U.text("Veja abaixo como atualizar.", 82, 98, U.font("r", 13), U.c.muted)
    end
    local steps = {
      "Baixe o pacote de atualização (update-arkos.tar) no PC.",
      "Copie o arquivo para a raiz da EASYROMS.",
      "Reinicie o console: a atualização é instalada e ele desliga.",
      "Ligue de novo: o lusmOS confere e coloca de volta tudo o que for dele.",
    }
    for i, t in ipairs(steps) do
      local y = 186 + (i - 1) * 52
      U.circle(40, y + 14, 13, U.c.line)
      U.text(tostring(i), 27, y + 4, U.font("m", 14), U.c.text, 1, 26, "center")
      lg.setFont(U.font("r", 14)); U.set(U.c.text2)
      lg.printf(U.safe(t), 64, y, 540)
    end
    U.rect(0, 428, 640, 1, 0, U.c.line)
    local h = {}
    if self.pkg then h[#h + 1] = { "A", "Instalar agora" } end
    h[#h + 1] = { "B", "Voltar" }
    U.hints(h, 616, 446)
  end
  return s
end

-- ================================================================ colecoes
Screens.collections = function()
  local scr
  scr = simpleList("Coleções", function()
    local rows = {}
    rows[#rows + 1] = { t = "Favoritos", sub = "Jogos marcados com Y", go = function() push("games", { title = "Favoritos", favorites = true }) end }
    for _, c in ipairs(data.collections()) do
      rows[#rows + 1] = { t = c.name, sub = #c.paths == 1 and "1 jogo" or (#c.paths .. " jogos"), go = function()
        push("games", { title = c.name, collection = c })
      end, coll = c }
    end
    rows[#rows + 1] = { t = "Nova coleção…", sub = "Crie e depois adicione jogos pelo Y", go = function()
      push("keyboard", { title = "Nome da coleção", onDone = function(txt)
        if data.newCollection(txt) then toast("Coleção criada"); scr.cache = nil end
      end })
    end }
    return rows
  end, { sub = "As mesmas coleções do EmulationStation. Y numa coleção para apagar." })
  local basePress = scr.press
  function scr:press(b)
    local r = self:rows()[self.sel]
    if b == "y" and r and r.coll then
      push("menu", { title = "Apagar a coleção " .. r.coll.name .. "?", items = {
        { label = "Sim, apagar (os jogos continuam no cartão)", act = function() data.deleteCollection(r.coll); pop(); scr.cache = nil end },
        { label = "Cancelar", act = function() pop() end },
      } })
      return
    end
    basePress(self, b)
  end
  return scr
end

Screens.collpick = function(arg)
  local g = arg.game
  local scr
  scr = simpleList("Coleções", function()
    local rows = {}
    for _, c in ipairs(data.collections()) do
      local inside = data.inCollection(c, g)
      rows[#rows + 1] = { t = c.name, sub = #c.paths == 1 and "1 jogo" or (#c.paths .. " jogos"), on = inside, val = inside and "está aqui" or nil, go = function()
        local added = data.toggleCollection(c, g)
        toast(added and ("Adicionado a " .. c.name) or ("Removido de " .. c.name))
        scr.cache = nil
      end }
    end
    rows[#rows + 1] = { t = "Nova coleção…", sub = "Cria e já coloca este jogo", go = function()
      push("keyboard", { title = "Nome da coleção", onDone = function(txt)
        local c = data.newCollection(txt)
        if c then data.toggleCollection(c, g); toast("Adicionado a " .. c.name); scr.cache = nil end
      end })
    end }
    return rows
  end, { sub = U.safe(g.name) .. " · A coloca ou tira da coleção", aLabel = "Colocar/tirar" })
  return scr
end

Screens.coregame = function(arg)
  local g = arg.game
  return simpleList("Emulador deste jogo", function()
    local cur = data.gameCore(g)
    local rows = {
      { t = "Igual ao do console", sub = "Usa a escolha de Emulador por sistema", on = cur == nil, val = cur == nil and "em uso" or nil,
        go = function() data.setGameCore(g, nil); toast("Usando o emulador do console"); pop() end },
    }
    for _, c in ipairs(data.coreChoices(g.system)) do
      local key = c.emu .. "|" .. c.core
      rows[#rows + 1] = { t = c.label, sub = c.emu, on = key == cur, val = key == cur and "em uso" or nil, go = function()
        data.setGameCore(g, key); toast("Emulador salvo para este jogo"); pop()
      end }
    end
    return rows
  end, { sub = U.safe(g.name), aLabel = "Usar" })
end

-- ================================================================ preparar jogo compactado (.zip)
Screens.prepare = function(arg)
  local g = arg.game
  local s = { t = 0, phase = "start" }
  local PRIO = { ".m3u", ".cue", ".chd", ".pbp", ".cso", ".iso", ".gdi", ".ccd" }
  function s:begin()
    self.files, self.total = data.zipInfo(g)
    if #self.files == 0 then self.phase = "vazio"; return end
    if data.freeBytes(g.path:match("^(.*)/")) < self.total + 50 * 1024 * 1024 then
      self.phase = "espaco"; return
    end
    self.dir = data.startUnzip(g)
    self.phase = "unzip"
  end
  function s:update(dt)
    self.t = self.t + dt
    if self.phase == "start" then
      if self.t > 0.15 then self:begin() end
    elseif self.phase == "unzip" then
      self.pollT = (self.pollT or 0) - dt
      if self.pollT <= 0 then
        self.pollT = 0.4
        local got = 0
        for _, f in ipairs(self.files) do got = got + data.fileSize(self.dir .. "/" .. f.name:match("([^/]+)$")) end
        self.got = got
        local rc = data.unzipDone()
        if rc then
          if rc ~= 0 then self.phase = "erro"; return end
          local best = nil
          for _, ext in ipairs(PRIO) do
            for _, f in ipairs(self.files) do
              if not best and f.name:lower():sub(-#ext) == ext then best = f end
            end
          end
          best = best or self.files[1]
          data.finishUnzip(g, self.dir .. "/" .. best.name:match("([^/]+)$"))
          self.phase = "ok"
          self.okT = self.t
        end
      end
    elseif self.phase == "ok" and self.t - self.okT > 0.8 then
      replace("launch", g)
    end
  end
  function s:press(b)
    if (self.phase == "vazio" or self.phase == "espaco" or self.phase == "erro") and (b == "a" or b == "b") then pop() end
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.logo(20, 14, 22)
    U.text("Preparando o jogo", 52, 13, U.font("m", 19), U.c.text)
    U.drawStatus(620, 15, U.c.text2)
    local item = gameItem(g)
    U.tile(40, 90, 150, item, 1, 14)
    U.text(g.name, 214, 96, U.font("m", 18), U.c.text, 1, 390)
    U.text(g.system.fullname or g.system.name, 214, 124, U.font("r", 13), U.c.muted, 1, 390)
    local msg, sub = "", ""
    local ph = self.phase
    if ph == "start" or ph == "unzip" then
      msg = "Descompactando…"
      sub = "Só na primeira vez. Depois o jogo abre direto."
      local p = (self.total and self.total > 0) and math.min(1, (self.got or 0) / self.total) or 0
      U.rect(214, 200, 380, 8, 4, U.c.line)
      U.gradientBar(214, 200, 380 * p, 8, U.c.accent, U.c.accent2, 1)
      local mb = function(n) return string.format("%.0f MB", (n or 0) / 1048576) end
      U.text(mb(self.got) .. " de " .. mb(self.total), 214, 216, U.font("r", 13), U.c.text2)
      U.text(math.floor(p * 100) .. "%", 214, 216, U.font("m", 13), U.c.text, 1, 380, "right")
    elseif ph == "ok" then
      msg, sub = "Pronto!", "Abrindo o jogo…"
    elseif ph == "vazio" then
      msg, sub = "Esse .zip não tem um jogo deste console", "Confira se o arquivo é mesmo de " .. (g.system.fullname or g.system.name) .. "."
    elseif ph == "espaco" then
      msg, sub = "Falta espaço no cartão", string.format("O jogo precisa de %.1f GB livres na EASYROMS.", (self.total or 0) / 1073741824)
    elseif ph == "erro" then
      msg, sub = "Não deu para descompactar", "O arquivo pode estar corrompido. O .zip continua no cartão."
    end
    U.text(msg, 214, 158, U.font("m", 16), U.c.text, 1, 390)
    U.text(sub, 214, 248, U.font("r", 13), U.c.muted, 1, 390)
    U.rect(0, 428, 640, 1, 0, U.c.line)
    if ph == "vazio" or ph == "espaco" or ph == "erro" then U.hints({ { "B", "Voltar" } }, 616, 446)
    else U.text("Não desligue o console.", 24, 446, U.font("r", 13), U.c.text2) end
  end
  return s
end

-- ================================================================ teclado virtual
-- arg = { title, sub, value, secret, onDone(text), onCancel() }
local KB_LAYERS = {
  { "1234567890", "qwertyuiop", "asdfghjkl@", "zxcvbnm-_." },
  { "1234567890", "QWERTYUIOP", "ASDFGHJKL@", "ZXCVBNM-_." },
  { "1234567890", "!@#$%&*()?", "/\\:;'\"<>[]", "{}+=~^`|,." },
}
local KB_SPECIAL = {
  { id = "shift", label = "Aa", w = 2 },
  { id = "sym", label = "#+=", w = 2 },
  { id = "space", label = "espaço", w = 2 },
  { id = "back", label = "Apagar", w = 2 },
  { id = "ok", label = "OK", w = 2 },
}

Screens.keyboard = function(arg)
  local s = { text = arg.value or "", layer = 1, row = 1, col = 1, show = not arg.secret, t = 0 }
  local function chars(row) return KB_LAYERS[s.layer][row] end
  -- coluna da linha especial correspondente a coluna de letras
  local function specialAt(col)
    local acc = 0
    for i, k in ipairs(KB_SPECIAL) do
      acc = acc + k.w
      if col <= acc then return i end
    end
    return #KB_SPECIAL
  end
  local function specialStart(idx)
    local acc = 1
    for i = 1, idx - 1 do acc = acc + KB_SPECIAL[i].w end
    return acc
  end
  function s:finish()
    pop()
    if arg.onDone then arg.onDone(self.text) end
  end
  function s:cancel()
    pop()
    if arg.onCancel then arg.onCancel() end
  end
  function s:typeChar(c)
    if #self.text < 63 then self.text = self.text .. c end
    if self.layer == 2 then self.layer = 1 end -- maiuscula vale para uma letra
  end
  function s:backspace()
    if #self.text == 0 then return end
    -- apaga um caractere UTF-8 inteiro
    local i = #self.text
    while i > 1 and self.text:byte(i) >= 128 and self.text:byte(i) < 192 do i = i - 1 end
    self.text = self.text:sub(1, i - 1)
  end
  function s:activate()
    if self.row <= 4 then
      local c = chars(self.row):sub(self.col, self.col)
      self:typeChar(c)
    else
      local k = KB_SPECIAL[specialAt(self.col)].id
      if k == "shift" then self.layer = (self.layer == 2) and 1 or 2
      elseif k == "sym" then self.layer = (self.layer == 3) and 1 or 3
      elseif k == "space" then self:typeChar(" ")
      elseif k == "back" then self:backspace()
      elseif k == "ok" then self:finish()
      end
    end
  end
  function s:press(b)
    if b == "up" then
      if self.row == 5 then self.col = specialStart(specialAt(self.col)) end
      self.row = self.row > 1 and self.row - 1 or 5
    elseif b == "down" then
      self.row = self.row < 5 and self.row + 1 or 1
    elseif b == "left" then
      if self.row == 5 then
        local idx = specialAt(self.col)
        idx = idx > 1 and idx - 1 or #KB_SPECIAL
        self.col = specialStart(idx)
      else
        self.col = self.col > 1 and self.col - 1 or 10
      end
    elseif b == "right" then
      if self.row == 5 then
        local idx = specialAt(self.col)
        idx = idx < #KB_SPECIAL and idx + 1 or 1
        self.col = specialStart(idx)
      else
        self.col = self.col < 10 and self.col + 1 or 1
      end
    elseif b == "a" then self:activate()
    elseif b == "b" then
      if #self.text > 0 then self:backspace() else self:cancel() end
    elseif b == "x" then self:typeChar(" ")
    elseif b == "y" then self.layer = (self.layer == 2) and 1 or 2
    elseif b == "l1" or b == "r1" then self.layer = (self.layer == 3) and 1 or 3
    elseif b == "select" then self.show = not self.show
    elseif b == "start" then self:finish()
    end
  end
  function s:update(dt) self.t = self.t + dt end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.text(arg.title or "Digite", 24, 14, U.font("m", 20), U.c.text, 1, 592)
    if arg.sub then U.text(arg.sub, 24, 44, U.font("r", 13), U.c.muted, 1, 592) end
    -- campo
    U.rect(24, 72, 592, 52, 12, U.c.panel)
    U.rectLine(24, 72, 592, 52, 12, U.c.accent, 2)
    local shown = self.show and self.text or string.rep("•", #self.text)
    local f = U.font("m", 20)
    local maxw = 540
    shown = U.fitLeft(f, shown, maxw)
    U.text(shown, 40, 84, f, U.c.text)
    if math.floor(self.t * 2) % 2 == 0 then
      U.rect(40 + f:getWidth(shown) + 2, 84, 2, 26, 1, U.c.accent)
    end
    if arg.secret then
      U.text(self.show and "visível" or "oculta", 520, 90, U.font("r", 12), U.c.muted, 1, 84, "right")
    end
    -- teclas
    local KW, KH, GAP = 54, 46, 4
    local x0, y0 = 320 - (10 * (KW + GAP) - GAP) / 2, 144
    for r = 1, 4 do
      local row = chars(r)
      for c = 1, 10 do
        local x = x0 + (c - 1) * (KW + GAP)
        local y = y0 + (r - 1) * (KH + GAP)
        local on = self.row == r and self.col == c
        U.rect(x, y, KW, KH, 9, on and U.c.accent or U.c.line)
        U.text(row:sub(c, c), x, y + 11, U.font("m", 18), on and U.c.bg or U.c.text, 1, KW, "center")
      end
    end
    local y = y0 + 4 * (KH + GAP)
    local sel = self.row == 5 and specialAt(self.col) or 0
    local x = x0
    for i, k in ipairs(KB_SPECIAL) do
      local w = k.w * (KW + GAP) - GAP
      local on = sel == i
      local active = (k.id == "shift" and self.layer == 2) or (k.id == "sym" and self.layer == 3)
      local bg = on and U.c.accent or (k.id == "ok" and U.c.accent2 or (active and U.c.line2 or U.c.card))
      U.rect(x, y, w, KH, 9, bg)
      U.text(k.label, x, y + 12, U.font("m", 15), (on or k.id == "ok") and U.c.bg or U.c.text, 1, w, "center")
      x = x + w + GAP
    end
    U.hints({ { "A", "Tecla" }, { "B", "Apagar" }, { "Y", "Maiúsc." }, { "SELECT", "Ver" }, { "START", "OK" } }, 616, 448)
  end
  return s
end

-- ================================================================ Wi-Fi
Screens.wifi = function()
  local s = { sel = 1, list = {}, status = {}, busy = "Procurando redes…", job = "scan", msg = nil, scroll = 0 }
  function s:refresh()
    self.status = data.wifiStatus()
  end
  function s:startScan()
    self.busy = "Procurando redes…"
    self.job = "scan"
  end
  function s:connect(net, pass)
    self.busy = "Conectando em " .. net.ssid .. "…"
    self.job = { kind = "connect", net = net, pass = pass }
  end
  function s:askPassword(net)
    push("keyboard", {
      title = "Senha de " .. net.ssid,
      sub = "Digite a senha do Wi-Fi",
      secret = true,
      onDone = function(text)
        if #text < 8 then toast("A senha precisa ter pelo menos 8 caracteres") return end
        s:connect(net, text)
      end,
    })
  end
  function s:press(b)
    if self.busy then return end
    local n = #self.list
    if b == "up" then self.sel = math.max(1, self.sel - 1)
    elseif b == "down" then self.sel = math.min(math.max(1, n), self.sel + 1)
    elseif b == "x" then self:startScan()
    elseif b == "b" then pop()
    elseif b == "a" then
      local net = self.list[self.sel]
      if not net then return end
      if net.inuse then
        toast("Você já está conectado nessa rede")
      elseif net.saved or not net.security then
        self:connect(net)
      else
        self:askPassword(net)
      end
    elseif b == "y" then
      local net = self.list[self.sel]
      if not net then return end
      local items = {}
      if net.inuse then
        items[#items + 1] = { label = "Desconectar", act = function()
          pop(); data.wifiDisconnect(self.status.iface); toast("Desconectado"); self:startScan()
        end }
      end
      if net.saved then
        items[#items + 1] = { label = "Esquecer esta rede", act = function()
          pop(); data.wifiForget(net.ssid); toast("Rede esquecida"); self:startScan()
        end }
      end
      if net.security then
        items[#items + 1] = { label = "Digitar outra senha", act = function() pop(); self:askPassword(net) end }
      end
      items[#items + 1] = { label = "Cancelar", act = function() pop() end }
      push("menu", { title = net.ssid, items = items })
    end
  end
  function s:update(dt)
    if self.busy then
      -- deixa um quadro com a mensagem aparecer antes de travar no comando
      self.waitFrame = (self.waitFrame or 0) + 1
      if self.waitFrame < 3 then return end
      self.waitFrame = 0
      local job = self.job
      self.job = nil
      if job == "scan" then
        self:refresh()
        if self.status.iface then self.list = data.wifiScan() else self.list = {} end
        self.sel = math.max(1, math.min(self.sel, #self.list))
      elseif type(job) == "table" and job.kind == "connect" then
        local ok, err = data.wifiConnect(job.net, job.pass)
        if ok then toast("Conectado em " .. job.net.ssid) else toast(err or "Não foi possível conectar") end
        self:refresh()
        if self.status.iface then self.list = data.wifiScan() end
        U.status.t = 99
      end
      self.busy = nil
    end
    local target = math.max(0, self.sel - 5) * 50
    self.scroll = self.scroll + (target - self.scroll) * math.min(1, dt * 14)
  end
  local function bars(x, y, signal, c)
    for i = 1, 4 do
      local h = 4 + i * 4
      local on = signal >= (i - 1) * 25 + 5
      U.rect(x + (i - 1) * 6, y + 18 - h, 4, h, 1, c, on and 1 or 0.25)
    end
  end
  function s:draw()
    U.rect(0, 0, 640, 480, 0, U.c.bg)
    U.icon("wifi", 24, 16, 22, U.c.accent)
    U.text("Wi-Fi", 56, 13, U.font("m", 20), U.c.text)
    U.drawStatus(616, 17, U.c.text2)
    -- cartao de status
    local st = self.status
    U.rect(24, 56, 592, 60, 14, U.c.panel)
    if not st.iface and not self.busy then
      U.text("Adaptador Wi-Fi não encontrado", 40, 64, U.font("m", 16), U.c.text)
      U.text("Conecte o adaptador USB no console e aperte X para procurar de novo.", 40, 88, U.font("r", 12), U.c.muted, 1, 560)
    elseif st.connected then
      U.circle(46, 86, 6, U.hex("#6FD6A3"))
      U.text("Conectado em " .. (st.ssid or "?"), 62, 64, U.font("m", 16), U.c.text, 1, 520)
      U.text("IP " .. (st.ip or "—") .. " · adaptador " .. st.iface, 62, 88, U.font("r", 12), U.c.muted, 1, 520)
    elseif st.iface then
      U.circle(46, 86, 6, U.hex("#3A4152"))
      U.text("Desconectado", 62, 64, U.font("m", 16), U.c.text)
      U.text("Escolha uma rede abaixo · adaptador " .. st.iface, 62, 88, U.font("r", 12), U.c.muted, 1, 520)
    end
    -- lista
    lg.setScissor(0, 126, 640, 306)
    for i, net in ipairs(self.list) do
      local y = 130 + (i - 1) * 50 - self.scroll
      local on = i == self.sel
      if on then U.rect(24, y, 592, 46, 10, U.c.line); U.rectLine(24, y, 592, 46, 10, U.c.accent, 2) end
      bars(40, y + 13, net.signal, on and U.c.accent or U.c.text2)
      U.text(net.ssid, 80, y + 5, U.font("m", 15), U.c.text, 1, 380)
      local sub = net.inuse and "Conectado" or (net.saved and "Salva" or (net.security and "Protegida" or "Aberta"))
      U.text(sub, 80, y + 25, U.font("r", 12), net.inuse and U.hex("#6FD6A3") or U.c.muted)
      if net.security then
        U.set(U.c.text2)
        lg.setLineWidth(1.5)
        lg.rectangle("line", 578, y + 21, 14, 11, 2, 2)
        lg.arc("line", "open", 585, y + 21, 5, math.pi, math.pi * 2, 10)
      end
    end
    if #self.list == 0 and not self.busy and st.iface then
      U.text("Nenhuma rede encontrada. Aperte X para procurar de novo.", 24, 150, U.font("r", 14), U.c.muted)
    end
    lg.setScissor()
    if self.busy then
      U.rect(170, 210, 300, 64, 16, U.c.card)
      U.rectLine(170, 210, 300, 64, 16, U.c.accent, 1.5)
      local a = app.t * 5
      for i = 0, 7 do
        U.circle(202 + math.cos(a + i * 0.785) * 12, 242 + math.sin(a + i * 0.785) * 12, 2.5, U.c.accent, (i + 1) / 8)
      end
      U.text(self.busy, 228, 232, U.font("m", 14), U.c.text, 1, 230)
    end
    U.hints({ { "A", "Conectar" }, { "Y", "Opções" }, { "X", "Procurar" }, { "B", "Voltar" } }, 616, 448)
  end
  return s
end

-- ================================================================ ciclo do LOVE
function love.load()
  math.randomseed(os.time())
  lg.setDefaultFilter("linear", "linear")
  love.keyboard.setKeyRepeat(false)
  -- mapeamento do controle do R36S (GO-Super Gamepad)
  local db = data.readfile(os.getenv("SDL_GAMECONTROLLERCONFIG_FILE") or "/opt/love2d/gamecontrollerdb.txt")
  if db and love.joystick and love.joystick.loadGamepadMappings then
    pcall(love.joystick.loadGamepadMappings, db)
  end
  data.loadConfig()
  restoreHW()
  loadSounds()
  data.loadRecents()
  data.loadFavs()
  data.loadGameSettings()
  U.applyAccent(data.config.accent)
  os.remove(NEXT_FILE)
  loadIntroImages()
  local st = readState()
  local mode = "boot"
  if st then mode = (data.config.returnAnim == false) and "plain" or "anim" end
  replace("loading", { mode = mode, state = st })
end

function love.update(dt)
  dt = math.min(dt, 0.1)
  app.t = app.t + dt
  U.updateStatus(dt)
  updateRepeat(dt)
  U.beginFrame()
  U.coverBudget = 2
  app.waiting = false
  if errs.t > 0 then errs.t = errs.t - dt; if errs.t <= 0 then errs.n = 0 end end
  if app.screen and app.screen.update then safeCall("update " .. tostring(app.screen.name), app.screen.update, app.screen, dt) end
  safeCall("leitura", bgUpdate, app.waiting and 0.035 or 0.006)
  watchHardware(dt)
  if app.updWatch then
    app.updT = (app.updT or 0) - dt
    if app.updT <= 0 then
      app.updT = 5
      local marker = "/tmp/lusmos_update_checked"
      local mf = io.open(marker, "r")
      if not mf and data.wifi() then
        local w = io.open(marker, "w"); if w then w:close() end
        data.startUpdateCheck()
      elseif mf then
        mf:close()
        local info = data.updateInfo()
        if info then
          app.updWatch = false
          local nf = io.open("/tmp/lusmos_update_notified", "r")
          if info.state == "nova" and not nf then
            toast("Atualização nova do lusmOS · Ajustes > Ferramentas")
            local w = io.open("/tmp/lusmos_update_notified", "w"); if w then w:close() end
          end
          if nf then nf:close() end
        end
      end
    end
  end
  if hwSave > 0 then
    hwSave = hwSave - dt
    if hwSave <= 0 then data.saveConfig() end
  end
  if osd.t > 0 then osd.t = osd.t - dt end
  if app.toastT > 0 then app.toastT = app.toastT - dt end
end

function love.draw()
  lg.setColor(1, 1, 1, 1)
  if app.screen and app.screen.draw then
    local ok = safeCall("draw " .. tostring(app.screen.name), app.screen.draw, app.screen)
    if not ok then
      lg.setScissor()
      lg.setColor(1, 1, 1, 1)
    end
  end
  drawOSD()
  if app.toastT > 0 and app.toast then
    local a = math.min(1, app.toastT * 3)
    local f = U.font("m", 14)
    local w = f:getWidth(app.toast) + 36
    U.rect(320 - w / 2, 400, w, 38, 19, U.c.card, a)
    U.rectLine(320 - w / 2, 400, w, 38, 19, U.c.accent, 1.5, a)
    U.text(app.toast, 320 - w / 2 + 18, 409, f, U.c.text, a)
  end
end

-- erro: registra e deixa o lusmos.sh reabrir (ou entrar na recuperacao)
function love.errorhandler(msg)
  local txt = tostring(msg) .. "\n" .. debug.traceback()
  local f = io.open("/tmp/lusmos_error.log", "w")
  if f then f:write(txt); f:close() end
  f = io.open(data.ROOT_ROMS .. "/lusmos-erros.txt", "a")
  if f then f:write(os.date("%d/%m %H:%M:%S"), " lusmOS ", BUILD, " [fatal] ", txt, "\n\n"); f:close() end
  writeNext("error", "")
  return nil
end
