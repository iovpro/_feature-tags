package a

import "testing"

// #f:fx.demo.run

// TestRun covers the happy path of the demo flow.
func TestRun(t *testing.T) {
	if err := Run(Config{Name: "x"}); err != nil {
		t.Fatal(err)
	}
}

// #f:fx.demo.run #f:fx.demo.stop

func TestRun_Stop(t *testing.T) {
	if err := Run(Config{Name: "y"}); err != nil {
		t.Fatal(err)
	}
}
