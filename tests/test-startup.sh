#!/usr/bin/env bash
# ============================================================================
# Тест двух правок по живому прогону 26.07 — тех, что чинят «офис не встаёт сам»:
#   wait-ready.sh — не объявлять готовность раньше времени, поднимать упавшую службу;
#   watchdog.sh   — лечить службу, упавшую в failed (раньше он на ней сразу выходил).
#
# systemd на Маке нет, поэтому systemctl подменяется заглушкой: она держит
# состояние службы в файле, пишет журнал вызовов и меняет состояние на start.
# Проверяем поведение наших скриптов, а не systemd.
#
# Запуск: bash projects/office-boilerplate/tests/test-startup.sh
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
mkdir -p "$HOME/.openclaw"

STATE_FILE="$WORK/state"          # что отвечает is-active
RESTARTS_FILE="$WORK/restarts"    # что отвечает show -p NRestarts
CALLS="$WORK/calls"               # журнал вызовов systemctl
START_BECOMES="$WORK/start_becomes"  # в какое состояние переходить на start

# ─── Заглушка systemctl ─────────────────────────────────────────────────────
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
args="$*"
case "$args" in
  *is-active*)  cat "$STATE_FILE"; [ "$(cat "$STATE_FILE")" = "active" ] && exit 0 || exit 3 ;;
  *is-failed*)  [ "$(cat "$STATE_FILE")" = "failed" ] && exit 0 || exit 1 ;;
  *NRestarts*)  cat "$RESTARTS_FILE" ;;
  *reset-failed*) echo inactive > "$STATE_FILE" ;;
  *start*)      cat "$START_BECOMES" > "$STATE_FILE" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/systemctl"
# journalctl молчит — как на реальном сервере (user-journald пуст)
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/journalctl"; chmod +x "$WORK/bin/journalctl"
export PATH="$WORK/bin:$PATH"
export CALLS STATE_FILE RESTARTS_FILE START_BECOMES

fail() { printf '\n❌ %s\n' "$1"; exit 1; }
reset_stub() { : > "$CALLS"; echo 0 > "$RESTARTS_FILE"; echo active > "$START_BECOMES"; }

echo "=== Тест: старт офиса и сторож ==="

# ─── 1. Служба уже работает и не перезапускается → готово, быстро ───────────
reset_stub; echo active > "$STATE_FILE"
WAIT_READY_STABLE=2 bash "$ROOT/wait-ready.sh" openclaw-gateway 20 1 >/dev/null \
  || fail "рабочая служба должна признаваться готовой"
echo "✓ живая служба признаётся готовой"

# ─── 2. Служба перезапускается → готовность НЕ объявляем ────────────────────
# Счётчик рестартов растёт на каждой проверке: именно так выглядит умирающий
# бот, которому старый install.sh печатал «Офис готов».
reset_stub; echo active > "$STATE_FILE"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  *" cat "*) [ -n "${NO_UNIT_FLAG:-}" ] && [ -f "$NO_UNIT_FLAG" ] && exit 1; exit 0 ;;
  *is-active*) echo active ;;
  *NRestarts*) n=$(cat "$RESTARTS_FILE"); echo $((n + 1)) > "$RESTARTS_FILE"; echo "$n" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/systemctl"
if WAIT_READY_STABLE=2 bash "$ROOT/wait-ready.sh" openclaw-gateway 6 1 >/dev/null; then
  fail "служба с растущими перезапусками не должна считаться готовой"
fi
echo "✓ перезапускающаяся служба готовой не считается (ложное «Офис готов» закрыто)"

# ─── 3. Служба упала в failed → поднимаем и дожидаемся ──────────────────────
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  *" cat "*) [ -n "${NO_UNIT_FLAG:-}" ] && [ -f "$NO_UNIT_FLAG" ] && exit 1; exit 0 ;;
  *is-active*)  cat "$STATE_FILE" ;;
  *is-failed*)  [ "$(cat "$STATE_FILE")" = "failed" ] && exit 0 || exit 1 ;;
  *NRestarts*)  cat "$RESTARTS_FILE" ;;
  *reset-failed*) echo inactive > "$STATE_FILE" ;;
  *start*)      cat "$START_BECOMES" > "$STATE_FILE" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/systemctl"
reset_stub; echo failed > "$STATE_FILE"
WAIT_READY_STABLE=2 bash "$ROOT/wait-ready.sh" openclaw-gateway 30 1 >/dev/null \
  || fail "упавшую службу установщик должен поднять и дождаться"
grep -q "reset-failed" "$CALLS" || fail "не снята отметка failed"
grep -q "start openclaw-gateway" "$CALLS" || fail "служба не запущена заново"
echo "✓ упавшая на старте служба поднимается установщиком (гонка миграций больше не фатальна)"

# ─── 4. Служба мертва навсегда → честный отказ, а не «готово» ───────────────
reset_stub; echo failed > "$STATE_FILE"; echo failed > "$START_BECOMES"
if WAIT_READY_STABLE=2 bash "$ROOT/wait-ready.sh" openclaw-gateway 6 1 >/dev/null; then
  fail "мёртвая служба не должна считаться готовой"
fi
echo "✓ безнадёжный случай не выдаётся за успех"

# ─── 5. Сторож поднимает failed ────────────────────────────────────────────
reset_stub; echo failed > "$STATE_FILE"; echo active > "$START_BECOMES"
bash "$ROOT/watchdog.sh" >/dev/null 2>&1
grep -q "reset-failed" "$CALLS" || fail "сторож не снял отметку failed"
grep -q "start openclaw-gateway" "$CALLS" || fail "сторож не поднял службу"
grep -q "failed" "$HOME/.openclaw/office-watchdog.log" || fail "сторож не записал случившееся в лог"
echo "✓ сторож поднимает упавший офис (раньше выходил на первой строке)"

# ─── 5а. Службы НЕТ вообще → сторож пересоздаёт её ─────────────────────────
# Первый живой прогон клиентом 29.07: `openclaw daemon install` упал в cloud-init,
# юнита не было, служба висела в inactive — не failed. Сторож просыпался каждые
# 2 минуты полчаса и не делал ничего. Проверяем, что теперь делает.
reset_stub
rm -f "$HOME/.openclaw/.watchdog-last-revive"          # антипетля не должна мешать сценарию
NO_UNIT_FLAG="$WORK/no_unit"; : > "$NO_UNIT_FLAG"      # заглушка: systemd не знает службу
export NO_UNIT_FLAG
cat > "$WORK/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
echo "openclaw $*" >> "$CALLS"
# «Создали юнит» — снимаем флаг, дальше systemctl cat отвечает успехом
[ "$1 $2" = "daemon install" ] && rm -f "$NO_UNIT_FLAG"
exit 0
STUB
chmod +x "$WORK/bin/openclaw"
bash "$ROOT/watchdog.sh" >/dev/null 2>&1
grep -q "openclaw daemon install" "$CALLS" || fail "сторож не попытался пересоздать отсутствующую службу"
grep -q "enable --now openclaw-gateway" "$CALLS" || fail "сторож не включил пересозданную службу"
grep -q "юнита openclaw-gateway НЕТ" "$HOME/.openclaw/office-watchdog.log" || fail "сторож не записал, что юнита не было"
rm -f "$WORK/bin/openclaw"
echo "✓ сторож пересоздаёт службу, которой нет вовсе (находка прогона 29.07)"

# ─── 6. Антипетля: сразу второй раз не дёргаем ─────────────────────────────
: > "$CALLS"; echo failed > "$STATE_FILE"
bash "$ROOT/watchdog.sh" >/dev/null 2>&1
if grep -q "start openclaw-gateway" "$CALLS"; then
  fail "сторож не должен рестартовать службу чаще раза в 5 минут"
fi
echo "✓ повторный подъём придержан (без петли рестартов)"

# ─── 7. Живая служба с пустой очередью — сторож не вмешивается ─────────────
: > "$CALLS"; echo active > "$STATE_FILE"
bash "$ROOT/watchdog.sh" >/dev/null 2>&1
if grep -qE "restart|start openclaw-gateway" "$CALLS"; then
  fail "сторож трогает здоровый офис"
fi
echo "✓ здоровый офис сторож не трогает"

# ─── 8. Версия движка читается целиком, вместе с суффиксом сборки ──────────
# Прежний разбор терял «-2» в «2026.7.1-2»: установщик пугал клиента «не удалось
# запинить движок», а еженедельное обновление считало бы версию разошедшейся.
cat > "$WORK/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && echo "OpenClaw 2026.7.1-2 (0790d9f)"
exit 0
STUB
chmod +x "$WORK/bin/openclaw"
# shellcheck source=../lib.sh
. "$ROOT/lib.sh"
got=$(engine_version)
[ "$got" = "2026.7.1-2" ] || fail "версия движка прочитана как «${got}» вместо «2026.7.1-2»"
# и версия без суффикса тоже должна читаться
printf '#!/usr/bin/env bash\n[ "$1" = "--version" ] && echo "OpenClaw 2026.6.11 (abc)"\nexit 0\n' > "$WORK/bin/openclaw"
chmod +x "$WORK/bin/openclaw"
[ "$(engine_version)" = "2026.6.11" ] || fail "версия без суффикса читается неверно"
echo "✓ версия движка читается целиком (ложная тревога про пин закрыта)"

# ─── 9. Лог сторожа читаем: текст ошибок, а не сырой JSON ──────────────────
export ENGINE_LOG_DIR="$WORK/enginelog"
mkdir -p "$ENGINE_LOG_DIR"
cat > "$ENGINE_LOG_DIR/openclaw-test.log" <<'ENGINE'
{"level":"info","msg":"gateway ready","ts":"2026-07-27T12:00:00Z"}
{"level":"error","msg":"telegram poller crashed: socket hang up","ts":"2026-07-27T12:01:00Z"}
{"level":"info","msg":"routine housekeeping","ts":"2026-07-27T12:02:00Z"}
ENGINE
compact=$(compact_engine_log 5)
echo "$compact" | grep -q "telegram poller crashed" || fail "в компактном логе нет текста ошибки"
echo "$compact" | grep -q "routine housekeeping" && fail "в компактный лог попали обычные строки"
echo "$compact" | grep -q '"level"' && fail "в компактном логе остался сырой JSON"
echo "✓ лог сторожа читаемый: только ошибки и только текст"

# ─── 10. Первый старт: службу поднимаем сами, systemd не молотит ───────────
# Заглушка изображает движок, который держит замок: первые попытки старта
# не выводят службу в active, потом замок снимается.
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  *" cat "*) [ -n "${NO_UNIT_FLAG:-}" ] && [ -f "$NO_UNIT_FLAG" ] && exit 1; exit 0 ;;
  *is-active*)  cat "$STATE_FILE" ;;
  *NRestarts*)  echo 0 ;;
  *daemon-reload*) : ;;
  *reset-failed*) : ;;
  *start*)
    n=$(cat "$WORK_TRIES"); n=$((n + 1)); echo "$n" > "$WORK_TRIES"
    # со второй попытки замок снят — служба выходит в рабочий режим
    if [ "$n" -ge 2 ]; then echo active > "$STATE_FILE"; else echo activating > "$STATE_FILE"; fi
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/systemctl"
export WORK_TRIES="$WORK/tries"; echo 0 > "$WORK_TRIES"; export WORK
: > "$CALLS"; echo inactive > "$STATE_FILE"
# лог движка сообщает, до какого момента держится замок — скрипт должен подождать, а не долбить
printf '{"level":"error","msg":"startup migrations are already running for this state directory; retry after 2026-07-27T12:00:03Z"}\n' \
  > "$ENGINE_LOG_DIR/openclaw-test.log"
FIRST_START_STABLE=1 FIRST_START_CHECK=1 bash "$ROOT/first-start.sh" openclaw-gateway 60 2 >/dev/null \
  || fail "первый старт должен довести службу до рабочего режима"
starts=$(grep -c -- "start openclaw-gateway" "$CALLS" 2>/dev/null | head -1)
starts=${starts:-0}
[ "$starts" -ge 1 ] || fail "служба вообще не запускалась"
[ "$starts" -le 3 ] || fail "слишком много попыток старта ($starts) — это и есть та самая молотилка"
[ ! -f "$HOME/.config/systemd/user/openclaw-gateway.service.d/office-firstboot.conf" ] \
  || fail "временная настройка первого старта не снята — служба осталась без авто-рестарта"
echo "✓ первый старт: служба поднята за $starts попытки, временная настройка снята"

# ─── 11. Первый старт не удался → честный неуспех и штатный режим ──────────
: > "$CALLS"; echo inactive > "$STATE_FILE"; echo 0 > "$WORK_TRIES"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  *" cat "*) [ -n "${NO_UNIT_FLAG:-}" ] && [ -f "$NO_UNIT_FLAG" ] && exit 1; exit 0 ;;
  *is-active*) echo activating ;;
  *NRestarts*) echo 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/systemctl"
if FIRST_START_STABLE=1 FIRST_START_CHECK=1 bash "$ROOT/first-start.sh" openclaw-gateway 6 2 >/dev/null; then
  fail "не поднявшаяся служба не должна отдавать успех"
fi
[ ! -f "$HOME/.config/systemd/user/openclaw-gateway.service.d/office-firstboot.conf" ] \
  || fail "после неудачи временная настройка должна сниматься (иначе офис останется без авто-рестарта)"
echo "✓ неудача первого старта: честный отказ, авто-рестарт возвращён"

# ─── 12. Ждём столько, сколько просит движок (а не вслепую) ────────────────
# Это та самая ветка, ради которой всё затевалось: при долгой первой настройке
# движок пишет в лог «retry after <время>», и мы ждём ровно до него. На прогоне
# 27.07 (№3) гонки не случилось, и вживую ветка не отстрелялась — значит она
# обязана быть покрыта здесь. `date -d` есть только в GNU (на Маке нет),
# поэтому подменяем и его — проверяем нашу арифметику, а не чужую утилиту.
cat > "$WORK/bin/date" <<'STUB'
#!/usr/bin/env bash
# date -d <iso> +%s  → «замок снимут через 2 секунды»; обычный date +%s — как есть
if [ "$1" = "-d" ]; then
  echo $(( $(/bin/date +%s) + 2 ))
else
  /bin/date "$@"
fi
STUB
chmod +x "$WORK/bin/date"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  *" cat "*) [ -n "${NO_UNIT_FLAG:-}" ] && [ -f "$NO_UNIT_FLAG" ] && exit 1; exit 0 ;;
  *is-active*) cat "$STATE_FILE" ;;
  *NRestarts*) echo 0 ;;
  *start*)
    n=$(cat "$WORK_TRIES"); n=$((n + 1)); echo "$n" > "$WORK_TRIES"
    if [ "$n" -ge 2 ]; then echo active > "$STATE_FILE"; else echo activating > "$STATE_FILE"; fi
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/systemctl"
: > "$CALLS"; echo inactive > "$STATE_FILE"; echo 0 > "$WORK_TRIES"
# Строка ровно в том виде, в каком её пишет движок (прогон 26.07, лог install)
cat > "$ENGINE_LOG_DIR/openclaw-test.log" <<'ENGINE'
{"level":"error","msg":"OpenClaw startup migrations are already running for this state directory; retry after the other gateway finishes or after 2026-07-26T16:45:45.325Z."}
ENGINE
out=$(FIRST_START_STABLE=1 FIRST_START_CHECK=1 bash "$ROOT/first-start.sh" openclaw-gateway 60 30 2>&1) \
  || fail "ожидание снятия замка должно заканчиваться успешным стартом"
echo "$out" | grep -q "движок приводит в порядок свои данные" \
  || fail "клиенту не сказали, что идёт разовая настройка (он увидит тишину и испугается)"
echo "$out" | grep -qE "ждём [0-9]+с" || fail "не видно, сколько ждём — в бою по логу нельзя будет разобраться"
# Пауза взята из лога (≈7с), а не дефолтные 30с из аргумента — иначе смысл ветки теряется
waited_line=$(echo "$out" | grep -oE "ждём [0-9]+с" | head -1 | grep -oE '[0-9]+')
[ "${waited_line:-99}" -le 15 ] || fail "ждали ${waited_line}с — значит время взято не из лога движка"
echo "✓ ждём ровно столько, сколько просит движок (${waited_line}с из его лога, не вслепую)"

# ─── 13. Старый Node из образа сервера ─────────────────────────────────────
# Живой стенд 27.07: свежий ubuntu-22-04 у DigitalOcean приехал с nodejs 12,
# и установщик движка упал проверкой версии на середине установки. Клиент такое
# не разрулит, поэтому Node мы теперь обеспечиваем сами — до движка.
NODE_STATE="$WORK/node_major"
APT_CALLS="$WORK/apt_calls"
export NODE_STATE APT_CALLS
cat > "$WORK/bin/node" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-v" ] && echo "v$(cat "$NODE_STATE").22.9"
exit 0
STUB
cat > "$WORK/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$APT_CALLS"
# установка nodejs из NodeSource поднимает версию
case "$*" in *install*nodejs*) echo 22 > "$NODE_STATE" ;; esac
exit 0
STUB
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$APT_CALLS"
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/fuser"
chmod +x "$WORK/bin/node" "$WORK/bin/apt-get" "$WORK/bin/curl" "$WORK/bin/fuser"

# 13а. Node уже подходящий — не трогаем чужое окружение
echo 22 > "$NODE_STATE"; : > "$APT_CALLS"
bash "$ROOT/ensure-node.sh" 22 >/dev/null || fail "подходящий Node должен приниматься как есть"
[ ! -s "$APT_CALLS" ] || fail "при подходящем Node ничего ставить и удалять нельзя: $(cat "$APT_CALLS")"
echo "✓ подходящий Node не трогаем"

# 13б. Node 12 из образа — убираем и ставим нужный
echo 12 > "$NODE_STATE"; : > "$APT_CALLS"
bash "$ROOT/ensure-node.sh" 22 >/dev/null || fail "старый Node должен заменяться на нужный"
grep -q "purge" "$APT_CALLS" || fail "дистрибутивный Node не удалён — он перекроет новый в PATH"
grep -q "deb.nodesource.com/setup_22" "$APT_CALLS" || fail "не подключён источник нужной версии Node"
grep -q "install .*nodejs" "$APT_CALLS" || fail "Node не установлен"
echo "✓ старый Node из образа заменяется (та самая находка со стенда закрыта)"

# 13в. Установить не удалось — честный неуспех, установщик остановится с понятным текстом
echo 12 > "$NODE_STATE"; : > "$APT_CALLS"
cat > "$WORK/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$APT_CALLS"
exit 0
STUB
chmod +x "$WORK/bin/apt-get"
if bash "$ROOT/ensure-node.sh" 22 >/dev/null; then
  fail "если Node так и не поставился, отдавать успех нельзя — установка пойдёт дальше и упадёт непонятно"
fi
echo "✓ неудача с Node не выдаётся за успех"

# ─── 14. Мозг определяем сами, человека не спрашиваем ──────────────────────
# Раньше установщик спрашивал «Вы в России?» — вопрос неправильный: доступ
# к моделям зависит от аккаунта OpenRouter, а не от места жительства. Клиент
# из Москвы с зарубежным аккаунтом получал слабый мозг, а с российским —
# молчащего бота. Теперь спрашиваем сам OpenRouter, ровно как бот-установщик.
HTTP_CODES="$WORK/http_codes"; export HTTP_CODES
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
# отдаёт коды по очереди из файла: первая строка — ответ на первую пробу
codes=$(cat "$HTTP_CODES"); first=$(echo "$codes" | head -1)
echo "$codes" | tail -n +2 > "$HTTP_CODES"
printf '%s' "$first"
exit 0
STUB
chmod +x "$WORK/bin/curl"

printf '200\n' > "$HTTP_CODES"
[ "$(bash "$ROOT/detect-brain.sh" sk-or-test 2>/dev/null)" = "global" ] \
  || fail "при доступной сильной модели должен ставиться обычный мозг"

printf '403\n200\n' > "$HTTP_CODES"
[ "$(bash "$ROOT/detect-brain.sh" sk-or-test 2>/dev/null)" = "ru" ] \
  || fail "закрытая модель (403) → DeepSeek, без вопросов человеку"

printf '404\n200\n' > "$HTTP_CODES"
[ "$(bash "$ROOT/detect-brain.sh" sk-or-test 2>/dev/null)" = "ru" ] \
  || fail "404 (нет доступного эндпоинта) тоже означает DeepSeek"

# Сеть молчит — не повод давать клиенту слабый мозг
printf '000\n' > "$HTTP_CODES"
[ "$(bash "$ROOT/detect-brain.sh" sk-or-test 2>/dev/null)" = "global" ] \
  || fail "сетевой сбой не должен понижать мозг"
printf '429\n' > "$HTTP_CODES"
[ "$(bash "$ROOT/detect-brain.sh" sk-or-test 2>/dev/null)" = "global" ] \
  || fail "429 не должен понижать мозг"

# И самое главное: в установщике не осталось вопроса про Россию
# Ищем именно ВОПРОС человеку (read), а не упоминание в комментарии-объяснении
grep -qE '^[^#]*read .*Вы в России' "$ROOT/install.sh" && fail "вопрос «Вы в России?» вернулся в установщик"
echo "✓ мозг определяется пробой ключа, вопроса «Вы в России?» в установщике нет"

# Слаги моделей в пробе и в конфиге офиса обязаны совпадать — иначе проверяем
# одно, а ставим другое
for m in "google/gemini-2.5-flash" "deepseek/deepseek-v4-flash"; do
  grep -q "$m" "$ROOT/detect-brain.sh" || fail "модель $m пропала из пробы"
  grep -q "$m" "$ROOT/install.sh" || fail "модель $m пропала из установщика"
done
echo "✓ проба и установка говорят об одних и тех же моделях"

# ─── 10. Память офиса и размер «стола» ──────────────────────────────────────
# Замер на живом офисе 29.07: 25k из 48k заняты в обычной переписке, больше
# половины окна съедали инструкции. Клиент видел, что офис забывает начало
# разговора. Стережём, чтобы значение не уехало обратно молча.
CTX=$(grep -oE '"contextTokens": *[0-9]+' "$ROOT/apply-settings.sh" | grep -oE '[0-9]+' | head -1)
[ -n "$CTX" ] || fail "contextTokens пропал из конфига офиса"
[ "$CTX" -ge 100000 ] || fail "стол офиса ужался до $CTX — клиент снова начнёт терять начало разговора"
echo "✓ офис держит разговор: contextTokens = $CTX"

# Модель для документов. Без неё чтение PDF падает с «No PDF model configured» —
# поймано 30.07 на живом офисе, клиент прислал документ и не получил разбора.
grep -q 'pdfModel' "$ROOT/apply-settings.sh" || fail "pdfModel пропал — офис снова не сможет читать документы"
# На пути DeepSeek модель документов НЕ ставится: он принимает только текст,
# и заглушка там означала бы обещание, которого офис не выполнит.
grep -q 'DOCS_OK=0' "$ROOT/apply-settings.sh" \
  || fail "на пути DeepSeek модель документов должна оставаться пустой"
echo "✓ документы: модель задана там, где их умеют читать, и не обещана там, где нет"

# Активная память включается явно: в движке она выключена по умолчанию
# («bundled (disabled by default)» — проверено 30.07 через openclaw plugins inspect).
grep -q "plugins enable active-memory" "$ROOT/apply-settings.sh" \
  || fail "включение активной памяти пропало — офис перестанет вспоминать сам"
# И не должна валить установку: офис без неё работает, просто помнит хуже
grep -A2 "plugins enable active-memory" "$ROOT/apply-settings.sh" | grep -q "else" \
  || fail "сбой включения активной памяти обязан быть мягким, а не ронять установку"
echo "✓ активная память включается явно и не роняет установку при сбое"

# ─── 11. Настройки доезжают и до тех, у кого офис уже стоит ────────────────
# До 30.07 конфиг применялся только установщиком, а обновлялка его не трогала —
# улучшения не доходили до существующих клиентов никогда (находка аудита).
[ -s "$ROOT/apply-settings.sh" ] || fail "apply-settings.sh пропал — настройки некому применять"
grep -q "apply-settings.sh" "$ROOT/install.sh" || fail "установщик не зовёт apply-settings.sh"
grep -q "apply-settings.sh" "$ROOT/update.sh"  || fail "обновлялка не зовёт apply-settings.sh — настройки не доедут до клиента"
grep -q "settings-changed" "$ROOT/update.sh"   || fail "обновлялка не видит признак изменений — офис не перезапустится"
grep -q "settings-changed" "$ROOT/apply-settings.sh" || fail "apply-settings.sh не сообщает об изменениях"
echo "✓ настройки применяются одним скриптом: и при установке, и при обновлении"

# Настройки не должны остаться и в установщике — иначе два источника правды разъедутся
grep -q "contextTokens" "$ROOT/install.sh" && fail "contextTokens остался в установщике: два источника правды"
grep -q "aliases add" "$ROOT/install.sh" && fail "псевдонимы остались в установщике: два источника правды"
echo "✓ у настроек один источник правды"

# Четыре уровня мозга. Псевдонимы движок принимает только латиницей — кириллица
# отвергается («Alias must use letters, numbers, dots, underscores, colons, or dashes»).
for a in lite fast smart max; do
  grep -q "\"$a:\$A_" "$ROOT/apply-settings.sh" || fail "уровень мозга $a пропал"
done
grep -E "aliases add \"?[а-яё]" "$ROOT/apply-settings.sh" && fail "псевдоним кириллицей — движок его не примет"
echo "✓ четыре уровня мозга заводятся латиницей: lite | fast | smart | max"

# Правда об уровнях — в BRAIN.md, у каждого клиента своя. Статическая таблица
# в AGENTS.md обещала «самый умный» тем, у кого уровней два (находка аудита).
grep -q "BRAIN.md" "$ROOT/apply-settings.sh" || fail "BRAIN.md не создаётся"
grep -q "BRAIN.md" "$ROOT/workspace/AGENTS.md" || fail "офис не знает про BRAIN.md — не прочитает уровни"
grep -qE "^\| .model (lite|max)." "$ROOT/workspace/AGENTS.md" && fail "статическая таблица уровней вернулась в AGENTS.md"
# office-sync не должен перезаписывать BRAIN.md — иначе правда о клиенте затрётся общей
grep -q "BRAIN" "$ROOT/office-sync.sh" && fail "office-sync трогает BRAIN.md — правда о клиенте затрётся"
echo "✓ уровни описаны в BRAIN.md под конкретного клиента, а не обещаны всем одинаково"

# Возврат на обычный уровень: на верхних не сидят постоянно
grep -qi "верн" "$ROOT/workspace/AGENTS.md" || fail "офис не возвращает владельца на обычный уровень"
echo "✓ офис возвращает владельца на обычный уровень"

# Поведение при собственной поломке: руководителю — одно действие, а не диагностика.
# Первый живой клиент получил дословно «проверьте логи OpenClaw Gateway».
grep -q "/new" "$ROOT/workspace/SOUL.md" || fail "в SOUL.md нет указания давать клиенту /new при сбое"
grep -qi "логи" "$ROOT/workspace/SOUL.md" || fail "в SOUL.md пропал запрет отправлять клиента в логи"
echo "✓ при сбое офис даёт одно действие, а не техническую диагностику"

# Гайд первой недели: на него ссылается финальное сообщение бота-установщика.
# Нет файла — ссылка ведёт в 404 у каждого нового клиента.
[ -s "$ROOT/guides/09-first-week.md" ] || fail "гайд первой недели пропал, а бот на него ссылается"
grep -q "/new" "$ROOT/guides/09-first-week.md" || fail "гайд первой недели не объясняет /new"
# Единственное место, откуда карта клиента может списаться сама. Называем тумблер
# его подписью — иначе человек не найдёт то, что мы просим выключить.
grep -q "Enable auto top up" "$ROOT/guides/09-first-week.md" \
  || fail "в гайде пропало предупреждение про автопополнение — клиент попадёт на деньги"
grep -q "Credit limit" "$ROOT/guides/09-first-week.md" \
  || fail "в гайде пропал лимит на ключ — главная защита клиента от переплаты"
echo "✓ гайд первой недели на месте: команды, автопополнение, лимит ключа"

# ─── 12. Расписание обновлений: ежедневное и доезжает до старых клиентов ────
# Расписание жило только в install.sh, то есть применялось при установке и
# больше никогда. У клиента, поставленного раньше, оставалось «понедельник
# 04:00»: доработка вторника приезжала к нему через шесть дней.
grep -q 'OnCalendar=\*-\*-\* 04:00:00' "$ROOT/install.sh" \
  || fail "в установщике не ежедневное расписание — новые клиенты будут ждать неделю"
grep -q 'OnCalendar=\*-\*-\* 04:00:00' "$ROOT/apply-settings.sh" \
  || fail "apply-settings не чинит расписание — до существующих клиентов ежедневное не доедет"
grep -qE 'OnCalendar=(Mon|Tue|Wed|Thu|Fri|Sat|Sun)' "$ROOT/install.sh" "$ROOT/apply-settings.sh" \
  && fail "вернулось недельное расписание"
echo "✓ обновления ежедневные и доезжают до тех, у кого офис уже стоит"

# Дальше — не поиск текста в исходнике, а прогон настоящего apply-settings.sh
# с подставными systemctl и openclaw. Grep по коду ловит только формулировку:
# первая версия этой секции пропускала регресс, при котором проверка искала одно
# расписание, а юнит нёс другое — офис клиента перезапускался бы КАЖДУЮ ночь,
# а тест рапортовал бы об успехе. Проверяем поведение.
SB="$WORK/sched"; mkdir -p "$SB/home/.config/systemd/user" "$SB/home/.openclaw" "$SB/bin" "$SB/office"
SCHED_CALLS="$SB/calls"; SCHED_ACTIVE="$SB/active"; export SCHED_CALLS SCHED_ACTIVE
echo 0 > "$SCHED_ACTIVE"        # 0 = таймер поднимается, 3 = не поднимается
cat > "$SB/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SCHED_CALLS"
case "$*" in *is-active*) exit "$(cat "$SCHED_ACTIVE")" ;; esac
exit 0
STUB
# Движок отвечает так, чтобы блоки 1-4 отработали вхолостую и не мешали.
cat > "$SB/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "config get agents.defaults.model.primary") echo "openrouter/google/gemini-2.5-flash" ;;
  "config get agents.defaults.contextTokens") echo "200000" ;;
  *"plugins list"*) echo "active-memory enabled" ;;
  *"aliases list"*) echo "- lite -> openrouter/google/gemini-2.5-flash" ;;
esac
exit 0
STUB
chmod +x "$SB/bin/systemctl" "$SB/bin/openclaw"

run_sched() {   # прогон apply-settings в песочнице; печатает вывод
  ( export HOME="$SB/home" PATH="$SB/bin:$PATH" OFFICE_DIR="$SB/office"
    : > "$SCHED_CALLS"
    bash "$ROOT/apply-settings.sh" global 2>&1 )
}
TIMER_F="$SB/home/.config/systemd/user/office-update.timer"
SERVICE_F="$SB/home/.config/systemd/user/office-update.service"
week_timer() { printf '[Unit]\nDescription=Run office self-update weekly (Mon 04:00)\n[Timer]\nOnCalendar=Mon *-*-* 04:00:00\nPersistent=true\n[Install]\nWantedBy=timers.target\n' > "$TIMER_F"
               printf '[Unit]\nDescription=Weekly OpenClaw office self-update\n[Service]\nType=oneshot\n' > "$SERVICE_F"; }

# А. Свежая установка: таймера ещё нет (его создаст шаг 8) — не пугать оператора
rm -f "$TIMER_F" "$SERVICE_F"
OUT_A="$(run_sched)"
printf '%s' "$OUT_A" | grep -q "не нашей сборкой" && fail "на свежей установке пугаем оператора чужой сборкой"
printf '%s' "$OUT_A" | grep -q "settings-changed" || fail "на свежей установке потерян сигнал об изменениях"
echo "✓ свежая установка: отсутствие таймера не выдаётся за поломку"

# Б. Существующий клиент: недельное расписание переезжает на ежедневное
week_timer
OUT_B="$(run_sched)"
grep -qxF 'OnCalendar=*-*-* 04:00:00' "$TIMER_F" \
  || fail "расписание не переехало на ежедневное — клиент так и ждёт понедельника"
grep -q '^Description=Daily' "$SERVICE_F" \
  || fail "описание службы осталось недельным — systemctl status будет врать клиенту"
printf '%s' "$OUT_B" | grep -q "settings-changed" || fail "переезд расписания не помечен как изменение"
echo "✓ существующий клиент переезжает на ежедневные обновления"

# В. Идемпотентность: второй прогон не трогает ничего и НЕ просит перезапуск.
# Иначе офис клиента перезапускался бы каждую ночь без причины.
OUT_C="$(run_sched)"
printf '%s' "$OUT_C" | grep -q "уже ежедневные" || fail "повторный прогон не распознал, что расписание уже ежедневное"
grep -q "restart office-update.timer" "$SCHED_CALLS" && fail "повторный прогон дёргает таймер — офис будет перезапускаться каждую ночь"
echo "✓ повторные прогоны ничего не трогают (ночных перезапусков не будет)"

# Г. Таймер не поднялся: возвращаем прежний юнит и бьём тревогу, которую видно.
# Молчаливый отказ здесь означает, что офис перестанет обновляться навсегда.
week_timer; echo 3 > "$SCHED_ACTIVE"
OUT_D="$(run_sched)"
printf '%s' "$OUT_D" | grep -q "TREVOGA-UPDATES" \
  || fail "таймер не поднялся, а тревоги нет — обновления умрут молча"
grep -qxF 'OnCalendar=Mon *-*-* 04:00:00' "$TIMER_F" \
  || fail "после неудачи не вернули прежний рабочий юнит"
printf '%s' "$OUT_D" | grep -q "settings-changed" || fail "неудача расписания погасила сигнал об остальных настройках"
echo 0 > "$SCHED_ACTIVE"
echo "✓ неудача отката видна человеку, прежний таймер возвращён"

# Д. Тревога из настроек доходит до владельца, а не оседает в логе
grep -q "TREVOGA-UPDATES" "$ROOT/update.sh" \
  || fail "обновлялка не ловит тревогу настроек — сообщение осядет в логе, который никто не читает"
grep -q "9>&-" "$ROOT/update.sh" \
  || fail "замок обновления наследуется демоном — следующие обновления будут тихо пропускаться"
echo "✓ тревога доходит до владельца, замок не утекает в демон"

# Е. Клиенту и оператору обещаем то, что происходит на самом деле.
grep -rn -iE "раз в неделю|еженедельн|по понедельник" "$ROOT/README.md" "$ROOT/guides" >/dev/null 2>&1 \
  && fail "клиенту всё ещё обещают обновления раз в неделю"
echo "✓ тексты для клиента и оператора совпадают с реальным расписанием"

# Ж. Установщик определяет все функции, которые зовёт. warn вызывался трижды,
# определён не был — под set -e установка обрывалась на клиенте с ключом,
# которому OpenRouter отдаёт только DeepSeek.
for fn in $(grep -oE '^\s*(say|ok|warn|die) ' "$ROOT/install.sh" | tr -d ' ' | sort -u); do
  grep -qE "^${fn}\(\)" "$ROOT/install.sh" || fail "install.sh зовёт ${fn}, но не определяет её — установка оборвётся"
done
echo "✓ установщик определяет все функции, которые вызывает"

# З. Проверки сети в установщике не роняют установку при моргании связи.
grep -qE 'curl [^|]*openrouter\.ai/api/v1/key.*\|\| echo' "$ROOT/install.sh" \
  || fail "запрос баланса без перехвата — сбой сети оборвёт установку без объяснения"
echo "✓ сбой сети при проверке баланса не обрывает установку"

echo
echo "============================================="
echo "🎉 Тест старта и сторожа пройден"
echo "============================================="
