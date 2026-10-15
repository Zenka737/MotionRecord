#!/bin/bash
# Прогресс-бар докачки ffmpeg: проценты и МБ из МБ. Использование: watch_download.sh <файл> [URL]
F="${1:?файл}"
URL="${2:-https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip}"
TOTAL=$(curl -sIL "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
[ -z "$TOTAL" ] && { echo "не удалось узнать размер"; exit 1; }
TM=$(( TOTAL / 1048576 ))
while true; do
  S=$(stat -f %z "$F" 2>/dev/null || echo 0)
  P=$(( S * 100 / TOTAL )); N=$(( P * 40 / 100 ))
  BAR=$(printf '%*s' "$N" '' | tr ' ' '#')$(printf '%*s' $((40 - N)) '' | tr ' ' '.')
  printf '\r[%s] %3d%%  %d МБ из %d МБ ' "$BAR" "$P" $(( S / 1048576 )) "$TM"
  [ "$S" -ge "$TOTAL" ] && { echo; echo "Готово"; break; }
  sleep 1
done
