---
name: scheduler
description: "AI agent skill for managing the tmux-based job scheduler in PRoot environments: creating, editing, deleting scheduled jobs, cron expressions, debugging. Use when scheduling recurring tasks, cron jobs, or automating periodic operations."
---

# Skill: scheduler

Управление tmux-планировщиком для PRoot-окружения (systemd недоступен). Планировщик запускает задачи по cron-расписанию через supervisor.pl.

## Architecture (три компонента)

### 1. `opencode-scheduler-ctl` — управление демоном

Скрипт: `~/.local/bin/opencode-scheduler-ctl`

| Команда | Действие |
|---|---|
| `start` | Запускает демона в tmux-сессии `opencode-scheduler` |
| `stop` | Убивает tmux-сессию |
| `restart` | stop + sleep 1 + start |
| `status` | Проверяет, жива ли сессия |
| `logs` | `tail -f` лога демона |

Вызов: `opencode-scheduler-ctl {start|stop|restart|status|logs}`

### 2. `opencode-scheduler-daemon` — планировщик

Скрипт: `~/.local/bin/opencode-scheduler-daemon`

**Бесконечный цикл:**
1. Читает жёстко заданный массив `JOBS` (файл `.json` + cron-выражение)
2. `parsecron()` вычисляет секунды до ближайшего запуска
3. Спит это количество секунд
4. Просыпается → запускает джоб через `perl supervisor.pl job.json`
5. Повторяет

**Массив JOBS** (вписывается вручную в скрипт):
```bash
JOBS=(
    "$SCOPE_DIR/jobs/morning-mail.json|30 7 * * *"
    "$SCOPE_DIR/jobs/task-processor.json|0 */4 * * *"
    "$SCOPE_DIR/jobs/daily-git-autocommit.json|0 0 * * *"
    "$SCOPE_DIR/jobs/wiki-ingest-daily.json|0 3 * * *"
)
```

**Важно:** демон не сканирует директорию `jobs/` автоматически. Каждый новый джоб нужно добавлять в этот массив вручную.

### 3. `supervisor.pl` — исполнитель джоба

Скрипт: `~/.config/opencode/scheduler/supervisor.pl`

Получает путь к job.json и:
1. Читает job.json, проверяет `scopeId`/`slug`
2. Блокировка: lock-файл `locks/<slug>.json` — не запускает джоб, если предыдущий экземпляр ещё жив (проверяет PID)
3. Обновляет `lastRunAt`, `lastRunStatus: "running"` в job.json
4. Устанавливает `OPENCODE_PERMISSION={"question":"deny"}` — scheduled-запуски не интерактивные
5. Форкает, делает `chdir` в `workdir`, запускает `invocation.command` с `invocation.args`
6. Если задан `timeoutSeconds` — вешает аларм: SIGTERM, через 5 сек SIGKILL
7. По завершению пишет `lastRunStatus`, `exitCode`, `lastRunError` обратно в job.json
8. Дописывает run-запись в `runs/<slug>.jsonl` (runId, duration, status)
9. stdout/stderr → `logs/scheduler/<scopeId>/<slug>.log`

## Job JSON format

Путь: `~/.config/opencode/scheduler/scopes/personal-51e9e3f41a6c/jobs/<slug>.json`

### Поля

| Поле | Тип | Обязательно | Описание |
|---|---|---|---|
| `name` | string | Да | Имя джоба |
| `slug` | string | Да | slug (обычно = name) |
| `schedule` | string | Да | cron-выражение (5 полей) |
| `enabled` | bool | Да | Включён ли джоб |
| `scopeId` | string | Да | `"personal-51e9e3f41a6c"` |
| `workdir` | string | Да | Рабочая директория |
| `timeoutSeconds` | number | Нет | Таймаут в секундах |
| `createdAt` | string | Нет | ISO-дата создания |
| `updatedAt` | string | Нет | ISO-дата обновления (пишется супервизором) |
| `lastRunAt` | string | Нет | Пишется супервизором |
| `lastRunStatus` | string | Нет | Пишется супервизором: running/success/failed |
| `lastRunExitCode` | number | Нет | Пишется супервизором |
| `lastRunError` | string | Нет | Пишется супервизором |
| `invocation` | object | Да | Команда для запуска |

### `invocation`

| Поле | Тип | Описание |
|---|---|---|
| `command` | string | Путь к исполняемому файлу |
| `args` | array | Аргументы командной строки |

### Пример: bash-команда (git autocommit)

```json
{
  "name": "daily-git-autocommit",
  "slug": "daily-git-autocommit",
  "schedule": "0 0 * * *",
  "enabled": true,
  "scopeId": "personal-51e9e3f41a6c",
  "workdir": "/mnt/sdcard/Documents/Personal",
  "timeoutSeconds": 300,
  "createdAt": "2026-07-10T12:00:00+0300",
  "updatedAt": "2026-07-10T12:00:00+0300",
  "invocation": {
    "command": "/bin/bash",
    "args": ["-c", "git add -A && (git diff --cached --quiet || git commit -m \"auto: daily backup $(date +%Y-%m-%d)\") && git push"]
  }
}
```

### Пример: opencode command

```json
{
  "name": "task-processor",
  "slug": "task-processor",
  "schedule": "0 */4 * * *",
  "enabled": true,
  "scopeId": "personal-51e9e3f41a6c",
  "workdir": "/mnt/sdcard/Documents/Personal",
  "timeoutSeconds": 1800,
  "invocation": {
    "command": "/home/master/.opencode/bin/opencode",
    "args": ["run", "--command", "task-processor", "--dangerously-skip-permissions", "--format", "default"]
  }
}
```

## Cron expressions (поддерживаемые)

`parsecron()` в `opencode-scheduler-daemon` парсит 5-польные cron-выражения.

### Фиксированное время
```
30 7 * * *    → каждый день в 7:30
0 0 * * *     → каждый день в полночь
0 9 * * 1     → каждый понедельник в 9:00
0 9 1 * *     → 1-го числа каждого месяца в 9:00
```

### Интервалы (только в поле hours)
```
0 */4 * * *   → каждые 4 часа (0:00, 4:00, 8:00, ...)
0 */6 * * *   → каждые 6 часов
30 */2 * * *  → каждые 2 часа в :30 (0:30, 2:30, ...)
```

### Перечисление часов (через запятую)
```
0 8,20 * * *  → в 8:00 и 20:00 каждый день
```

### Ограничения
- Не поддерживает `*/N` в поле минут (только часы)
- Не поддерживает диапазоны (`1-5`)
- Не поддерживает сложные комбинации полей
- Только 5 полей (без секунд)

## Добавление нового джоба (полный алгоритм)

### Шаг 1: создать JSON

```bash
# путь
JOB_DIR="$HOME/.config/opencode/scheduler/scopes/personal-51e9e3f41a6c/jobs"
```

Создать `<slug>.json` по формату выше. Поля `createdAt` и `updatedAt` опциональны, супервизор сам добавит `lastRunAt`, `lastRunStatus` и т.д. при первом запуске.

### Шаг 2: добавить в массив JOBS демона

Отредактировать `~/.local/bin/opencode-scheduler-daemon`, добавить строку в массив:
```bash
JOBS=(
    "$SCOPE_DIR/jobs/morning-mail.json|30 7 * * *"
    ...
    "$SCOPE_DIR/jobs/<new-slug>.json|<cron-expression>"
)
```

**Внимание:** cron-выражение в массиве JOBS дублирует `schedule` из JSON. Убедись, что они совпадают.

### Шаг 3: рестарт демона

```bash
opencode-scheduler-ctl restart
```

### Шаг 4: проверить

```bash
# статус
opencode-scheduler-ctl status

# логи демона — должен показывать "Monitoring job: .../<slug>.json"
tail -20 ~/.config/opencode/logs/scheduler/daemon/opencode-scheduler-daemon.log
```

## Удаление джоба

1. Удалить строку из массива `JOBS` в `opencode-scheduler-daemon`
2. Удалить `<slug>.json` из `jobs/`
3. `opencode-scheduler-ctl restart`

## Диагностика и логи

| Что | Путь |
|---|---|
| Лог демона | `~/.config/opencode/logs/scheduler/daemon/opencode-scheduler-daemon.log` |
| Лог джоба | `~/.config/opencode/logs/scheduler/personal-51e9e3f41a6c/<slug>.log` |
| Run-история | `~/.config/opencode/scheduler/scopes/personal-51e9e3f41a6c/runs/<slug>.jsonl` |
| Lock-файл | `~/.config/opencode/scheduler/scopes/personal-51e9e3f41a6c/locks/<slug>.json` |
| Сам job.json | `~/.config/opencode/scheduler/scopes/personal-51e9e3f41a6c/jobs/<slug>.json` |

### Просмотр логов джоба

```bash
cat ~/.config/opencode/logs/scheduler/personal-51e9e3f41a6c/<slug>.log
```

### Проверка статуса последнего запуска

```bash
cat ~/.config/opencode/scheduler/scopes/personal-51e9e3f41a6c/jobs/<slug>.json | python3 -m json.tool | grep lastRun
```

### Ручной запуск джоба (для тестирования)

```bash
perl ~/.config/opencode/scheduler/supervisor.pl ~/.config/opencode/scheduler/scopes/personal-51e9e3f41a6c/jobs/<slug>.json
```

## Ограничения и важные замечания

1. **Нет авто-обнаружения джобов.** Демон не сканирует `jobs/` — только жёстко заданный массив `JOBS` в скрипте. Каждый новый джоб требует правки двух файлов.
2. **После перезагрузки устройства** демон не стартует автоматически. Нужно вручную: `opencode-scheduler-ctl start`.
3. **Инструмент `schedule_job` не работает** в этом окружении (PRoot, нет systemd). Не используй его — создавай JSON и правь демона вручную.
4. **Инструмент `list_jobs` не показывает** джобы tmux-планировщика (он смотрит в другой источник). Используй `ls ~/.config/opencode/scheduler/scopes/personal-*/jobs/`.
5. **Lock-файл** в `locks/<slug>.json` предотвращает двойной запуск. Если джоб завис, удали lock-файл вручную.
6. **Таймаут:** если `timeoutSeconds` не задан, джоб может висеть бесконечно. Рекомендуется всегда указывать.
7. **OPENCODE_PERMISSION** всегда `question: deny` в scheduled-запусках. Джоб не может задавать вопросы пользователю.

## Examples

### Git autocommit каждый день в полночь
```bash
# job.json
schedule: "0 0 * * *"
invocation: bash -c "git add -A && ... && git push"
workdir: /mnt/sdcard/Documents/Personal
```

### OpenCode command каждые 4 часа
```bash
# job.json
schedule: "0 */4 * * *"
invocation: opencode run --command task-processor --dangerously-skip-permissions
timeoutSeconds: 1800
```

### Bash-скрипт раз в неделю
```bash
# job.json
schedule: "0 9 * * 1"   # каждый понедельник в 9:00
invocation: bash -c "/path/to/weekly-report.sh"
timeoutSeconds: 600
```

## File structure

```
~/.config/opencode/
├── scheduler/
│   ├── supervisor.pl                          # исполнитель джобов
│   └── scopes/
│       └── personal-51e9e3f41a6c/
│           ├── jobs/
│           │   ├── morning-mail.json
│           │   ├── task-processor.json
│           │   └── <slug>.json                # новые джобы
│           ├── locks/
│           │   └── <slug>.json                # lock при запуске
│           └── runs/
│               └── <slug>.jsonl               # история запусков
├── logs/
│   └── scheduler/
│       ├── daemon/
│       │   └── opencode-scheduler-daemon.log  # лог демона
│       └── personal-51e9e3f41a6c/
│           └── <slug>.log                     # лог джоба
~/.local/bin/
├── opencode-scheduler-ctl                     # управление демоном
└── opencode-scheduler-daemon                  # демон-планировщик
```
