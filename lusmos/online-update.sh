#!/bin/bash
# lusmOS 4 - atualizacao pela internet (GitHub)
#   online-update.sh check    -> escreve /tmp/lusmos_update.txt com a versao nova (ou "atual")
#   online-update.sh install  -> baixa, confere e instala a versao nova
REPO="Lucasmassaroto1/lusmOs4"
API="https://api.github.com/repos/$REPO/releases/latest"
OUT=/tmp/lusmos_update.txt
PROG=/tmp/lusmos_update_progress.txt
LOG=/roms/lusmos-log.txt
CUR=$(cat /opt/lusmos/VERSION 2>/dev/null)
log() { echo "[$(date '+%d/%m %T')] atualizacao online: $*" >> "$LOG" 2>/dev/null; }
step() { echo "$1" > "$PROG"; log "$1"; }

fetch_info() {
  local json
  json=$(curl -fsSL --max-time 12 -H "Accept: application/vnd.github+json" "$API" 2>/dev/null | tr "," "\n") || return 1
  TAG=$(echo "$json" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  NEW=${TAG#v}
  PKG=$(echo "$json" | grep '"browser_download_url"' | grep -m1 'lusmos-.*\.tar\.gz"' | sed 's/.*"\(https[^"]*\)".*/\1/')
  SUM=$(echo "$json" | grep '"browser_download_url"' | grep -m1 '\.sha256"' | sed 's/.*"\(https[^"]*\)".*/\1/')
  NOTES=$(echo "$json" | grep -m1 '"name"' | sed 's/.*"name": *"\([^"]*\)".*/\1/')
  [ -n "$NEW" ] && [ -n "$PKG" ]
}

case "$1" in
  check)
    rm -f "$OUT"
    if ! fetch_info; then echo "erro" > "$OUT"; exit 1; fi
    # as versoes sao do tipo 4-AAAA.MM.DDx: comparar como texto ja diz qual e a mais nova
    if [ "$NEW" != "$CUR" ] && [ "$(printf '%s\n%s\n' "$CUR" "$NEW" | sort | tail -n1)" = "$NEW" ]; then
      printf 'nova\n%s\n%s\n' "$NEW" "$NOTES" > "$OUT"
    else
      printf 'atual\n%s\n' "$CUR" > "$OUT"
    fi
    ;;
  install)
    rm -f "$PROG"
    step "Procurando a versão nova…"
    fetch_info || { step "ERRO: sem conexão com o GitHub"; exit 1; }
    T=/tmp/lusmos-download; rm -rf "$T"; mkdir -p "$T"
    step "Baixando lusmOS $NEW…"
    curl -fsSL --max-time 300 -o "$T/pkg.tar.gz" "$PKG" || { step "ERRO: o download falhou"; exit 1; }
    if [ -n "$SUM" ]; then
      step "Conferindo o arquivo…"
      want=$(curl -fsSL --max-time 30 "$SUM" | cut -d' ' -f1)
      got=$(sha256sum "$T/pkg.tar.gz" | cut -d' ' -f1)
      [ -n "$want" ] && [ "$want" = "$got" ] || { step "ERRO: o arquivo baixado veio corrompido"; exit 1; }
    fi
    step "Preparando…"
    mkdir -p "$T/x" && tar -xzf "$T/pkg.tar.gz" -C "$T/x" || { step "ERRO: pacote inválido"; exit 1; }
    [ -f "$T/x/lusmos/install.sh" ] && [ -f "$T/x/lusmos/VERSION" ] || { step "ERRO: pacote incompleto"; exit 1; }
    step "Copiando para o cartão…"
    # o EmulationStation nao vai no pacote: o que ja esta no cartao continua
    sudo mkdir -p /boot/lusmos
    sudo cp -rf "$T/x/lusmos/." /boot/lusmos/ || { step "ERRO: não deu para gravar no cartão"; exit 1; }
    [ -f "$T/x/boot/firstboot.sh" ] && sudo cp -f "$T/x/boot/firstboot.sh" /boot/firstboot.sh
    [ -f "$T/x/boot/logo.mp4" ] && sudo cp -f "$T/x/boot/logo.mp4" /boot/logo.mp4
    sync
    step "Instalando…"
    # o instalador reabre o lusmOS no final, ja na versao nova
    sudo bash /boot/lusmos/install.sh
    step "PRONTO $NEW"
    rm -rf "$T"
    ;;
esac
