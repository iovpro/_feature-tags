package a

// #f:fx.demo.run@entry

// Run starts the demo flow: verify the config, hash the name, hand over to the peer.
func Run(cfg Config) error {
	if err := Verify(cfg); err != nil {
		return err
	}
	_ = hash(cfg.Name)
	return nil
}

// #f:fx.demo

// Config holds the demo flow settings.
type Config struct {
	Name    string
	Retries int
}

// #f:fx.demo

const (
	defaultRetries = 3
	maxRetries     = 10
)
