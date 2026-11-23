-- lusmOS 4 :: desenho (cores, fontes, icones, helpers)
local data = require("data")
local lg = love.graphics
local U = {}

U.W, U.H = 640, 480

local function hex(h, a)
  local c = data.hexcolor(h)
  c[4] = a or 1
  return c
end
U.hex = hex

U.c = {
  bg = hex("#0B0D12"),
  bg2 = hex("#12151C"),
  panel = hex("#11141B"),
  card = hex("#151922"),
  line = hex("#1E2330"),
  line2 = hex("#2C3242"),
  text = hex("#F2F4F8"),
  text2 = hex("#C9CFDA"),
  muted = hex("#9AA3B2"),
  dim = hex("#8790A3"),
  black = hex("#07080C"),
  white = { 1, 1, 1, 1 },
}

U.accents = {
  azulroxo = { name = "Azul + Roxo", a = "#6C8CFF", b = "#A774FF", light = "#C9D4FF" },
  azul = { name = "Azul", a = "#6C8CFF", b = "#4F7BFF", light = "#C9D4FF" },
  roxo = { name = "Roxo", a = "#A774FF", b = "#8B5CF6", light = "#E0CCFF" },
  ciano = { name = "Ciano", a = "#3DD6F5", b = "#6C8CFF", light = "#C4F3FD" },
}
U.accentOrder = { "azulroxo", "azul", "roxo", "ciano" }

function U.applyAccent(key)
  local a = U.accents[key] or U.accents.azulroxo
  U.c.accent = hex(a.a)
  U.c.accent2 = hex(a.b)
  U.c.accentLight = hex(a.light)
end
U.applyAccent("azulroxo")

-- ---------------------------------------------------------------- fontes
local fontCache = {}
local FONTDIR = "fonts/"
local files = { r = "Poppins-Regular.ttf", m = "Poppins-Medium.ttf", b = "Poppins-Bold.ttf", l = "Poppins-Light.ttf" }
function U.font(w, size)
  local key = w .. size
  if not fontCache[key] then
    local ok, f = pcall(lg.newFont, FONTDIR .. files[w], size)
    if not ok then f = lg.newFont(size) end
    fontCache[key] = f
  end
  return fontCache[key]
end

-- ---------------------------------------------------------------- helpers
function U.set(c, a)
  lg.setColor(c[1], c[2], c[3], (c[4] or 1) * (a or 1))
end

function U.mix(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, 1 }
end

function U.rect(x, y, w, h, r, c, a)
  U.set(c, a)
  lg.rectangle("fill", x, y, w, h, r or 0, r or 0, 12)
end

function U.rectLine(x, y, w, h, r, c, width, a)
  U.set(c, a)
  lg.setLineWidth(width or 2)
  lg.rectangle("line", x, y, w, h, r or 0, r or 0, 12)
end

function U.circle(x, y, r, c, a)
  U.set(c, a)
  lg.circle("fill", x, y, r, 32)
end

-- ---------------------------------------------------------------- texto UTF-8 seguro
-- O LOVE fecha com erro se receber texto com UTF-8 invalido (ex.: um "é" cortado ao meio).
local okutf, utf8 = pcall(require, "utf8")
if not okutf then utf8 = nil end

local function scanUTF8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = (c < 0x80 and 1) or (c >= 0xC2 and c < 0xE0 and 2) or (c >= 0xE0 and c < 0xF0 and 3) or (c >= 0xF0 and c < 0xF5 and 4) or 0
    if len == 0 or i + len - 1 > n then return false end
    for k = i + 1, i + len - 1 do
      local b = s:byte(k)
      if b < 0x80 or b > 0xBF then return false end
    end
    i = i + len
  end
  return true
end

local function validUTF8(s)
  if not s:find("[\128-\255]") then return true end
  if utf8 and utf8.len then return utf8.len(s) ~= nil end
  return scanUTF8(s)
end
U.validUTF8 = validUTF8

-- troca bytes invalidos por "?"
function U.safe(s)
  s = tostring(s or "")
  if validUTF8(s) then return s end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = (c < 0x80 and 1) or (c >= 0xC2 and c < 0xE0 and 2) or (c >= 0xE0 and c < 0xF0 and 3) or (c >= 0xF0 and c < 0xF5 and 4) or 0
    local good = len > 0 and i + len - 1 <= n
    if good then
      for k = i + 1, i + len - 1 do
        local b = s:byte(k)
        if b < 0x80 or b > 0xBF then good = false end
      end
    end
    if good then
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    else
      out[#out + 1] = "?"
      i = i + 1
    end
  end
  return table.concat(out)
end

-- lista de caracteres inteiros (para cortar sem quebrar acentos)
local function chars(s)
  local t = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
  return t
end
U.chars = chars

-- texto cortado com reticencias, sempre em limite de caractere
function U.fit(font, s, maxw)
  s = U.safe(s)
  if font:getWidth(s) <= maxw then return s end
  local ell = "…"
  local cs = chars(s)
  local lo, hi = 0, #cs
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if font:getWidth(table.concat(cs, "", 1, mid) .. ell) <= maxw then lo = mid else hi = mid - 1 end
  end
  if lo == 0 then return ell end
  return table.concat(cs, "", 1, lo) .. ell
end

-- remove caracteres do comeco ate caber (campo do teclado)
function U.fitLeft(font, s, maxw)
  s = U.safe(s)
  if font:getWidth(s) <= maxw then return s end
  local cs = chars(s)
  local i = 1
  while i < #cs and font:getWidth(table.concat(cs, "", i)) > maxw do i = i + 1 end
  return table.concat(cs, "", i)
end

function U.text(s, x, y, font, c, a, maxw, align)
  s = U.safe(s)
  lg.setFont(font)
  U.set(c, a)
  if maxw then
    s = U.fit(font, s, maxw)
    if align == "center" then
      x = x + (maxw - font:getWidth(s)) / 2
    elseif align == "right" then
      x = x + maxw - font:getWidth(s)
    end
  end
  lg.print(s, math.floor(x + 0.5), math.floor(y + 0.5))
end

function U.textWidth(s, font) return font:getWidth(s) end

-- degrade horizontal simples
function U.gradientBar(x, y, w, h, c1, c2, a)
  if w <= 0 then return end
  local steps = math.max(1, math.floor(w / 3))
  for i = 0, steps - 1 do
    local t = i / steps
    U.set(U.mix(c1, c2, t), a)
    lg.rectangle("fill", x + w * t, y, w / steps + 1, h)
  end
end

-- ---------------------------------------------------------------- logo
function U.logo(x, y, size, a)
  local r = size * 0.29
  -- degrade diagonal aproximado com duas camadas
  U.rect(x, y, size, size, r, U.c.accent, a)
  U.set(U.c.accent2, (a or 1) * 0.55)
  lg.polygon("fill", x + size, y + size * 0.15, x + size, y + size - r * 0.3, x + size - r * 0.3, y + size, x + size * 0.15, y + size)
  U.circle(x + size / 2, y + size / 2, size * 0.21, U.c.bg, a)
end

function U.wordmark(x, y, size, a, center)
  local f1, f2 = U.font("l", size), U.font("b", size)
  local w = f1:getWidth("lusm") + f2:getWidth("OS") + f2:getWidth(" 4")
  if center then x = x - w / 2 end
  U.text("lusm", x, y, f1, U.c.text, a)
  x = x + f1:getWidth("lusm")
  U.text("OS", x, y, f2, U.c.text, a)
  x = x + f2:getWidth("OS")
  U.text(" 4", x, y, f2, U.c.accent2, a)
  return w
end

-- ---------------------------------------------------------------- icones (traco)
local function arc(x, y, r, a1, a2)
  lg.arc("line", "open", x, y, r, a1, a2, 16)
end

-- maiusculas que entendem acentos (string.upper so troca a-z)
local UP = { ["á"]="Á",["à"]="À",["â"]="Â",["ã"]="Ã",["é"]="É",["ê"]="Ê",["í"]="Í",["ó"]="Ó",["ô"]="Ô",["õ"]="Õ",["ú"]="Ú",["ç"]="Ç" }
function U.upper(str)
  return ((str or ""):upper():gsub("\195[\128-\191]", function(c) return UP[c] or c end))
end

function U.icon(name, x, y, s, c, a)
  U.set(c, a)
  lg.setLineWidth(math.max(1.5, s / 12))
  lg.setLineJoin("bevel")
  local h = s / 2
  local cx, cy = x + h, y + h
  if name == "grid" then
    local q = s * 0.36
    for i = 0, 1 do
      for j = 0, 1 do
        lg.rectangle("line", x + s * 0.08 + i * (q + s * 0.12), y + s * 0.08 + j * (q + s * 0.12), q, q, 2, 2)
      end
    end
  elseif name == "star" then
    local pts = {}
    for i = 0, 9 do
      local ang = -math.pi / 2 + i * math.pi / 5
      local rr = (i % 2 == 0) and h * 0.95 or h * 0.42
      pts[#pts + 1] = cx + math.cos(ang) * rr
      pts[#pts + 1] = cy + math.sin(ang) * rr
    end
    pts[#pts + 1] = pts[1]; pts[#pts + 1] = pts[2]
    lg.line(pts)
  elseif name == "starfill" then
    local pts = {}
    for i = 0, 9 do
      local ang = -math.pi / 2 + i * math.pi / 5
      local rr = (i % 2 == 0) and h * 0.95 or h * 0.42
      pts[#pts + 1] = cx + math.cos(ang) * rr
      pts[#pts + 1] = cy + math.sin(ang) * rr
    end
    -- estrela cheia em leque a partir do centro (sem triangulate)
    for i = 0, 9 do
      local j = (i + 1) % 10
      lg.polygon("fill", cx, cy, pts[i * 2 + 1], pts[i * 2 + 2], pts[j * 2 + 1], pts[j * 2 + 2])
    end
  elseif name == "wifi" then
    arc(cx, y + s * 0.92, s * 0.8, -math.pi * 0.78, -math.pi * 0.22)
    arc(cx, y + s * 0.92, s * 0.52, -math.pi * 0.75, -math.pi * 0.25)
    arc(cx, y + s * 0.92, s * 0.26, -math.pi * 0.72, -math.pi * 0.28)
  elseif name == "gear" then
    lg.circle("line", cx, cy, h * 0.32, 20)
    for i = 0, 7 do
      local ang = i * math.pi / 4
      lg.line(cx + math.cos(ang) * h * 0.55, cy + math.sin(ang) * h * 0.55, cx + math.cos(ang) * h * 0.9, cy + math.sin(ang) * h * 0.9)
    end
    lg.circle("line", cx, cy, h * 0.6, 24)
  elseif name == "power" then
    arc(cx, cy + s * 0.04, h * 0.78, -math.pi * 0.32, math.pi * 1.32)
    lg.line(cx, y + s * 0.04, cx, cy)
  elseif name == "tools" then
    lg.line(x + s * 0.2, y + s * 0.8, x + s * 0.62, y + s * 0.38)
    lg.circle("line", x + s * 0.7, y + s * 0.3, s * 0.18, 16)
    lg.line(x + s * 0.12, y + s * 0.3, x + s * 0.45, y + s * 0.3)
    lg.line(x + s * 0.12, y + s * 0.5, x + s * 0.3, y + s * 0.5)
  elseif name == "check" then
    lg.setLineWidth(math.max(2, s / 8))
    lg.line(x + s * 0.15, y + s * 0.52, x + s * 0.4, y + s * 0.76, x + s * 0.88, y + s * 0.24)
  elseif name == "download" then
    lg.setLineWidth(math.max(2, s / 10))
    lg.line(x + s * 0.5, y + s * 0.1, x + s * 0.5, y + s * 0.62)
    lg.line(x + s * 0.28, y + s * 0.42, x + s * 0.5, y + s * 0.64, x + s * 0.72, y + s * 0.42)
    lg.line(x + s * 0.12, y + s * 0.78, x + s * 0.12, y + s * 0.9, x + s * 0.88, y + s * 0.9, x + s * 0.88, y + s * 0.78)
  elseif name == "search" then
    lg.circle("line", x + s * 0.42, y + s * 0.42, s * 0.28, 24)
    lg.setLineWidth(math.max(2, s / 9))
    lg.line(x + s * 0.63, y + s * 0.63, x + s * 0.9, y + s * 0.9)
  elseif name == "list" then
    for i = 0, 2 do
      local yy = y + s * (0.2 + i * 0.3)
      lg.circle("fill", x + s * 0.14, yy, s * 0.06, 8)
      lg.line(x + s * 0.32, yy, x + s * 0.92, yy)
    end
  elseif name == "clock" then
    lg.circle("line", cx, cy, h * 0.85, 24)
    lg.line(cx, cy, cx, cy - h * 0.5)
    lg.line(cx, cy, cx + h * 0.4, cy)
  elseif name == "gamepad" then
    lg.rectangle("line", x + s * 0.05, y + s * 0.25, s * 0.9, s * 0.5, s * 0.22, s * 0.22)
    lg.line(x + s * 0.24, cy - s * 0.1, x + s * 0.24, cy + s * 0.1)
    lg.line(x + s * 0.14, cy, x + s * 0.34, cy)
    lg.circle("fill", x + s * 0.68, cy - s * 0.06, s * 0.05)
    lg.circle("fill", x + s * 0.78, cy + s * 0.06, s * 0.05)
  elseif name == "sliders" then
    lg.line(x + s * 0.1, y + s * 0.3, x + s * 0.9, y + s * 0.3)
    lg.line(x + s * 0.1, y + s * 0.7, x + s * 0.9, y + s * 0.7)
    U.circle(x + s * 0.65, y + s * 0.3, s * 0.1, c, a)
    U.circle(x + s * 0.35, y + s * 0.7, s * 0.1, c, a)
  elseif name == "play" then
    lg.polygon("fill", x + s * 0.25, y + s * 0.15, x + s * 0.25, y + s * 0.85, x + s * 0.85, cy)
  elseif name == "globe" then
    lg.circle("line", cx, cy, h * 0.85, 24)
    lg.line(x + s * 0.08, cy, x + s * 0.92, cy)
    lg.ellipse("line", cx, cy, h * 0.4, h * 0.85, 20)
  elseif name == "chevron" then
    lg.line(x + s * 0.35, y + s * 0.2, x + s * 0.65, cy, x + s * 0.35, y + s * 0.8)
  elseif name == "plus" then
    lg.line(cx, y + s * 0.2, cx, y + s * 0.8)
    lg.line(x + s * 0.2, cy, x + s * 0.8, cy)
  elseif name == "dots" then
    for i = -1, 1 do lg.circle("fill", cx + i * s * 0.28, cy, s * 0.08) end
  elseif name == "folder" then
    lg.polygon("line", x + s * 0.08, y + s * 0.25, x + s * 0.4, y + s * 0.25, x + s * 0.5, y + s * 0.35,
      x + s * 0.92, y + s * 0.35, x + s * 0.92, y + s * 0.8, x + s * 0.08, y + s * 0.8)
  end
  lg.setLineWidth(1)
end

-- ---------------------------------------------------------------- status (relogio / wifi / bateria)
U.status = { batt = nil, charging = false, wifi = nil, t = -99 }
function U.updateStatus(dt)
  local st = U.status
  st.t = st.t + dt
  if st.t > 10 or st.t < 0 then
    st.t = 0
    st.batt, st.charging = data.battery()
    st.wifi = data.wifi()
  end
end

function U.clockText()
  if data.config.clock24 then return os.date("%H:%M") end
  local h = tonumber(os.date("%I"))
  return h .. os.date(":%M %p")
end

function U.drawStatus(xr, y, c, a)
  local f = U.font("m", 14)
  local x = xr
  local t = U.clockText()
  x = x - f:getWidth(t)
  U.text(t, x, y, f, U.c.text, a)
  local st = U.status
  if st.batt then
    local bt = st.batt .. "%"
    x = x - 12 - f:getWidth(bt)
    U.text(bt, x, y, f, c, a)
    x = x - 28
    U.set(c, a)
    lg.setLineWidth(1.4)
    lg.rectangle("line", x, y + 4, 21, 12, 3, 3)
    lg.rectangle("fill", x + 22, y + 8, 2, 4)
    local fill = math.max(0.08, math.min(1, st.batt / 100))
    local fc = c
    if st.batt <= 15 and not st.charging then fc = hex("#FF6B6B") end
    U.set(fc, a)
    lg.rectangle("fill", x + 2.5, y + 6.5, 16 * fill, 7, 1.5, 1.5)
  end
  if st.wifi ~= nil then
    x = x - 26
    U.icon("wifi", x, y + 1, 18, c, st.wifi and a or (a or 1) * 0.35)
  end
end

-- dica de botao  (A) Jogar
function U.hint(x, y, btn, label, fg, bg, a)
  local f = U.font("b", 11)
  local lf = U.font("r", 13)
  local w = math.max(20, f:getWidth(btn) + 10)
  U.rect(x, y, w, 20, 10, bg, a)
  U.text(btn, x + (w - f:getWidth(btn)) / 2, y + 3, f, fg, a)
  U.text(label, x + w + 6, y + 1, lf, U.c.text2, a)
  return w + 6 + lf:getWidth(label)
end

-- desenha varias dicas alinhadas a direita
function U.hints(list, xr, y, fg, bg, a)
  local f = U.font("b", 11)
  local lf = U.font("r", 13)
  local total = 0
  for i, h in ipairs(list) do
    total = total + math.max(20, f:getWidth(h[1]) + 10) + 6 + lf:getWidth(h[2]) + (i > 1 and 16 or 0)
  end
  local x = xr - total
  for i, h in ipairs(list) do
    if i > 1 then x = x + 16 end
    x = x + U.hint(x, y, h[1], h[2], fg or U.c.bg, bg or U.c.text, a)
  end
end

-- ---------------------------------------------------------------- capas (cache de imagens)
local imgCache, imgOrder = {}, {}
U.bboxes = {}
local quads = {}
U.pendingRelease = {}
function U.beginFrame()
  if #U.pendingRelease > 0 then
    for _, o in ipairs(U.pendingRelease) do
      if o.release then pcall(o.release, o) end
    end
    U.pendingRelease = {}
  end
end
local MISSING = {}
function U.cover(path)
  if not path then return nil end
  local v = imgCache[path]
  if v == MISSING then return nil end
  if v then return v end
  -- no maximo algumas capas novas por quadro, para a rolagem nao engasgar
  if (U.coverBudget or 1) <= 0 then return nil end
  U.coverBudget = (U.coverBudget or 1) - 1
  -- usa a miniatura (pequena) quando ja existe; senao abre a original e pede a miniatura
  local src = path
  local tp = data.thumbPath(path)
  if data.exists(tp) then src = tp else data.queueThumb(path, tp) end
  local bytes = data.readfile(src)
  local img = nil
  U.bboxes[path], quads[path] = nil, nil
  if bytes and #bytes > 0 then
    local ok, res = pcall(function()
      local fd = love.filesystem.newFileData(bytes, path:match("([^/]+)$") or "img.png")
      local id = love.image.newImageData(fd)
      -- area visivel (sem a margem transparente), para as capas ocuparem o bloco inteiro
      local w, h = id:getDimensions()
      local minx, miny, maxx, maxy = w, h, -1, -1
      -- amostra no maximo ~90 pontos por lado (ler pixel a pixel e lento)
      local step = math.max(2, math.floor(math.max(w, h) / 90))
      for yy = 0, h - 1, step do
        for xx = 0, w - 1, step do
          local _, _, _, a = id:getPixel(xx, yy)
          if a > 0.08 then
            if xx < minx then minx = xx end
            if xx > maxx then maxx = xx end
            if yy < miny then miny = yy end
            if yy > maxy then maxy = yy end
          end
        end
      end
      if maxx >= minx then
        U.bboxes[path] = { minx, miny, math.min(w, maxx + step) - minx, math.min(h, maxy + step) - miny }
      end
      return lg.newImage(id)
    end)
    if ok then img = res end
  end
  imgCache[path] = img or MISSING
  imgOrder[#imgOrder + 1] = path
  if #imgOrder > 48 then
    local old = table.remove(imgOrder, 1)
    -- a imagem pode ainda estar na fila de desenho deste quadro: so e liberada
    -- no comeco do proximo quadro (U.beginFrame), quando ja foi desenhada
    local o = imgCache[old]
    if o and o ~= MISSING then U.pendingRelease[#U.pendingRelease + 1] = o end
    imgCache[old] = nil
    quads[old] = nil
  end
  return img
end

-- bloco "capa"
--  item.image + item.fill  -> icone do sistema ocupando o bloco todo
--  item.image              -> capa do jogo inteira sobre fundo escuro
--  item.sysImage           -> jogo sem capa: icone do videogame apagado + nome do jogo
--  nada                    -> bloco colorido com sigla (atalhos)
local function withClip(x, y, w, h, fn)
  local sx, sy, sw, sh = lg.getScissor()
  lg.intersectScissor(x, y, w, h)
  fn()
  if sx then lg.setScissor(sx, sy, sw, sh) else lg.setScissor() end
end
U.withClip = withClip

local function drawImage(img, x, y, w, h, mode, a, pad, path)
  local iw, ih = img:getDimensions()
  pad = pad or 0
  lg.setColor(1, 1, 1, a or 1)
  local bb = path and U.bboxes[path]
  if bb and (bb[3] < iw or bb[4] < ih) then
    local q = quads[path]
    if not q then q = lg.newQuad(bb[1], bb[2], bb[3], bb[4], iw, ih); quads[path] = q end
    local sc
    if mode == "fill" then sc = math.max(w / bb[3], h / bb[4]) else sc = math.min((w - pad * 2) / bb[3], (h - pad * 2) / bb[4]) end
    lg.draw(img, q, x + (w - bb[3] * sc) / 2, y + (h - bb[4] * sc) / 2, 0, sc, sc)
    return
  end
  local sc
  if mode == "fill" then sc = math.max(w / iw, h / ih) else sc = math.min((w - pad * 2) / iw, (h - pad * 2) / ih) end
  lg.draw(img, x + (w - iw * sc) / 2, y + (h - ih * sc) / 2, 0, sc, sc)
end
U.drawImage = drawImage

function U.tile(x, y, size, item, a, round)
  a = a or 1
  local color = item.color or (item.system and item.system.color) or U.c.line
  local r = round or 10
  local img = item.image and U.cover(item.image)
  local sysimg = (not img) and item.sysImage and U.cover(item.sysImage)
  if img and item.fill then
    -- icone do videogame: ocupa o bloco inteiro, sem moldura
    withClip(x, y, size, size, function() drawImage(img, x, y, size, size, "fill", a, 0, item.image) end)
  elseif img then
    U.rect(x, y, size, size, r, U.mix(color, U.c.black, 0.6), a)
    withClip(x, y, size, size, function() drawImage(img, x, y, size, size, "fit", a, math.max(3, size * 0.04), item.image) end)
  elseif sysimg then
    -- capa padrao "Estojo": lombada na cor do videogame com o nome na vertical,
    -- icone do videogame no meio e o nome do jogo embaixo
    U.rect(x, y, size, size, r, U.hex("#12151C"), a)
    local sw = math.max(8, math.floor(size * 0.16))
    withClip(x, y, size, size, function()
      U.rect(x, y, sw + r, size, r, color, a)
      U.rect(x + sw, y, r, size, 0, U.hex("#12151C"), a)
      if size >= 70 then
        local sname = ((item.system and (item.system.fullname or item.system.name)) or ""):upper()
        local sf = U.font("b", math.max(9, math.floor(size * 0.072)))
        local maxlen = size - 16
        local txt = U.fit(sf, sname, maxlen)
        U.set(U.c.white, a)
        lg.setFont(sf)
        lg.print(txt, x + (sw - sf:getHeight()) / 2 + 1, y + size - 8, -math.pi / 2)
      end
      local rw = size - sw
      local isz = (size >= 90) and rw * 0.42 or rw * 0.7
      local iy = (size >= 90) and (y + size * 0.1) or (y + (size - isz) / 2)
      drawImage(sysimg, x + sw + (rw - isz) / 2, iy, isz, isz, "fit", a, 0, item.sysImage)
      if size >= 90 then
        local fs = math.max(11, math.floor(size * 0.09))
        local f = U.font("b", fs)
        local _, lines = f:getWrap(U.safe(item.title or ""), rw - 18)
        local maxl = 3
        local n = math.min(#lines, maxl)
        local lh = f:getHeight() * 0.92
        for i = 1, n do
          local txt = lines[i]
          if i == maxl and #lines > maxl then txt = U.fit(f, txt .. "…", rw - 18) end
          U.text(txt, x + sw + 10, y + size - 10 - (n - i + 1) * lh, f, U.c.white, a)
        end
      end
    end)
  else
    U.rect(x, y, size, size, r, color, a)
    withClip(x, y, size, size, function()
      U.set(U.c.white, a * 0.10)
      lg.circle("fill", x + size * 0.92, y + size * 0.92, size * 0.42, 32)
    end)
    local label = item.initials or "?"
    local fs = math.max(12, math.floor(size * (#label > 3 and 0.2 or 0.27)))
    local f = U.font("b", fs)
    U.text(label, x, y + (size - f:getHeight()) / 2, f, U.c.white, a, size, "center")
  end
  if item.badge and size >= 70 and not item.fill and not img and not sysimg then
    local f = U.font("m", size >= 120 and 11 or 10)
    local w = f:getWidth(item.badge) + 14
    U.rect(x + 8, y + 8, w, 18, 9, U.c.black, a * 0.6)
    U.text(item.badge, x + 15, y + 9, f, U.c.white, a)
  end
end

function U.initials(name)
  local clean = tostring(name or ""):gsub("%b()", ""):gsub("%b[]", "")
  local out = {}
  for w in clean:gmatch("[%w']+") do
    local ch = w:sub(1, 1)
    if w:match("^%d+$") then ch = w end
    if not ({ the = 1, of = 1, ["and"] = 1, ["a"] = 1, ["o"] = 1, ["de"] = 1, ["da"] = 1, ["do"] = 1 })[w:lower()] or #out == 0 then
      out[#out + 1] = ch:upper()
    end
    if #out >= 3 then break end
  end
  return table.concat(out)
end

return U
