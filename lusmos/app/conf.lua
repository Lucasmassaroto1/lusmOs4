-- O compilador JIT do LuaJIT tem falhas conhecidas em ARM 32 bits (RK3326): gerava
-- erros sem sentido e derrubava o lusmOS. O interpretador e rapido o bastante para a interface.
if jit then jit.off(); jit.flush() end

function love.conf(t)
  t.identity = "lusmos"
  t.version = "11.4"
  t.console = false
  t.window.title = "lusmOS 4"
  t.window.width = 640
  t.window.height = 480
  t.window.fullscreen = (os.getenv("LUSMOS_WINDOWED") == nil)
  t.window.vsync = 1
  t.window.borderless = true
  t.modules.physics = false
  t.modules.video = false
  t.modules.touch = false
  t.modules.mouse = false
  t.modules.audio = true
  t.modules.sound = true
end
