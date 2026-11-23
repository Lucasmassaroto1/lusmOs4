#!/bin/bash
# lusmOS 4 - gera miniaturas das capas em segundo plano (prioridade baixa).
# Recebe uma lista "origem<TAB>destino" e cria cada miniatura que ainda nao existe.
# O lusmOS abre a miniatura (pequena, rapida) no lugar da capa original (grande, lenta).
Q=/tmp/lusmos_thumbq.txt
PID=/tmp/lusmos_thumbs.pid
command -v ffmpeg >/dev/null || exit 0
if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then exit 0; fi
echo $$ > "$PID"
renice -n 19 $$ >/dev/null 2>&1
ionice -c3 -p $$ >/dev/null 2>&1
while [ -s "$Q" ]; do
  W=/tmp/lusmos_thumbq.work
  mv -f "$Q" "$W"
  while IFS=$'\t' read -r src dst; do
    [ -z "$src" ] || [ ! -f "$src" ] && continue
    # ja existe e e mais nova que a capa: nada a fazer
    [ -f "$dst" ] && [ ! "$src" -nt "$dst" ] && continue
    [ -f "$dst.falhou" ] && continue
    mkdir -p "$(dirname "$dst")"
    tmp="$dst.tmp.${dst##*.}"
    if ffmpeg -nostdin -loglevel error -y -i "$src" \
        -vf "scale='min(256,iw)':'min(256,ih)':force_original_aspect_ratio=decrease" \
        -frames:v 1 "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv -f "$tmp" "$dst"
    else
      rm -f "$tmp"
      : > "$dst.falhou"
    fi
  done < "$W"
  rm -f "$W"
done
rm -f "$PID"
