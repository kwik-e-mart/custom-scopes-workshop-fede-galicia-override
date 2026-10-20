#!/usr/bin/env bats

setup() {
  command -v helm >/dev/null || { echo "bats necesita helm." >&2; return 1; }
  command -v yq >/dev/null || { echo "bats necesita yq." >&2; return 1; }
  CHART="${BATS_TEST_DIRNAME}/../chart"
  BASE=(--namespace apim-mock
    --set image.repository=public.ecr.aws/test/apim-mock
    --set "httpRoute.parentRefs[0].name=s2s-ingress"
    --set "httpRoute.parentRefs[0].namespace=gateways"
    --set "httpRoute.hostnames[0]=apim-mock.test.local"
    --set mock.token=tok-123
    --set "credentialSecrets.namespaces={sigla-x-qa}")
}

render() {
  helm template mock "$CHART" "${BASE[@]}" "$@"
}

kinds() {
  render "$@" | yq -N '.kind' | sort | tr '\n' ' '
}

@test "renderiza deployment, service, httproute y el rbac, sin ingress" {
  run kinds
  [ "$status" -eq 0 ]
  [ "$output" = "Deployment HTTPRoute Role Role Role RoleBinding RoleBinding RoleBinding Secret Service ServiceAccount " ]
}

@test "falla sin parentRefs del HTTPRoute" {
  run helm template mock "$CHART" --set mock.token=t --set "credentialSecrets.namespaces={a}" --set image.repository=x --set "httpRoute.hostnames[0]=h"
  [ "$status" -ne 0 ]
  [[ "$output" == *parentRefs* ]]
}

@test "falla sin hostnames del HTTPRoute" {
  run helm template mock "$CHART" --set mock.token=t --set "credentialSecrets.namespaces={a}" --set image.repository=x --set "httpRoute.parentRefs[0].name=g" --set "httpRoute.parentRefs[0].namespace=n"
  [ "$status" -ne 0 ]
  [[ "$output" == *hostnames* ]]
}

@test "falla sin el repositorio de la imagen" {
  run helm template mock "$CHART" --set mock.token=t --set "credentialSecrets.namespaces={a}" --set "httpRoute.parentRefs[0].name=g" --set "httpRoute.parentRefs[0].namespace=n" --set "httpRoute.hostnames[0]=h"
  [ "$status" -ne 0 ]
  [[ "$output" == *image.repository* ]]
}

@test "el httproute cuelga del gateway pedido y apunta al service" {
  route=$(render | yq -N 'select(.kind == "HTTPRoute")')
  [ "$(yq -N '.spec.parentRefs[0].name' <<<"$route")" = "s2s-ingress" ]
  [ "$(yq -N '.spec.parentRefs[0].namespace' <<<"$route")" = "gateways" ]
  [ "$(yq -N '.spec.hostnames[0]' <<<"$route")" = "apim-mock.test.local" ]
  [ "$(yq -N '.spec.rules[0].backendRefs[0].name' <<<"$route")" = "mock-apim-mock" ]
  [ "$(yq -N '.spec.rules[0].backendRefs[0].port' <<<"$route")" = "$(render | yq -N 'select(.kind == "Service") | .spec.ports[0].port')" ]
}

@test "el deployment corre una sola replica con el estado en un configmap" {
  deployment=$(render | yq -N 'select(.kind == "Deployment")')
  [ "$(yq -N '.spec.replicas' <<<"$deployment")" = "1" ]
  [ "$(yq -N '.spec.template.spec.containers[0].image' <<<"$deployment")" = "public.ecr.aws/test/apim-mock:0.2.3" ]
  [ "$(yq -N '.spec.template.spec.containers[0].env[] | select(.name == "STATE_BACKEND") | .value' <<<"$deployment")" = "configmap" ]
  [ "$(yq -N '.spec.template.spec.containers[0].env[] | select(.name == "POD_NAMESPACE") | .valueFrom.fieldRef.fieldPath' <<<"$deployment")" = "metadata.namespace" ]
  [ "$(yq -N '.spec.template.spec.serviceAccountName' <<<"$deployment")" = "mock-apim-mock" ]
}

@test "el role del estado solo toca configmaps en el namespace del release" {
  role=$(render | yq -N 'select(.kind == "Role" and .metadata.name == "mock-apim-mock-state")')
  [ "$(yq -N '.metadata.namespace' <<<"$role")" = "apim-mock" ]
  [ "$(yq -N -o=json -I=0 '.rules' <<<"$role")" = '[{"apiGroups":[""],"resources":["configmaps"],"verbs":["create"]},{"apiGroups":[""],"resources":["configmaps"],"resourceNames":["mock-apim-mock-state"],"verbs":["get","update"]}]' ]
}

@test "el clusterrole solo crea secrets y gestiona los objetos de la api" {
  run render --set "credentialSecrets.namespaces=null" --set credentialSecrets.allowAllNamespaces=true
  [ "$(yq -N -o=json -I=0 'select(.kind == "ClusterRole") | .rules' <<<"$output")" = '[{"apiGroups":[""],"resources":["secrets"],"verbs":["create"]},{"apiGroups":["gateway.networking.k8s.io"],"resources":["httproutes"],"verbs":["create","patch","delete"]},{"apiGroups":["kuadrant.io"],"resources":["authpolicies","ratelimitpolicies"],"verbs":["create","patch","delete"]}]' ]
}

@test "sin crear secretos no hay permisos sobre secrets y el mock lo sabe" {
  run kinds --set credentialSecrets.create=false
  [ "$output" = "Deployment HTTPRoute Role Role RoleBinding RoleBinding Secret Service ServiceAccount " ]
  run render --set credentialSecrets.create=false
  [ "$(yq -N 'select(.kind == "Role") | .rules[].resources[]' <<<"$output" | grep -c '^secrets$')" = "0" ]
  run render --set credentialSecrets.create=false
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "CREATE_CREDENTIAL_SECRET") | .value' <<<"$output")" = "false" ]
}

@test "NP_API_KEY sale de un secret existente" {
  run render --set npApiKey.existingSecret=np-key --set npApiKey.key=api_key
  ref=$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "NP_API_KEY") | .valueFrom.secretKeyRef' <<<"$output")
  [ "$(yq -N '.name' <<<"$ref")" = "np-key" ]
  [ "$(yq -N '.key' <<<"$ref")" = "api_key" ]
  [ "$(yq -N 'select(.kind == "Secret") | .stringData | has("NP_API_KEY")' <<<"$output")" = "false" ]
}

@test "NP_API_KEY por valor crea el secret del chart" {
  run render --set npApiKey.value=np-123
  [ "$(yq -N 'select(.kind == "Secret") | .stringData.NP_API_KEY' <<<"$output")" = "np-123" ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "NP_API_KEY") | .valueFrom.secretKeyRef.name' <<<"$output")" = "mock-apim-mock" ]
}

@test "sin NP_API_KEY el mock arranca igual y no avisa" {
  run render
  [ "$status" -eq 0 ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "NP_API_KEY") | .name' <<<"$output" | wc -l | tr -d ' ')" = "0" ]
}

@test "falla sin el token del mock" {
  run helm template mock "$CHART" --set image.repository=x --set "httpRoute.parentRefs[0].name=g" --set "httpRoute.parentRefs[0].namespace=n" --set "httpRoute.hostnames[0]=h"
  [ "$status" -ne 0 ]
  [[ "$output" == *mock.token* ]]
}

@test "el token del mock viaja en un secret y no en texto plano" {
  run render
  [ "$(yq -N 'select(.kind == "Secret") | .stringData.MOCK_TOKEN' <<<"$output")" = "tok-123" ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "MOCK_TOKEN") | .valueFrom.secretKeyRef.key' <<<"$output")" = "MOCK_TOKEN" ]
}

@test "con namespaces permitidos crea un role por namespace y no el clusterrole" {
  run render --set "credentialSecrets.namespaces={ns-a,ns-b}"
  [ "$status" -eq 0 ]
  [ "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' <<<"$output" | wc -l | tr -d ' ')" = "0" ]
  [ "$(yq -N 'select(.kind == "Role" and .metadata.name == "mock-apim-mock-credentials") | .metadata.namespace' <<<"$output" | tr '\n' ' ')" = "ns-a ns-b " ]
  [ "$(yq -N 'select(.kind == "RoleBinding" and .metadata.name == "mock-apim-mock-credentials") | .metadata.namespace' <<<"$output" | tr '\n' ' ')" = "ns-a ns-b " ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "ALLOWED_NAMESPACES") | .value' <<<"$output")" = "ns-a,ns-b" ]
}

@test "el pod corre con el perfil seccomp por default" {
  run render
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.securityContext.seccompProfile.type' <<<"$output")" = "RuntimeDefault" ]
}

@test "sin namespaces permitidos y sin pedir todos, el chart falla" {
  run helm template mock "$CHART" --set mock.token=t --set image.repository=x --set "httpRoute.parentRefs[0].name=g" --set "httpRoute.parentRefs[0].namespace=n" --set "httpRoute.hostnames[0]=h"
  [ "$status" -ne 0 ]
  [[ "$output" == *credentialSecrets.namespaces* ]]
}

@test "pedir todos los namespaces es explicito y el mock lo sabe" {
  run render --set "credentialSecrets.namespaces=null" --set credentialSecrets.allowAllNamespaces=true
  [ "$status" -eq 0 ]
  [ "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' <<<"$output")" = "mock-apim-mock-credentials" ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "ALLOW_ALL_NAMESPACES") | .value' <<<"$output")" = "true" ]
}

@test "el role del namespace permitido puede aplicar y borrar los objetos de la api" {
  role=$(render | yq -N 'select(.kind == "Role" and .metadata.name == "mock-apim-mock-credentials")')
  [ "$(yq -N '.metadata.namespace' <<<"$role")" = "sigla-x-qa" ]
  [ "$(yq -N -o=json -I=0 '.rules' <<<"$role")" = '[{"apiGroups":[""],"resources":["secrets"],"verbs":["create"]},{"apiGroups":["gateway.networking.k8s.io"],"resources":["httproutes"],"verbs":["create","patch","delete"]},{"apiGroups":["kuadrant.io"],"resources":["authpolicies","ratelimitpolicies"],"verbs":["create","patch","delete"]}]' ]
}

@test "la credencial del gateway se gestiona solo en su namespace" {
  run render --set credentialSecrets.gatewayNamespace=auth-ns
  role=$(yq -N 'select(.kind == "Role" and .metadata.name == "mock-apim-mock-gateway-credentials")' <<<"$output")
  [ "$(yq -N '.metadata.namespace' <<<"$role")" = "auth-ns" ]
  [ "$(yq -N -o=json -I=0 '.rules' <<<"$role")" = '[{"apiGroups":[""],"resources":["secrets"],"verbs":["create","patch","delete"]}]' ]
  [ "$(yq -N 'select(.kind == "RoleBinding" and .metadata.name == "mock-apim-mock-gateway-credentials") | .subjects[0].namespace' <<<"$output")" = "apim-mock" ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "CREDENTIALS_NAMESPACE") | .value' <<<"$output")" = "auth-ns" ]
}

@test "por default la credencial del gateway va a kuadrant-system" {
  run render
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "CREDENTIALS_NAMESPACE") | .value' <<<"$output")" = "kuadrant-system" ]
}

@test "sin crear secretos sigue pudiendo publicar en el namespace permitido" {
  run render --set credentialSecrets.create=false
  [ "$(yq -N 'select(.kind == "Role" and .metadata.name == "mock-apim-mock-credentials") | .metadata.namespace' <<<"$output")" = "sigla-x-qa" ]
}
