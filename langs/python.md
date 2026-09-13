# Python · `reference`

| Поле            | Значение |
| --------------- | -------- |
| Файлы           | `--include=*.py`. Исключения: `.venv/`, `__pycache__/`, `*_pb2.py`, миграции Alembic/Django, если генерируются |
| Комментарий     | `#` |
| Тег-группа      | Отдельная `#`-группа перед декораторами и `def`/`class`, отделённая от них пустой строкой. Не в docstring |
| Объявления      | `def`, `async def`, метод, `class` (уровень фичи), модульный хендлер |
| Ветка           | Хвостовой `# #f:…` на `case`/`elif`/`if` |
| Тесты           | `test_*.py`, `*_test.py`; тест — `^\s*(async )?def (test_\w+)`; отдельная тег-группа перед `@pytest.mark…`/`def test_…` |
| Точечный прогон | `pytest -k 'test_a or test_b'` |

```python
# #f:auth.login.oauth@entry

@router.post("/auth/login")
async def login_oauth(req: OAuthLoginRequest) -> AuthTokenResponse:
    """Validate OAuth code and issue a session token."""
```
