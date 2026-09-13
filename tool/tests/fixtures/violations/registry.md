# Registry (violations fixture)

Dependency table carries three broken edges: unknown target, self-reference, duplicate.
Domain `fxx` clashes with `fx` as a prefix.

## Flow dependencies

| Флоу-потребитель | Использует |
| --- | --- |
| `#f:fx.demo.run` | `#f:fx.nope.missing` |
| `#f:fx.demo.stop` | `#f:fx.demo.stop` |
| `#f:fx.demo.run` | `#f:fx.demo.stop` |
| `#f:fx.demo.run` | `#f:fx.demo.stop` |

## fx — Fixture domain

| Тег | Описание | Спека | Статус |
| --- | --- | --- | --- |
| `#f:fx` | Fixture domain | — | partial |
| `#f:fx.demo` | Demo feature | — | partial |
| `#f:fx.demo.run` | RunEntry → legacy steps → result | `docs/demo.md` §1 | done |
| `#f:fx.demo.stop` | finish → result; no start marker in code | `docs/demo.md` §2 | done |
| `#f:fx.old.gone` | Deprecated; replaced by fx.demo.stop | — | deprecated |
| `#f:fx.later.x` | Planned flow without code | — | planned |

## fxx — Domain that has fx as a prefix

| Тег | Описание | Спека | Статус |
| --- | --- | --- | --- |
| `#f:fxx` | Second domain; prefix clash with fx | — | partial |
