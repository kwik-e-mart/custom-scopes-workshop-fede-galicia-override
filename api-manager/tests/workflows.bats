#!/usr/bin/env bats

setup() {
  command -v yq >/dev/null || {
    echo "bats necesita yq." >&2; return 1
  }
  CREATE="${BATS_TEST_DIRNAME}/../workflows/istio/create.yaml"
  DELETE="${BATS_TEST_DIRNAME}/../workflows/istio/delete.yaml"
}

@test "create.yaml no declara GITOPS_SUBSTRATE en configuration: tiene que venir del entorno del agente" {
  run yq -r '.configuration | has("GITOPS_SUBSTRATE")' "$CREATE"
  [ "$output" = "false" ]
}

@test "delete.yaml no declara GITOPS_SUBSTRATE en configuration: tiene que venir del entorno del agente" {
  run yq -r '.configuration | has("GITOPS_SUBSTRATE")' "$DELETE"
  [ "$output" = "false" ]
}

@test "create.yaml no re-declara GITOPS_SUBSTRATE en el output del build context" {
  run yq -r '.steps[] | select(.name == "build context") | .output[].name' "$CREATE"
  ! echo "$output" | grep -qx "GITOPS_SUBSTRATE"
}

@test "delete.yaml no re-declara GITOPS_SUBSTRATE en el output del build context" {
  run yq -r '.steps[] | select(.name == "build context") | .output[].name' "$DELETE"
  ! echo "$output" | grep -qx "GITOPS_SUBSTRATE"
}

@test "create.yaml sigue declarando las variables GITOPS_* que SÍ son por service" {
  run yq -r '.configuration | keys | .[]' "$CREATE"
  echo "$output" | grep -qx "GITOPS_BRANCH"
  echo "$output" | grep -qx "GITOPS_PATH_PREFIX"
  echo "$output" | grep -qx "GITOPS_PUSH_RETRIES"
}

@test "delete.yaml sigue declarando las variables GITOPS_* que SÍ son por service" {
  run yq -r '.configuration | keys | .[]' "$DELETE"
  echo "$output" | grep -qx "GITOPS_BRANCH"
  echo "$output" | grep -qx "GITOPS_PATH_PREFIX"
  echo "$output" | grep -qx "GITOPS_PUSH_RETRIES"
}

@test "ningún workflow declara GITOPS_REPO_URL: lleva credencial y va solo por el env del agente" {
  run yq -r '.configuration | has("GITOPS_REPO_URL")' "$CREATE"
  [ "$output" = "false" ]
  run yq -r '.configuration | has("GITOPS_REPO_URL")' "$DELETE"
  [ "$output" = "false" ]
}
