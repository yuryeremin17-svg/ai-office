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
# warn вызывался трижды (ветка DeepSeek на шаге 1 и сбой настроек на шаге 4),
# но определён не был ни здесь, ни в lib.sh. Файл идёт под `set -e`, поэтому
# «command not found» обрывал установку: клиент с ключом, которому OpenRouter
# отдаёт только DeepSeek, не мог поставить офис вообще — падало на шаге 1 из 9.
warn(){ printf "\033[0;33m  ⚠ %s\033[0m\n" "$1"; }
die() { printf "\n\033[0;31m✗ %s\033[0m\n" "$1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # наша сборка (git-репо, останется для обновлений)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"                                       # разбор версии движка и чтение его логов — одни на всю болванку
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

# Какой мозг ставить — НЕ спрашиваем человека. Раньше здесь был вопрос «Вы в России?»,
# и он вводил в заблуждение: доступ к моделям зависит не от места жительства, а от того,
# отдаёт ли OpenRouter модели этому ключу (у части аккаунтов Claude/GPT/Gemini закрыты
# по региону аккаунта). Руководитель из Москвы с зарубежным аккаунтом отвечал «да» и
# получал слабый мозг; с российским аккаунтом отвечал «нет» — и офис вставал на модель,
# к которой у него доступа нет: установка прошла, а бот молчит.
# Теперь спрашиваем сам OpenRouter (detect-brain.sh) — как это делает бот-установщик.
# Заданный в окружении OFFICE_REGION имеет приоритет: его ставит бот, уже сделавший пробу.
: "${OFFICE_REGION:=}"
if [ -z "$OFFICE_REGION" ]; then
  say "Проверяю, какие модели открыты вашему ключу"
  OFFICE_REGION="$(bash "$SCRIPT_DIR/detect-brain.sh" "$OPENROUTER_API_KEY")"
fi
# Разговорная модель. Уровни мозга, модель документов и остальные настройки —
# в apply-settings.sh (вызывается на шаге 4), там же цены и обоснование выбора.
if [ "$OFFICE_REGION" = "ru" ]; then
  MODEL_PRIMARY="openrouter/deepseek/deepseek-v4-flash"
  MODEL_FALLBACK="openrouter/deepseek/deepseek-v4-pro"
  # У аккаунта открыт только DeepSeek: настоящих четырёх уровней нет, есть два.
  # Верхние псевдонимы ведут на тот же pro — обещать несуществующий «самый умный»
  # нельзя, но и оставлять команду мёртвой тоже: человек напишет /model max.
  ok "мозг офиса: DeepSeek (быстрый и умный варианты)"
  warn "чтение PDF и картинок недоступно: DeepSeek принимает только текст"
  warn "уровней мозга два, а не четыре: сильнее pro вашему аккаунту не открыто"
else
  MODEL_PRIMARY="openrouter/google/gemini-2.5-flash"
  MODEL_FALLBACK="openrouter/anthropic/claude-sonnet-5"
  ok "мозг офиса: Gemini на каждый день + Claude на сложное"
fi

# проверка бота и баланса ДО установки — чтобы не ловить грабли теста
say "Проверяю бота и баланс OpenRouter"
# различаем сетевой сбой (пустой ответ) и реально невалидный токен (ok:false)
GETME=$(curl -s -m 15 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" || echo '')
[ -z "$GETME" ] && die "нет связи с Telegram — проверьте сеть и повторите"
echo "$GETME" | grep -q '"ok":true' || die "токен бота невалиден (Telegram отклонил запрос)"
BOT_USER=$(echo "$GETME" | grep -o '"username":"[^"]*"' | sed 's/.*:"//;s/"$//')
ok "бот: @${BOT_USER}"
# Таймаут и перехват — как у проверки Telegram строкой выше. Без них моргание
# сети обрывало установку с голым кодом ошибки: файл под `set -e`, а неудачный
# curl возвращает ненулевой код. Баланс — справочная величина, ради неё терять
# установку нельзя: не узнали — идём дальше молча.
KEYINFO=$(curl -s -m 15 "https://openrouter.ai/api/v1/key" -H "Authorization: Bearer ${OPENROUTER_API_KEY}" || echo '')
[ -z "$KEYINFO" ] && warn "баланс OpenRouter проверить не удалось (сеть) — установка продолжается"
echo "$KEYINFO" | grep -o '"is_free_tier":[a-z]*' | grep -q true && printf "\033[0;31m  ⚠ OpenRouter на free-tier — платные модели не работают, пополните баланс!\033[0m\n"
# Остаток баланса: если задан лимит и осталось мало — предупредить (иначе бот замолчит через день-два)
REMAIN=$(echo "$KEYINFO" | python3 -c "import sys,json;d=json.load(sys.stdin).get('data',{});r=d.get('limit_remaining');print(r if r is not None else '')" 2>/dev/null || echo '')
if [ -n "$REMAIN" ]; then
  awk -v r="$REMAIN" 'BEGIN{exit !(r<3)}' && printf "\033[0;31m  ⚠ На ключе OpenRouter осталось ~\$%s — мало, бот скоро замолчит. Пополните до старта работы клиента.\033[0m\n" "$REMAIN" || ok "баланс OpenRouter: ~\$${REMAIN}"
fi

# --- 2. Установка OpenClaw ---------------------------------------------------
say "Шаг 2/9 — установка OpenClaw"
# git нужен обновлялке (update.sh git pull ежедневно). На голом сервере/из
# cloud-init его может не быть — доставляем заранее, тихо.
apt_wait 300 || printf "  (apt занят автообновлениями дольше обычного — продолжаю)\n"
command -v git >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null 2>&1 || true; }

# Node нужной версии — ДО установщика движка. Если в образе сервера лежит старый
# дистрибутивный Node (у DigitalOcean 27.07 приехал v12), установщик движка падает
# проверкой версии, и клиент упирается в непонятную ошибку на середине установки.
bash "$SCRIPT_DIR/ensure-node.sh" 22 || die "нужен Node 22+, поставить не удалось — напишите нам, поможем"

# Пин движка: держим протестированную версию (фикс P0 session conflict — ≥2026.6.11).
# Читаем ДО установки, чтобы поставить нужную версию сразу: установщик движка принимает
# `--version`. Иначе идёт лишний цикл latest → downgrade (прогон 24.07: +минуты к установке).
PIN=$(tr -d '[:space:]' < "$SCRIPT_DIR/ENGINE_VERSION" 2>/dev/null || echo '')

if ! command -v openclaw >/dev/null 2>&1; then
  if [ -n "$PIN" ]; then
    curl -fsSL https://openclaw.ai/install.sh | bash -s -- --version "$PIN"
  else
    curl -fsSL https://openclaw.ai/install.sh | bash
  fi
  # Свежеустановленный бинарь может лежать вне PATH неинтерактивной оболочки
  # (cloud-init, curl|bash). Добавляем типовые каталоги и сбрасываем кэш путей.
  export PATH="$PATH:$HOME/.local/bin:/usr/local/bin:/root/.local/bin:/root/.npm-global/bin"
  hash -r 2>/dev/null || true
fi
command -v openclaw >/dev/null 2>&1 || die "openclaw не установился (или не найден в PATH)"

# Страховка: если версия всё же разошлась с пином (движок уже стоял, или --version не сработал) — довести.
# Версию читаем через engine_version() из lib.sh — она берёт номер ЦЕЛИКОМ, вместе с
# суффиксом сборки. Прежний разбор терял «-2» в «2026.7.1-2»: пин фактически стоял,
# а установщик печатал «не удалось запинить» и строкой ниже — верную версию (прогон 27.07).
if [ -n "$PIN" ]; then
  ev_cur=$(engine_version || echo '')
  if [ "$ev_cur" != "$PIN" ]; then
    say "Пин движка: $ev_cur → $PIN"
    openclaw update --yes --no-restart --tag "$PIN" >/dev/null 2>&1 || true
    # Судим по ФАКТИЧЕСКОЙ версии, а не по коду возврата update: на прогоне 24.07 команда
    # вернула ненулевой код, хотя пин реально встал → клиент видел ложную тревогу.
    ev_new=$(engine_version || echo '')
    if [ "$ev_new" = "$PIN" ]; then
      ok "движок запинен на $PIN"
    else
      printf "\033[0;31m  ⚠ не удалось запинить движок на %s (остаётся %s) — проверьте вручную\033[0m\n" "$PIN" "${ev_new:-неизвестно}"
    fi
  fi
fi
ok "$(openclaw --version 2>/dev/null | head -1)"

# --- 3. Болванка офиса (две полки: наше / личное клиента) --------------------
# SCRIPT_DIR = наша сборка (git-репо, обновляется). OFFICE_DIR = рабочая папка,
# где живёт ЛИЧНОЕ клиента (память/MEMORY/USER) — его обновление не трогает.
say "Шаг 3/9 — рабочая папка офиса (наше и личное — раздельно)"
bash "$SCRIPT_DIR/office-sync.sh" "$SCRIPT_DIR" "$OFFICE_DIR"
ok "болванка развёрнута в $OFFICE_DIR"

# --- 4. Конфигурация ---------------------------------------------------------
# Здесь — ТОЛЬКО то, что содержит секреты клиента или ставится один раз при
# установке. Всё остальное (размер стола, модель документов, активная память,
# уровни мозга) живёт в apply-settings.sh и вызывается ниже — тем же скриптом,
# который зовёт обновлялка. Так настройки доезжают и до тех, у кого офис уже стоит:
# до 30.07 они применялись только при установке и до существующих клиентов
# не доходили никогда.
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
    "maxConcurrent": 1
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

# Настройки без секретов — тем же скриптом, который зовёт обновлялка.
# Размер стола разговора, модель документов, активная память, четыре уровня мозга
# и BRAIN.md с правдой об уровнях именно этого офиса. Регион передаём явно:
# на этом шаге он уже определён пробой ключа.
OFFICE_DIR="$OFFICE_DIR" bash "$SCRIPT_DIR/apply-settings.sh" "$OFFICE_REGION" || \
  warn "часть настроек не применилась — офис поднимется, но хуже помнит и может не читать документы"

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
# ПОРЯДОК ЗДЕСЬ КРИТИЧЕН — не менять местами (первый живой прогон клиентом,
# 29.07). Служба движка ставится как ПОЛЬЗОВАТЕЛЬСКАЯ, а такую нельзя
# создать, пока для пользователя не поднят его systemd: нет сессии — нет
# /run/user/0 — `openclaw daemon install` падает. При установке по SSH сессия
# уже есть, поэтому три прогона были зелёными; через cloud-init бота сессии нет,
# и служба не появлялась вовсе. Клиент получал рапорт «9 шагов из 9» и мёртвый бот.
# Поэтому: сначала linger, потом ждём user-manager, и только потом ставим службу.
loginctl enable-linger "$(whoami)" >/dev/null 2>&1 || true
# дождаться готовности user-manager, иначе systemctl --user не подхватит таймеры (гонка на свежем сервере)
for _ in $(seq 1 15); do systemctl --user is-system-running >/dev/null 2>&1 && break; sleep 1; done
# Без каталога рантайма пользовательский systemd недоступен даже при linger.
for _ in $(seq 1 15); do [ -d "$XDG_RUNTIME_DIR" ] && break; sleep 1; done

# Провал этой команды раньше глушился (`>/dev/null 2>&1 || true`) — и это было
# опаснее самой ошибки: установка молча ехала дальше и рапортовала об успехе
# на несуществующей службе. Теперь проверяем результат делом: появился ли юнит.
GW_UNIT="$HOME/.config/systemd/user/openclaw-gateway.service"
DAEMON_OUT="$(openclaw daemon install 2>&1)" || true
if [ ! -f "$GW_UNIT" ]; then
  # Одна честная попытка ещё раз: user-manager мог подняться на секунду позже.
  sleep 5
  DAEMON_OUT="$(openclaw daemon install 2>&1)" || true
fi
if [ ! -f "$GW_UNIT" ]; then
  printf "\n\033[0;31m  Вывод движка: %s\033[0m\n" "$DAEMON_OUT"
  die "не удалось создать службу офиса — без неё офис не запустится. Установка остановлена намеренно: лучше честная остановка здесь, чем зелёный рапорт на мёртвом офисе"
fi
systemctl --user daemon-reload >/dev/null 2>&1 || true
ok "служба офиса создана"

# Первый запуск на чистом диске прогоняет стартовые миграции (~2 мин) и держит лок
# state-dir. Дефолтные Restart=always + RestartSec=5 успевают за это окно сделать
# ~10 попыток, каждая утыкается в лок, systemd упирается в лимит стартов и бросает
# службу в failed — офис не встаёт вообще. Лок при этом истекает уже ПОСЛЕ того,
# как systemd сдался (живой прогон 26.07, дроплет progon-faza3).
# Лечим не хаком в движке, а настройкой рестартов: лимит снимаем, паузу увеличиваем —
# очередная попытка приходит уже на свободный state-dir. Файл в drop-in, сам unit
# движка не трогаем: его переписывает `openclaw daemon install` при обновлении.
GW_DROPIN_DIR="$HOME/.config/systemd/user/openclaw-gateway.service.d"
mkdir -p "$GW_DROPIN_DIR"
cat > "$GW_DROPIN_DIR/office-startup.conf" <<'UNIT'
[Unit]
# 0 = не ограничивать частоту стартов: долгая первая миграция не должна
# заканчиваться отказом systemd продолжать попытки.
StartLimitIntervalSec=0
[Service]
# Пауза между попытками: 5 секунд били в лок десять раз подряд, 20 — дают миграции
# закончиться за 5-6 попыток без выжигания лимита.
RestartSec=20
UNIT
systemctl --user daemon-reload >/dev/null 2>&1 || true

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

# Первый запуск ведём сами (см. first-start.sh): на чистом сервере движок делает
# разовую настройку данных ~5 минут и запирает каталог состояния. Если позволить
# systemd в это время перезапускать службу, получаем десяток холостых попыток в
# логе и подход вплотную к лимиту ожидания (прогон 27.07). Стартуем по одной
# попытке и ждём ровно столько, сколько движок просит в логе.
if bash "$SCRIPT_DIR/first-start.sh" openclaw-gateway 720 20; then
  systemctl --user start office-menu.service >/dev/null 2>&1 || true
  ok "служба поднята (переживёт выход из SSH), меню доигрывается после старта"
else
  printf "\033[0;31m  ⚠ служба не вышла в рабочий режим за 12 минут — проверка на Шаге 9 покажет подробности\033[0m\n"
fi

# --- 8. Автообновление (будильник ежедневно) --------------------------------
say "Шаг 8/9 — автообновление офиса"
# Окружение для обновлялки: где рабочая папка и куда слать пульс (пока выключен).
# HEARTBEAT_URL берём из окружения (cloud-init задаёт наш датчик пульса).
# Пусто → пульс выключен (heartbeat.sh тихо выходит). Не интерактивный запуск не трогает.
: "${HEARTBEAT_URL:=}"
cat > "$HOME/.openclaw/.office-env" <<ENV
OFFICE_DIR="${OFFICE_DIR}"
OFFICE_SRC="${SCRIPT_DIR}"
OWNER_TG_ID="${OWNER_TG_ID}"
HEARTBEAT_URL="${HEARTBEAT_URL}"
ENV
chmod 600 "$HOME/.openclaw/.office-env"
# Будильник: каждую ночь зовёт update.sh из нашей сборки.
# update.sh сам решает, есть ли что обновлять, и трогает офис только если да.
cat > "$HOME/.config/systemd/user/office-update.service" <<UNIT
[Unit]
Description=Daily OpenClaw office self-update (engine + our skills, keeps client data)
[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/update.sh
TimeoutStartSec=600
UNIT
cat > "$HOME/.config/systemd/user/office-update.timer" <<'UNIT'
[Unit]
Description=Run office self-update daily (04:00)
[Timer]
OnCalendar=*-*-* 04:00:00
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
# Сторож: каждые 2 минуты проверяет, не залипла ли очередь Telegram (баг движка —
# при сообщениях впритык бот замолкает насмерть). Если залипла — чистит и рестартует
# шлюз сам. Клиент ждёт минуту вместо «бот умер». Найдено живым прогоном 24.07.
cat > "$HOME/.config/systemd/user/office-watchdog.service" <<UNIT
[Unit]
Description=OpenClaw office watchdog (heal stuck Telegram queue / session conflict)
[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/watchdog.sh
TimeoutStartSec=120
UNIT
cat > "$HOME/.config/systemd/user/office-watchdog.timer" <<'UNIT'
[Unit]
Description=Run office watchdog every 2 minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
UNIT
systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user enable --now office-update.timer >/dev/null 2>&1 || true
systemctl --user enable --now office-heartbeat.timer >/dev/null 2>&1 || true
systemctl --user enable --now office-watchdog.timer >/dev/null 2>&1 || true
ok "будильник (обновление каждую ночь), пульс (15 мин) и сторож (2 мин) поставлены"

# --- 9. Проверка -------------------------------------------------------------
say "Шаг 9/9 — проверка"

# Ждём настоящей готовности: active и полминуты без новых перезапусков. Логика
# вынесена в wait-ready.sh, чтобы её можно было проверить тестом с подставным
# systemctl (tests/test-startup.sh) — на Маке systemd нет, а ошибка тут стоит
# клиенту мёртвого офиса с зелёным рапортом.
if bash "$SCRIPT_DIR/wait-ready.sh" openclaw-gateway 300 10; then
  ok "служба: active и держится (перезапусков нет)"
else
  STATE=$(systemctl --user is-active openclaw-gateway 2>/dev/null || echo unknown)
  printf "\n\033[0;31m  ⚠ Офис собран, но служба не вышла в рабочий режим (состояние: %s).\033[0m\n" "$STATE"
  printf "  Что посмотреть: systemctl --user status openclaw-gateway\n"
  printf "  Логи офиса: /tmp/openclaw/ и %s/office-watchdog.log\n" "$HOME/.openclaw"
  printf "  Сторож попробует поднять службу сам в ближайшие 2 минуты.\n\n"
  exit 1
fi

printf "\n\033[1;32m════════════════════════════════════════════\033[0m\n"
printf "\033[1;32m  Офис готов. Напишите боту @%s → /start\033[0m\n" "${BOT_USER}"
printf "\033[1;32m════════════════════════════════════════════\033[0m\n\n"
echo "Команды экономии в чате: /new (новый диалог), /compact (сжать), /model (сменить мозг), /status"
echo "Сменить на умную модель:  openclaw config set agents.defaults.model.primary ${MODEL_FALLBACK}"
