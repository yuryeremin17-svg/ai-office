#!/usr/bin/env bash
# ============================================================================
# watchdog.sh — самолечение офиса. Зовётся таймером каждые 2 минуты.
#
# Лечит боевой баг движка (найден живым прогоном 24.07): при сообщениях впритык
# первый update застревает на инициализации сессии («reply session initialization
# conflicted»), вечно висит в ingress-spool с «keeping for retry» и блокирует ВСЕ
# следующие — бот молчит и сам не расчищается. Руками лечится рестартом шлюза
# и очисткой очереди; здесь это делает машина, пока клиент не заметил.
#
# Нужен при ЛЮБОЙ версии движка: корень бага у автора движка, не у нас.
# На 2026.7.1-2 конфликт не воспроизводится, но гарантий под нагрузкой нет.
#
# Признак залипания: файлы в очереди лежат дольше STALE_MIN минут.
# В норме апдейты разбираются за секунды, поэтому «старый» файл = застряло.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"                 # recent_engine_log / compact_engine_log / ENGINE_LOG_DIR

SPOOL="$HOME/.openclaw/telegram/ingress-spool-default"
LOG="$HOME/.openclaw/office-watchdog.log"
STALE_MIN=5          # файл в очереди дольше этого — подозрение на залипание
HARD_STALE_MIN=15    # дольше этого — залипание без вариантов, лечим и без улик в логах
COOLDOWN_SEC=600     # не лечить чаще раза в 10 мин (защита от петли рестартов)
STAMP="$HOME/.openclaw/.watchdog-last-heal"
FAILED_COOLDOWN_SEC=300
FAILED_STAMP="$HOME/.openclaw/.watchdog-last-revive"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$1" >> "$LOG" 2>/dev/null || true; }

# Улики ищем в двух местах — user-journald и файловые логи движка (recent_engine_log
# из lib.sh). На живом прогоне 26.07 `journalctl --user` оказался пуст, то есть сторож,
# смотревший только туда, улик не находил никогда и лечил лишь по «очередь стоит >15 мин».

# Службы НЕТ вообще — самый тяжёлый случай, и до 29.07 сторож его не видел.
# Первый живой прогон клиентом 29.07: `openclaw daemon install` упал
# в cloud-init, юнит не создался, служба висела в inactive — не failed. Сторож
# честно просыпался каждые 2 минуты полчаса подряд и не делал ничего, потому что
# ниже стоит `is-active || exit 0`, а inactive под это подпадает.
# Лечим тем же способом, каким ставили: создаём юнит заново и запускаем.
# Спрашиваем systemd, а не диск: наличие файла — не то же самое, что «служба
# известна системе», и проверка по файлу давала ложное срабатывание там, где
# служба на самом деле есть (поймано тестом test-startup.sh сразу после правки).
if ! systemctl --user cat openclaw-gateway >/dev/null 2>&1; then
  now=$(date +%s)
  last_revive=0
  [ -f "$FAILED_STAMP" ] && last_revive=$(cat "$FAILED_STAMP" 2>/dev/null || echo 0)
  if [ $((now - last_revive)) -lt "$FAILED_COOLDOWN_SEC" ]; then
    log "юнита gateway нет, но пересоздавали <${FAILED_COOLDOWN_SEC}с назад — жду"
    exit 0
  fi
  log "юнита openclaw-gateway НЕТ → пересоздаю службу"
  date +%s > "$FAILED_STAMP" 2>/dev/null || true
  out="$(openclaw daemon install 2>&1)" || true
  # Результат проверяем тем же способом, каким искали пропажу — у systemd,
  # а не по файлу на диске. Разные способы в одной ветке уже дали расхождение.
  if systemctl --user cat openclaw-gateway >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable --now openclaw-gateway >/dev/null 2>&1 || true
    sleep 10
    log "после пересоздания: gateway=$(systemctl --user is-active openclaw-gateway 2>/dev/null || echo unknown)"
  else
    log "пересоздать службу не вышло: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fi
  exit 0
fi

# Служба упала совсем (failed) — поднимаем. Это НЕ случай залипшей очереди: тут
# лечить нечего, надо просто вернуть офис к жизни. Живой прогон 26.07: гонка
# «миграция ↔ авто-рестарт» уронила службу в failed, а сторож выходил на первой
# же строке (is-active) и клиент остался бы с мёртвым офисом навсегда.
if systemctl --user is-failed --quiet openclaw-gateway 2>/dev/null; then
  now=$(date +%s)
  last_revive=0
  [ -f "$FAILED_STAMP" ] && last_revive=$(cat "$FAILED_STAMP" 2>/dev/null || echo 0)
  if [ $((now - last_revive)) -lt "$FAILED_COOLDOWN_SEC" ]; then
    log "gateway в failed, но поднимали <${FAILED_COOLDOWN_SEC}с назад — жду (иначе петля)"
    exit 0
  fi
  log "gateway в состоянии failed → reset-failed + start"
  # Причина падения — в наш лог, но по-человечески: только ошибки и только текст
  # сообщения. Сырой JSON движка (как было) топил в себе собственные строки сторожа
  # и для поддержки был бесполезен (замечание прогона 27.07).
  compact_engine_log 8 | while IFS= read -r line; do
    [ -n "$line" ] && log "  движок: $line"
  done
  systemctl --user reset-failed openclaw-gateway >/dev/null 2>&1 || true
  systemctl --user start openclaw-gateway >/dev/null 2>&1 || true
  date +%s > "$FAILED_STAMP" 2>/dev/null || true
  sleep 10
  log "после подъёма: gateway=$(systemctl --user is-active openclaw-gateway 2>/dev/null || echo unknown)"
  exit 0
fi

# Шлюз не запущен и не failed (штатно остановлен, ещё стартует) — лечить нечего.
systemctl --user is-active openclaw-gateway >/dev/null 2>&1 || exit 0

[ -d "$SPOOL" ] || exit 0

# Застрявшие апдейты: файлы старше STALE_MIN минут.
stuck_count=$(find "$SPOOL" -type f -mmin +"$STALE_MIN" 2>/dev/null | wc -l | tr -d '[:space:]')
[ "${stuck_count:-0}" -gt 0 ] 2>/dev/null || exit 0

# ВАЖНО: сам по себе «старый» файл ещё не повод рестартовать — модель может долго
# думать над сложным запросом, и рестарт оборвёт живую работу клиента. Поэтому
# лечим либо при улике в логах (тот самый конфликт), либо при явном долгом залипании.
hard_count=$(find "$SPOOL" -type f -mmin +"$HARD_STALE_MIN" 2>/dev/null | wc -l | tr -d '[:space:]')
evidence=""
if recent_engine_log | grep -qiE "session initialization conflicted|conflicted for agent|keeping for retry"; then
  evidence="конфликт в логах"
elif [ "${hard_count:-0}" -gt 0 ] 2>/dev/null; then
  evidence="очередь стоит >${HARD_STALE_MIN} мин"
fi
if [ -z "$evidence" ]; then
  log "в очереди $stuck_count старых update(ов), но улик залипания нет — не трогаю (возможно, идёт долгий ответ)"
  exit 0
fi

# Антипетля: если лечили недавно — не долбим рестартами, пишем в лог и выходим.
if [ -f "$STAMP" ]; then
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - last)) -lt "$COOLDOWN_SEC" ]; then
    log "залипание есть ($stuck_count шт.), но лечили <${COOLDOWN_SEC}с назад — жду, не рестартую"
    exit 0
  fi
fi

log "залипла очередь Telegram: $stuck_count update(ов) старше ${STALE_MIN} мин ($evidence) → чищу и рестартую шлюз"
rm -f "$SPOOL"/* 2>/dev/null || true
systemctl --user restart openclaw-gateway >/dev/null 2>&1 || true
date +%s > "$STAMP" 2>/dev/null || true

sleep 5
state=$(systemctl --user is-active openclaw-gateway 2>/dev/null || echo unknown)
log "после лечения: gateway=$state"

# Хвост лога не растёт бесконечно.
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 500 ]; then
  tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
fi
