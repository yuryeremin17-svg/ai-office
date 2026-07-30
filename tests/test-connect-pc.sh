#!/usr/bin/env bash
# ============================================================================
# Тест connect-pc.sh — «второе окно офиса».
#
# Настоящего сервера здесь нет, поэтому подменяются `code` (программа-туннель),
# `id` (скрипт требует root) и `hostname`. Проверяем НАШУ логику: как строится
# имя машины и ссылка, не просим ли вход второй раз, честно ли скрипт говорит,
# что связь не поднялась, и что выключение действительно всё снимает.
#
# Чего этот тест не проверяет (нужен живой Ubuntu): встаёт ли туннель под root
# и переживает ли он перезагрузку. Это отдельная проверка на сервере.
#
# Запуск: bash projects/office-boilerplate/tests/test-connect-pc.sh
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CALLS="$WORK/calls"                 # журнал вызовов code
LOGGED_IN="$WORK/logged_in"         # выполнен ли вход
STATUS_SAYS="$WORK/status_says"     # что отвечает `code tunnel status`
HOSTNAME_IS="$WORK/hostname_is"

mkdir -p "$WORK/bin"

cat > "$WORK/bin/code" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  --version)            echo "code 1.131.0 (stub)" ;;
  "tunnel user show")   [ -f "$LOGGED_IN" ] && { echo "github (stub)"; exit 0; } || exit 1 ;;
  "tunnel user login"*) touch "$LOGGED_IN" ;;
  "tunnel status")      cat "$STATUS_SAYS" ;;
esac
exit 0
STUB

cat > "$WORK/bin/id" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
STUB

cat > "$WORK/bin/hostname" <<'STUB'
#!/usr/bin/env bash
cat "$HOSTNAME_IS"
STUB

cat > "$WORK/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

chmod +x "$WORK/bin"/*
export PATH="$WORK/bin:$PATH"
export CALLS LOGGED_IN STATUS_SAYS HOSTNAME_IS
export CODE_BIN="$WORK/bin/code"

PASS=0; FAIL=0
check() {                      # check "что проверяем" "ожидаем" "получили"
  if [ "$2" = "$3" ]; then printf "  ✓ %s\n" "$1"; PASS=$((PASS+1))
  else printf "  ✗ %s\n     ожидали: %s\n     вышло:   %s\n" "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
contains() {                   # contains "что проверяем" "подстрока" "текст"
  case "$3" in
    *"$2"*) printf "  ✓ %s\n" "$1"; PASS=$((PASS+1)) ;;
    *) printf "  ✗ %s\n     не нашли: %s\n" "$1" "$2"; FAIL=$((FAIL+1)) ;;
  esac
}

run() { OFFICE_DIR="$WORK/office" bash "$ROOT/connect-pc.sh" "$@" 2>&1; }

reset() { : > "$CALLS"; rm -f "$LOGGED_IN"; echo "connected" > "$STATUS_SAYS"; echo "office-boss" > "$HOSTNAME_IS"; }
mkdir -p "$WORK/office"

echo "=== Тест connect-pc.sh ==="

# ─── 1. Первый запуск: вход просят, служба ставится, ссылка выдаётся ────────
echo "--- 1. Первый запуск"
reset
OUT="$(run)"
contains "просит открыть страницу входа" "github.com/login/device" "$OUT"
contains "вход запрошен" "tunnel user login --provider github" "$(cat "$CALLS")"
contains "связь ставится службой, а не разовым запуском" "tunnel service install" "$(cat "$CALLS")"
contains "ссылка собрана из имени машины и папки офиса" "https://vscode.dev/tunnel/office-boss/office" "$OUT"
contains "сказано, чем открывать" "Chrome" "$OUT"

# ─── 2. Повторный запуск: вход второй раз не просим ────────────────────────
echo "--- 2. Повторный запуск"
: > "$CALLS"
OUT="$(run)"
case "$(cat "$CALLS")" in
  *"user login"*) check "вход второй раз не просят" "не просят" "просят" ;;
  *) check "вход второй раз не просят" "не просят" "не просят" ;;
esac
contains "ссылка та же" "https://vscode.dev/tunnel/office-boss/office" "$OUT"

# ─── 3. Кривое имя сервера ─────────────────────────────────────────────────
# Хостинг может назвать сервер как угодно, а сервису туннеля нужны латиница,
# цифры и дефис. Кириллическое имя раньше уронило бы регистрацию.
echo "--- 3. Имя сервера, которое сервис не примет"
reset; touch "$LOGGED_IN"
echo "Офис Юрия!!" > "$HOSTNAME_IS"
OUT="$(run)"
contains "кириллица и знаки не уезжают в имя машины" "https://vscode.dev/tunnel/office/office" "$OUT"

reset; touch "$LOGGED_IN"
echo "MyOffice.Server_01" > "$HOSTNAME_IS"
OUT="$(run)"
contains "точки и подчёркивания заменены, регистр снижен" "vscode.dev/tunnel/myoffice-server-01/office" "$OUT"

# ─── 4. Служба поставлена, но связь не поднялась ────────────────────────────
# Худший вариант — сказать «готово» и дать ссылку, которая не открывается.
echo "--- 4. Связь не поднялась"
reset; touch "$LOGGED_IN"
echo "stopped" > "$STATUS_SAYS"
OUT="$(run)"
contains "честно предупреждает, а не рапортует «готово»" "связь пока не поднялась" "$OUT"
contains "говорит, куда посмотреть" "tunnel service log" "$OUT"

# ─── 5. Выключение снимает всё ──────────────────────────────────────────────
echo "--- 5. Выключение"
reset; touch "$LOGGED_IN"
OUT="$(run --off)"
CALLED="$(cat "$CALLS")"
contains "служба снята" "tunnel service uninstall" "$CALLED"
contains "машина отвязана" "tunnel unregister" "$CALLED"
contains "выход из аккаунта" "tunnel user logout" "$CALLED"
contains "сказано, что бот продолжает работать" "Бот в Telegram работает" "$OUT"

echo
echo "Пройдено: $PASS, провалено: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
