#!/bin/bash
# lusmOS 4 - guarda. Roda em todo boot (lusmos-guard.service) e depois de cada atualizacao.
# Se alguma atualizacao trocou arquivos do lusmOS, coloca os do lusmOS de volta.
P=/opt/lusmos/payload
LOG=/roms/lusmos-log.txt
fixed=""
log() { echo "[$(date '+%d/%m %T')] guarda: $*" >> "$LOG" 2>/dev/null; }
[ -d "$P" ] || exit 0

put() { cp -f "$1" "$2.novo" && chmod "${3:-644}" "$2.novo" && mv -f "$2.novo" "$2"; }

# 1. o inicio do sistema abre o lusmOS
D=/usr/bin/emulationstation
for f in "$D/emulationstation.sh" "$D/emulationstation.sh.es" "$D/emulationstation.sh.ra"; do
  if [ "$1" = force ] || ! grep -q "lusmos.sh" "$f" 2>/dev/null; then
    put "$P/emulationstation.sh.lusmos" "$f" 755 && fixed="$fixed inicio"
  fi
done
# 2. o boot chama o instalador do lusmOS
if [ -f /boot/firstboot.sh ] && ! grep -q "lusmos/install.sh" /boot/firstboot.sh; then
  sed -i 's|^main "\$@"|if [ -f /boot/lusmos/install.sh ]; then bash /boot/lusmos/install.sh; fi\nmain "$@"|' /boot/firstboot.sh
  fixed="$fixed firstboot"
fi
# 3. tela de boot do lusmOS
T=/usr/share/plymouth/themes
if [ -f "$P/text.plymouth" ] && ! cmp -s "$P/text.plymouth" "$T/text.plymouth"; then
  mkdir -p "$T/lusmos" && cp -f "$P"/plymouth/* "$T/lusmos/" 2>/dev/null
  put "$P/text.plymouth" "$T/text.plymouth" 644 && fixed="$fixed plymouth"
fi
# 4. nome do sistema
if [ "$(cat /etc/hostname 2>/dev/null)" != "lusmos" ]; then
  echo lusmos > /etc/hostname; hostname lusmos 2>/dev/null
  sed -i '/127.0.1.1/d' /etc/hosts; echo "127.0.1.1    lusmos" >> /etc/hosts
  fixed="$fixed nome"
fi
for f in /etc/issue /etc/issue.net /etc/motd; do
  grep -qi "arkos" "$f" 2>/dev/null && { echo "lusmOS 4" > "$f"; fixed="$fixed $f"; }
done
# 5. tela de entrada no jogo: so troca se sumiu ou se voltou a ser a original do sistema antigo
OLD="45a2f63ec6333fd5c43550c772ad0864 0fe453d4fc4a34e430d9a94ebad4425e bc80ff9c33767e1423c0360dac9bb462 00f63b55c77428cd5c88cbc19ec0bde9"
for f in loading.gif loading.mp4 loading.ascii loading.jpg; do
  [ -f "$P/launchimages/$f" ] || continue
  dst="/roms/launchimages/$f"
  sum=$(md5sum "$dst" 2>/dev/null | cut -d' ' -f1)
  if [ ! -f "$dst" ] || echo "$OLD" | grep -q "${sum:-x}"; then
    mkdir -p /roms/launchimages && cp -f "$P/launchimages/$f" "$dst" && fixed="$fixed $f"
  fi
done
# 6. a interface do lusmOS existe
[ -f /opt/lusmos/app/main.lua ] || { cp -rf "$P/app/." /opt/lusmos/app/ && fixed="$fixed interface"; }
if [ -n "$fixed" ]; then log "restaurado:$fixed"; fi
sync
exit 0
