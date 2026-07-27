#!/usr/bin/env bash
# ============================================================================
# first-start.sh — первый запуск офиса на чистом сервере.
#
# Зачем отдельный шаг. При самом первом старте движок приводит в порядок свои
# данные (стартовые миграции) и на это время запирает каталог состояния. Живой
# прогон 27.07: миграция шла ~5 минут, а systemd в это окно перезапускал службу
# каждые 20 секунд — 10 попыток подряд, каждая утыкалась в замок и падала.
# Служба в итоге встала, но:
#   — 10 тревожных записей в логе, по которым непонятно, всё ли в порядке;
#   — общее время подошло вплотную к лимиту ожидания: на диске помедленнее
#     установщик сдался бы за десяток секунд до успеха.
#
# Здесь мы убираем причину, а не последствие: на время первой настройки
# авто-рестарт выключается, и мы стартуем службу сами — по одной попытке,
# дожидаясь, пока замок снимут. Движок сам сообщает в логе, до какого момента
# держит замок («retry after <время>») — мы это читаем и ждём ровно столько,
# сколько он просит, вместо слепых попыток.
#
# После успеха временная настройка снимается, и служба живёт как обычно:
# перезапускается сама, если упадёт.
#
# Аргументы: [unit] [общий_лимит_сек] [пауза_между_попытками_сек]
# Выход: 0 — служба поднялась; 1 — не поднялась за отведённое время.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

UNIT="${1:-openclaw-gateway}"
LIMIT="${2:-900}"
PAUSE="${3:-20}"
DROPIN_DIR="$HOME/.config/systemd/user/${UNIT}.service.d"
DROPIN="$DROPIN_DIR/office-firstboot.conf"
STABLE_NEEDED="${FIRST_START_STABLE:-2}"
CHECK_EVERY="${FIRST_START_CHECK:-5}"

note() { printf '  %s\n' "$1"; }

cleanup_dropin() {
  rm -f "$DROPIN"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

# На время первой настройки: systemd не перезапускает службу сам (перезапускаем
# мы, осознанно) и не убивает её по таймауту старта, пока идёт долгая миграция.
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<'UNIT_CONF'
[Service]
Restart=no
TimeoutStartSec=900
UNIT_CONF
systemctl --user daemon-reload >/dev/null 2>&1 || true

# Сколько ещё ждать снятия замка, по словам самого движка. Пусто — не знаем.
lock_wait_seconds() {
  local line iso until_ts now_ts
  line=$(recent_engine_log | grep -oE 'retry after [^"]*' | tail -1)
  [ -z "$line" ] && return 1
  iso=$(printf '%s' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | tail -1)
  [ -z "$iso" ] && return 1
  until_ts=$(date -d "$iso" +%s 2>/dev/null) || return 1   # BSD date не умеет -d — тогда обычная пауза
  now_ts=$(date +%s)
  [ -z "$until_ts" ] && return 1
  echo $(( until_ts - now_ts + 5 ))
}

waited=0
attempt=0
told_about_migration=0

while [ "$waited" -lt "$LIMIT" ]; do
  attempt=$((attempt + 1))
  systemctl --user start "$UNIT" >/dev/null 2>&1 || true

  # Даём службе шанс выйти в рабочий режим и продержаться.
  stable=0
  checked=0
  while [ "$checked" -lt 60 ]; do
    state=$(systemctl --user is-active "$UNIT" 2>/dev/null || echo unknown)
    if [ "$state" = "active" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge "$STABLE_NEEDED" ] && { cleanup_dropin; exit 0; }
    else
      stable=0
      [ "$state" = "failed" ] && systemctl --user reset-failed "$UNIT" >/dev/null 2>&1 || true
      break
    fi
    sleep "$CHECK_EVERY"
    checked=$((checked + CHECK_EVERY))
    waited=$((waited + CHECK_EVERY))
  done

  # Не поднялась — узнаём у движка, сколько он ещё держит замок.
  if wait_for=$(lock_wait_seconds) && [ "$wait_for" -gt 0 ] 2>/dev/null; then
    if [ "$told_about_migration" -eq 0 ]; then
      note "первый запуск: движок приводит в порядок свои данные — это разовая работа, ждём"
      told_about_migration=1
    fi
    [ "$wait_for" -gt "$LIMIT" ] && wait_for="$PAUSE"
    note "настройка ещё идёт, ждём ${wait_for}с (попытка ${attempt})"
    sleep "$wait_for"
    waited=$((waited + wait_for))
  else
    sleep "$PAUSE"
    waited=$((waited + PAUSE))
  fi
done

# Не успели: возвращаем штатное поведение (пусть systemd пробует сам) и честно
# отдаём неуспех наверх — установщик не должен рапортовать «готово».
cleanup_dropin
systemctl --user start "$UNIT" >/dev/null 2>&1 || true
exit 1
