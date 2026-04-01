# WARP Relay Panel v2

Панель управления whitelist для WARP Relay серверов.
Бесплатный хостинг на **Vercel + Supabase**.

## Архитектура

```
Telegram Bot  ──HTTP──▶  Vercel (FastAPI)  ──HTTP──▶  Relay Agent 1
                         Supabase (PostgreSQL)  ────▶  Relay Agent 2
                              ▲                 ────▶  Relay Agent N
                              │
                       Клиент по ссылке
                       (определяется IPv4)
```

| Компонент | Где | Стоимость |
|-----------|-----|-----------|
| API-панель | Vercel serverless | Бесплатно (если соблюдать лимиты) |
| База данных | Supabase PostgreSQL | Бесплатно (500 MB) |
| Relay Agent | На каждом relay-сервере | Платно |
| Telegram Bot | Сервер | Платно |

## Быстрый старт

### 1. Supabase

1. Создать проект на [supabase.com](https://supabase.com)
2. Открыть **SQL Editor** → вставить содержимое `supabase_schema.sql` → Run
3. Скопировать **Project URL** и **service_role key** (Settings → API)

### 2. Vercel

```bash
# Клонировать / загрузить проект
cd warp-relay-panel

# Установить Vercel CLI
npm i -g vercel

# Задеплоить
vercel

# Задать переменные окружения (Vercel Dashboard → Settings → Environment Variables):
# SUPABASE_URL=https://xxx.supabase.co
# SUPABASE_KEY=eyJ...service-role-key...
# ENCRYPTION_KEY=<python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())">
# API_KEY=your-secret-api-key
# AGENT_SECRET=your-agent-secret
# MAX_ACTIVATIONS_PER_DAY=10

# Передеплоить с переменными
vercel --prod
```

### 3. Каждый Relay-сервер

```bash
# Скопировать папку relay-agent на сервер
scp -r relay-agent root@RELAY_IP:/tmp/

# Запустить установку
ssh root@RELAY_IP "bash /tmp/relay-agent/setup_relay.sh"

# Скрипт спросит:
#   Agent secret → тот же что в AGENT_SECRET на Vercel
#   Agent port   → 7580 (по умолчанию)

# Проверить
ssh root@RELAY_IP 'curl -s http://localhost:7580/health | python3 -m json.tool'
```

### 4. Добавить relay в панель

```bash
PANEL="https://your-project.vercel.app"
KEY="your-api-key"

curl -X POST ${PANEL}/api/relays \
  -H "X-API-Key: ${KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "DE-Frankfurt",
    "host": "1.2.3.4",
    "agent_port": 7580,
    "agent_secret": "your-agent-secret"
  }'
```

### 5. Создать клиента

```bash
curl -X POST ${PANEL}/api/clients \
  -H "X-API-Key: ${KEY}" \
  -H "Content-Type: application/json" \
  -d '{"label": "Иван", "note": "подписчик канала"}'

# Ответ: {"id": 1, "token": "a1b2c3d4e5f67890", ...}
# Ссылка активации: https://your-project.vercel.app/activate/a1b2c3d4e5f67890
```

## API

Все `/api/*` эндпоинты требуют заголовок `X-API-Key`.

### Клиенты

| Метод | Путь | Описание |
|-------|------|----------|
| `POST` | `/api/clients` | Создать `{"label":"...", "note":"..."}` |
| `GET` | `/api/clients` | Список всех |
| `GET` | `/api/clients/{id}` | Детали клиента |
| `GET` | `/api/clients/{id}/logs` | История активаций |
| `PATCH` | `/api/clients/{id}/block` | Блокировать `{"blocked": true}` |
| `DELETE` | `/api/clients/{id}` | Удалить (+ убрать IP с relay) |

### Relay-серверы

| Метод | Путь | Описание |
|-------|------|----------|
| `POST` | `/api/relays` | Добавить relay |
| `GET` | `/api/relays` | Список |
| `DELETE` | `/api/relays/{id}` | Удалить |
| `PATCH` | `/api/relays/{id}/toggle` | Вкл/выкл `{"active": false}` |
| `GET` | `/api/relays/{id}/health` | Здоровье relay (через agent) |
| `GET` | `/api/relays/{id}/stats` | Статистика (клиенты, трафик) |
| `POST` | `/api/relays/{id}/sync` | Синхронизировать whitelist |
| `POST` | `/api/relays/sync-all` | Синхронизировать все relay |
| `GET` | `/api/relays/health-all` | Проверить все relay |

### Активация

| Метод | Путь | Описание |
|-------|------|----------|
| `GET` | `/activate/{token}` | Публичная ссылка (HTML-страница) |

### Прочее

| Метод | Путь | Описание |
|-------|------|----------|
| `GET` | `/api/stats` | Общая статистика |
| `GET` | `/health` | Healthcheck |

## Relay Agent API

Работает на каждом relay-сервере. Все эндпоинты (кроме `/health`) требуют `X-Agent-Key`.

| Метод | Путь | Описание |
|-------|------|----------|
| `POST` | `/whitelist/update` | `{"new_ip":"...", "old_ip":"..."}` |
| `POST` | `/whitelist/remove` | `{"ip":"..."}` |
| `POST` | `/whitelist/sync` | `{"ips":["..."]}` — полная синхронизация |
| `GET` | `/whitelist/list` | Текущий ipset |
| `GET` | `/health` | Система, conntrack, ipset (без авторизации) |
| `GET` | `/stats` | Клиенты, порты, сессии |

## Безопасность relay-агента

Агент слушает на порту 7580 по HTTP. Рекомендуемая защита:

```bash
# Ограничить доступ к порту агента только с определённых IP (если возможно)
# Либо использовать firewall:
ufw allow from PANEL_IP to any port 7580
ufw deny 7580
```

Если фиксированного IP у панели нет (Vercel serverless) —
защита только через `AGENT_SECRET` в заголовке.

## Интеграция в Telegram-бота

Пример для aiogram 3:

```python
import aiohttp

PANEL_URL = "https://your-project.vercel.app"
API_KEY = "your-api-key"
HEADERS = {"X-API-Key": API_KEY, "Content-Type": "application/json"}

async def create_client(label: str) -> dict:
    async with aiohttp.ClientSession() as session:
        async with session.post(
            f"{PANEL_URL}/api/clients",
            headers=HEADERS,
            json={"label": label},
        ) as resp:
            return await resp.json()

async def get_activate_url(token: str) -> str:
    return f"{PANEL_URL}/activate/{token}"

async def get_client_info(client_id: int) -> dict:
    async with aiohttp.ClientSession() as session:
        async with session.get(
            f"{PANEL_URL}/api/clients/{client_id}",
            headers=HEADERS,
        ) as resp:
            return await resp.json()
```

## Структура проекта

```
warp-relay-panel/
├── api/                     # Vercel serverless
│   ├── index.py             # FastAPI (роуты, активация)
│   ├── database.py          # Supabase операции
│   ├── relay_client.py      # HTTP-клиент для relay-агентов
│   └── crypto.py            # Шифрование IP (Fernet)
├── relay-agent/             # Ставится на каждый relay
│   ├── agent.py             # FastAPI агент (ipset, stats)
│   ├── setup_relay.sh       # Установка всего
│   ├── requirements.txt
│   └── .env.example
├── supabase_schema.sql      # SQL для создания таблиц
├── vercel.json              # Конфигурация Vercel
├── requirements.txt         # Python зависимости (Vercel)
└── .env.example             # Переменные окружения
```
