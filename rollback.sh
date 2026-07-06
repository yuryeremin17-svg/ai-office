#!/usr/bin/env bash
# ============================================================================
# rollback.sh — откат офиса на прошлую версию сборки (когда обновление сломало).
# Откатывает НАШУ сборку на git-метку, накатывает её в рабочую папку (память
# клиента НЕ трогается) и перезапускает. Движок откатывается отдельно и осознанно
# (openclaw update --tag <версия> --yes), т.к. downgrade движка — редкий шаг.
#
#   rollback.sh --list          показать доступные версии (git-метки)
#   rollback.sh <метка|commit>  откатиться на неё
#   rollback.sh                 откатиться на предыдущую метку
# ============================================================================
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVF="$HOME/.openclaw/.office-env"; [ -f "$ENVF" ] && . "$ENVF" || true
OFFICE_DIR="${OFFICE_DIR:-/root/office}"
cd "$SRC_DIR"
[ -d .git ] || { echo "rollback: сборка не git-репо — откат невозможен"; exit 1; }

if [ "${1:-}" = "--list" ]; then
  echo "Доступные версии (метки, свежие сверху):"
  git tag --sort=-version:refname | head -20
  echo "Текущее состояние: $(git describe --tags --always 2>/dev/null || echo '?')"
  exit 0
fi

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  TARGET=$(git tag --sort=-version:refname | sed -n '2p')   # предыдущая метка
  [ -z "$TARGET" ] && { echo "rollback: нет предыдущей метки — укажите версию явно (см. --list)"; exit 1; }
  echo "rollback: откат на предыдущую метку $TARGET"
fi

git checkout "$TARGET" 2>&1 | tail -1
bash "$SRC_DIR/office-sync.sh" "$SRC_DIR" "$OFFICE_DIR"
openclaw daemon restart >/dev/null 2>&1 || openclaw daemon start >/dev/null 2>&1 || true

echo "rollback: офис откачен на $TARGET и перезапущен (память клиента не тронута)."
echo "  сборка: $(cat "$SRC_DIR/VERSION" 2>/dev/null || echo '?'); движок: $(openclaw --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1 || echo '?')"
echo "  ВНИМАНИЕ: автообновление приостановлено (открепились от ветки). Когда почините —"
echo "  верните на ветку:  cd $SRC_DIR && git checkout master && bash update.sh"
