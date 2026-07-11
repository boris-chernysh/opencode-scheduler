# opencode-scheduler

Легковесный cron-планировщик для окружений без systemd (PRoot, контейнеры). Работает поверх tmux — bash-демон + perl-супервизор.

## Архитектура

```
opencode-scheduler/
├── bin/
│   ├── opencode-scheduler-daemon   # демон: цикл sleep → parsecron → supervisor
│   └── opencode-scheduler-ctl      # управление (start|stop|restart|status|logs)
└── lib/
    └── supervisor.pl               # исполнитель: форк, таймаут, lock, статус
```

### Как работает

1. **Демон** (`opencode-scheduler-daemon`) — бесконечный цикл:
   - Парсит cron-выражения для каждого джоба
   - Спит до ближайшего запуска
   - При пробуждении собирает **все** due-джобы и запускает их через supervisor
2. **Супервизор** (`supervisor.pl`) — на каждый джоб:
   - Lock-файл (защита от двойного запуска)
   - Форкает процесс, выполняет команду с таймаутом
   - Пишет статус (`lastRunStatus`, `exitCode`) в job.json
3. **Управление** (`opencode-scheduler-ctl`) — обёртка над tmux

### Job-конфиги

Хранятся в `~/.config/opencode/scheduler/scopes/<scope>/jobs/<slug>.json`:

```json
{
  "name": "daily-backup",
  "slug": "daily-backup",
  "schedule": "0 3 * * *",
  "enabled": true,
  "scopeId": "personal-xxx",
  "workdir": "/path/to/workdir",
  "timeoutSeconds": 600,
  "invocation": {
    "command": "/bin/bash",
    "args": ["-c", "tar czf backup.tar.gz /data"]
  }
}
```

### Cron-выражения (5 полей)

| Пример | Значение |
|---|---|
| `30 7 * * *` | Каждый день в 7:30 |
| `0 0 * * *` | Каждый день в полночь |
| `0 */4 * * *` | Каждые 4 часа (0:00, 4:00, ...) |
| `0 9 * * 1` | Каждый понедельник в 9:00 |
| `0 8,20 * * *` | В 8:00 и 20:00 каждый день |

Поддерживаются: фиксированное время, интервалы в часах (`*/N`), перечисление часов через запятую. Не поддерживаются: `*/N` в минутах, диапазоны, сложные комбинации.

## Установка

```bash
git clone https://github.com/boris-chernysh/opencode-scheduler.git
cd opencode-scheduler

# Симлинки
ln -sf "$(pwd)/bin/opencode-scheduler-daemon" ~/.local/bin/
ln -sf "$(pwd)/bin/opencode-scheduler-ctl" ~/.local/bin/
ln -sf "$(pwd)/lib/supervisor.pl" ~/.config/opencode/scheduler/

# Создать директории
mkdir -p ~/.config/opencode/scheduler/scopes
mkdir -p ~/.config/opencode/logs/scheduler/daemon

# Добавить джобы в массив JOBS внутри daemon (см. ниже)
```

## Добавление джоба

1. Создать `<slug>.json` в `~/.config/opencode/scheduler/scopes/<scope>/jobs/`
2. Добавить запись в массив `JOBS` внутри `opencode-scheduler-daemon`:
   ```bash
   JOBS=(
       "$SCOPE_DIR/jobs/<slug>.json|<cron-expression>"
       ...
   )
   ```
3. `opencode-scheduler-ctl restart`

## Запуск

```bash
opencode-scheduler-ctl start    # запустить демон
opencode-scheduler-ctl status   # проверить статус
opencode-scheduler-ctl logs     # tail -f лога
opencode-scheduler-ctl stop     # остановить
opencode-scheduler-ctl restart  # перезапустить
```

После перезагрузки устройства нужен ручной `start`.

## Логи

| Что | Путь |
|---|---|
| Демон | `~/.config/opencode/logs/scheduler/daemon/` |
| Джобы | `~/.config/opencode/logs/scheduler/<scope>/<slug>.log` |
| Run-история | `~/.config/opencode/scheduler/scopes/<scope>/runs/<slug>.jsonl` |

## Ограничения

- Нет авто-обнаружения джобов — массив `JOBS` задаётся вручную в коде демона
- Нет systemd — только tmux, перезапуск после ребута вручную
- `sleep` может дрейфовать в PRoot-окружениях
- Нет поддержки секунд в cron, нет диапазонов дат

## Лицензия

MIT
