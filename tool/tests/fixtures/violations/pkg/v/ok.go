package v

// #f:fx.demo.run@entry

// RunEntry is the valid start of the run flow in this fixture.
func RunEntry() error {
	return nil
}

// #f:fx.demo.stop.finish

// finish continues the stop flow, which has no start marker anywhere in this repository.
func finish() {}

// #f:fx.zzz.orphan

// orphan carries a tag that is missing from the registry.
func orphan() {}
