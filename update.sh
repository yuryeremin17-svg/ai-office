#!/usr/bin/env bash
# ============================================================================
# update.sh — обновлялка офиса. Зовётся будильником (или вручную оператором).
# Порядок:
#   1) тянет свежую нашу сборку с GitHub (git pull);
#   2) обновляет сам движок OpenClaw его же командой;
#   3) накатывает наши файлы, НЕ трогая память клиента (office-sync.sh);
#   4) перезапускает офис ТОЛЬКО если что-то реально изменилось;
#   5) шлёт пульс «жив», если задан HEARTBEAT_URL.
# Тихо выходит (без перезапуска), если ни сборка, ни движок не менялись.
# ============================================================================
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # наша git-сборка
# engine_version(): версия ЦЕЛИКОМ, с суффиксом сборки. Мягко: у офисов, поставленных
# до 27.07, lib.sh в сборке ещё нет — он приедет этим же обновлением, а до того
# держим запасное определение, чтобы обновление не падало на переходном цикле.
if [ -f "$SRC_DIR/lib.sh" ]; then
  # shellcheck source=lib.sh
  . "$SRC_DIR/lib.sh"
else
  engine_version() { openclaw --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+(-[0-9]+)?' | head -1; }
fi
LOG="$HOME/.openclaw/office-update.log"
ENVF="$HOME/.openclaw/.office-env"
[ -f "$ENVF" ] && . "$ENVF" || true                       # OFFICE_DIR, HEARTBEAT_URL
OFFICE_DIR="${OFFICE_DIR:-/root/office}"

mkdir -p "$(dirname "$LOG")"
log(){ printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG"; }
# alert — сообщить владельцу в Телеграм, когда автообновление застряло (лог никто не читает).
alert(){
  local tok; tok=$(cat "$HOME/.openclaw/.office-menu-token" 2>/dev/null || echo '')
  [ -n "${OWNER_TG_ID:-}" ] && [ -n "$tok" ] || return 0
  curl -fsS -m 10 "https://api.telegram.org/bot${tok}/sendMessage" \
    --data-urlencode "chat_id=${OWNER_TG_ID}" --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

log "=== запуск обновлялки (версия сборки $(cat "$SRC_DIR/VERSION" 2>/dev/null || echo '?')) ==="
changed=0

# --- 1. свежая сборка с GitHub ----------------------------------------------
if [ -d "$SRC_DIR/.git" ]; then
  if [ -n "$(git -C "$SRC_DIR" status --porcelain 2>/dev/null)" ]; then
    log "сборка: локальные изменения — pull пропущен"
    alert "Офис: сборка изменена локально, автообновление приостановлено. Нужна проверка."
  elif ! git -C "$SRC_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
    log "сборка: detached HEAD (после отката) — pull пропущен"
    alert "Офис: после отката автообновление приостановлено. Верните сборку на ветку, когда почините."
  else
    before=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo none)
    if git -C "$SRC_DIR" pull --ff-only >>"$LOG" 2>&1; then
      after=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo none)
      [ "$before" != "$after" ] && { changed=1; log "сборка: $before -> $after"; } || log "сборка: актуальна"
    else
      log "сборка: git pull не удался"
      alert "Офис: обновление сборки не удалось (git pull). Нужна проверка."
    fi
  fi
else
  log "сборка: не git-репо — pull пропущен"
fi

# --- 2. движок OpenClaw: ТОЛЬКО на закреплённую нами версию (пиннинг) --------
# Мы — фильтр: клиент не тянет свежий движок от автора вслепую. Обновляем движок
# строго на версию из ENGINE_VERSION (её мы предварительно проверили у себя).
# Пусто = движок заморожен на версии установки, автообновление движка выключено.
PIN=$(tr -d '[:space:]' < "$SRC_DIR/ENGINE_VERSION" 2>/dev/null || echo '')
# Версия ЦЕЛИКОМ: прежний разбор терял суффикс сборки («2026.7.1» вместо «2026.7.1-2»),
# и еженедельное обновление каждую неделю считало бы версию разошедшейся с пином —
# гоняло бы update вхолостую на офисе клиента (найдено на прогоне 27.07).
ev_cur=$(engine_version || echo '')
[ -z "$ev_cur" ] && ev_cur='?'
if [ -z "$PIN" ]; then
  log "движок: версия не закреплена — автообновление движка выключено, оставляю $ev_cur"
elif [ "$ev_cur" = "?" ]; then
  log "движок: не смог определить текущую версию — обновление движка пропущено (защита от циклов)"
elif [ "$PIN" = "$ev_cur" ]; then
  log "движок: уже на закреплённой $PIN"
else
  log "движок: $ev_cur -> закреплённая $PIN"
  if openclaw update --yes --no-restart --tag "$PIN" >>"$LOG" 2>&1; then
    changed=1; log "движок обновлён на $PIN"
  else
    log "движок: обновление на $PIN не удалось (офис остаётся на $ev_cur)"
  fi
fi

# --- 3. настройки офиса -----------------------------------------------------
# Раньше обновлялка накатывала только файлы, а конфиг не трогала вовсе — и улучшения
# настроек не доезжали до тех, у кого офис уже стоит (аудит 30.07: четыре изменения
# конфига за день дошли бы только до новых клиентов). Теперь тот же скрипт, что
# зовёт установщик. Он идемпотентен и печатает `settings-changed`, если реально
# что-то поменял, — по этому и решаем, нужен ли перезапуск.
#
# Регион не передаём: скрипт сам смотрит, какая модель стоит в конфиге. Так офис,
# у которого владелец сменил мозг вручную, не получит чужие настройки.
if [ -f "$SRC_DIR/apply-settings.sh" ]; then
  if SETTINGS_OUT=$(OFFICE_DIR="$OFFICE_DIR" bash "$SRC_DIR/apply-settings.sh" 2>&1); then
    printf '%s\n' "$SETTINGS_OUT" >>"$LOG"
    if printf '%s' "$SETTINGS_OUT" | grep -q 'settings-changed'; then
      changed=1
      log "настройки офиса обновлены"
    fi
  else
    printf '%s\n' "$SETTINGS_OUT" >>"$LOG"
    log "настройки: ОШИБКА — офис работает на прежних настройках"
  fi
fi

# --- 4+5. накат наших файлов и перезапуск — только если что-то изменилось ----
if [ "$changed" = 1 ]; then
  if bash "$SRC_DIR/office-sync.sh" "$SRC_DIR" "$OFFICE_DIR" >>"$LOG" 2>&1; then
    openclaw daemon restart >>"$LOG" 2>&1 || openclaw daemon start >>"$LOG" 2>&1 || true
    log "офис обновлён и перезапущен"
  else
    log "office-sync: ОШИБКА — офис НЕ перезапущен, работает прошлая версия"
    alert "Офис: обновление прервано (sync failed), работает прошлая рабочая версия. Нужна проверка."
  fi
else
  log "изменений нет — офис не трогаю"
fi

# Пульс «жив» шлёт отдельный частый таймер (heartbeat.sh, каждые 15 мин) —
# здесь не дублируем: раз в неделю пинг падение не отловил бы.

log "=== обновлялка завершена ==="
exit 0
