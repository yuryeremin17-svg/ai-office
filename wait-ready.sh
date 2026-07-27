#!/usr/bin/env bash
# ============================================================================
# wait-ready.sh — дождаться, пока служба офиса реально заработает.
#
# Зачем отдельным файлом: раньше проверка жила внутри install.sh как `sleep 8`
# и одно чтение статуса. На первой установке служба в этот момент ещё
# «activating» (идут стартовые миграции ~2 мин) — установщик печатал
# «Офис готов» при умирающем боте, а клиент получал мёртвый офис с зелёным
# рапортом (живой прогон 26.07). Вынесено, чтобы проверялось тестом:
# tests/test-startup.sh гоняет это с подставным systemctl.
#
# Готово = active И без новых перезапусков подряд (по умолчанию 3 проверки).
# Если служба успела упасть в failed — поднимаем: reset-failed + start.
#
# Аргументы: [unit] [лимит_сек] [интервал_сек]
# Выход: 0 — служба готова; 1 — не дождались (вызывающий решает, что говорить).
# ============================================================================
set -uo pipefail

UNIT="${1:-openclaw-gateway}"
LIMIT="${2:-360}"
INTERVAL="${3:-10}"
STABLE_NEEDED="${WAIT_READY_STABLE:-3}"

waited=0
prev=""
stable=0

while [ "$waited" -lt "$LIMIT" ]; do
  state=$(systemctl --user is-active "$UNIT" 2>/dev/null || echo unknown)
  case "$state" in
    active)
      restarts=$(systemctl --user show "$UNIT" -p NRestarts --value 2>/dev/null || echo 0)
      if [ "$restarts" = "$prev" ]; then stable=$((stable + 1)); else stable=0; fi
      prev="$restarts"
      [ "$stable" -ge "$STABLE_NEEDED" ] && exit 0
      ;;
    failed)
      # Гонка «долгая миграция ↔ авто-рестарт» могла выжечь лимит стартов
      # и бросить службу. Снимаем отметку и стартуем заново.
      printf "  служба упала на старте — поднимаю (первая миграция могла затянуться)\n"
      systemctl --user reset-failed "$UNIT" >/dev/null 2>&1 || true
      systemctl --user start "$UNIT" >/dev/null 2>&1 || true
      stable=0; prev=""
      ;;
    *)
      stable=0
      ;;
  esac
  sleep "$INTERVAL"
  waited=$((waited + INTERVAL))
done

exit 1
