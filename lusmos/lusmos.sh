#!/bin/bash
# lusmOS 4 - roda a interface do lusmOS.
# A interface escreve em /tmp/lusmos_next o que deve ser executado
# (jogo, ferramenta, reiniciar ou desligar) e fecha.
# Este script executa e abre a interface de novo.

LUSMOS_DIR=/opt/lusmos
NEXT=/tmp/lusmos_next
LOG=/roms/lusmos-log.txt   # fica no cartao (EASYROMS) para dar para ler no PC

export SDL_ASSERT="always_ignore"
export TERM=linux
export XDG_RUNTIME_DIR=/run/user/$UID/
export LD_LIBRARY_PATH="/opt/love2d/lib:$LD_LIBRARY_PATH"
export SDL_GAMECONTROLLERCONFIG_FILE="/opt/love2d/gamecontrollerdb.txt"

sudo chmod 666 /dev/tty1 2>/dev/null

clear_tty() { printf "\033c" > /dev/tty1 2>/dev/null; }
log() { echo "[$(date '+%d/%m %T')] $*" >> "$LOG" 2>/dev/null; }

# so pode existir uma copia do lusmOS: fecha qualquer outra que tenha ficado aberta
PIDFILE=/tmp/lusmos.pid
old=$(cat "$PIDFILE" 2>/dev/null)
if [ -n "$old" ] && [ "$old" != "$$" ] && grep -q "lusmos.sh" "/proc/$old/cmdline" 2>/dev/null; then
  kill "$old" 2>/dev/null
fi
echo $$ > "$PIDFILE"
pkill -f "love $LUSMOS_DIR/app" 2>/dev/null

# registro: guarda so o final quando ficar grande
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 200000 ]; then
  tail -c 100000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi
log "=== lusmOS iniciado (versao $(cat $LUSMOS_DIR/VERSION 2>/dev/null)) pid $$ recuperacao=${LUSMOS_RECOVERY:-0}"

fails=0
while true; do
  rm -f "$NEXT"
  clear_tty
  t0=$(date +%s)
  (cd /opt/love2d && ./love "$LUSMOS_DIR/app") >> "$LOG" 2>&1
  rc=$?
  # a recuperacao so abre uma vez por boot
  unset LUSMOS_RECOVERY

  kind=""
  cmd=""
  if [ -f "$NEXT" ]; then
    kind=$(head -n 1 "$NEXT")
    cmd=$(tail -n +2 "$NEXT")
  fi
  log "interface fechou (codigo $rc, $(( $(date +%s) - t0 ))s): ${kind:-sem comando}"

  case "$kind" in
    game|tool)
      fails=0
      # nada pesado em segundo plano durante o jogo (miniaturas das capas param e voltam depois)
      tp=$(cat /tmp/lusmos_thumbs.pid 2>/dev/null)
      if [ -n "$tp" ]; then pkill -P "$tp" 2>/dev/null; kill "$tp" 2>/dev/null; rm -f /tmp/lusmos_thumbs.pid; fi
      clear_tty
      log "$kind: $cmd"
      bash -c "$cmd"
      log "$kind terminou (codigo $?)"
      clear_tty
      ;;
    reboot)
      log "reiniciando"
      sync
      sudo systemctl reboot
      exit 0
      ;;
    poweroff)
      log "desligando"
      sync
      sudo systemctl poweroff
      exit 0
      ;;
    *)
      # a interface fechou com erro: abre de novo; depois de 3 falhas abre a recuperacao
      fails=$((fails + 1))
      [ -f /tmp/lusmos_error.log ] && { cat /tmp/lusmos_error.log >> "$LOG"; rm -f /tmp/lusmos_error.log; }
      if [ $fails -ge 3 ]; then
        fails=0
        export LUSMOS_RECOVERY=1
        rm -f /tmp/lusmos_state.lua
      fi
      sleep 1
      ;;
  esac
done
