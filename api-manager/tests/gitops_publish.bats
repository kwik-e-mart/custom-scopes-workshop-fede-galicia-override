#!/usr/bin/env bats

setup() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "bats necesita bash >= 4 (tenés ${BASH_VERSION}). Corré: PATH=/opt/homebrew/bin:\$PATH bats tests/" >&2
    return 1
  }
  command -v gomplate >/dev/null && command -v jq >/dev/null \
    && command -v yq >/dev/null && command -v git >/dev/null || {
    echo "bats necesita gomplate, jq, yq y git." >&2; return 1
  }

  gitops_sleep() { GITOPS_SLEEPS=$(( ${GITOPS_SLEEPS:-0} + 1 )); }

  source "${BATS_TEST_DIRNAME}/../logging"
  source "${BATS_TEST_DIRNAME}/../scripts/k8s/manifests_lib"
  source "${BATS_TEST_DIRNAME}/../scripts/k8s/gitops_lib"
  export -f gitops_redact

  export NAMESPACE=payments
  export ROUTE_NAME=api-manager-svc-1
  export GITOPS_BRANCH=main
  export GITOPS_PATH_PREFIX=cross-namespace-rules
  export GITOPS_PUSH_RETRIES=5
  unset GITOPS_REPO_URL GITOPS_SUBSTRATE ORIGIN
}

make_render() {
  local route="${1:-$ROUTE_NAME}"
  CTX="$BATS_TEST_TMPDIR/ctx-$route.json"
  MDIR="$BATS_TEST_TMPDIR/manifests-$route"
  jq -n --arg route_name "$route" '{
    namespace: "payments", route_name: $route_name, app_target: "payments.reports",
    gateway_name: "s2s-ingress", gateway_namespace: "gateways", api_key_header: "x-api-key",
    managed_label: "api-manager.nullplatform.io/managed", target_label: "apimgr-target",
    authpolicy_api_version: "kuadrant.io/v1",
    wristband_secret: "payments-wristband-key", token_duration: 300,
    hosts: ["api.expuesta.com"],
    routes: [{path:"/r1", methods:["GET"], scope:"prod", backend:"appy.internas.com"}]
  }' >"$CTX"
  rm -rf "$MDIR"
  mkdir -p "$MDIR"
  render_manifests "$CTX" "$MDIR" >/dev/null
}

objetos() { yq -r '[.kind, (.metadata.namespace // ""), .metadata.name] | join("/")' "$@"; }

armar_remoto() {
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init --quiet --bare --initial-branch=main "$REMOTE"
  local seed="$BATS_TEST_TMPDIR/seed"
  git clone --quiet "$REMOTE" "$seed"
  git -C "$seed" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m init
  git -C "$seed" push --quiet origin HEAD:refs/heads/main
  rm -rf "$seed"
  export GITOPS_REPO_URL="$REMOTE"
  export GITOPS_SUBSTRATE=openshift
}

en_clon_del_remoto() {
  local check="$BATS_TEST_TMPDIR/check-$$-$RANDOM"
  git clone --quiet "$REMOTE" "$check" || return 1
  git -C "$check" "$@"
  local rc=$?
  rm -rf "$check"
  return "$rc"
}

remoto_ls() { en_clon_del_remoto ls-files; }

remoto_commits() { en_clon_del_remoto rev-list --count HEAD; }

rechazar_un_push() {
  cat >"$REMOTE/hooks/pre-receive" <<'HOOK'
#!/bin/sh
if [ ! -f "$GIT_DIR/rechazado-una-vez" ]; then
  touch "$GIT_DIR/rechazado-una-vez"
  echo "rechazo simulado" >&2
  exit 1
fi
exit 0
HOOK
  chmod +x "$REMOTE/hooks/pre-receive"
}

rechazar_todo_push() {
  cat >"$REMOTE/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo "rechazo permanente" >&2
exit 1
HOOK
  chmod +x "$REMOTE/hooks/pre-receive"
}

@test "el path del subárbol es prefix/substrato/namespace/ruta" {
  run gitops_subtree
  [ "$output" = "cross-namespace-rules/openshift/payments/api-manager-svc-1" ]
}

@test "sin GITOPS_SUBSTRATE y sin ORIGIN, el fallback es openshift" {
  run gitops_subtree
  [[ "$output" == cross-namespace-rules/openshift/* ]]
}

@test "GITOPS_SUBSTRATE valido pisa el fallback de ORIGIN" {
  export GITOPS_SUBSTRATE=eks
  export ORIGIN=OS
  run gitops_subtree
  [ "$output" = "cross-namespace-rules/eks/payments/api-manager-svc-1" ]
}

@test "GITOPS_SUBSTRATE invalido ABORTA antes de tocar el filesystem" {
  export GITOPS_SUBSTRATE='../etc'
  run gitops_subtree
  [ "$status" -ne 0 ]
}

@test "GITOPS_SUBSTRATE con barra tambien se rechaza" {
  export GITOPS_SUBSTRATE='a/b'
  run gitops_subtree
  [ "$status" -ne 0 ]
}

@test "con GitOps habilitado y GITOPS_SUBSTRATE vacío, publica bajo el sustrato que deriva de ORIGIN" {
  armar_remoto
  unset GITOPS_SUBSTRATE
  export ORIGIN=EKS
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" == *"cross-namespace-rules/eks/payments/api-manager-svc-1/10-httproute.yaml"* ]]
}

@test "con GitOps habilitado y un GITOPS_SUBSTRATE válido, el subárbol publicado lo usa" {
  armar_remoto
  export GITOPS_SUBSTRATE=eks
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" == *"cross-namespace-rules/eks/payments/api-manager-svc-1/10-httproute.yaml"* ]]
}

@test "con GitOps deshabilitado y GITOPS_SUBSTRATE vacío, no pasa nada" {
  unset GITOPS_REPO_URL GITOPS_SUBSTRATE
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -eq 0 ]
}

@test "sin URL el publisher está apagado" {
  run gitops_enabled
  [ "$status" -ne 0 ]
}

@test "con URL en el env el publisher está prendido" {
  export GITOPS_REPO_URL=https://x@example.com/o/r.git
  run gitops_enabled
  [ "$status" -eq 0 ]
}

@test "la redacción tapa el userinfo y deja el host" {
  run bash -c 'printf %s "fatal: no anduvo https://ghp_secreto@github.com/o/r.git" | gitops_redact'
  [[ "$output" != *ghp_secreto* ]]
  [[ "$output" == *"https://***@github.com/o/r.git"* ]]
}

@test "una URL con transporte ext:: se RECHAZA sin clonar" {
  export GITOPS_REPO_URL='ext::sh -c whoami'
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no tiene una forma aceptada"* ]]
}

@test "una URL que arranca con guión se RECHAZA: seria una opción de git" {
  export GITOPS_REPO_URL='--upload-pack=whoami'
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no tiene una forma aceptada"* ]]
}

@test "una URL con barra en la credencial se RECHAZA en vez de filtrarla" {
  export GITOPS_REPO_URL='https://x-access-token:gh_p/secreto_con_barra@github.com/o/r.git'
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" != *secreto_con_barra* ]]
}

@test "un NAMESPACE con .. ABORTA antes de cualquier rm -rf" {
  armar_remoto
  export NAMESPACE='../../../etc'
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"path del repo"* ]]
}

@test "un ROUTE_NAME con .. ABORTA" {
  armar_remoto
  make_render
  export ROUTE_NAME='../../../etc'
  run gitops_publish "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"path del repo"* ]]
}

@test "los dos manifiestos quedan en la hoja del servicio" {
  make_render
  gitops_render_tree "$MDIR" "$BATS_TEST_TMPDIR/tree"
  [ -f "$BATS_TEST_TMPDIR/tree/10-httproute.yaml" ]
  [ -f "$BATS_TEST_TMPDIR/tree/20-authpolicy.yaml" ]
}

@test "los objetos publicados son los mismos que los aplicados" {
  make_render
  gitops_render_tree "$MDIR" "$BATS_TEST_TMPDIR/tree"
  local aplicados publicados
  aplicados=$(objetos "$MDIR"/*.yaml | sort)
  publicados=$(objetos "$BATS_TEST_TMPDIR/tree"/*.yaml | sort)
  [ "$aplicados" = "$publicados" ]
}

@test "la clasificación de manifiestos cubre TODOS los templates" {
  local tpl base clasificados
  clasificados=$(printf '%s\n' $GITOPS_NAMESPACE_MANIFESTS $GITOPS_PER_SERVICE_MANIFESTS)
  for tpl in "${BATS_TEST_DIRNAME}/../manifests/expose"/*.yaml.tpl; do
    base=$(basename "$tpl" .tpl)
    printf '%s\n' "$clasificados" | grep -qx "$base" || {
      echo "template sin clasificar en gitops_lib: $base" >&2
      return 1
    }
  done
}

@test "publica el subárbol bajo cross-namespace-rules" {
  armar_remoto
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" == *"cross-namespace-rules/openshift/payments/api-manager-svc-1/10-httproute.yaml"* ]]
  [[ "$output" == *"cross-namespace-rules/openshift/payments/api-manager-svc-1/20-authpolicy.yaml"* ]]
}

@test "sin URL configurada no publica y NO falla" {
  unset GITOPS_REPO_URL
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -eq 0 ]
}

@test "una segunda corrida sin cambios no crea commit" {
  armar_remoto
  make_render
  gitops_publish "$MDIR"
  local antes despues
  antes=$(remoto_commits)
  run gitops_publish "$MDIR"
  [ "$status" -eq 0 ]
  despues=$(remoto_commits)
  [ "$antes" = "$despues" ]
}

@test "el delete borra solo la hoja de ESTE servicio" {
  armar_remoto
  make_render
  gitops_publish "$MDIR"
  run gitops_publish_removal
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" != *"api-manager-svc-1"* ]]
}

@test "el delete de algo nunca publicado es un no-op que no falla" {
  armar_remoto
  run gitops_publish_removal
  [ "$status" -eq 0 ]
}

@test "dos servicios en el MISMO namespace no se pisan: publicar uno no borra la hoja del otro" {
  armar_remoto
  make_render api-manager-svc-1
  gitops_publish "$MDIR"
  export ROUTE_NAME=api-manager-svc-2
  make_render api-manager-svc-2
  run gitops_publish "$MDIR"
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" == *"api-manager-svc-1/10-httproute.yaml"* ]]
  [[ "$output" == *"api-manager-svc-2/10-httproute.yaml"* ]]
}

@test "borrar un servicio no toca la hoja de otro en el mismo namespace" {
  armar_remoto
  make_render api-manager-svc-1
  gitops_publish "$MDIR"
  export ROUTE_NAME=api-manager-svc-2
  make_render api-manager-svc-2
  gitops_publish "$MDIR"
  export ROUTE_NAME=api-manager-svc-1
  run gitops_publish_removal
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" != *"api-manager-svc-1"* ]]
  [[ "$output" == *"api-manager-svc-2/10-httproute.yaml"* ]]
}

@test "un push rechazado se reintenta y termina publicando" {
  armar_remoto
  rechazar_un_push
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" == *"api-manager-svc-1/10-httproute.yaml"* ]]
}

@test "agotados los intentos, ABORTA" {
  armar_remoto
  export GITOPS_PUSH_RETRIES=2
  rechazar_todo_push
  make_render
  run gitops_publish "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"después de 2 intentos"* ]]
}
