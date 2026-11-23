#!/bin/bash
# lusmOS 4 - instalador/atualizador. Roda como root no boot, chamado pelo /boot/firstboot.sh.
# So instala quando a versao em /boot/lusmos/VERSION for diferente da instalada.
SRC=/boot/lusmos
NEW=$(cat "$SRC/VERSION" 2>/dev/null)
CUR=$(cat /opt/lusmos/VERSION 2>/dev/null)
[ -n "$NEW" ] && [ "$NEW" = "$CUR" ] && exit 0
exec >> /boot/lusmos_install.log 2>&1
echo "=== instalando lusmOS ${NEW:-?} (antes: ${CUR:-nenhum}) $(date)"

# copia trocando o arquivo de uma vez (nunca reescreve um arquivo que esteja em uso)
put() { cp -f "$1" "$2.novo" && chmod "${3:-644}" "$2.novo" && mv -f "$2.novo" "$2"; }

# a interface estava aberta durante a instalacao? (no fim ela e reaberta limpa)
UI_RUNNING=0
pgrep -f "/opt/lusmos/lusmos.sh|love /opt/lusmos/app" >/dev/null && UI_RUNNING=1

# ---------------------------------------------------------------- interface
mkdir -p /opt/lusmos/app/fonts /opt/lusmos/app/sounds /opt/lusmos/app/img
cp -f "$SRC"/app/*.lua /opt/lusmos/app/
cp -f "$SRC"/app/fonts/* /opt/lusmos/app/fonts/
[ -d "$SRC/app/sounds" ] && cp -f "$SRC"/app/sounds/* /opt/lusmos/app/sounds/
[ -d "$SRC/app/img" ] && cp -f "$SRC"/app/img/* /opt/lusmos/app/img/
put "$SRC/lusmos.sh" /opt/lusmos/lusmos.sh 755
chmod 755 /opt/lusmos /opt/lusmos/app /opt/lusmos/app/fonts /opt/lusmos/app/sounds /opt/lusmos/app/img /opt/lusmos/lusmos.sh
chmod 644 /opt/lusmos/app/*.lua /opt/lusmos/app/fonts/* /opt/lusmos/app/sounds/* /opt/lusmos/app/img/* 2>/dev/null
rm -f "/opt/system/Ativar lusmOS.sh"

# ---------------------------------------------------------------- inicio do sistema
# o servico de interface passa a abrir so o lusmOS (com a recuperacao do lusmOS)
D=/usr/bin/emulationstation
for f in "$D/emulationstation.sh" "$D/emulationstation.sh.es" "$D/emulationstation.sh.ra"; do
  put "$SRC/emulationstation.sh.lusmos" "$f" 755
done
rm -f "$D"/*.antes-lusmos

# ---------------------------------------------------------------- EmulationStation como app
# (abre pelo lusmOS em Ferramentas e, ao sair, volta para o lusmOS)
if [ -f "$SRC/es-bundle.tar.gz" ] && [ ! -f "$D/emulationstation" ]; then
  TMP=/tmp/lusmos-es; rm -rf "$TMP"; mkdir -p "$TMP"
  if tar -xzf "$SRC/es-bundle.tar.gz" -C "$TMP" && [ -s "$TMP/emulationstation" ]; then
    put "$TMP/emulationstation" "$D/emulationstation" 755
    rm -rf "$D/resources" && cp -r "$TMP/resources" "$D/resources"
    chown -R 1002:1002 "$D/resources" "$D/emulationstation" 2>/dev/null
    echo "EmulationStation instalado como app"
  else
    echo "ERRO: pacote do EmulationStation incompleto"
  fi
  rm -rf "$TMP"
fi
for f in es-app.sh guard.sh online-update.sh thumbs.sh; do
  [ -f "$SRC/$f" ] && put "$SRC/$f" "/opt/lusmos/$f" 755
done

# ---------------------------------------------------------------- volume na tela dentro dos jogos
# o RetroArch mostra a mensagem que o lusmOS manda (interface de comandos na porta 55355)
for cfg in /home/ark/.config/retroarch/retroarch.cfg /home/ark/.config/retroarch32/retroarch.cfg; do
  [ -f "$cfg" ] || continue
  if grep -q '^network_cmd_enable' "$cfg"; then
    sed -i 's/^network_cmd_enable.*/network_cmd_enable = "true"/' "$cfg"
  else
    echo 'network_cmd_enable = "true"' >> "$cfg"
  fi
  grep -q '^network_cmd_port' "$cfg" || echo 'network_cmd_port = "55355"' >> "$cfg"
  echo "comandos do RetroArch ativados em $cfg"
done
if [ -f "$SRC/osd.sh" ]; then
  put "$SRC/osd.sh" /opt/lusmos/osd.sh 755
  put "$SRC/lusmos-osd.service" /etc/systemd/system/lusmos-osd.service 644
  systemctl daemon-reload 2>/dev/null
  systemctl enable lusmos-osd.service 2>/dev/null
  systemctl restart lusmos-osd.service 2>/dev/null &
  echo "volume na tela dentro dos jogos ativado"
fi

# ---------------------------------------------------------------- guarda do lusmOS
# copia do que e do lusmOS, para a guarda reaplicar se uma atualizacao trocar algo
P=/opt/lusmos/payload
rm -rf "$P" && mkdir -p "$P/plymouth" "$P/launchimages" "$P/app"
cp -f "$SRC/emulationstation.sh.lusmos" "$P/"
cp -f "$SRC"/plymouth/* "$P/plymouth/" 2>/dev/null
cp -f "$SRC"/launchimages/* "$P/launchimages/" 2>/dev/null
cp -rf /opt/lusmos/app/. "$P/app/"
if [ -f "$SRC/lusmos-guard.service" ]; then
  put "$SRC/lusmos-guard.service" /etc/systemd/system/lusmos-guard.service 644
  systemctl daemon-reload 2>/dev/null
  systemctl enable lusmos-guard.service 2>/dev/null && echo "guarda do lusmOS ativada"
fi

# ---------------------------------------------------------------- nome do sistema
echo "lusmos" > /etc/hostname
hostname lusmos 2>/dev/null
sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1    lusmos" >> /etc/hosts
printf 'lusmOS 4 \\n \\l\n\n' > /etc/issue
echo "lusmOS 4" > /etc/issue.net
echo "lusmOS 4" > /etc/motd
for f in /etc/update-motd.d/*; do [ -f "$f" ] && chmod -x "$f"; done
if [ -f /etc/lsb-release ]; then
  sed -i 's/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION="lusmOS 4"/' /etc/lsb-release
fi
if [ -f /etc/os-release ] && [ ! -L /etc/os-release ]; then
  sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="lusmOS 4"/' /etc/os-release
fi

# ---------------------------------------------------------------- tela de boot do lusmOS
T=/usr/share/plymouth/themes
if [ -d "$SRC/plymouth" ] && [ -f "$T/text.plymouth" ]; then
  mkdir -p "$T/lusmos"
  rm -f "$T/lusmos/logo.png"
  cp -f "$SRC"/plymouth/* "$T/lusmos/"
  chmod 755 "$T/lusmos"; chmod 644 "$T"/lusmos/*
  cat > "$T/text.plymouth" <<EOT
[Plymouth Theme]
Name=lusmOS
Description=lusmOS 4
ModuleName=script

[script]
ImageDir=$T/lusmos
ScriptFile=$T/lusmos/lusmos.script

[ubuntu-text]
title=lusmOS 4
EOT
  rm -f "$T/text.plymouth.antes-lusmos" "$T/text.plymouth.orig"
  cp -f "$T/text.plymouth" "$P/text.plymouth"
  echo "tela de boot do lusmOS instalada"
fi

mkdir -p /home/ark/.config/lusmos
rm -f /home/ark/.config/lusmos/use_es
chown -R 1002:1002 /home/ark/.config/lusmos
[ -n "$NEW" ] && echo "$NEW" > /opt/lusmos/VERSION
sync
touch "$SRC/.instalado"
echo "=== lusmOS ${NEW:-?} instalado"
if [ "$UI_RUNNING" = 1 ]; then
  # fecha tudo o que estava aberto com os arquivos antigos e abre uma copia so, ja atualizada
  echo "interface estava aberta: reabrindo"
  rm -f /tmp/lusmos_state.lua /tmp/lusmos_counts.lua
  systemctl --no-block restart emulationstation.service
fi
exit 0
