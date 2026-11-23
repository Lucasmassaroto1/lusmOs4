-- lusmOS 4 :: dados (sistemas, jogos, favoritos, recentes, configuracao)
local M = {}

M.ROOT_ROMS = os.getenv("LUSMOS_ROMS") or "/roms"
M.ES_SYSTEMS = os.getenv("LUSMOS_ES_SYSTEMS") or "/etc/emulationstation/es_systems.cfg"
M.ES_SETTINGS = os.getenv("LUSMOS_ES_SETTINGS") or "/home/ark/.emulationstation/es_settings.cfg"
M.CONF_DIR = os.getenv("LUSMOS_CONF") or "/home/ark/.config/lusmos"

-- ---------------------------------------------------------------- util
local function readfile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end
M.readfile = readfile

local function writefile(path, s)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(s)
  f:close()
  return true
end

function M.shquote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function unxml(s)
  if not s then return s end
  s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
  s = s:gsub("&#(%d+);", function(n)
    n = tonumber(n)
    if n and n < 128 then return string.char(n) end
    return "?"
  end)
  return (s:gsub("&amp;", "&"))
end

local function tag(block, name)
  local v = block:match("<" .. name .. ">(.-)</" .. name .. ">")
  if v then v = unxml(v:match("^%s*(.-)%s*$")) end
  return v
end

function M.popen_lines(cmd)
  local out = {}
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return out end
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

-- ---------------------------------------------------------------- cores por sistema
local palette = {
  "#8C2B2B", "#2B3A8C", "#1F6B4A", "#5A2B8C", "#8C5A1F", "#1F5C8C",
  "#6B2B6B", "#2B6B6B", "#4B3A9C", "#7A3A2B", "#2B4A6B", "#5C6B1F",
}
local fixed = {
  snes = "#5A2B8C", sfc = "#5A2B8C", nes = "#8C2B2B", famicom = "#8C2B2B",
  gba = "#2B3A8C", gb = "#1F6B4A", gbc = "#1F5C8C", n64 = "#2B6B6B",
  psx = "#3A3F5C", psp = "#2B2F4A", megadrive = "#1E2F5C", genesis = "#1E2F5C",
  mastersystem = "#5C1E2F", gamegear = "#2F2F5C", arcade = "#7A3A2B", mame = "#7A3A2B",
  fbneo = "#7A3A2B", neogeo = "#6B5A1F", nds = "#3A3A4A", dreamcast = "#8C5A1F",
  ports = "#4B3A9C", pcengine = "#6B2B2B", atari2600 = "#6B3A1F",
}
local function hexcolor(h)
  local r, g, b = h:match("#(%x%x)(%x%x)(%x%x)")
  return { tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255 }
end
M.hexcolor = hexcolor

function M.systemColor(name)
  if fixed[name] then return hexcolor(fixed[name]) end
  local h = 0
  for i = 1, #name do h = (h * 31 + name:byte(i)) % 9973 end
  return hexcolor(palette[h % #palette + 1])
end

local shortnames = {
  snes = "SNES", nes = "NES", gba = "GBA", gb = "GB", gbc = "GBC", n64 = "N64",
  psx = "PS1", psp = "PSP", megadrive = "MD", genesis = "GEN", mastersystem = "SMS",
  gamegear = "GG", arcade = "ARC", mame = "MAME", fbneo = "FBN", neogeo = "NEO",
  nds = "NDS", dreamcast = "DC", ports = "PORT", pcengine = "PCE", segacd = "SCD",
  sega32x = "32X", atari2600 = "2600", famicom = "FC", sfc = "SFC", wonderswan = "WS",
  wonderswancolor = "WSC", ngp = "NGP", ngpc = "NGPC", pico8 = "P8", ["pico-8"] = "P8",
  saturn = "SAT", atarilynx = "LYNX", virtualboy = "VB", msx = "MSX", dos = "DOS",
  scummvm = "SCUMM", openbor = "BOR", cps1 = "CPS1", cps2 = "CPS2", cps3 = "CPS3",
}
function M.shortName(sys)
  return shortnames[sys.name] or sys.name:upper():sub(1, 4)
end

-- ---------------------------------------------------------------- configuracao
M.config = {
  layout = "grade",      -- grade | cruz | vitrine | metro
  accent = "azulroxo",   -- azulroxo | azul | roxo | ciano
  clock24 = true,
  governor = nil,        -- nil = padrao do sistema
  showEmpty = false,
  swapAB = false,
}

local function serialize(t)
  local out = { "return {" }
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "string" then
      out[#out + 1] = string.format("  [%q] = %q,", k, v)
    elseif type(v) == "number" or type(v) == "boolean" then
      out[#out + 1] = string.format("  [%q] = %s,", k, tostring(v))
    end
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n")
end

function M.loadConfig()
  os.execute("mkdir -p " .. M.shquote(M.CONF_DIR))
  local s = readfile(M.CONF_DIR .. "/config.lua")
  if s then
    local fn = loadstring and loadstring(s) or load(s)
    if fn then
      local ok, t = pcall(fn)
      if ok and type(t) == "table" then
        for k, v in pairs(t) do M.config[k] = v end
      end
    end
  end
end

function M.saveConfig()
  writefile(M.CONF_DIR .. "/config.lua", serialize(M.config))
end

-- recentes: uma linha por jogo  "<sistema>\t<caminho>\t<epoch>"
M.recents = {}
function M.loadRecents()
  M.recents = {}
  local s = readfile(M.CONF_DIR .. "/recents.tsv")
  if not s then return end
  for line in s:gmatch("[^\n]+") do
    local sys, path, t = line:match("^(.-)\t(.-)\t(%d+)$")
    if sys then M.recents[#M.recents + 1] = { sys = sys, path = path, t = tonumber(t) } end
  end
end

function M.pushRecent(game)
  local list = { { sys = game.system.name, path = game.path, t = os.time() } }
  for _, r in ipairs(M.recents) do
    if not (r.sys == game.system.name and r.path == game.path) then list[#list + 1] = r end
    if #list >= 30 then break end
  end
  M.recents = list
  local out = {}
  for _, r in ipairs(list) do out[#out + 1] = r.sys .. "\t" .. r.path .. "\t" .. r.t end
  writefile(M.CONF_DIR .. "/recents.tsv", table.concat(out, "\n") .. "\n")
end

local function firstExistingEarly(list)
  for _, p in ipairs(list) do if M.exists(p) then return p end end
  return nil
end

-- ---------------------------------------------------------------- miniaturas das capas
-- capas grandes demoram para abrir; o thumbs.sh cria uma copia pequena (256 px) em segundo plano
M.THUMB_DIR = M.ROOT_ROMS .. "/.lusmos-thumbs"
M.THUMBS_SCRIPT = os.getenv("LUSMOS_THUMBS") or "/opt/lusmos/thumbs.sh"
local thumbQ, thumbSeen = {}, {}
local function strhash(str)
  local h1, h2 = 5381, 52711
  for i = 1, #str do
    local c = str:byte(i)
    h1 = (h1 * 33 + c) % 4294967296
    h2 = (h2 * 31 + c) % 4294967296
  end
  return string.format("%08x%08x", h1, h2)
end
function M.thumbPath(path)
  local ext = (path:match("%.([^%./]+)$") or ""):lower()
  if ext ~= "png" and ext ~= "jpg" and ext ~= "jpeg" then ext = "png" end
  local h = strhash(path)
  return M.THUMB_DIR .. "/" .. h:sub(1, 2) .. "/" .. h .. "." .. ext
end
function M.queueThumb(src, dst)
  if thumbSeen[src] then return end
  thumbSeen[src] = true
  thumbQ[#thumbQ + 1] = src .. "\t" .. (dst or M.thumbPath(src))
end
-- grava a fila e acorda o gerador (chamado de tempos em tempos pela interface)
function M.flushThumbs()
  if #thumbQ == 0 then return end
  local f = io.open("/tmp/lusmos_thumbq.txt", "a")
  if not f then return end
  f:write(table.concat(thumbQ, "\n"), "\n")
  f:close()
  thumbQ = {}
  os.execute("nohup " .. M.shquote(M.THUMBS_SCRIPT) .. " >/dev/null 2>&1 &")
end
-- todas as capas de um console entram na fila (o gerador pula as que ja existem)
function M.queueSystemThumbs(sys)
  for _, g in ipairs(sys.games or {}) do
    if g.image then M.queueThumb(g.image) end
  end
  if sys.image then M.queueThumb(sys.image) end
end

-- ---------------------------------------------------------------- jogos compactados (.zip)
-- descompacta em segundo plano na mesma pasta; o .zip so e apagado se der tudo certo
function M.zipInfo(g)
  local files, total = {}, 0
  for _, l in ipairs(M.popen_lines("unzip -l " .. M.shquote(g.path) .. " 2>/dev/null")) do
    local size, name = l:match("^%s*(%d+)%s+%S+%s+%S+%s+(.+)$")
    if size and name and not name:match("/$") then
      local ext = (name:match("(%.[^%./]+)$") or ""):lower()
      if g.system.exts[ext] then files[#files + 1] = { name = name, size = tonumber(size) } end
      total = total + tonumber(size)
    end
  end
  return files, total
end
function M.freeBytes(dir)
  local l = M.popen_lines("df -B1 --output=avail " .. M.shquote(dir) .. " 2>/dev/null | tail -n1")[1]
  return tonumber(l or "") or 0
end
function M.startUnzip(g)
  local dir = g.path:match("^(.*)/[^/]+$")
  local done = "/tmp/lusmos_unzip.done"
  os.remove(done)
  os.execute("(unzip -o -j " .. M.shquote(g.path) .. " -d " .. M.shquote(dir) .. " -x '*.txt' '*.nfo' '*.url' >/tmp/lusmos_unzip.log 2>&1; echo $? > " .. done .. ") &")
  return dir
end
function M.unzipDone()
  local t = readfile("/tmp/lusmos_unzip.done")
  if not t then return nil end
  return tonumber(t:match("%d+")) or 1
end
function M.fileSize(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local n = f:seek("end"); f:close()
  return n or 0
end
-- depois de descompactar: o jogo passa a apontar para o arquivo novo e o .zip sai
function M.finishUnzip(g, newPath)
  os.remove(g.path)
  g.path = newPath
  g.zipped = nil
end

-- ---------------------------------------------------------------- ajustes por jogo
-- nome trocado e "escondido" ficam em overrides.tsv; emulador por jogo em cores.tsv
M.overrides, M.gameCores = {}, {}
function M.loadGameSettings()
  M.overrides, M.gameCores = {}, {}
  for line in (readfile(M.CONF_DIR .. "/overrides.tsv") or ""):gmatch("[^\n]+") do
    local sys, path, hid, name = line:match("^(.-)\t(.-)\t(%d)\t(.*)$")
    if sys then M.overrides[sys .. "\t" .. path] = { hidden = hid == "1", name = name } end
  end
  for line in (readfile(M.CONF_DIR .. "/cores.tsv") or ""):gmatch("[^\n]+") do
    local sys, path, pick = line:match("^(.-)\t(.-)\t(.+)$")
    if sys then M.gameCores[sys .. "\t" .. path] = pick end
  end
end
local function saveOverrides()
  local out = {}
  for k, v in pairs(M.overrides) do out[#out + 1] = k .. "\t" .. (v.hidden and "1" or "0") .. "\t" .. (v.name or "") end
  writefile(M.CONF_DIR .. "/overrides.tsv", table.concat(out, "\n") .. "\n")
end
local function saveCores()
  local out = {}
  for k, v in pairs(M.gameCores) do out[#out + 1] = k .. "\t" .. v end
  writefile(M.CONF_DIR .. "/cores.tsv", table.concat(out, "\n") .. "\n")
end
local function gkey(g) return g.system.name .. "\t" .. g.path end
function M.gameCore(g) return M.gameCores[gkey(g)] end
function M.setGameCore(g, pick)
  M.gameCores[gkey(g)] = pick
  saveCores()
end
local function override(g)
  local o = M.overrides[gkey(g)]
  if not o then o = { hidden = g.hidden or false, name = "" }; M.overrides[gkey(g)] = o end
  return o
end
function M.renameGame(g, name)
  local o = override(g)
  o.name = (name or ""):gsub("[\t\n]", " ")
  g.name = o.name ~= "" and o.name or g.name
  g._sort, g._norm = nil, nil
  saveOverrides()
end
function M.setHidden(g, hidden)
  local o = override(g)
  o.hidden = hidden
  g.hidden = hidden
  saveOverrides()
  -- some da lista na hora (ou volta, se estiver mostrando escondidos)
  if hidden and not M.config.showHidden and g.system.games then
    for i, x in ipairs(g.system.games) do if x == g then table.remove(g.system.games, i); break end end
    g.system.count = #g.system.games
  end
end
function M.hiddenCount()
  local n = 0
  for _, o in pairs(M.overrides) do if o.hidden then n = n + 1 end end
  return n
end
-- recarrega as listas (depois de mostrar/esconder jogos)
function M.rescanAll()
  for _, sys in ipairs(M.systems) do sys.games = nil end
end

-- ---------------------------------------------------------------- colecoes
-- mesmos arquivos do EmulationStation: ~/.emulationstation/collections/custom-<nome>.cfg
-- (uma linha por jogo, com o caminho completo); o que muda num aparece no outro
M.COLL_DIR = (os.getenv("LUSMOS_ES_DIR") or "/home/ark/.emulationstation") .. "/collections"
function M.collections()
  local out = {}
  for _, f in ipairs(M.popen_lines("ls -1 " .. M.shquote(M.COLL_DIR) .. "/custom-*.cfg 2>/dev/null")) do
    local name = f:match("custom%-(.+)%.cfg$")
    if name then
      local paths = {}
      for line in (readfile(f) or ""):gmatch("[^\r\n]+") do paths[#paths + 1] = line end
      out[#out + 1] = { name = name, file = f, paths = paths }
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end
local byPath = nil
function M.gameByPath(path)
  if not byPath or byPath.n ~= #M.allGames() then
    byPath = { n = #M.allGames() }
    for _, g in ipairs(M.allGames()) do byPath[g.path] = g end
  end
  return byPath[path]
end
function M.collectionGames(c)
  local out = {}
  for _, p in ipairs(c.paths) do
    local g = M.gameByPath(p)
    if g then out[#out + 1] = g end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end
function M.inCollection(c, g)
  for _, p in ipairs(c.paths) do if p == g.path then return true end end
  return false
end
function M.toggleCollection(c, g)
  local keep, found = {}, false
  for _, p in ipairs(c.paths) do
    if p == g.path then found = true else keep[#keep + 1] = p end
  end
  if not found then keep[#keep + 1] = g.path end
  c.paths = keep
  os.execute("mkdir -p " .. M.shquote(M.COLL_DIR))
  writefile(c.file, table.concat(keep, "\n") .. (#keep > 0 and "\n" or ""))
  return not found
end
function M.newCollection(name)
  name = (name or ""):gsub("[/\\%c]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil end
  os.execute("mkdir -p " .. M.shquote(M.COLL_DIR))
  local f = M.COLL_DIR .. "/custom-" .. name .. ".cfg"
  if not M.exists(f) then writefile(f, "") end
  for _, c in ipairs(M.collections()) do if c.file == f then return c end end
  return nil
end
function M.deleteCollection(c) os.remove(c.file) end

-- ---------------------------------------------------------------- EmulationStation e atualizacao
M.ES_BIN = "/usr/bin/emulationstation/emulationstation"
function M.hasES() return M.exists(M.ES_BIN) end
-- ---------------------------------------------------------------- atualizacao do lusmOS pela internet
M.UPDATE_SCRIPT = "/opt/lusmos/online-update.sh"
M.UPDATE_INFO = "/tmp/lusmos_update.txt"
M.UPDATE_PROG = "/tmp/lusmos_update_progress.txt"
M.REPO_URL = "github.com/Lucasmassaroto1/lusmOs4"
function M.startUpdateCheck()
  os.remove(M.UPDATE_INFO)
  os.execute(M.UPDATE_SCRIPT .. " check >/dev/null 2>&1 &")
end
-- nil = ainda procurando; { state = "nova"|"atual"|"erro", version, notes }
function M.updateInfo()
  local t = readfile(M.UPDATE_INFO)
  if not t then return nil end
  local l = {}
  for line in t:gmatch("[^\n]+") do l[#l + 1] = line end
  return { state = l[1] or "erro", version = l[2], notes = l[3] }
end
function M.startUpdateInstall()
  os.remove(M.UPDATE_PROG)
  os.execute("nohup " .. M.UPDATE_SCRIPT .. " install >/dev/null 2>&1 &")
end
function M.updateProgress()
  local t = readfile(M.UPDATE_PROG)
  return t and t:gsub("%s+$", "") or nil
end

-- pacote de atualizacao do sistema (update-arkos.tar na EASYROMS), aplicado no boot
function M.updatePackage()
  return firstExistingEarly({ M.ROOT_ROMS .. "/update-arkos.tar", "/roms2/update-arkos.tar" })
end

-- favoritos proprios do lusmOS (somam com os do gamelist)
M.favs = {}
function M.loadFavs()
  M.favs = {}
  local s = readfile(M.CONF_DIR .. "/favorites.tsv")
  if not s then return end
  for line in s:gmatch("[^\n]+") do
    local sys, path, flag = line:match("^(.-)\t(.-)\t(%d)$")
    if sys then M.favs[sys .. "\t" .. path] = (flag == "1") end
  end
end

function M.saveFavs()
  local out = {}
  for k, v in pairs(M.favs) do out[#out + 1] = k .. "\t" .. (v and "1" or "0") end
  writefile(M.CONF_DIR .. "/favorites.tsv", table.concat(out, "\n") .. "\n")
end

function M.isFav(game)
  local v = M.favs[game.system.name .. "\t" .. game.path]
  if v ~= nil then return v end
  return game.esFav == true
end

function M.toggleFav(game)
  M.favs[game.system.name .. "\t" .. game.path] = not M.isFav(game)
  M.saveFavs()
end

-- ---------------------------------------------------------------- es_settings
M.es = {}
function M.loadESSettings()
  M.es = {}
  local s = readfile(M.ES_SETTINGS)
  if not s then return end
  for kind, name, value in s:gmatch('<(%a+) name="(.-)" value="(.-)"%s*/>') do
    M.es[name] = unxml(value)
  end
end

-- ---------------------------------------------------------------- capas dos sistemas (do tema instalado no cartao)
local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end
M.exists = exists

function M.systemImage(sys)
  local themes = {}
  if M.es.ThemeSet and M.es.ThemeSet ~= "" then themes[#themes + 1] = M.es.ThemeSet end
  themes[#themes + 1] = "R36S_Switch_Black_Rounded_v3"
  local roots = { M.ROOT_ROMS .. "/themes", "/etc/emulationstation/themes", "/home/ark/.emulationstation/themes" }
  local names = {}
  if sys.theme then names[#names + 1] = sys.theme end
  names[#names + 1] = sys.name
  for _, root in ipairs(roots) do
    for _, th in ipairs(themes) do
      for _, n in ipairs(names) do
        for _, rel in ipairs({ "/_inc/system.png", "/_inc/system.jpg", "/system.png" }) do
          local p = root .. "/" .. th .. "/" .. n .. rel
          if exists(p) then return p end
        end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------- es_systems
M.systems = {}
M.byName = {}
M.optionsSystem = nil

function M.loadSystems()
  M.systems, M.byName = {}, {}
  local s = readfile(M.ES_SYSTEMS)
  if not s then return false end
  local hidden = {}
  for h in (M.es.HiddenSystems or ""):gmatch("[^;]+") do hidden[h] = true end
  for block in s:gmatch("<system>(.-)</system>") do
    local sys = {
      name = tag(block, "name"),
      fullname = tag(block, "fullname"),
      path = tag(block, "path"),
      command = tag(block, "command"),
      platform = tag(block, "platform"),
      theme = tag(block, "theme"),
      exts = {},
      emulators = {},
      games = nil,
      count = 0,
    }
    for e in (tag(block, "extension") or ""):gmatch("%S+") do sys.exts[e:lower()] = true end
    -- consoles cujo emulador nao abre .zip: o lusmOS mostra o .zip e descompacta na primeira vez
    if M.ZIP_PREP[sys.name] and not sys.exts[".zip"] then sys.zipPrep = true end
    local emus = block:match("<emulators>(.-)</emulators>")
    if emus then
      for ename, ebody in emus:gmatch('<emulator name="(.-)"%s*>(.-)</emulator>') do
        local cores = {}
        for c in ebody:gmatch("<core>(.-)</core>") do cores[#cores + 1] = c end
        sys.emulators[#sys.emulators + 1] = { name = ename, cores = cores }
      end
      for ename in emus:gmatch('<emulator name="(.-)"%s*/>') do
        sys.emulators[#sys.emulators + 1] = { name = ename, cores = {} }
      end
    end
    if sys.name and sys.path and sys.command then
      sys.path = sys.path:gsub("/+$", "")
      -- ports e sistemas de scripts: so os atalhos da raiz (as subpastas sao dados dos jogos)
      local onlySh = true
      for e in pairs(sys.exts) do if e ~= ".sh" then onlySh = false end end
      sys.depth = (sys.name == "ports" or onlySh) and 1 or 3
      if sys.name == "options" or sys.path == "/opt/system" then
        M.optionsSystem = sys
      elseif not hidden[sys.name] and not M.byName[sys.name] then
        sys.color = M.systemColor(sys.name)
        sys.short = M.shortName(sys)
        sys.image = M.systemImage(sys)
        M.systems[#M.systems + 1] = sys
        M.byName[sys.name] = sys
      elseif M.byName[sys.name] then
        -- mesmo nome em duas entradas: a "de verdade" e a que tem a pasta com o mesmo nome
        -- (ex.: o SuFami Turbo tambem aparece como "snes")
        local base = M.byName[sys.name]
        local function own(p) return p:match("/" .. sys.name:gsub("%p", "%%%0") .. "$") ~= nil end
        if own(sys.path) and not own(base.path) then
          base.extraPaths = base.extraPaths or {}
          base.extraPaths[#base.extraPaths + 1] = base.path
          base.path, base.fullname, base.theme = sys.path, sys.fullname, sys.theme
          base.image = M.systemImage(base)
        else
          base.extraPaths = base.extraPaths or {}
          base.extraPaths[#base.extraPaths + 1] = sys.path
        end
      end
    end
  end
  return true
end

local skipDirs = {
  images = true, downloaded_images = true, downloaded_videos = true, videos = true,
  media = true, manuals = true, snap = true, snaps = true, boxart = true, cfg = true,
  saves = true, states = true, savestates = true, controls = true, backup = true,
}

local function cleanName(file)
  local n = file:gsub("^.*/", ""):gsub("%.[^%.]+$", "")
  n = n:gsub("(%a)_(%a)", "%1'%2")   -- "Bug_s" -> "Bug's"
  n = n:gsub("_", " ")
  return n
end

-- o gamelist.xml grande (milhares de jogos com descricao) demora para ler; o resultado
-- fica guardado e so e lido de novo quando o arquivo muda (tamanho + final do arquivo)
local function glSignature(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - 4096))
  local tail = f:read("*a") or ""
  f:close()
  local h = 0
  for i = 1, #tail, 3 do h = (h * 31 + tail:byte(i)) % 2147483647 end
  return size .. ":" .. h
end
local function glCacheFile(dir)
  return M.CONF_DIR .. "/cache/gl_" .. dir:gsub("[^%w]", "_") .. ".lua"
end
local function saveGlCache(file, sig, map, dir)
  os.execute("mkdir -p " .. M.shquote(M.CONF_DIR .. "/cache"))
  local out = { "-- " .. sig, "return {" }
  local function q(v) return v == nil and "nil" or string.format("%q", v) end
  for path, m in pairs(map) do
    if m.base == dir then
      local d = m.desc and m.desc:sub(1, 600) or nil
      out[#out + 1] = string.format("[%q]={name=%s,image=%s,fav=%s,lastplayed=%s,playcount=%s,desc=%s,developer=%s,releasedate=%s,emulator=%s,core=%s,hidden=%s},",
        path, q(m.name), q(m.image), tostring(m.fav), q(m.lastplayed), tostring(m.playcount), q(d), q(m.developer),
        q(m.releasedate), q(m.emulator), q(m.core), tostring(m.hidden))
    end
  end
  out[#out + 1] = "}"
  writefile(file, table.concat(out, "\n"))
end

local function parseGamelist(sys, dir, map, y)
  local glpath = dir .. "/gamelist.xml"
  local sig = glSignature(glpath)
  if not sig then return end
  local cfile = glCacheFile(dir)
  local cf = io.open(cfile, "r")
  if cf then
    local first = cf:read("*l") or ""
    cf:close()
    if first == "-- " .. sig then
      local chunk = loadfile(cfile)
      local ok, t = pcall(chunk or error)
      if ok and type(t) == "table" then
        for path, m in pairs(t) do m.base = dir; map[path] = m end
        return
      end
    end
  end
  local s = readfile(glpath)
  if not s then return end
  local n = 0
  for g in s:gmatch("<game>(.-)</game>") do
    n = n + 1
    if y and n % 120 == 0 then y() end
    local p = tag(g, "path")
    if p then
      p = p:gsub("^%./", "")
      map[dir .. "/" .. p] = {
        name = tag(g, "name"),
        image = tag(g, "thumbnail") or tag(g, "image"),
        fav = tag(g, "favorite") == "true",
        lastplayed = tag(g, "lastplayed"),
        playcount = tonumber(tag(g, "playcount") or ""),
        desc = tag(g, "desc"),
        developer = tag(g, "developer"),
        releasedate = tag(g, "releasedate"),
        emulator = tag(g, "emulator"),
        core = tag(g, "core"),
        hidden = tag(g, "hidden") == "true",
        base = dir,
      }
    end
  end
  pcall(saveGlCache, cfile, sig, map, dir)
end

-- capa dos ports do PortMaster: o script aponta para a pasta do jogo (GAMEDIR), que tem cover.jpg
function M.portCover(dir, script)
  local txt = readfile(script)
  if not txt then return nil end
  local gd = txt:match('GAMEDIR="?[^\n"]-/ports/([^/\n"]+)') or txt:match("GAMEDIR=[^\n]-/ports/([^/\n\"' ]+)")
  local names = {}
  if gd then names[#names + 1] = gd end
  local base = script:match("([^/]+)%.[sS][hH]$")
  if base then names[#names + 1] = base:lower():gsub("[^%w]", "") end
  for _, n in ipairs(names) do
    for _, f in ipairs({ "cover.jpg", "cover.png", "screenshot.jpg", "screenshot.png" }) do
      local p = dir .. "/" .. n .. "/" .. f
      if M.exists(p) then return p end
    end
  end
  return nil
end

-- devolve lista de jogos do sistema (com cache)
-- lista os arquivos; com "y" (dentro de uma corrotina) o find roda em segundo plano
-- e a tela continua respondendo enquanto ele trabalha
M.ZIP_PREP = { ppsspp = true, psp = true, pspminis = true, psx = true, segacd = true, saturn = true, dreamcast = true, pcenginecd = true }
local scanSeq = 0
local function listFiles(dir, depth, y)
  local cmd = "find " .. M.shquote(dir) .. " -maxdepth " .. depth .. " -type f"
  if not y then return M.popen_lines(cmd) end
  scanSeq = scanSeq + 1
  local out = "/tmp/lusmos_scan_" .. scanSeq .. ".txt"
  local done = out .. ".ok"
  os.remove(out); os.remove(done)
  os.execute("(" .. cmd .. " > " .. M.shquote(out) .. " 2>/dev/null; touch " .. M.shquote(done) .. ") &")
  while not exists(done) do y() end
  local lines = {}
  local f = io.open(out, "r")
  if f then
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
  end
  os.remove(out); os.remove(done)
  return lines
end

function M.scanSystem(sys, y)
  if sys.games then return sys.games end
  local games = {}
  local dirs = { sys.path }
  for _, p in ipairs(sys.extraPaths or {}) do dirs[#dirs + 1] = p end
  for _, dir in ipairs(dirs) do
    local meta = {}
    parseGamelist(sys, dir, meta, y)
    local lines = listFiles(dir, sys.depth or 3, y)
    for li, full in ipairs(lines) do
      if y and li % 150 == 0 then y() end
      local rel = full:sub(#dir + 2)
      local skip = false
      for part in rel:gmatch("([^/]+)/") do
        if skipDirs[part:lower()] or part:sub(1, 1) == "." then skip = true end
      end
      local ext = (full:match("(%.[^%./]+)$") or ""):lower()
      local base = full:match("([^/]+)$")
      local zipped = ext == ".zip" and sys.zipPrep
      if not skip and (sys.exts[ext] or zipped) and base:sub(1, 1) ~= "." and not base:match("^Scan_for_new_games") then
        local m = meta[full] or {}
        local img = nil
        if m.image then
          img = m.image:sub(1, 1) == "/" and m.image or (m.base .. "/" .. m.image:gsub("^%./", ""))
        end
        if not img and ext == ".sh" then img = M.portCover(dir, full) end
        games[#games + 1] = {
          system = sys,
          path = full,
          name = m.name or cleanName(full),
          image = img,
          esFav = m.fav,
          lastplayed = m.lastplayed,
          desc = m.desc,
          developer = m.developer,
          year = m.releasedate and m.releasedate:sub(1, 4) or nil,
          folder = rel:match("^(.*)/[^/]+$"),
          esEmu = m.emulator, esCore = m.core,
          esHidden = m.hidden,
          zipped = zipped or nil,
        }
        local g = games[#games]
        local ov = M.overrides[sys.name .. "\t" .. full]
        if ov then
          if ov.name and ov.name ~= "" then g.name = ov.name end
          g.hidden = ov.hidden
        else
          g.hidden = m.hidden
        end
        if g.hidden and not M.config.showHidden then games[#games] = nil end
      end
    end
  end
  if y then y() end
  table.sort(games, function(a, b) return a.name:lower() < b.name:lower() end)
  sys.games = games
  sys.count = #games
  M.queueSystemThumbs(sys)
  return games
end

-- contagem rapida para a lista de sistemas (sem ler gamelist)
function M.countSystem(sys)
  if sys.games then return sys.count end
  local exts = {}
  for e in pairs(sys.exts) do exts[#exts + 1] = "-iname " .. M.shquote("*" .. e) end
  if sys.zipPrep then exts[#exts + 1] = "-iname '*.zip'" end
  if #exts == 0 then return 0 end
  local paths = M.shquote(sys.path)
  for _, p in ipairs(sys.extraPaths or {}) do paths = paths .. " " .. M.shquote(p) end
  local cmd = "find " .. paths .. " -maxdepth " .. (sys.depth or 3) .. " -type f \\( " .. table.concat(exts, " -o ") ..
      " \\) -not -path '*/images/*' -not -name '.*' -not -name 'Scan_for_new_games*' 2>/dev/null | wc -l"
  local l = M.popen_lines(cmd)
  sys.count = tonumber(l[1] or "0") or 0
  return sys.count
end

function M.findGame(sysname, path)
  local sys = M.byName[sysname]
  if not sys then return nil end
  for _, g in ipairs(M.scanSystem(sys)) do
    if g.path == path then return g end
  end
  return nil
end

function M.recentGames(max)
  local out = {}
  for _, r in ipairs(M.recents) do
    local sys = M.byName[r.sys]
    if sys then
      local g = M.findGame(r.sys, r.path)
      if g then
        g.lastTime = r.t
        out[#out + 1] = g
      end
    end
    if #out >= (max or 12) then break end
  end
  return out
end

function M.allScanned()
  for _, sys in ipairs(M.systems) do
    if sys.count > 0 and not sys.games then return false end
  end
  return true
end

-- todos os jogos de todos os sistemas, em ordem alfabetica (guardado ate mudar algo)
local allCache, allKey = nil, nil
function M.allGames()
  local key, total = 0, 0
  for _, sys in ipairs(M.systems) do
    if sys.games then key = key + 1; total = total + #sys.games end
  end
  key = key .. ":" .. total
  if allCache and allKey == key then return allCache end
  local out = {}
  for _, sys in ipairs(M.systems) do
    if sys.count > 0 and sys.games then
      for _, g in ipairs(sys.games) do out[#out + 1] = g end
    end
  end
  for _, g in ipairs(out) do g._sort = g._sort or g.name:lower() end
  table.sort(out, function(a, b)
    if a._sort ~= b._sort then return a._sort < b._sort end
    return (a.system.name or "") < (b.system.name or "")
  end)
  allCache, allKey = out, key
  return out
end

-- pesquisa: ignora maiusculas, acentos e pontuacao; todas as palavras precisam aparecer
local ACC = { ["á"]="a",["à"]="a",["â"]="a",["ã"]="a",["ä"]="a",["é"]="e",["è"]="e",["ê"]="e",["ë"]="e",
  ["í"]="i",["ì"]="i",["î"]="i",["ï"]="i",["ó"]="o",["ò"]="o",["ô"]="o",["õ"]="o",["ö"]="o",
  ["ú"]="u",["ù"]="u",["û"]="u",["ü"]="u",["ç"]="c",["ñ"]="n",
  ["Á"]="a",["À"]="a",["Â"]="a",["Ã"]="a",["É"]="e",["Ê"]="e",["Í"]="i",["Ó"]="o",["Ô"]="o",["Õ"]="o",["Ú"]="u",["Ç"]="c" }
function M.normalize(str)
  str = (str or ""):gsub("[\195][\128-\191]", function(c) return ACC[c] or c end)
  str = str:lower():gsub("[^%w]+", " ")
  return str
end

function M.searchGames(query)
  local words = {}
  for w in M.normalize(query):gmatch("%S+") do words[#words + 1] = w end
  local out = {}
  if #words == 0 then return out end
  for _, g in ipairs(M.allGames()) do
    g._norm = g._norm or (" " .. M.normalize(g.name) .. " ")
    local ok = true
    for _, w in ipairs(words) do
      if not g._norm:find(w, 1, true) then ok = false; break end
    end
    if ok then out[#out + 1] = g end
  end
  return out
end

-- algumas capas para o bloco "todos os jogos" (recentes, favoritos e o resto)
function M.sampleCovers(n)
  local out, seen = {}, {}
  local function add(g)
    if #out < n and g and g.image and not seen[g.image] then seen[g.image] = true; out[#out + 1] = g.image end
  end
  for _, g in ipairs(M.recentGames(12)) do add(g) end
  for _, sys in ipairs(M.systems) do
    if sys.games then
      for _, g in ipairs(sys.games) do if M.isFav(g) then add(g) end end
    end
  end
  -- depois, um de cada console, alternando, para a capa ficar variada
  local idx = 1
  while #out < n do
    local any = false
    for _, sys in ipairs(M.systems) do
      if sys.games and sys.games[idx] then any = true; add(sys.games[idx]) end
    end
    if not any or idx > 400 then break end
    idx = idx + 1
  end
  return out
end

function M.totalGames()
  local n = 0
  for _, sys in ipairs(M.systems) do n = n + (sys.count or 0) end
  return n
end

function M.favoriteGames()
  local out = {}
  for _, sys in ipairs(M.systems) do
    if sys.count > 0 and sys.games then
      for _, g in ipairs(sys.games) do
        if M.isFav(g) then out[#out + 1] = g end
      end
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

-- ---------------------------------------------------------------- comando de execucao
function M.buildCommand(game)
  local sys = game.system
  local emu, core = M.es[sys.name .. ".emulator"], M.es[sys.name .. ".core"]
  -- escolha feita no lusmOS (Ajustes > Emulação > Emulador por sistema) vale primeiro
  local pick = M.config["core." .. sys.name]
  if type(pick) == "string" and pick ~= "" then
    local e, c = pick:match("^(.-)|(.*)$")
    emu, core = e or pick, c or ""
  end
  -- por jogo: escolha do lusmOS, depois a do EmulationStation (gamelist)
  local gp = M.gameCore(game)
  if gp then
    local e, c = gp:match("^(.-)|(.*)$")
    emu, core = e or gp, c or ""
  elseif game.esEmu and game.esEmu ~= "" then
    emu, core = game.esEmu, game.esCore or ""
  end
  if (not emu or emu == "") and sys.emulators[1] then emu = sys.emulators[1].name end
  if not core or core == "" then
    for _, e in ipairs(sys.emulators) do
      if e.name == emu and e.cores[1] then core = e.cores[1] end
    end
  end
  local gov = M.config.governor or M.es.GlobalPerformanceGovernor or "ondemand"
  local cmd = sys.command
  cmd = cmd:gsub("%%ROM%%", function() return M.shquote(game.path) end)
  cmd = cmd:gsub("%%EMULATOR%%", function() return emu or "retroarch" end)
  cmd = cmd:gsub("%%CORE%%", function() return core or "" end)
  cmd = cmd:gsub("%%GOVERNOR%%", function() return gov end)
  cmd = cmd:gsub("%%BASENAME%%", function() return M.shquote(game.path:match("([^/]+)%.[^.]+$") or "") end)
  return cmd, emu, core
end

function M.optionsCommand(script)
  local sys = M.optionsSystem
  local tpl = sys and sys.command or 'sudo chmod 666 /dev/tty1; %ROM% 2>&1 > /dev/tty1; printf "\\033c" >> /dev/tty1'
  return (tpl:gsub("%%ROM%%", function() return M.shquote(script) end))
end

-- ---------------------------------------------------------------- ferramentas do lusmOS
local function runrc_(cmd) return M.runrc(cmd) end

local function firstExisting(list)
  for _, p in ipairs(list) do if exists(p) then return p end end
  return nil
end

function M.portMaster()
  return firstExisting({
    "/opt/system/Tools/PortMaster/PortMaster.sh",
    "/opt/system/Tools/PortMaster.sh",
    "/roms/tools/PortMaster/PortMaster.sh",
    "/roms/tools/PortMaster.sh",
    "/roms/ports/PortMaster/PortMaster.sh",
  })
end

function M.fileManager()
  return firstExisting({ "/opt/system/351Files.sh", "/opt/system/File Manager.sh", "/opt/system/Tools/351Files.sh" })
end

-- emulador/nucleo escolhidos para um sistema (para mostrar nos Ajustes)
function M.coreChoices(sys)
  local out = {}
  for _, e in ipairs(sys.emulators or {}) do
    if #e.cores == 0 then
      out[#out + 1] = { emu = e.name, core = "", label = e.name }
    else
      for _, c in ipairs(e.cores) do
        out[#out + 1] = { emu = e.name, core = c, label = (e.name == "retroarch" or e.name == "retrorun") and c or (e.name .. " · " .. c) }
      end
    end
  end
  return out
end

function M.currentCore(sys)
  local pick = M.config["core." .. sys.name]
  if type(pick) == "string" and pick ~= "" then return pick end
  local emu, core = M.es[sys.name .. ".emulator"], M.es[sys.name .. ".core"]
  local ch = M.coreChoices(sys)
  if (not emu or emu == "") and ch[1] then return ch[1].emu .. "|" .. ch[1].core end
  return (emu or "") .. "|" .. (core or "")
end

-- backup das configuracoes do lusmOS e do RetroArch em /roms/backup
M.BACKUP_DIR = M.ROOT_ROMS .. "/backup"
local BACKUP_PATHS = "home/ark/.config/lusmos home/ark/.config/retroarch/retroarch.cfg home/ark/.config/retroarch/config home/ark/.config/retroarch32/retroarch.cfg home/ark/.config/retroarch32/config"

function M.makeBackup()
  local name = "lusmos-ajustes-" .. os.date("%Y%m%d-%H%M") .. ".tar.gz"
  local out = M.BACKUP_DIR .. "/" .. name
  local ok = runrc_(("mkdir -p %s && cd / && tar -czf %s --ignore-failed-read %s"):format(
    M.shquote(M.BACKUP_DIR), M.shquote(out), BACKUP_PATHS))
  return ok, name
end

function M.listBackups()
  local l = M.popen_lines("ls -1t " .. M.shquote(M.BACKUP_DIR) .. "/lusmos-ajustes-*.tar.gz 2>/dev/null")
  local out = {}
  for _, f in ipairs(l) do out[#out + 1] = { path = f, name = f:match("([^/]+)$") } end
  return out
end

function M.restoreBackup(path)
  return runrc_("cd / && sudo tar -xzf " .. M.shquote(path))
end

-- volta os ajustes do lusmOS ao padrao (mantem favoritos e recentes)
function M.resetConfig()
  os.remove(M.CONF_DIR .. "/config.lua")
end

-- informacoes do sistema
function M.systemInfo()
  local info = {}
  local ip = M.popen_lines("hostname -I 2>/dev/null")[1]
  info.ip = (ip and ip:match("%S+")) or "sem rede"
  info.host = (readfile("/etc/hostname") or "lusmos"):match("%S+") or "lusmos"
  local df = M.popen_lines("df -h " .. M.shquote(M.ROOT_ROMS) .. " / 2>/dev/null | tail -n +2")
  local function parse(l) local _, size, used, avail, pct = (l or ""):match("(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)"); return size, avail, pct end
  info.romsSize, info.romsFree, info.romsPct = parse(df[1])
  info.sysSize, info.sysFree, info.sysPct = parse(df[2])
  info.battery, info.charging = M.battery()
  local up = tonumber((readfile("/proc/uptime") or ""):match("^(%d+)") or "")
  info.uptime = up and string.format("%dh %02dmin", math.floor(up / 3600), math.floor((up % 3600) / 60)) or "—"
  info.kernel = (M.popen_lines("uname -r")[1]) or "—"
  local games = 0
  for _, sys in ipairs(M.systems) do games = games + (sys.count or 0) end
  info.games, info.systems = games, #M.systems
  return info
end

function M.battery()
  local c = readfile("/sys/class/power_supply/battery/capacity")
  local st = readfile("/sys/class/power_supply/battery/status")
  return tonumber(c or ""), st and st:match("Charging") ~= nil
end

-- ---------------------------------------------------------------- Wi-Fi (adaptador USB, NetworkManager)
-- divide uma linha do "nmcli -t" respeitando "\:" escapado
local function nmsplit(line)
  local out, cur, i = {}, {}, 1
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == "\\" and i < #line then
      cur[#cur + 1] = line:sub(i + 1, i + 1)
      i = i + 2
    elseif ch == ":" then
      out[#out + 1] = table.concat(cur)
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = ch
      i = i + 1
    end
  end
  out[#out + 1] = table.concat(cur)
  return out
end
M.nmsplit = nmsplit

-- interface sem fio presente (adaptador conectado)?
function M.wifiIface()
  local l = M.popen_lines("ls -d /sys/class/net/*/wireless 2>/dev/null | head -n 1")
  if l[1] then return l[1]:match("/sys/class/net/([^/]+)/wireless") end
  return nil
end

-- status rapido para a barra superior: nil = sem adaptador, true/false = conectado
function M.wifi()
  local iface = M.wifiIface()
  if not iface then return nil end
  local st = readfile("/sys/class/net/" .. iface .. "/operstate")
  return st ~= nil and st:match("up") ~= nil
end

-- status completo
function M.wifiStatus()
  local st = { iface = M.wifiIface() }
  if not st.iface then return st end
  for _, line in ipairs(M.popen_lines("nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status")) do
    local f = nmsplit(line)
    if f[1] == st.iface then
      st.state = f[3]
      st.connected = f[3] == "connected"
      st.ssid = (f[4] ~= "" and f[4] ~= "--") and f[4] or nil
    end
  end
  if st.connected then
    local ip = M.popen_lines("nmcli -g IP4.ADDRESS dev show " .. M.shquote(st.iface))
    st.ip = ip[1] and ip[1]:match("^([%d%.]+)") or nil
  end
  return st
end

function M.wifiName()
  local st = M.wifiStatus()
  return st.ssid
end

-- redes salvas (nome da conexao)
function M.wifiSaved()
  local saved = {}
  for _, line in ipairs(M.popen_lines("nmcli -t -f NAME,TYPE connection show")) do
    local f = nmsplit(line)
    if f[2] and f[2]:match("wireless") then saved[f[1]] = true end
  end
  return saved
end

-- procura redes (demora alguns segundos)
function M.wifiScan()
  local saved = M.wifiSaved()
  local best = {}
  for _, line in ipairs(M.popen_lines("sudo nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY dev wifi list --rescan yes")) do
    local f = nmsplit(line)
    local ssid = f[2]
    if ssid and ssid ~= "" then
      local net = {
        ssid = ssid,
        inuse = f[1] == "*",
        signal = tonumber(f[3]) or 0,
        security = (f[4] and f[4] ~= "" and f[4] ~= "--") and f[4] or nil,
        saved = saved[ssid] == true,
      }
      local old = best[ssid]
      if not old or net.inuse or (net.signal > old.signal and not old.inuse) then best[ssid] = net end
    end
  end
  local list = {}
  for _, n in pairs(best) do list[#list + 1] = n end
  table.sort(list, function(a, b)
    if a.inuse ~= b.inuse then return a.inuse end
    if a.saved ~= b.saved then return a.saved end
    return a.signal > b.signal
  end)
  return list
end

local function runrc(cmd)
  local out = M.popen_lines(cmd .. " 2>&1; echo \"__RC=$?\"")
  local rc, msg = 1, {}
  for _, l in ipairs(out) do
    local r = l:match("^__RC=(%d+)$")
    if r then rc = tonumber(r) else msg[#msg + 1] = l end
  end
  return rc == 0, table.concat(msg, " ")
end

M.runrc = runrc

function M.wifiConnect(net, password)
  local cmd
  if net.saved and not password then
    cmd = "sudo nmcli connection up id " .. M.shquote(net.ssid)
  else
    cmd = "sudo nmcli dev wifi connect " .. M.shquote(net.ssid)
    if password and password ~= "" then cmd = cmd .. " password " .. M.shquote(password) end
  end
  local ok, msg = runrc("timeout 40 " .. cmd)
  if not ok then
    if msg:lower():match("secrets") or msg:lower():match("password") or msg:lower():match("802%-1x") then
      return false, "Senha incorreta"
    end
    if msg:lower():match("no network with ssid") then return false, "Rede não encontrada" end
    return false, "Não foi possível conectar"
  end
  return true
end

function M.wifiDisconnect(iface)
  return runrc("sudo nmcli dev disconnect " .. M.shquote(iface))
end

function M.wifiForget(ssid)
  return runrc("sudo nmcli connection delete id " .. M.shquote(ssid))
end

M.MAXBRIGHT = 160
function M.getBrightness()
  local v = tonumber(readfile("/sys/class/backlight/backlight/brightness") or "")
  local max = tonumber(readfile("/sys/class/backlight/backlight/max_brightness") or "") or M.MAXBRIGHT
  if not v then return nil end
  return math.floor(v * 100 / max + 0.5), max
end

function M.setBrightness(pct)
  local _, max = M.getBrightness()
  max = max or M.MAXBRIGHT
  pct = math.max(1, math.min(100, math.floor(pct + 0.5)))
  local v = math.max(1, math.floor(max * pct / 100 + 0.5))
  os.execute("echo " .. v .. " | sudo tee /sys/class/backlight/backlight/brightness >/dev/null 2>&1")
  M.brightPct, M.brightRaw = pct, v
  return pct
end

-- leitura que respeita o ultimo valor escolhido (evita "pular" por arredondamento)
function M.brightnessPct()
  local raw = tonumber(readfile("/sys/class/backlight/backlight/brightness") or "")
  if raw and M.brightRaw == raw and M.brightPct then return M.brightPct end
  local p = M.getBrightness()
  M.brightPct, M.brightRaw = p, raw
  return p
end

-- volume em escala "mapeada" (-M): segue o ouvido, e nao o valor bruto do chip.
-- Na escala bruta, metade da barra ja e quase mudo e o fim dela estoura de alto.
M.VOL_FILE = M.CONF_DIR .. "/volume"
function M.getVolume()
  local l = M.popen_lines("amixer -M sget Playback | awk -F'[][]' '/Left:/ { print $2; exit }'")
  return tonumber((l[1] or ""):match("(%d+)"))
end
function M.setVolume(pct)
  pct = math.max(0, math.min(100, math.floor(pct + 0.5)))
  M.volPct = pct
  os.execute("amixer -q -M sset Playback " .. math.floor(pct) .. "% >/dev/null 2>&1")
end
-- ultimo volume salvo (tambem quando mudado dentro de um jogo, pelo servico do volume)
function M.savedVolume()
  return tonumber((readfile(M.VOL_FILE) or ""):match("(%d+)"))
end
function M.saveVolume(pct)
  writefile(M.VOL_FILE, tostring(math.floor(pct)) .. "\n")
end

return M
