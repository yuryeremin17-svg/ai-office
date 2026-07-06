#!/usr/bin/env bash
# ============================================================================
# office-sync.sh — единая правда «наша полка / полка клиента».
# Накатывает НАШУ сборку в рабочую папку офиса, НЕ трогая личное клиента.
# Зовётся и установщиком (install.sh), и обновлялкой (update.sh).
#
#   Наше (обновляется, перезаписывается): skills/, SOUL.md, AGENTS.md
#   Личное клиента (создаётся 1 раз, дальше не трогаем): MEMORY.md, USER.md,
#                                                        memory/, knowledge/
#
# Использование:  office-sync.sh <SRC_сборка> <DST_рабочая_папка>
# ============================================================================
set -euo pipefail
SRC="${1:?нужен путь к сборке}"
DST="${2:?нужен путь к рабочей папке офиса}"
[ -d "$SRC/workspace" ] || { echo "office-sync: нет $SRC/workspace"; exit 1; }

# guard: пустой/битый DST — недопустим (ниже есть rm, страхуемся)
[ -n "$DST" ] && [ "$DST" != "/" ] || { echo "office-sync: недопустимый DST '$DST'"; exit 1; }
mkdir -p "$DST"

# --- Наша полка: всегда свежая ---------------------------------------------
# Накатываем наши навыки поверх (перезапись), НЕ удаляя чужое: навыки, созданные
# ботом/клиентом, остаются. Каждый НАШ навык помечен файлом .ours — по нему и только
# по нему удаляем отозванные (были нашими, убраны из сборки). Клиентские без .ours не трогаем.
mkdir -p "$DST/skills"
cp -rf "$SRC/workspace/skills/." "$DST/skills/"
for d in "$DST"/skills/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  if [ -f "$d/.ours" ] && [ ! -d "$SRC/workspace/skills/$name" ]; then
    rm -rf "$d" && echo "office-sync: удалён отозванный навык $name"
  fi
done
cp -f  "$SRC/workspace/SOUL.md"   "$DST/SOUL.md"
cp -f  "$SRC/workspace/AGENTS.md" "$DST/AGENTS.md"

# --- Полка клиента: только если ещё нет (никогда не перезатираем) -----------
for f in MEMORY.md USER.md; do
  [ -e "$DST/$f" ] || cp "$SRC/workspace/$f" "$DST/$f"
done
mkdir -p "$DST/memory" "$DST/knowledge"

echo "office-sync: наша полка накатана, личное клиента не тронуто"
