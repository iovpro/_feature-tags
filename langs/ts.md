# TypeScript / JavaScript · `active`

| Поле            | Значение |
| --------------- | -------- |
| Файлы           | `--include=*.ts --include=*.tsx --include=*.js --include=*.jsx`. Исключения: `node_modules/`, `dist/`, `build/`, `*.d.ts`, `*.generated.*` |
| Комментарий     | `//` |
| Тег-группа      | Отдельная `//`-группа перед JSDoc/декораторами и объявлением, отделённая от них пустой строкой. Не внутри `/** */` |
| Объявления      | `function`, стрелочная функция в `const`, метод класса, `class`, React-компонент, hook, Redux slice/thunk, роут/хендлер, `interface`/`type` (уровень фичи) |
| Ветка           | Хвостовой `// #f:…` на `case`/`if`; в JSX — `{/* #f:… */}` не используется, помечается компонент |
| Тесты           | `*.test.ts(x)`, `*.spec.ts(x)`; тест — `^\s*(it|test)\(['"\`]([^'"\`]+)`; отдельная тег-группа перед `it(`/`test(`; `describe` не помечается |
| Точечный прогон | `jest -t '<name1>|<name2>'` или `vitest -t '<name>'` |

```ts
// #f:por.form.submit@entry

/** Submits the form and moves the wizard to the confirmation step. */
export async function submitForm(values: FormValues): Promise<void> { ... }

// #f:por.form.submit

it('rejects submission with empty amount', async () => { ... });
```
