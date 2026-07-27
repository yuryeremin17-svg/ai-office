#!/usr/bin/env bash
# ============================================================================
# ensure-node.sh — гарантировать нужный Node ДО установки движка.
#
# Зачем. Установщик движка ставит Node сам, но если в образе сервера уже лежит
# старый дистрибутивный Node, он остаётся первым в PATH и установка падает
# проверкой версии:
#   «Installed Node.js must be 22.22.3+ … but this shell is using v12.22.9 (/usr/bin/node)»
# Живой стенд 27.07 (вечер): свежий ubuntu-22-04-x64 у DigitalOcean приехал
# с nodejs 12.22.9 — установка офиса встала намертво. Днём того же дня на том же
# образе этого не было, то есть зависит от того, какой образ клиенту достанется.
# Клиент такое не разрулит: он видит непонятную ошибку на середине установки.
#
# Что делаем: если Node старый — убираем дистрибутивный пакет (иначе он перекроет
# новый в PATH) и ставим нужный из NodeSource. Если Node уже подходящий — ничего
# не трогаем, чужие окружения не ломаем.
#
# Аргументы: [минимальная_мажорная_версия]  (по умолчанию 22)
# Выход: 0 — Node нужной версии на месте; 1 — не получилось (установщик решит, как быть).
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
[ -f "$HERE/lib.sh" ] && . "$HERE/lib.sh"

NEED="${1:-22}"

node_major() {
  command -v node >/dev/null 2>&1 || return 1
  node -v 2>/dev/null | grep -oE '[0-9]+' | head -1
}

cur="$(node_major || echo '')"

if [ -n "$cur" ] && [ "$cur" -ge "$NEED" ] 2>/dev/null; then
  printf '  ✓ Node v%s — подходит (нужен ≥%s)\n' "$cur" "$NEED"
  exit 0
fi

if [ -n "$cur" ]; then
  printf '  Node v%s слишком старый (движку нужен ≥%s) — заменяю\n' "$cur" "$NEED"
else
  printf '  Node не найден — ставлю v%s\n' "$NEED"
fi

# Свежезагруженный сервер часто занят автообновлениями — без этого apt просто
# упадёт на замке (ловилось на том же стенде).
type apt_wait >/dev/null 2>&1 && apt_wait 300

# Дистрибутивный пакет убираем: он кладёт /usr/bin/node, который перекрывает
# новый /usr/bin/node из NodeSource... точнее, ставится в тот же путь, и apt
# отказывается их совмещать. Только если версия действительно старая.
if [ -n "$cur" ] && [ "$cur" -lt "$NEED" ] 2>/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq nodejs npm libnode-dev >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null 2>&1 || true
fi

curl -fsSL "https://deb.nodesource.com/setup_${NEED}.x" | bash - >/dev/null 2>&1 || true
type apt_wait >/dev/null 2>&1 && apt_wait 300
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null 2>&1 || true
hash -r 2>/dev/null || true

new="$(node_major || echo '')"
if [ -n "$new" ] && [ "$new" -ge "$NEED" ] 2>/dev/null; then
  printf '  ✓ Node v%s установлен\n' "$new"
  exit 0
fi

printf '  ⚠ не удалось получить Node ≥%s (сейчас: %s)\n' "$NEED" "${new:-нет}"
exit 1
