# Registry (lang-ts fixture)

## Flow dependencies

| Флоу-потребитель | Использует |
| --- | --- |
| `#f:tx.api.list` | `#f:tx.core.validate` |

## tx — Fixture domain

| Тег | Описание | Спека | Статус |
| --- | --- | --- | --- |
| `#f:tx` | Fixture domain | — | partial |
| `#f:tx.api` | API handlers | — | done |
| `#f:tx.api.list` | List items: validate → query → respond | — | done |
| `#f:tx.api.create` | Create a new item | — | done |
| `#f:tx.core` | Core operations | — | done |
| `#f:tx.core.validate` | Validate input data | — | done |
| `#f:tx.ui` | UI components | — | done |
| `#f:tx.ui.card` | Card component | — | done |
| `#f:tx.ns` | Namespace utilities | — | done |
| `#f:tx.ns.format` | Format dates and amounts | — | done |
