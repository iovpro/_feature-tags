package a

import (
	"crypto/sha256"
	"fmt"
)

// #f:fx.demo.run.verify

// Verify checks that the config is complete.
func Verify(cfg Config) error {
	if cfg.Name == "" {
		return fmt.Errorf("empty name")
	}
	return nil
}

// #f:fx.core.hash@operation

// hash returns a short digest of the name; shared by run and stop.
func hash(name string) string {
	sum := sha256.Sum256([]byte(name))
	return string(sum[:4])
}
