# Registry (clean fixture)

Mirrors the layout of `features.md` (code repository root): dependency table first, then one flow table per domain.

## Flow dependencies

| Флоу-потребитель | Использует |
| --- | --- |
| `#f:fx.demo.run` | `#f:fx.core.hash` |
| `#f:fx.demo.stop` | `#f:fx.core.hash` |
| `#f:fx.ops.up` | `#f:fx.demo.run` |

## fx — Fixture domain

| Тег | Описание | Спека | Статус |
| --- | --- | --- | --- |
| `#f:fx` | Fixture domain | — | partial |
| `#f:fx.demo` | Demo flows | `docs/demo.md` | done |
| `#f:fx.demo.run` | Run → Verify → hash → HandleRun on the peer → shared persist | `docs/demo.md` §1 | done |
| `#f:fx.demo.stop` | Stop → shared persist | `docs/demo.md` §2 | done |
| `#f:fx.core` | Core primitives | `docs/core.md` | done |
| `#f:fx.core.hash` | hash → short digest of a name | `docs/core.md` §1 | done |
| `#f:fx.ops` | Operations and stand | — | done |
| `#f:fx.ops.up` | compose demo service → run.sh up → up_main | — | done |
| `#f:fx.ops.build` | Dockerfile: runtime image for the demo | — | done |
| `#f:fx.remote` | Flows started in another repository | — | partial |
| `#f:fx.remote.only` | Started elsewhere → Continue on this side | `docs/remote.md` | done |
| `#f:fx.later` | Future work | — | planned |
| `#f:fx.later.x` | Planned flow without code | — | planned |
