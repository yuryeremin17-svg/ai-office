#!/usr/bin/env bash
# ============================================================================
# AI-офис руководителя на OpenClaw — установщик «под ключ»
# Разворачивает готовый, настроенный, безопасный офис на чистом сервере.
#
# Требуется заранее:
#   1. Сервер Ubuntu 22.04/24.04, доступ root по SSH
#   2. OpenRouter API-ключ с ПОПОЛНЕННЫМ балансом (free-tier не годится)
#   3. Токен Telegram-бота от @BotFather
#   4. Свой числовой Telegram user id (узнать у @userinfobot)
#
# Запуск:  sudo bash install.sh
# ============================================================================
set -euo pipefail

say() { printf "\n\033[1;33m▸ %s\033[0m\n" "$1"; }
ok()  { printf "\033[0;32m  ✓ %s\033[0m\n" "$1"; }
die() { printf "\n\033[0;31m✗ %s\033[0m\n" "$1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # наша сборка (git-репо, останется для обновлений)
OFFICE_DIR="/root/office"                                    # рабочая папка: ЛИЧНОЕ клиента живёт тут
# Сборка и рабочая папка не должны совпадать — иначе обновление перемешает наше с личным.
[ "$SCRIPT_DIR" = "$OFFICE_DIR" ] && die "склонируйте сборку в /root/office-src (не в /root/office) и запустите оттуда"

# Все пути офиса (.openclaw, systemd --user) — под root. sudo без -H мог оставить HOME юзера — форсируем.
[ "$(id -u)" = "0" ] && export HOME=/root
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# --- 1. Секреты (из окружения или спросим) ---------------------------------
say "Шаг 1/9 — ключи и доступы"
: "${OPENROUTER_API_KEY:=}"; : "${TELEGRAM_BOT_TOKEN:=}"; : "${OWNER_TG_ID:=}"
# Не интерактивный запуск (curl|bash, службы) без готовых секретов — не тыкаться в пустой read, а честно упасть.
if { [ -z "$OPENROUTER_API_KEY" ] || [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$OWNER_TG_ID" ]; } && [ ! -t 0 ]; then
  die "не хватает секретов, а ввод не интерактивный. Задайте в окружении: OPENROUTER_API_KEY, TELEGRAM_BOT_TOKEN, OWNER_TG_ID"
fi
[ -z "$OPENROUTER_API_KEY" ] && read -rsp "  OpenRouter API-ключ (sk-or-...): " OPENROUTER_API_KEY && echo
[ -z "$TELEGRAM_BOT_TOKEN" ] && read -rp  "  Токен Telegram-бота: " TELEGRAM_BOT_TOKEN
[ -z "$OWNER_TG_ID" ]        && read -rp  "  Ваш числовой Telegram id: " OWNER_TG_ID
[ -z "$OPENROUTER_API_KEY" ] && die "нет OpenRouter ключа"
[ -z "$TELEGRAM_BOT_TOKEN" ] && die "нет токена бота"
[[ "$OWNER_TG_ID" =~ ^[0-9]+$ ]] || die "id должен быть числом (узнать: @userinfobot)"

# Регион влияет на выбор AI-модели: у российских аккаунтов OpenRouter недоступны Claude/GPT/Gemini
# (регион-блок с мая 2026), поэтому для России дефолт — DeepSeek (доступен, дёшев, платится рублями).
: "${OFFICE_REGION:=}"
if [ -z "$OFFICE_REGION" ]; then
  if [ -t 0 ]; then
    read -rp "  Вы в России? (влияет на выбор AI-модели) [y/N]: " _reg
    case "$_reg" in [yYдД]*) OFFICE_REGION=ru;; *) OFFICE_REGION=global;; esac
  else
    OFFICE_REGION=global
  fi
fi
if [ "$OFFICE_REGION" = "ru" ]; then
  MODEL_PRIMARY="openrouter/deepseek/deepseek-v4-flash"
  MODEL_FALLBACK="openrouter/deepseek/deepseek-v4-pro"
  ok "регион: Россия — мозг DeepSeek (Claude/GPT/Gemini недоступны рос. аккаунту OpenRouter)"
else
  MODEL_PRIMARY="openrouter/google/gemini-2.5-flash"
  MODEL_FALLBACK="openrouter/anthropic/claude-sonnet-5"
  ok "регион: обычный — мозг Gemini (эконом) + Claude (умный)"
fi

# проверка бота и баланса ДО установки — чтобы не ловить грабли теста
say "Проверяю бота и баланс OpenRouter"
# различаем сетевой сбой (пустой ответ) и реально невалидный токен (ok:false)
GETME=$(curl -s -m 15 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" || echo '')
[ -z "$GETME" ] && die "нет связи с Telegram — проверьте сеть и повторите"
echo "$GETME" | grep -q '"ok":true' || die "токен бота невалиден (Telegram отклонил запрос)"
BOT_USER=$(echo "$GETME" | grep -o '"username":"[^"]*"' | sed 's/.*:"//;s/"$//')
ok "бот: @${BOT_USER}"
KEYINFO=$(curl -s "https://openrouter.ai/api/v1/key" -H "Authorization: Bearer ${OPENROUTER_API_KEY}")
echo "$KEYINFO" | grep -o '"is_free_tier":[a-z]*' | grep -q true && printf "\033[0;31m  ⚠ OpenRouter на free-tier — платные модели не работают, пополните баланс!\033[0m\n"
# Остаток баланса: если задан лимит и осталось мало — предупредить (иначе бот замолчит через день-два)
REMAIN=$(echo "$KEYINFO" | python3 -c "import sys,json;d=json.load(sys.stdin).get('data',{});r=d.get('limit_remaining');print(r if r is not None else '')" 2>/dev/null || echo '')
if [ -n "$REMAIN" ]; then
  awk -v r="$REMAIN" 'BEGIN{exit !(r<3)}' && printf "\033[0;31m  ⚠ На ключе OpenRouter осталось ~\$%s — мало, бот скоро замолчит. Пополните до старта работы клиента.\033[0m\n" "$REMAIN" || ok "баланс OpenRouter: ~\$${REMAIN}"
fi

# --- 2. Установка OpenClaw ---------------------------------------------------
say "Шаг 2/9 — установка OpenClaw"
if ! command -v openclaw >/dev/null 2>&1; then
  curl -fsSL https://openclaw.ai/install.sh | bash
fi
command -v openclaw >/dev/null 2>&1 || die "openclaw не установился"
ok "OpenClaw $(openclaw --version 2>/dev/null | head -1)"

# --- 3. Болванка офиса (две полки: наше / личное клиента) --------------------
# SCRIPT_DIR = наша сборка (git-репо, обновляется). OFFICE_DIR = рабочая папка,
# где живёт ЛИЧНОЕ клиента (память/MEMORY/USER) — его обновление не трогает.
say "Шаг 3/9 — рабочая папка офиса (наше и личное — раздельно)"
bash "$SCRIPT_DIR/office-sync.sh" "$SCRIPT_DIR" "$OFFICE_DIR"
ok "болванка развёрнута в $OFFICE_DIR"

# --- 4. Конфигурация (все уроки теста одним патчем) --------------------------
say "Шаг 4/9 — конфигурация офиса"
PATCH="$(mktemp)"
trap 'rm -f "$PATCH"' EXIT   # temp содержит ключи — стереть при любом выходе, даже при падении
cat > "$PATCH" <<JSON
{
  "env": { "OPENROUTER_API_KEY": "${OPENROUTER_API_KEY}" },
  "gateway": { "mode": "local", "auth": { "mode": "none" } },
  "agents": { "defaults": {
    "workspace": "${OFFICE_DIR}",
    "model": { "primary": "${MODEL_PRIMARY}",
               "fallbacks": ["${MODEL_FALLBACK}"] },
    "thinkingDefault": "off",
    "maxConcurrent": 1,
    "contextTokens": 48000,
    "compaction": { "mode": "default" },
    "contextPruning": { "mode": "cache-ttl", "keepLastAssistants": 8, "softTrimRatio": 0.7, "hardClearRatio": 0.9 }
  }},
  "messages": { "inbound": { "debounceMs": 2000 } },
  "tools": {
    "profile": "full",
    "deny": ["gateway","exec","process","subagents","sessions_spawn","apply_patch","nodes","skill_workshop","browser"],
    "elevated": { "enabled": false },
    "loopDetection": { "enabled": true },
    "web": { "search": { "enabled": true, "provider": "duckduckgo", "maxResults": 5, "cacheTtlMinutes": 15 } }
  },
  "cron": { "enabled": true },
  "channels": { "telegram": {
    "enabled": true,
    "botToken": "${TELEGRAM_BOT_TOKEN}",
    "dmPolicy": "allowlist",
    "allowFrom": [${OWNER_TG_ID}],
    "commands": { "native": false, "nativeSkills": false },
    "customCommands": [
      { "command": "start",    "description": "Знакомство: кто я и что умею" },
      { "command": "fokus",    "description": "Фокус дня — 3 задачи из хаоса" },
      { "command": "zadacha",  "description": "Разобрать задачу по шагам" },
      { "command": "proekt",   "description": "Вести проект: этапы, сроки, статус" },
      { "command": "pismo",    "description": "Помочь с деловым письмом" },
      { "command": "dokument", "description": "Разобрать документ или PDF" },
      { "command": "proverit", "description": "Проверить текст перед отправкой" },
      { "command": "razbor",   "description": "Разобрать вопрос или тему" },
      { "command": "rynok",    "description": "Разбор рынка и конкурентов" },
      { "command": "dengi",    "description": "Экономика решения, окупаемость" },
      { "command": "pomosh",   "description": "Что я умею" }
    ]
  }}
}
JSON
openclaw config patch --file "$PATCH" >/dev/null
rm -f "$PATCH"
openclaw config validate >/dev/null && ok "конфиг применён и валиден"

# --- 5. Безопасность: файрвол (наружу только SSH) ---------------------------
say "Шаг 5/9 — файрвол (наружу только SSH, шлюз остаётся loopback)"
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
  # подтверждаем, что SSH реально разрешён — иначе можно залочить себя из сервера
  if ufw status 2>/dev/null | grep -q "22/tcp"; then
    ok "ufw: разрешён только SSH(22)"
  else
    printf "\033[0;31m  ⚠ ВНИМАНИЕ: ufw включён, но правило SSH(22) не подтверждено — проверьте доступ до выхода!\033[0m\n"
  fi
else
  printf "  (ufw не найден — поставьте файрвол вручную, порт 18789 наружу НЕ открывать)\n"
fi

# --- 6. Права на секреты -----------------------------------------------------
say "Шаг 6/9 — права доступа"
chmod 700 "$HOME/.openclaw" 2>/dev/null || true
chmod 600 "$HOME/.openclaw/openclaw.json" 2>/dev/null || true
ok "права ужаты (700/600)"

# --- 7. Автозапуск -----------------------------------------------------------
say "Шаг 7/9 — служба, автозапуск и полное русское меню"
openclaw daemon install >/dev/null 2>&1 || true
loginctl enable-linger "$(whoami)" >/dev/null 2>&1 || true
# дождаться готовности user-manager, иначе systemctl --user не подхватит таймеры (гонка на свежем сервере)
for _ in $(seq 1 15); do systemctl --user is-system-running >/dev/null 2>&1 && break; sleep 1; done

# Полное меню (11 команд, включая /new /compact /model /status). Движок вырезает эти
# зарезервированные команды из своего меню — поэтому доставляем их через Telegram API
# systemd-службой, которая доигрывает меню после каждого старта шлюза (перекрывает пуш движка).
MENU_DIR="$HOME/.openclaw"
printf '%s' "$TELEGRAM_BOT_TOKEN" > "$MENU_DIR/.office-menu-token"; chmod 600 "$MENU_DIR/.office-menu-token"
cat > "$MENU_DIR/office-menu.json" <<'MENU'
{"commands":[
{"command":"start","description":"Знакомство: кто я и что умею"},
{"command":"fokus","description":"Фокус дня — 3 задачи из хаоса"},
{"command":"zadacha","description":"Разобрать задачу по шагам"},
{"command":"proekt","description":"Вести проект: этапы, сроки, статус"},
{"command":"pismo","description":"Помочь с деловым письмом"},
{"command":"dokument","description":"Разобрать документ или PDF"},
{"command":"proverit","description":"Проверить текст перед отправкой"},
{"command":"razbor","description":"Разобрать вопрос или тему"},
{"command":"rynok","description":"Разбор рынка и конкурентов"},
{"command":"dengi","description":"Экономика решения, окупаемость"},
{"command":"new","description":"🔄 Новый диалог — обнулить контекст (дешевле)"},
{"command":"compact","description":"Сжать контекст — оставить суть"},
{"command":"model","description":"Сменить мозг — умный / экономный"},
{"command":"status","description":"Статус: модель и заполнение сессии"},
{"command":"pomosh","description":"Что я умею"}
]}
MENU
cat > "$MENU_DIR/office-set-menu.sh" <<SH
#!/usr/bin/env bash
TOKEN=\$(cat "$MENU_DIR/.office-menu-token")
for w in 20 20 15; do sleep "\$w"
  curl -s -X POST "https://api.telegram.org/bot\${TOKEN}/setMyCommands" \\
    -H "Content-Type: application/json" --data @"$MENU_DIR/office-menu.json" >/dev/null 2>&1 || true
done
SH
chmod +x "$MENU_DIR/office-set-menu.sh"
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/office-menu.service" <<UNIT
[Unit]
Description=Enforce Russian Telegram menu after OpenClaw gateway start
After=openclaw-gateway.service
PartOf=openclaw-gateway.service
[Service]
Type=oneshot
ExecStart=$MENU_DIR/office-set-menu.sh
TimeoutStartSec=120
[Install]
WantedBy=openclaw-gateway.service
UNIT
systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user enable office-menu.service >/dev/null 2>&1 || true

openclaw daemon restart >/dev/null 2>&1 || openclaw daemon start >/dev/null 2>&1 || true
systemctl --user start office-menu.service >/dev/null 2>&1 || true
ok "служба поднята (переживёт выход из SSH), меню доигрывается после старта"

# --- 8. Автообновление (будильник раз в неделю) -----------------------------
say "Шаг 8/9 — автообновление офиса"
# Окружение для обновлялки: где рабочая папка и куда слать пульс (пока выключен).
cat > "$HOME/.openclaw/.office-env" <<ENV
OFFICE_DIR="${OFFICE_DIR}"
OFFICE_SRC="${SCRIPT_DIR}"
OWNER_TG_ID="${OWNER_TG_ID}"
HEARTBEAT_URL=""
ENV
chmod 600 "$HOME/.openclaw/.office-env"
# Будильник: раз в неделю ночью зовёт update.sh из нашей сборки.
# update.sh сам решает, есть ли что обновлять, и трогает офис только если да.
cat > "$HOME/.config/systemd/user/office-update.service" <<UNIT
[Unit]
Description=Weekly OpenClaw office self-update (engine + our skills, keeps client data)
[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/update.sh
TimeoutStartSec=600
UNIT
cat > "$HOME/.config/systemd/user/office-update.timer" <<'UNIT'
[Unit]
Description=Run office self-update weekly (Mon 04:00)
[Timer]
OnCalendar=Mon *-*-* 04:00:00
Persistent=true
RandomizedDelaySec=1800
[Install]
WantedBy=timers.target
UNIT
# Пульс «жив»: частый таймер (каждые 15 мин) шлёт сигнал на датчик, если офис работает.
# Пока HEARTBEAT_URL пуст в .office-env — heartbeat.sh тихо ничего не делает.
cat > "$HOME/.config/systemd/user/office-heartbeat.service" <<UNIT
[Unit]
Description=OpenClaw office heartbeat (ping external monitor if gateway alive)
[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/heartbeat.sh
TimeoutStartSec=30
UNIT
cat > "$HOME/.config/systemd/user/office-heartbeat.timer" <<'UNIT'
[Unit]
Description=Send office heartbeat every 15 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
UNIT
systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user enable --now office-update.timer >/dev/null 2>&1 || true
systemctl --user enable --now office-heartbeat.timer >/dev/null 2>&1 || true
ok "будильник (обновление раз в неделю) и пульс (каждые 15 мин) поставлены"

# --- 9. Проверка -------------------------------------------------------------
say "Шаг 9/9 — проверка"
sleep 8
STATE=$(systemctl --user is-active openclaw-gateway 2>/dev/null || echo unknown)
ok "служба: $STATE"
printf "\n\033[1;32m════════════════════════════════════════════\033[0m\n"
printf "\033[1;32m  Офис готов. Напишите боту @%s → /start\033[0m\n" "${BOT_USER}"
printf "\033[1;32m════════════════════════════════════════════\033[0m\n\n"
echo "Команды экономии в чате: /new (новый диалог), /compact (сжать), /model (сменить мозг), /status"
echo "Сменить на умную модель:  openclaw config set agents.defaults.model.primary ${MODEL_FALLBACK}"
