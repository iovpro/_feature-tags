# Bootstrap: развёртывание фич-хэштегов

Настройка инструмента `ftags` и инфраструктуры хэштегов в новом кодовом репозитории или проекте.
Ядро правил — [spec.md](spec.md); справка инструмента — [tool/README.md](tool/README.md).

Репозиторий `_feature-tags` подключается как **git submodule** под именем `_feature-tags/`: на уровне
проекта (мета-репозитория) для multi-repo или в корень кодового репозитория для single-repo.
Обновление — `git submodule update --remote _feature-tags`.

## Новый репозиторий в проекте

Когда submodule `_feature-tags/` уже подключён — остаётся настроить кодовый репозиторий.

### 1. `.ftags.conf`

Файл в корне кодового репозитория. Декларативный `KEY=VALUE`; инструмент разбирает как данные
(без `source`/`eval`). Кавычки вокруг значения (одинарные или двойные) снимаются.

| Ключ              | Обязательный | Описание                                                                          |
| ----------------- | ------------ | --------------------------------------------------------------------------------- |
| `LANGS`           | да           | Активные языковые профили через пробел. Имена из `tool/langs/*.conf`              |
| `EXCLUDE`         | нет          | Дополнительные маски исключения (сгенерированный код, vendor и т.п.)              |
| `REG`             | нет          | Путь к реестру. По умолчанию `features.md` в корне репозитория                    |
| `NOSTART_IGNORE`  | нет          | Флоу, чья стартовая точка в другом репозитории (через пробел, без `#f:` префикса) |

Пример:

```
# ftags repository config (declarative KEY=VALUE, parsed as data; never sourced)
LANGS=go yaml sh
EXCLUDE=docs/generated/*
NOSTART_IGNORE=
```

### 2. `features.md`

Реестр флоу в корне кодового репозитория. Шаблон пустого реестра:

```markdown
# Реестр фич и флоу

Иерархический каталог: домен → фича → флоу. Тег в реестре = хэштег в кодовой базе.
Шаги глубже флоу (4-й сегмент и далее) в реестр не вносятся.
Формат и правила — [\_feature-tags/spec.md](<FTAGS_REL>/spec.md).

Для флоу в колонке «Описание» — **цепочка**: откуда начинается, через что проходит,
чем заканчивается. Точки входа в реестре не перечисляются — они находятся по маркерам
`@entry` и `@operation` в коде.

Статусы: `planned` · `partial` · `done` · `deprecated`
(подробнее — spec.md регламента).

## Зависимости флоу

| Флоу-потребитель | Использует |
| ---------------- | ---------- |

## <домен> — <название>

| Тег | Описание | Спека | Статус |
| --- | -------- | ----- | ------ |
```

> `<FTAGS_REL>` — относительный путь от корня кодового репозитория до `_feature-tags/`.
> Для multi-repo проекта (кодовый репозиторий — вложенный): `../_feature-tags`.
> Для single-repo проекта (кодовый репозиторий = проект): `_feature-tags`.

### 3. Makefile

Три стандартных цели. `FTAGS` — относительный путь от корня кодового репозитория
до `_feature-tags/tool/ftags.sh`.

```makefile
FTAGS := <FTAGS_REL>/tool/ftags.sh
BASE_REV ?= HEAD

.PHONY: ftags-check ftags-changed ftags-qa-scope

# feature-hashtag integrity checks
ftags-check:
	$(FTAGS) check

ftags-changed:
	$(FTAGS) changed --base $(BASE_REV)

ftags-qa-scope:
	$(FTAGS) qa-scope --base $(BASE_REV)
```

> **Multi-repo:** `FTAGS := ../_feature-tags/tool/ftags.sh`
> **Single-repo:** `FTAGS := _feature-tags/tool/ftags.sh`

Если Makefile уже существует — добавить `FTAGS` и `BASE_REV` в секцию переменных,
`ftags-check ftags-changed ftags-qa-scope` — в `.PHONY`, и три цели.

### 4. CLAUDE.md

В корневой `CLAUDE.md` проекта (или репозитория, если он самостоятельный) добавить ссылки на регламент
и инструмент, чтобы AI-ассистенты загружали правила при работе с кодом:

- Ссылка на `_feature-tags/spec.md` — ядро правил (безусловное применение)
- Ссылка на `_feature-tags/bootstrap.md` — развёртывание
- Ссылка на `_feature-tags/checks.md` — целостность и QA scope
- Ссылка на `_feature-tags/tool/README.md` — справка инструмента
- Ссылка на `features.md` — реестр фич репозитория
- Указание, что фич-хэштеги действуют безусловно при любой доработке кода

Без этих ссылок ассистент не узнает о регламенте и не будет расставлять теги и вести реестр.

## Новый проект

### Подключение submodule

```bash
cd <project-root>
git submodule add <url-репозитория-_feature-tags> _feature-tags
git commit -m "Add _feature-tags submodule"
```

### Далее

1. Определить домены и начальный список фич.
2. Для каждого кодового репозитория — выполнить шаги [§Новый репозиторий](#новый-репозиторий-в-проекте).
3. Если нужен новый язык — добавить профиль по чеклисту в [langs.md](langs.md#чеклист-добавить-язык).

### Обновление submodule

```bash
cd <project-root>
git submodule update --remote _feature-tags
git add _feature-tags
git commit -m "Update _feature-tags"
```

### Клонирование проекта с submodule

```bash
git clone --recurse-submodules <url-проекта>
# или после обычного clone:
git submodule update --init _feature-tags
```

## Чеклист

- [ ] Submodule `_feature-tags` подключён на уровне проекта
- [ ] `.ftags.conf` в корне кодового репозитория с `LANGS`
- [ ] `features.md` в корне кодового репозитория (шаблон с шапкой)
- [ ] Makefile: `FTAGS`, `BASE_REV`, три цели в `.PHONY`
- [ ] CLAUDE.md: ссылки на регламент, инструмент и реестр
- [ ] `make ftags-check` проходит без ошибок
- [ ] Домены определены, начальные записи в реестре заведены
