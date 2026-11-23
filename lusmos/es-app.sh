#!/bin/bash
# lusmOS 4 - abre o EmulationStation como aplicativo. Ao sair dele, volta para o lusmOS.
export SDL_ASSERT="always_ignore"
export TERM=linux
export XDG_RUNTIME_DIR=/run/user/$UID/
sudo chmod 666 /dev/tty1 2>/dev/null
printf "\033c" > /dev/tty1 2>/dev/null
cd /usr/bin/emulationstation || exit 1
ret=0
while true; do
  rm -f /tmp/es-restart /tmp/es-sysrestart /tmp/es-shutdown
  ./emulationstation
  ret=$?
  [ -f /tmp/es-restart ] && continue
  if [ -f /tmp/es-sysrestart ]; then rm -f /tmp/es-sysrestart; sync; sudo systemctl reboot; fi
  if [ -f /tmp/es-shutdown ]; then rm -f /tmp/es-shutdown; sync; sudo systemctl poweroff; fi
  break
done
# o EmulationStation pode ter mudado nomes, coleções e jogos: o lusmOS recarrega tudo
rm -f /tmp/lusmos_counts.lua
printf "\033c" > /dev/tty1 2>/dev/null
exit $ret
