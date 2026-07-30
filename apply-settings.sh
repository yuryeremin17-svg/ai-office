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

[ "$CHANGED" = "1" ] && echo "settings-changed"
exit 0
