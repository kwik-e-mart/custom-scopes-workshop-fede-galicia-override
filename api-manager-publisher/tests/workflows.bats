#!/usr/bin/env bats

setup() {
  command -v yq >/dev/null || {
    echo "bats necesita yq." >&2; return 1
  }
  CREATE="${BATS_TEST_DIRNAME}/../workflows/istio/create.yaml"
  DELETE="${BATS_TEST_DIRNAME}/../workflows/istio/delete.yaml"

  source "${BATS_TEST_DIRNAME}/../logging"
  source "${BATS_TEST_DIRNAME}/../scripts/k8s/gitops_lib"
  export -f log

  export NAMESPACE=payments
  export ROUTE_NAME=api-manager-svc-1
  unset GITOPS_REPO_URL ORIGIN
}

aplicar_configuration_del_workflow() {
  local file="$1" key value
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] || continue
    export "$key=$value"
  done < <(yq -r '.configuration | to_entries[] | [.key, .value] | @tsv' "$file")
}

@test "create.yaml no declara ORIGIN en configuration: tiene que venir del entorno del agente" {
  run yq -r '.configuration | has("ORIGIN")' "$CREATE"
  [ "$output" = "false" ]
}

@test "delete.yaml no declara ORIGIN en configuration: tiene que venir del entorno del agente" {
  run yq -r '.configuration | has("ORIGIN")' "$DELETE"
  [ "$output" = "false" ]
}

@test "create.yaml no re-declara ORIGIN en el output del build context" {
  run yq -r '.steps[] | select(.name == "build context") | .output[].name' "$CREATE"
  ! echo "$output" | grep -qx "ORIGIN"
}

@test "delete.yaml no re-declara ORIGIN en el output del build context" {
  run yq -r '.steps[] | select(.name == "build context") | .output[].name' "$DELETE"
  ! echo "$output" | grep -qx "ORIGIN"
}

@test "create.yaml sigue declarando las variables GITOPS_* que SÍ son por service" {
  run yq -r '.configuration | keys | .[]' "$CREATE"
  echo "$output" | grep -qx "GITOPS_PUSH_RETRIES"
  ! echo "$output" | grep -qx "GITOPS_BRANCH"
  ! echo "$output" | grep -qx "GITOPS_PATH_PREFIX"
}

@test "delete.yaml sigue declarando las variables GITOPS_* que SÍ son por service" {
  run yq -r '.configuration | keys | .[]' "$DELETE"
  echo "$output" | grep -qx "GITOPS_PUSH_RETRIES"
  ! echo "$output" | grep -qx "GITOPS_BRANCH"
  ! echo "$output" | grep -qx "GITOPS_PATH_PREFIX"
}

@test "ningún workflow declara GITOPS_REPO_URL: lleva credencial y va solo por el env del agente" {
  run yq -r '.configuration | has("GITOPS_REPO_URL")' "$CREATE"
  [ "$output" = "false" ]
  run yq -r '.configuration | has("GITOPS_REPO_URL")' "$DELETE"
  [ "$output" = "false" ]
}

@test "un ORIGIN puesto por el agente llega al subárbol sin que la configuration: de create.yaml lo pise" {
  export ORIGIN=EKS
  aplicar_configuration_del_workflow "$CREATE"
  run gitops_subtree
  [ "$output" = "cross-namespace-rules/eks/payments/api-manager-svc-1" ]
}

@test "un ORIGIN puesto por el agente llega al subárbol sin que la configuration: de delete.yaml lo pise" {
  export ORIGIN=EKS
  aplicar_configuration_del_workflow "$DELETE"
  run gitops_subtree
  [ "$output" = "cross-namespace-rules/eks/payments/api-manager-svc-1" ]
}
