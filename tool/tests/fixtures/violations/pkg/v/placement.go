package v

// #f:fx.demo.run.gap


func twoBlankLines() {}

func body() {
	// #f:fx.demo.run.inner

	x := 1
	_ = x
}

func tail() error {
	return nil // #f:fx.demo.run.tail
}

// #f:fx.demo.run.eof
