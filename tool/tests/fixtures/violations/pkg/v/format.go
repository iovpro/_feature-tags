package v

// #f:fx.demo.run.ok #f:FX.Demo.Run

// upperCase carries a second tag with upper-case letters.
func upperCase() {}

// #f:fx.demo.run.ok #f:fx

// bareDomain carries a bare domain tag.
func bareDomain() {}

// #f:fx.demo

// twoSegmentsOnFunc carries a feature-level tag on a function.
func twoSegmentsOnFunc() {}

// #f:fx.demo.run

// ThreeSegmentsOnType carries a flow-level tag on a type.
type ThreeSegmentsOnType struct {
	ID int
}

// #f:fx.demo.run.ok #f:fx.demo.run@exit

// badMarker carries an unknown marker.
func badMarker() {}

// #f:fx.demo@entry

// MarkerOnFeature carries a marker on a feature-level tag.
type MarkerOnFeature struct {
	ID int
}
