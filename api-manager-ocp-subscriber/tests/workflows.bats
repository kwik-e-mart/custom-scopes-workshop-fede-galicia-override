#!/usr/bin/env bats

setup() {
  command -v yq >/dev/null || { echo "bats necesita yq." >&2; return 1; }
  WF="${BATS_TEST_DIRNAME}/../workflows"
}

@test "cada workflow carga logging y termina en su script" {
  [ "$(yq -r '.steps[-1].file' "$WF/create.yaml")" = '$SERVICE_PATH/scripts/subscribe' ]
  [ "$(yq -r '.steps[-1].file' "$WF/update.yaml")" = '$SERVICE_PATH/scripts/change_plan' ]
  [ "$(yq -r '.steps[-1].file' "$WF/delete.yaml")" = '$SERVICE_PATH/scripts/unsubscribe' ]
  for f in create update delete; do
    [ "$(yq -r '.steps[0].file' "$WF/$f.yaml")" = '$SERVICE_PATH/logging' ]
  done
}

@test "los workflows piden el provider de container-orchestration" {
  for f in create update delete; do
    [ "$(yq -r '.provider_categories[0]' "$WF/$f.yaml")" = "container-orchestration" ]
  done
}
