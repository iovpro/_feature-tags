package b

// #f:fx.demo.run.apply@recv

// HandleRun applies a run request that arrived from another node.
func HandleRun(kind string, payload []byte) error {
	switch kind {
	case "ack": // #f:fx.demo.run.ack
		return nil
	default: // #f:fx.demo.stop
		return Stop(payload)
	}
}
