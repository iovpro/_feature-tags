#!/usr/bin/env bats

# #f:fx.ops.up

@test "up starts the demo stack" {
  run sh "$BATS_TEST_DIRNAME/run.sh" up
  [ "$status" -eq 0 ]
}
