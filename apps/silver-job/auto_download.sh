#!/usr/bin/env bash
set -euo pipefail

# DEBUG=1 ./auto_download.sh URL — покажет каждую выполняемую команду
if [ "${DEBUG:-0}" = "1" ]; then set -x; fi

# при любом падении сообщаем, на какой строке это случилось
trap 'echo "ERROR: скрипт упал на строке $LINENO (код $?)" >&2' ERR

usage() {
  echo "Usage:"
  echo "  $0 [--delete] <episode_url>                              скачать один выпуск"
  echo "    пример: $0 https://silver.ru/episodes/den-idealnoy-semi/"
  echo "  $0 [--delete] <program_url> <DD.MM.YYYY> <DD.MM.YYYY>     скачать все выпуски программы за период"
  echo "    пример: $0 https://silver.ru/programs/zavtrak-do-obeda/ 01.01.2026 01.03.2026"
  echo "  $0 --auto                                                 догнать выпуски, которых нет в плейлисте (для cron)"
  echo "    нужны PROGRAM_URL и PLAYLIST (см. переменные ниже); --auto включает --delete"
  echo "  --delete   удалять локальные файлы выпуска сразу после успешной загрузки в S3"
  echo ""
  echo "Переменные окружения:"
  echo "  S3_MOUNT         если задана — файл копируется в этот каталог (s3fs), иначе aws s3 cp"
  echo "  PLAYLIST         файл плейлиста (по одному пути на строку)"
  echo "  PLAYLIST_PREFIX  префикс пути в плейлисте (по умолчанию /music/s3)"
  echo "  PROGRAM_URL      страница программы для режима --auto"
  exit 1
}

DELETE_AFTER_UPLOAD=0
AUTO=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --delete) DELETE_AFTER_UPLOAD=1 ;;
    --auto) AUTO=1; DELETE_AFTER_UPLOAD=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

if [ "$AUTO" = "1" ]; then
  [ "$#" -eq 0 ] || usage
  : "${PROGRAM_URL:?PROGRAM_URL не задан}"
  : "${PLAYLIST:?PLAYLIST не задан}"
elif [ "$#" -ne 1 ] && [ "$#" -ne 3 ]; then
  usage
fi

S3_BUCKET="${S3_BUCKET:-radio-fed-bucket}"
S3_MOUNT="${S3_MOUNT:-}"
PLAYLIST="${PLAYLIST:-}"
PLAYLIST_PREFIX="${PLAYLIST_PREFIX:-/music/s3}"

BASE_URL="https://silver.ru"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
ARTIST="Петя FM"
BASE_DIR="$PWD"

########################################
# Загрузка файла с компактным прогрессом
########################################
# wget без tty пишет строку на каждые 50 КБ и забивает логи, поэтому запускаем его тихо
# и раз в PROGRESS_INTERVAL секунд печатаем одну строку с размером и процентами.
# Использует WGET_OPTS из download_episode (динамическая область видимости bash).

PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-30}"

download_file() {
  local URL="$1" OUT="$2" TOTAL PID
  TOTAL=$(curl -sIL --connect-timeout 10 --max-time 30 -A "$UA" "$URL" \
    | awk 'tolower($1) == "content-length:" {v = $2 + 0} END {print v + 0}' || true)
  TOTAL="${TOTAL:-0}"

  wget -q "${WGET_OPTS[@]}" "$URL" -O "$OUT" &
  PID=$!

  while kill -0 "$PID" 2>/dev/null; do
    sleep "$PROGRESS_INTERVAL"
    kill -0 "$PID" 2>/dev/null || break
    stat -c %s "$OUT" 2>/dev/null | awk -v name="$OUT" -v total="$TOTAL" '{
      cur = $1 / 1048576
      if (total > 0) printf "  %s: %.1f / %.1f МиБ (%d%%)\n", name, cur, total / 1048576, $1 * 100 / total
      else printf "  %s: %.1f МиБ\n", name, cur
    }' || true
  done

  wait "$PID" || return 1
  echo "  $OUT: готово, $(stat -c %s "$OUT" | awk '{printf "%.1f", $1 / 1048576}') МиБ"
}

########################################
# Скачивание одного выпуска по ссылке на его страницу
########################################

download_episode() {
  local PAGE_URL="$1"
  local WGET_OPTS=(-c --user-agent="$UA" --referer="$PAGE_URL" --timeout=30 --tries=5)

  cd "$BASE_DIR"

  # забираем HTML один раз
  echo "Fetching page: $PAGE_URL"
  local HTML
  if ! HTML=$(curl -fsSL \
        --connect-timeout 10 --max-time 30 \
        -A "$UA" \
        "$PAGE_URL"); then
    echo "ERROR: не удалось скачать страницу $PAGE_URL" >&2
    return 1
  fi

  if [ -z "$HTML" ]; then
    echo "ERROR: страница вернула пустой ответ" >&2
    return 1
  fi
  echo "Page fetched: ${#HTML} bytes"

  ########################################
  # 0. Извлекаем русский заголовок из HTML
  ########################################

  # Пробуем JSON-LD: "headline":"...", потом <title>
  local EPISODE_TITLE
  EPISODE_TITLE=$(printf '%s\n' "$HTML" \
    | grep -o '"headline":"[^"]*"' \
    | head -1 \
    | sed 's/"headline":"//;s/"$//' || true)

  if [ -z "${EPISODE_TITLE:-}" ]; then
    EPISODE_TITLE=$(printf '%s\n' "$HTML" \
      | grep -oP '(?<=<title>)[^<]+' \
      | head -1 \
      | sed 's/ *[|—–-].*$//' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
  fi

  echo "Episode title: ${EPISODE_TITLE:-не найден}"

  ########################################
  # 1. Достаём дату выпуска для имени папки и файла
  ########################################

  # "datePublished":"2026-07-18T...
  local RAW_DATE FOLDER
  RAW_DATE=$(printf '%s\n' "$HTML" \
    | grep -o '"datePublished":"[0-9-]\+T' \
    | sed -E 's/\"datePublished\":\"([0-9-]+)T/\1/' \
    | sed -n '1p' || true)

  if [ -z "${RAW_DATE:-}" ]; then
    echo "WARNING: datePublished not found, using 'unknown-date'"
    FOLDER="unknown-date"
    if [ "$AUTO" = "1" ]; then
      echo "ERROR: в режиме --auto выпуск без даты не загружаем" >&2
      return 1
    fi
  else
    FOLDER=$(date -d "$RAW_DATE" +"%Y-%m-%d" 2>/dev/null || echo "$RAW_DATE")
  fi

  echo "Episode date: ${RAW_DATE:-unknown}, folder: $FOLDER"

  mkdir -p "$FOLDER"
  cd "$FOLDER"

  # имя итогового mp3
  local OUT_MP3="${FOLDER}.mp3"
  local LIST_FILE="list.txt"
  : > "$LIST_FILE"   # очищаем/создаем list.txt

  ########################################
  # 2. Качаем все части из data-episode-url (в порядке на странице)
  ########################################
  # Сейчас на странице: первая часть — плеер, части 2..N — кнопки «Часть N»,
  # у всех один и тот же атрибут data-episode-url. Дубли отбрасываем.

  local -a PART_URLS=()
  mapfile -t PART_URLS < <(printf '%s\n' "$HTML" \
    | grep -oE 'data-episode-url="[^"]+\.mp3"' \
    | sed -E 's/data-episode-url="([^"]+)"/\1/' \
    | awk '!seen[$0]++' || true)

  local PART_COUNT=${#PART_URLS[@]} N REL
  if [ "$PART_COUNT" -eq 0 ]; then
    echo "WARNING: no data-episode-url found"
  fi
  for ((N = 1; N <= PART_COUNT; N++)); do
    REL="${PART_URLS[$((N - 1))]}"
    echo "Downloading part $N/$PART_COUNT: $BASE_URL$REL -> ${N}.mp3"
    download_file "$BASE_URL$REL" "${N}.mp3" || { echo "ERROR: не скачалась ${N}.mp3" >&2; return 1; }
    printf "file '%s'\n" "${N}.mp3" >> "$LIST_FILE"
  done

  ########################################
  # 3. Качаем остальные части (список «Аудиозапись»)
  ########################################

  if [ "$PART_COUNT" -le 1 ]; then   # старая вёрстка: остальные части в списке «Аудиозапись»
  printf '%s\n' "$HTML" \
    | awk -F'"' '/class="red audio bigaudio"/ {print $2, $4}' \
    | while read -r href title; do
        URL="$BASE_URL$href"
        PART=$(echo "$title" | sed -E 's/.*_([0-9]+)\.mp3/\1/')
        if [ -z "$PART" ]; then
          OUT="$title"
        else
          OUT="${PART}.mp3"
        fi

        echo "Downloading $URL -> $OUT (title: $title)"
        download_file "$URL" "$OUT" || { echo "ERROR: не скачалась часть $OUT" >&2; exit 1; }

        # Добавляем в список для ffmpeg в порядке скачивания
        printf "file '%s'\n" "$OUT" >> "$LIST_FILE"
      done || { echo "ERROR: не все части выпуска скачались" >&2; return 1; }
  fi

  ########################################
  # 4. Склейка mp3-частей без перекодирования
  ########################################

  if [ ! -s "$LIST_FILE" ]; then
    echo "ERROR: list.txt is empty, nothing to concat." >&2
    return 1
  fi

  echo "Concatenating (no re-encode) to MP3: $OUT_MP3"
  ffmpeg -y -f concat -safe 0 -i "$LIST_FILE" -c copy \
    -metadata artist="$ARTIST" \
    -metadata title="${EPISODE_TITLE:-}" \
    "$OUT_MP3" || { echo "ERROR: ffmpeg завершился с ошибкой" >&2; return 1; }

  echo "Done. Files are in: $PWD"
  echo "Output: $OUT_MP3"

  ########################################
  # 5. Загрузка итогового MP3 в S3
  ########################################

  local S3_KEY="${OUT_MP3}"

  if [ -n "$S3_MOUNT" ]; then
    echo "Copying to ${S3_MOUNT}/${S3_KEY}"
    if command -v pv >/dev/null 2>&1; then
      # прогресс-бар в stderr; -f нужен, потому что в поде нет tty; обновление раз в 5 секунд
      pv -f -i 5 -N "$OUT_MP3" "$OUT_MP3" > "${S3_MOUNT}/${S3_KEY}" || return 1
    else
      cp "$OUT_MP3" "${S3_MOUNT}/${S3_KEY}" || return 1
    fi
    chown 1000:1000 "${S3_MOUNT}/${S3_KEY}" 2>/dev/null || true
    # размер на диске и в s3fs должен совпасть, иначе загрузка оборвалась
    if [ "$(stat -c %s "$OUT_MP3")" != "$(stat -c %s "${S3_MOUNT}/${S3_KEY}")" ]; then
      echo "ERROR: размер ${S3_MOUNT}/${S3_KEY} не совпал с локальным файлом" >&2
      return 1
    fi
    echo "Copied: ${S3_MOUNT}/${S3_KEY}"
  else
    echo "Uploading to s3://${S3_BUCKET}/${S3_KEY}"
    aws s3 cp "$OUT_MP3" "s3://${S3_BUCKET}/${S3_KEY}" || return 1
    echo "Uploaded: s3://${S3_BUCKET}/${S3_KEY}"
  fi

  ########################################
  # 5b. Добавление в конец плейлиста
  ########################################

  if [ -n "$PLAYLIST" ]; then
    local ENTRY="${PLAYLIST_PREFIX}/${S3_KEY}"
    if grep -qxF "$ENTRY" "$PLAYLIST"; then
      echo "Playlist already contains: $ENTRY"
    else
      # если файл не заканчивается переводом строки, добавляем его, чтобы не склеить строки
      if [ -s "$PLAYLIST" ] && [ -n "$(tail -c1 "$PLAYLIST")" ]; then
        printf '\n' >> "$PLAYLIST"
      fi
      printf '%s\n' "$ENTRY" >> "$PLAYLIST"
      echo "Playlist: added $ENTRY"
    fi
  fi

  ########################################
  # 6. Удаление локальных файлов (--delete)
  ########################################

  if [ "$DELETE_AFTER_UPLOAD" = "1" ]; then
    cd "$BASE_DIR"
    echo "Removing local files: $FOLDER"
    rm -rf "$FOLDER"
  fi
}

########################################
# Скачивание всех выпусков программы за диапазон дат
########################################

download_range() {
  local PROGRAM_URL="$1" FROM_STR="$2" TO_STR="$3"

  local FROM_ISO TO_ISO FROM_EPOCH TO_EPOCH
  FROM_ISO=$(echo "$FROM_STR" | sed -E 's#([0-9]{2})\.([0-9]{2})\.([0-9]{4})#\3-\2-\1#')
  TO_ISO=$(echo "$TO_STR" | sed -E 's#([0-9]{2})\.([0-9]{2})\.([0-9]{4})#\3-\2-\1#')
  FROM_EPOCH=$(date -d "$FROM_ISO" +%s)
  TO_EPOCH=$(date -d "$TO_ISO" +%s)

  if [ "$FROM_EPOCH" -gt "$TO_EPOCH" ]; then
    echo "ERROR: дата начала позже даты окончания" >&2
    exit 1
  fi

  echo "Fetching program page: $PROGRAM_URL"
  local PROGRAM_HTML
  PROGRAM_HTML=$(curl -fsSL --connect-timeout 10 --max-time 30 -A "$UA" "$PROGRAM_URL")

  local PROGRAM_ID
  PROGRAM_ID=$(printf '%s' "$PROGRAM_HTML" \
    | grep -oE 'data-program-ids="[0-9]+"' \
    | head -1 \
    | grep -oE '[0-9]+')

  if [ -z "${PROGRAM_ID:-}" ]; then
    echo "ERROR: не удалось определить program_ids на странице $PROGRAM_URL" >&2
    exit 1
  fi
  echo "Program ID: $PROGRAM_ID"

  # список ссылок на выпуски, попавшие в диапазон дат (пока в порядке от новых к старым)
  local -a EPISODE_URLS=()
  local OFFSET=0 LIMIT=50 HAS_MORE STOP=0

  while :; do
    echo "Loading episodes list: offset=$OFFSET"
    local JSON PAGE_HTML
    JSON=$(curl -fsSL -A "$UA" \
      "$BASE_URL/local/php_interface/ajax/load_episodes.php?program_ids=${PROGRAM_ID}&offset=${OFFSET}&layout=list&limit=${LIMIT}")
    PAGE_HTML=$(printf '%s' "$JSON" | jq -r '.html')
    HAS_MORE=$(printf '%s' "$JSON" | jq -r '.hasMore')

    local -a HREFS DATES
    mapfile -t HREFS < <(printf '%s' "$PAGE_HTML" | grep -oE 'href="/episodes/[^"]+/"' | sed -E 's/href="(.*)"/\1/')
    mapfile -t DATES < <(printf '%s' "$PAGE_HTML" | grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}')

    if [ "${#HREFS[@]}" -eq 0 ]; then
      break
    fi

    local i EP_HREF EP_DATE EP_ISO EP_EPOCH
    for ((i = 0; i < ${#HREFS[@]}; i++)); do
      EP_HREF="${HREFS[$i]}"
      EP_DATE="${DATES[$i]}"
      EP_ISO=$(echo "$EP_DATE" | sed -E 's#([0-9]{2})\.([0-9]{2})\.([0-9]{4})#\3-\2-\1#')
      EP_EPOCH=$(date -d "$EP_ISO" +%s)

      if [ "$EP_EPOCH" -gt "$TO_EPOCH" ]; then
        continue
      fi
      if [ "$EP_EPOCH" -lt "$FROM_EPOCH" ]; then
        STOP=1
        break
      fi
      EPISODE_URLS+=("${BASE_URL}${EP_HREF}")
    done

    if [ "$STOP" -eq 1 ] || [ "$HAS_MORE" != "true" ]; then
      break
    fi
    OFFSET=$((OFFSET + LIMIT))
  done

  if [ "${#EPISODE_URLS[@]}" -eq 0 ]; then
    echo "Выпусков за период $FROM_STR - $TO_STR не найдено"
    return 0
  fi

  echo "Найдено выпусков за период $FROM_STR - $TO_STR: ${#EPISODE_URLS[@]}"

  # разворачиваем список, чтобы качать от старых выпусков к новым
  local -a ORDERED=()
  for ((i = ${#EPISODE_URLS[@]} - 1; i >= 0; i--)); do
    ORDERED+=("${EPISODE_URLS[$i]}")
  done

  local URL FAILED=0
  for URL in "${ORDERED[@]}"; do
    echo "========================================"
    echo "Episode: $URL"
    if ! download_episode "$URL"; then
      FAILED=$((FAILED + 1))
      if [ "$AUTO" = "1" ]; then
        # порядок в плейлисте важен, а «последняя дата» определяет следующий запуск:
        # пропущенный выпуск не должен остаться позади более нового
        echo "ERROR: не удалось скачать $URL, останавливаюсь (повтор при следующем запуске)" >&2
        break
      fi
      echo "WARNING: не удалось скачать $URL, пропускаю" >&2
    fi
    sleep 1
  done

  echo "========================================"
  echo "Готово. Скачано: $((${#ORDERED[@]} - FAILED)) из ${#ORDERED[@]}"
  [ "$FAILED" -eq 0 ] || return 1
}

########################################
# Режим --auto: от последней даты в плейлисте до сегодня
########################################

download_auto() {
  [ -f "$PLAYLIST" ] || { echo "ERROR: плейлист $PLAYLIST не найден" >&2; return 1; }

  local LAST
  LAST=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$PLAYLIST" | sort | tail -1 || true)
  if [ -z "$LAST" ]; then
    echo "ERROR: в плейлисте нет ни одной записи с датой" >&2
    return 1
  fi
  echo "Последняя передача в плейлисте: $LAST"

  local FROM TODAY
  if [ "$(date -d "$LAST + 1 day" +%s)" -gt "$(date +%s)" ]; then
    echo "Плейлист актуален, качать нечего"
    return 0
  fi
  FROM=$(date -d "$LAST + 1 day" +%d.%m.%Y)
  TODAY=$(date +%d.%m.%Y)
  download_range "$PROGRAM_URL" "$FROM" "$TODAY"
}

########################################
# Точка входа
########################################

if [ "$AUTO" = "1" ]; then
  download_auto
elif [ "$#" -eq 1 ]; then
  download_episode "$1"
else
  download_range "$1" "$2" "$3"
fi
