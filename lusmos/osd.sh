#!/bin/bash
# lusmOS 4 - mostra o volume dentro dos jogos do RetroArch.
# Escuta as mudancas do volume do sistema e manda a mensagem para o RetroArch
# (comando SHOW_MSG da interface de comandos, porta 55355).
pct() { amixer sget Playback 2>/dev/null | awk -F'[][]' '/Left:/ { gsub("%", "", $2); print $2; exit }'; }
show() {
  local v n bar rest
  v=$(pct)
  [ -z "$v" ] && return
  pgrep -x retroarch >/dev/null || pgrep -x retroarch32 >/dev/null || return
  n=$(( v / 5 ))
  bar=$(printf '%*s' "$n" '' | tr ' ' '|')
  rest=$(printf '%*s' $(( 20 - n )) '' | tr ' ' '.')
  printf 'SHOW_MSG Volume %s%%   [%s%s]' "$v" "$bar" "$rest" > /dev/udp/127.0.0.1/55355 2>/dev/null
}
while true; do
  stdbuf -oL amixer events 2>/dev/null | while read -r line; do
    case "$line" in *Playback*|*value*|*VALUE*) ;; *) continue ;; esac
    # espera os botoes pararem (segurar o volume gera varios eventos) e mostra uma vez
    while read -r -t 0.15 more; do :; done
    show
  done
  sleep 2
done
