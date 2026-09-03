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
  export SITE=openshift-crc
  unset GITOPS_REPO_URL
}

aplicar_configuration_del_workflow() {
  local file="$1" key value
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] || continue
    export "$key=$value"
  done < <(yq -r '.configuration | to_entries[] | [.key, .value] | @tsv' "$file")
}

@test "create.yaml no declara SITE en configuration: sale de la dimension de la instancia" {
  run yq -r '.configuration | has("SITE")' "$CREATE"
  [ "$output" = "false" ]
}

@test "delete.yaml no declara SITE en configuration: sale de la dimension de la instancia" {
  run yq -r '.configuration | has("SITE")' "$DELETE"
  [ "$output" = "false" ]
}

@test "create.yaml declara SITE en el output del build context" {
  run yq -r '.steps[] | select(.name == "build context") | .output[].name' "$CREATE"
  echo "$output" | grep -qx "SITE"
}

@test "delete.yaml declara SITE en el output del build context" {
  run yq -r '.steps[] | select(.name == "build context") | .output[].name' "$DELETE"
  echo "$output" | grep -qx "SITE"
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

@test "el SITE del build context llega al subárbol sin que la configuration: de create.yaml lo pise" {
  export SITE=aws-us-east-1
  aplicar_configuration_del_workflow "$CREATE"
  run gitops_subtree
  [ "$output" = "cross-namespace-rules/aws-us-east-1/payments/api-manager-svc-1" ]
}

@test "el SITE del build context llega al subárbol sin que la configuration: de delete.yaml lo pise" {
  export SITE=aws-us-east-1
  aplicar_configuration_del_workflow "$DELETE"
  run gitops_subtree
  [ "$output" = "cross-namespace-rules/aws-us-east-1/payments/api-manager-svc-1" ]
}
