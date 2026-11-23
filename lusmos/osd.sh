#!/bin/bash
# lusmOS 4 - servico do volume.
#  - Ao ligar, coloca de volta o ultimo volume salvo.
#  - Salva o volume sempre que ele muda (inclusive dentro dos jogos).
#  - Nos jogos do RetroArch, mostra o volume na tela (comando SHOW_MSG, porta 55355).
# O volume usa a escala "mapeada" (-M), que segue o ouvido.
VOLFILE=/home/ark/.config/lusmos/volume
pct() { amixer -M sget Playback 2>/dev/null | awk -F'[][]' '/Left:/ { gsub("%", "", $2); print $2; exit }'; }
save() {
  local v=$1
  mkdir -p "$(dirname "$VOLFILE")"
  [ "$(cat "$VOLFILE" 2>/dev/null)" = "$v" ] && return
  echo "$v" > "$VOLFILE" && chown 1002:1002 "$VOLFILE" 2>/dev/null
}
show() {
  local v=$1 n bar rest
  pgrep -x retroarch >/dev/null || pgrep -x retroarch32 >/dev/null || return
  n=$(( v / 5 ))
  bar=$(printf '%*s' "$n" '' | tr ' ' '|')
  rest=$(printf '%*s' $(( 20 - n )) '' | tr ' ' '.')
  printf 'SHOW_MSG Volume %s%%   [%s%s]' "$v" "$bar" "$rest" > /dev/udp/127.0.0.1/55355 2>/dev/null
}

# volta o ultimo volume salvo
saved=$(grep -o '[0-9]*' "$VOLFILE" 2>/dev/null | head -n1)
[ -n "$saved" ] && amixer -q -M sset Playback "${saved}%" 2>/dev/null

while true; do
  stdbuf -oL amixer events 2>/dev/null | while read -r line; do
    case "$line" in *Playback*|*value*|*VALUE*) ;; *) continue ;; esac
    # espera os botoes pararem (segurar o volume gera varios eventos)
    while read -r -t 0.15 more; do :; done
    v=$(pct)
    [ -z "$v" ] && continue
    save "$v"
    show "$v"
  done
  sleep 2
done
