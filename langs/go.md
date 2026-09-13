# Go · `active`

| Поле            | Значение |
| --------------- | -------- |
| Файлы           | `--include=*.go`. Исключения: `*_gen.go`, `docs/docs.go` (swag), `vendor/` |
| Комментарий     | `//` |
| Тег-группа      | Отдельная `//`-группа перед doc-comment и объявлением, отделённая от них одной пустой строкой. Если doc-comment отсутствует, пустая строка остаётся между тегом и объявлением |
| Объявления      | `func`, метод, `type`, группа `const`/`var` (тег над `const (`), пакетный `init` |
| Ветка           | Хвостовой `// #f:…` на строке `case`/`default`/`if` |
| Тесты           | `*_test.go`; тест — `^func (Test\w+)`; отдельная тег-группа перед test doc-comment/функцией; табличные подтесты не помечаются отдельно |
| Точечный прогон | см. ниже |

```bash
# имена тестов флоу → go test -run; awk проходит пустую строку и test doc-comment
FLOW='billing\.invoice\.create'
find . -name '*_test.go' -print0 | xargs -0 awk -v flow="#f:${FLOW}([.@ ]|$)" '
  FNR == 1 { tagged=0 }
  /^[[:space:]]*\/\/[[:space:]]+#f:/ && $0 ~ flow { tagged=1; next }
  tagged && /^[[:space:]]*$/ { next }
  tagged && /^[[:space:]]*\/\// { next }
  tagged && /^func Test[A-Za-z0-9_]+/ {
    name=$2; sub(/\(.*/, "", name); print name; tagged=0; next
  }
  tagged { tagged=0 }
' | sort -u | paste -sd'|' -
# → go test -race ./... -run '^(TestA|TestB)$'
```

```go
// #f:billing.invoice.create@operation

// Create generates a new invoice for the given order.
func (s *InvoiceService) Create(orderID string, items []LineItem) (*Invoice, error) { ... }

// #f:billing.invoice

// Invoice represents a billable document with line items and totals.
type Invoice struct { ... }

switch eventType {
case EventPaymentReceived: // #f:billing.invoice.create.confirm@recv
	s.handlePaymentConfirmation(invoiceID, data)
default: // #f:notify.email.send #f:notify.webhook.fire
	notifier.HandleEvent(eventType, data)
}

// #f:billing.invoice.create #f:crypto.sign.verify

func TestInvoice_Create_RejectsDuplicateOrder(t *testing.T) { ... }
```
