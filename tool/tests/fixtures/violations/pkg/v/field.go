package v

// Payload is untagged; the tag on its field is the violation.
type Payload struct {
	Name string // #f:fx.demo.run.name
}

// Body is untagged; the tag group inside the struct is the violation.
type Body struct {
	// #f:fx.demo.run.inner

	Data []byte
}

// Runner is untagged; the tag on its method is the violation.
type Runner interface {
	Run() error // #f:fx.demo.run.iface
}
