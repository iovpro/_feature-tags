package b

// #f:fx.demo.stop@entry

// Stop terminates the demo flow and persists the final state.
func Stop(payload []byte) error {
	return shared(payload)
}

// #f:fx.demo.run.persist #f:fx.demo.stop.persist

// shared persists the state for both run and stop.
func shared(payload []byte) error {
	_ = payload
	return nil
}
