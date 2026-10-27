#!/usr/bin/env bats

setup() {
  command -v yq >/dev/null || { echo "bats necesita yq." >&2; return 1; }
  WF="${BATS_TEST_DIRNAME}/../workflows"
}

@test "cada workflow carga logging y termina en su script" {
  for pair in create:publish update:publish delete:unpublish link:link_subscribe link_update:link_update unlink:link_unsubscribe; do
    [ "$(yq -r '.steps[0].file' "$WF/${pair%%:*}.yaml")" = '$SERVICE_PATH/logging' ]
    [ "$(yq -r '.steps[-1].file' "$WF/${pair%%:*}.yaml")" = "\$SERVICE_PATH/scripts/${pair##*:}" ]
  done
}

@test "los workflows piden el provider de container-orchestration" {
  for f in create update delete link link_update unlink; do
    [ "$(yq -r '.provider_categories[0]' "$WF/$f.yaml")" = "container-orchestration" ]
  done
}
