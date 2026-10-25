# Мониторинг лимитов OpenCode GO — Windows (трей)

Windows-аналог апплета Cinnamon [`clrblind/opencode-go-usage`](https://github.com/clrblind/opencode-go-usage) и плагина Noctalia `zumik3-del/opencode-go-usage`. Показывает остаток подписки **OpenCode GO** прямо в системном трее: 5-часовой, недельный и месячный лимиты, процент использования и время до сброса.

> ⚠️ **Важно:** свой ключ/API нужно вставить **самому** в файл `config.json` (см. раздел «Настройка»). Никакой чужой ключ в репозитории не хранится и не должен публиковаться.

---

## Что это и как работает

- Делает запросы к официальному API OpenCode (`https://opencode.ai/console/api/go/status`) или, как резерв, парсит HTML страницы `/workspace/{wrk}/go`.
- Раз в 300 секунд (по умолчанию) обновляет данные в фоне — интерфейс не подвисает.
- Отображает иконку в трее Windows: подводите курсор — видите `5ч 4% · Нед 25% · Мес 13%`. Левый клик открывает окно с полной статистикой. Правый клик — меню (обновить, открыть в браузере, уведомления, автозапуск).
- Уведомляет, когда лимит обнуляется (было >0 → стало 0).
- Не требует Cinnamon, Wayland, Linux или OpenCode-плагина — это чистое PowerShell-п приложение под Windows.

---

## Требования

- Windows 10/11
- PowerShell 5.1 (встроен)
- Активная подписка **OpenCode GO**

---

## Установка

```powershell
# 1. Склонировать репозиторий (или скачать ZIP и распаковать)
git clone https://github.com/craftinglivegames/opencodego_limitsmonitoring_forwindows.git
cd opencodego_limitsmonitoring_forwindows
# или просто скопируйте папку с файлами куда удобно, например:
# C:\Users\ВАШ_ПОЛЬЗОВАТЕЛЬ\.config\opencode\go-usage-tray\

# 2. Запустить через VBS (без окна консоли)
double-click GoUsage.vbs
# или из PowerShell:
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File .\GoUsage.ps1
```

Иконка появится в области переполнения трея (`^` слева от часов) — перетащите на панель, если хотите держать видимой.

---

## Настройка (важно!)

Откройте файл `config.json` в папке проекта и вставьте **свои** данные.

### Рекомендуемый способ — API-ключ (простое, надёжное)

```json
{
  "api_key": "oc_sk_...",
  "update_interval": 300,
  "show_notifications": true
}
```

**Где взять ключ:** войдите в [console.opencode.ai](https://opencode.ai/auth) → раздел с ключами / API → скопируйте ключ вида `oc_sk_...`. Не публикуйте его в репозитории — это только для вас.

### Альтернатива — cookie из браузера (как в оригинальном апплете)

Если по какой-то причине нет ключа:

```json
{
  "workspace_id": "wrk_...",
  "auth_cookie": "...",
  "update_interval": 30,
  "show_notifications": true
}
```

- `workspace_id` — из адресной строки после входа на `https://opencode.ai/auth` (начинается с `wrk_`).
- `auth_cookie` — F12 → Application → Cookies → `opencode.ai` → значение `auth`. Живёт недолго: когда страница начнёт просить повторный вход, обновите.

### Параметры

| Параметр | По умолчанию | Описание |
|---|---|---|
| `api_key` | `""` | Ключ `oc_sk_...`; включается режим API |
| `workspace_id` | `""` | Только для режима cookie |
| `auth_cookie` | `""` | Только для режима cookie |
| `update_interval` | `300` (API) / `30` (cookie) | Период опроса в секундах |
| `show_notifications` | `true` | Уведомлять о сбросе лимита |

Если заполнены оба варианта — приоритет у `api_key`.

---

## Как проверить без запуска трея

```powershell
# Один запрос с выводом результата в консоль
powershell -ExecutionPolicy Bypass -File .\GoUsage.ps1 -Once

# Проверка разбора ответа на образце (без сети)
powershell -ExecutionPolicy Bypass -File .\GoUsage.ps1 -SelfTest
```

`-Once` покажет либо `5 часов | 4% | ...`, либо ошибку (401 — ключ не принят, 429 — слишком часто, и т.д.).

---

## Автозапуск при входе в Windows

Через меню трея (правый клик → «Запускать при входе в Windows») или командой:

```powershell
powershell -ExecutionPolicy Bypass -File .\GoUsage.ps1 -InstallAutostart
```

Чтобы отключить:

```powershell
powershell -ExecutionPolicy Bypass -File .\GoUsage.ps1 -RemoveAutostart
```

---

## Файлы в папке

| Файл | Назначение |
|---|---|
| `GoUsage.ps1` | Вся логика: опрос, разбор, интерфейс, уведомления |
| `config.json` | Ваши настройки — **здесь вставляете свой ключ** |
| `GoUsage.vbs` | Запуск без окна PowerShell |
| `icon.png` | Иконка в трее (перерисована под тёмную панель) |
| `README.md` | Эта инструкция |
| `go-usage.log` | Журнал (создаётся автоматически) |

---

## Безопасность и ключи

- Ваш `api_key` и `auth_cookie` хранятся **только** в локальном `config.json`. Никакие данные не идут в репозиторий (файл `.gitignore` исключает лог и не добавляет ключи в коммит — но всё равно: не коммитьте `config.json` с реальными значениями).
- Приложение не пишет ключи в сетевые логи, не отправляет их куда-либо кроме `opencode.ai`.
- Для собственного репозитория: после клонирования сразу замените `config.json` на пустой шаблон (см. выше) и вставьте свой ключ локально.

---

## Лицензия

MIT — используйте на своё усмотрение, без гарантий. Основано на концепциях оригинальных проектов (Cinnamon-апплет и Noctalia-плагин), но это самостоятельная реализация под Windows.
