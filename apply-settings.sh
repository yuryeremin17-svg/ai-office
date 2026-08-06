#!/usr/bin/env bash
# ============================================================================
# apply-settings.sh — настройки офиса, которые НЕ содержат секретов.
#
# Зачем отдельным файлом. Раньше всё это жило внутри install.sh, вперемешку с
# ключами клиента, и поэтому применялось ровно один раз — при установке.
# Обновлялка (update.sh) накатывала файлы, но конфиг не трогала вовсе, так что
# улучшения настроек не доезжали до тех, у кого офис уже стоит. Аудит 30.07:
# четыре изменения конфига за день дошли бы только до новых клиентов.
#
# Теперь это один скрипт, который зовут оба: и установщик, и обновлялка.
# Секретов здесь нет — их по-прежнему пишет только install.sh.
#
# Идемпотентен: config patch мержит, aliases add — «add or update»,
# plugins enable повторно безвреден. Запускать можно сколько угодно раз.
#
# Печатает строку `settings-changed`, если что-то реально изменилось, —
# по ней обновлялка решает, нужен ли перезапуск офиса.
#
# Использование:  apply-settings.sh [регион]
#   регион: ru | global. Не указан — определяем по текущей модели в конфиге.
# ============================================================================
set -euo pipefail

REGION="${1:-}"

say(){ printf "\n\033[1;33m▸ %s\033[0m\n" "$1"; }
ok(){  printf "\033[0;32m  ✓ %s\033[0m\n" "$1"; }
warn(){ printf "\033[0;33m  ⚠ %s\033[0m\n" "$1"; }

CHANGED=0
mark(){ CHANGED=1; }

cfg_get(){ openclaw config get "$1" 2>/dev/null || true; }

# --- Регион: по явному аргументу или по тому, что уже стоит в конфиге --------
if [ -z "$REGION" ]; then
  if cfg_get agents.defaults.model.primary | grep -qi deepseek; then REGION="ru"; else REGION="global"; fi
fi

# --- Кто за какой уровень отвечает ------------------------------------------
# Цены за 1 млн токенов вход/выход (openrouter.ai/api/v1/models, 30.07):
#   gemini-2.5-flash-lite $0.10/$0.40 · gemini-2.5-flash $0.30/$2.50
#   claude-sonnet-5 $2/$10 · claude-opus-5 $5/$25
#   deepseek-v4-flash $0.14/$0.28 · deepseek-v4-pro $0.43/$0.87
if [ "$REGION" = "ru" ]; then
  A_LITE="openrouter/deepseek/deepseek-v4-flash"
  A_FAST="openrouter/deepseek/deepseek-v4-flash"
  A_SMART="openrouter/deepseek/deepseek-v4-pro"
  A_MAX="openrouter/deepseek/deepseek-v4-pro"
  LEVELS=2          # честно: сильнее pro этому аккаунту не открыто
  DOCS_OK=0         # DeepSeek принимает только текст
else
  A_LITE="openrouter/google/gemini-2.5-flash-lite"
  A_FAST="openrouter/google/gemini-2.5-flash"
  A_SMART="openrouter/anthropic/claude-sonnet-5"
  A_MAX="openrouter/anthropic/claude-opus-5"
  LEVELS=4
  DOCS_OK=1
fi

say "Настройки офиса (регион: $REGION)"

# --- 1. Размер «стола» разговора и модель документов ------------------------
# contextTokens стоял 48000 с первого установщика, без расчёта. Замер на живом
# офисе: 25k из 48k заняты обычной перепиской. Модели держат ~1 млн; ставим
# 200000 — вчетверо больше прежнего и вшестеро меньше потолка. Больше не берём:
# весь стол уходит модели при каждой реплике и оплачивается заново.
PATCH="$(mktemp)"
trap 'rm -f "$PATCH"' EXIT
if [ "$DOCS_OK" = "1" ]; then
  # Модель для документов и картинок задаётся ОТДЕЛЬНО от разговорной. Без неё
  # чтение PDF падает с «No PDF model configured» — поймано 30.07 на живом офисе.
  cat > "$PATCH" <<JSON
{ "agents": { "defaults": {
    "contextTokens": 200000,
    "compaction": { "mode": "default" },
    "contextPruning": { "mode": "cache-ttl", "keepLastAssistants": 8, "softTrimRatio": 0.7, "hardClearRatio": 0.9 },
    "pdfModel":   { "primary": "${A_FAST}", "fallbacks": ["${A_SMART}"] },
    "imageModel": { "primary": "${A_FAST}", "fallbacks": ["${A_SMART}"] }
}}}
JSON
else
  # Модель документов намеренно НЕ задаём: этот мозг их не принимает, и заглушка
  # была бы обещанием, которого офис не выполнит.
  cat > "$PATCH" <<JSON
{ "agents": { "defaults": {
    "contextTokens": 200000,
    "compaction": { "mode": "default" },
    "contextPruning": { "mode": "cache-ttl", "keepLastAssistants": 8, "softTrimRatio": 0.7, "hardClearRatio": 0.9 }
}}}
JSON
fi

BEFORE_CTX="$(cfg_get agents.defaults.contextTokens)"
if openclaw config patch --file "$PATCH" >/dev/null 2>&1; then
  [ "$BEFORE_CTX" = "$(cfg_get agents.defaults.contextTokens)" ] || mark
  ok "стол разговора и модель документов применены"
else
  warn "настройки конфига применить не удалось — офис работает на прежних"
fi
rm -f "$PATCH"

# --- 2. Активная память -----------------------------------------------------
# В движке выключена по умолчанию («bundled (disabled by default)»). Без неё
# записанное лежит мёртвым грузом: офис заглядывает в память, лишь если догадается.
if openclaw plugins list 2>/dev/null | grep -q "active-.*enabled"; then
  ok "активная память уже включена"
else
  if openclaw plugins enable active-memory >/dev/null 2>&1; then
    mark; ok "активная память включена — офис вспоминает сам"
  else
    warn "активную память включить не удалось — офис будет помнить только то, что перечитает сам"
  fi
fi

# --- 3. Уровни мозга под короткими именами ----------------------------------
# Псевдонимы движок принимает только латиницей («Alias must use letters, numbers,
# dots, underscores, colons, or dashes» — проверено 30.07). Поэтому команды
# латинские, а объяснение уровней по-русски — в BRAIN.md ниже.
ALIAS_OK=0
for pair in "lite:$A_LITE" "fast:$A_FAST" "smart:$A_SMART" "max:$A_MAX"; do
  name="${pair%%:*}"; target="${pair#*:}"
  current="$(openclaw models aliases list 2>/dev/null | grep -E "^- $name ->" | sed 's/.*-> //' || true)"
  if [ "$current" = "$target" ]; then
    ALIAS_OK=$((ALIAS_OK+1))
  elif openclaw models aliases add "$name" "$target" >/dev/null 2>&1; then
    ALIAS_OK=$((ALIAS_OK+1)); mark
  fi
done
if [ "$ALIAS_OK" -eq 4 ]; then
  ok "уровни мозга готовы: /model lite | fast | smart | max"
else
  warn "уровни мозга встали не полностью ($ALIAS_OK из 4)"
fi

# --- 4. BRAIN.md — правда об уровнях ИМЕННО этого офиса ---------------------
# Почему отдельный файл, а не таблица в AGENTS.md: AGENTS.md одинаков у всех и
# перезаписывается обновлением, а уровни у клиентов разные. Статическая таблица
# на четыре уровня обещала бы «самый умный» тем, у кого их два (находка аудита).
# office-sync.sh этот файл не трогает — он не в списке нашей полки.
OFFICE_DIR="${OFFICE_DIR:-/root/office}"
BRAIN="$OFFICE_DIR/BRAIN.md"
mkdir -p "$OFFICE_DIR"
BRAIN_TMP="$(mktemp)"
if [ "$LEVELS" = "4" ]; then
  cat > "$BRAIN_TMP" <<'MD'
# Уровни «мозга» этого офиса

Владельцу доступны четыре уровня. Говори с ним уровнями, не именами моделей.

| Команда | Уровень | Для чего | Цена |
|---|---|---|---|
| `/model lite` | экономный | переписка, короткие вопросы, черновики | втрое дешевле обычного |
| `/model fast` | обычный, **стоит по умолчанию** | ежедневная работа, документы, разборы | — |
| `/model smart` | умный | сложный анализ, тонкие тексты, важные решения | примерно ×6 |
| `/model max` | самый умный | серьёзный вопрос, где на кону деньги | примерно ×15 |

Документы, картинки и голосовые этот офис принимает.
MD
else
  cat > "$BRAIN_TMP" <<'MD'
# Уровни «мозга» этого офиса

Аккаунт владельца открывает не все модели, поэтому уровня **два**, а не четыре.
Не обещай ему «самый умный» уровень — его здесь нет.

| Команда | Уровень | Для чего |
|---|---|---|
| `/model fast` | обычный, **стоит по умолчанию** | ежедневная работа, переписка, разборы |
| `/model smart` | умный | сложный анализ, важные решения |

`/model lite` ведёт на тот же обычный, `/model max` — на тот же умный.
Команды рабочие, но разницы не будет: сильнее этих моделей аккаунту не открыто.

**Документы, картинки и голосовые этот офис не читает** — доступная модель
принимает только текст. Если владелец пришлёт файл, скажи об этом сразу и честно,
не пытайся его открыть.
MD
fi
if [ -f "$BRAIN" ] && cmp -s "$BRAIN_TMP" "$BRAIN"; then
  ok "BRAIN.md актуален"
else
  cp -f "$BRAIN_TMP" "$BRAIN"; mark
  ok "BRAIN.md записан: уровней $LEVELS"
fi
rm -f "$BRAIN_TMP"

# --- 5. Расписание обновлений: ежедневно вместо раз в неделю ----------------
# Расписание задаётся в install.sh и потому применялось только при установке:
# у клиентов, поставленных раньше, так и остаётся «понедельник 04:00». Правка
# в установщике до них не доедет никогда — тот же класс дефекта, ради которого
# заведён этот файл. Поэтому расписание чиним здесь.
#
# Зачем ежедневно: недельный цикл означал, что доработка, выпущенная во вторник,
# приезжает клиенту только в понедельник. Обновлялка и так тихо выходит, когда
# нового нет, — частота ничего не стоит.
#
# Время оставлено ночным, разброс получаса сохранён: когда клиентов станет
# много, они не постучатся в GitHub одной секундой.
#
# Почему целиком в функции с перехватом ошибки. Файл идёт под `set -e`, а этот
# блок ПОСЛЕДНИЙ — падение здесь оборвало бы скрипт до строки `settings-changed`,
# и обновлялка решила бы, что менять нечего: конфиг применён, а офис не
# перезапущен, и тревога никому не уходит (update.sh в ветке ошибки только пишет
# в лог). Расписание — не та вещь, ради которой можно потерять всё обновление.
schedule_daily() {
  local timer="$HOME/.config/systemd/user/office-update.timer"
  local service="$HOME/.config/systemd/user/office-update.service"
  local want_cal="OnCalendar=*-*-* 04:00:00"

  command -v systemctl >/dev/null 2>&1 || return 0   # не systemd (прогон на Маке) — не наша забота

  # На свежей установке apply-settings зовётся на шаге 4, а таймер появляется на
  # шаге 8 — его отсутствие здесь нормально, это не «чужая сборка».
  [ -f "$timer" ] || { ok "таймера ещё нет — его поставит установщик"; return 0; }

  local need=0
  grep -qxF "$want_cal" "$timer" || need=1
  # Описание службы правится здесь же: оно живёт в install.sh и до существующих
  # клиентов иначе не доедет — у них `systemctl status` врал бы «Weekly».
  [ -f "$service" ] && ! grep -q '^Description=Daily' "$service" && need=1
  [ "$need" = "0" ] && { ok "обновления уже ежедневные"; return 0; }

  # Мусор от прерванных прогонов: временный файл лежит в каталоге systemd, и без
  # уборки он копился бы там вечно. Чистим свои и чужие остатки до записи.
  rm -f "$timer".new.* 2>/dev/null || true

  # Копия прежнего юнита — вне каталога systemd: там ей не место, systemd читает
  # весь каталог. Копия одна и перезаписывается: история версий тут не нужна.
  # Честно: это откат на одну ночь. Пока правка живёт в сборке, ближайшее
  # обновление вернёт ежедневное расписание. Настоящий откат — откатить сборку.
  local bakdir="$HOME/.openclaw"
  mkdir -p "$bakdir" 2>/dev/null || true
  cp -f "$timer" "$bakdir/office-update.timer.before-daily" 2>/dev/null || true

  # Пишем через временный файл и переносим одним движением: обрыв на середине
  # оставил бы обрезанный юнит, systemd его не загрузит, и офис не обновится
  # больше НИКОГДА — молча. Перенос атомарен, битого состояния не бывает.
  # Расписание в юните собирается из той же переменной, по которой проверяли
  # выше. Двумя отдельными местами они разъезжались бы молча: проверка искала
  # бы одно, юнит нёс другое, need оставался бы 1 навсегда — и офис клиента
  # перезапускался бы КАЖДУЮ ночь без причины. Тесты такого не ловят.
  local tmp="$timer.new.$$"
  cat > "$tmp" <<UNIT
[Unit]
Description=Run office self-update daily (04:00)
[Timer]
${want_cal}
Persistent=true
RandomizedDelaySec=1800
[Install]
WantedBy=timers.target
UNIT
  mv -f "$tmp" "$timer" || { rm -f "$tmp"; warn "расписание записать не удалось — осталось прежнее"; return 0; }

  # Описание службы — через временный файл, а не `sed -i`: у GNU и BSD разный
  # синтаксис ключа (BSD требует аргумент суффикса), и на одной из систем правка
  # молча не применялась бы. Заодно запись остаётся атомарной, как у таймера.
  if [ -f "$service" ] && grep -q '^Description=Weekly ' "$service"; then
    local stmp="$service.new.$$"
    if sed 's/^Description=Weekly /Description=Daily /' "$service" > "$stmp" 2>/dev/null; then
      mv -f "$stmp" "$service" || rm -f "$stmp"
    else
      rm -f "$stmp"
    fi
  fi

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user restart office-update.timer >/dev/null 2>&1 || true

  # «Перезапустили» и «работает» — разные вещи. Спрашиваем systemd, а не себя.
  if systemctl --user is-active --quiet office-update.timer 2>/dev/null; then
    mark; ok "обновления переведены на ежедневные (было: раз в неделю)"
    return 0
  fi

  # Таймер не поднялся — возвращаем прежний юнит. Лучше редкие обновления,
  # чем никаких: без живого таймера офис замолкает навсегда и незаметно.
  # Юнит мог остаться в failed — снимаем отметку, иначе start не сработает.
  if [ -f "$bakdir/office-update.timer.before-daily" ]; then
    cp -f "$bakdir/office-update.timer.before-daily" "$timer" 2>/dev/null || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user reset-failed office-update.timer >/dev/null 2>&1 || true
    systemctl --user start office-update.timer >/dev/null 2>&1 || true
  fi

  # Проверяем и откат тоже. Рапортовать «вернул прежнее», не убедившись, —
  # ровно тот грех, ради которого выше добавлена проверка живости.
  if systemctl --user is-active --quiet office-update.timer 2>/dev/null; then
    warn "TREVOGA-UPDATES: новое расписание systemd не принял, вернул прежнее — сообщите нам"
  else
    warn "TREVOGA-UPDATES: таймер обновлений не работает — офис больше не обновляется сам, срочно сообщите нам"
  fi
  return 0
}
schedule_daily || warn "расписание обновлений не тронуто из-за сбоя — офис работает на прежнем"

[ "$CHANGED" = "1" ] && echo "settings-changed"
exit 0
