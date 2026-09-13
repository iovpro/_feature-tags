# YAML · Dockerfile · docker-compose · Kubernetes-манифесты · `active`

| Поле            | Значение |
| --------------- | -------- |
| Файлы           | `--include=*.yml --include=*.yaml --include=Dockerfile*`. Исключения: сгенерированные манифесты (`kustomize build` output), lock-файлы |
| Комментарий     | `#` |
| Тег-группа      | Отдельная `#`-группа на том же отступе перед описывающими комментариями и ресурсом, отделённая от них одной пустой строкой |
| Объявления      | YAML-документ (`---` / `kind:`), сервис в `services:`, job/step в CI-пайплайне, стадия `FROM` в Dockerfile |
| Ветка           | Не применяется |
| Тесты           | Нет. Регресс — стенд |
| Точечный прогон | Не применяется; поднимается стенд целиком |

```yaml
services:
  # #f:ops.testnet.up@entry

  node-a:
    build: .
```

```dockerfile
# #f:ops.testnet.build@entry

FROM golang:1.24-alpine AS builder
```
