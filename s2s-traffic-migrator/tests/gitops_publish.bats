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
  export ORIGIN=EKS
  export GITOPS_BRANCH=main
  export GITOPS_PATH_PREFIX=""
  export GITOPS_PUSH_RETRIES=5
  unset GITOPS_REPO_URL
}

make_render() {
  ORIGIN="$1"
  CTX="$BATS_TEST_TMPDIR/ctx.json"
  MDIR="$BATS_TEST_TMPDIR/manifests"
  jq -n --arg origin "$1" --argjson interceptions "$2" '{
    namespace: "payments", gateway_name: "s2s-egress", gateway_class: "istio",
    listen_port: 8080, token_duration: 300, wristband_secret: "payments-wristband-key",
    peer_ca_secret: "s2s-remote-ca", peer_gateway_host: "peer.example.io",
    local_ingress_host: "s2s-ingress-istio.gateways.svc.cluster.local",
    gateway_namespace: "gateways", cluster_label: "gal-poc-eks-dev",
    authpolicy_api_version: "kuadrant.io/v1",
    managed_label: "egress-interceptor/managed",
    origin: $origin, interceptions: $interceptions
  }' >"$CTX"
  rm -rf "$MDIR"
  mkdir -p "$MDIR"
  render_manifests "$CTX" "$MDIR" >/dev/null
}

dos_reglas() {
  printf '%s' '[{"service_name":"reports","scope":"eks","scope_fqdn":"reports.example.io","percent":50},{"service_name":"checkout","scope":"eks","scope_fqdn":"checkout.example.io","percent":100}]'
}

una_regla() {
  printf '%s' '[{"service_name":"reports","scope":"eks","scope_fqdn":"reports.example.io","percent":50}]'
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

@test "el path del subárbol es substrato/namespace" {
  run gitops_subtree
  [ "$output" = "eks/payments" ]
}

@test "el substrato sale de ORIGIN, no de la configuración" {
  ORIGIN=OS
  run gitops_subtree
  [ "$output" = "openshift/payments" ]
}

@test "el prefix se cuelga adelante y no duplica la barra" {
  GITOPS_PATH_PREFIX="clusters/"
  run gitops_subtree
  [ "$output" = "clusters/eks/payments" ]
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

@test "la URL sale del env var, tal cual" {
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  run gitops_repo_url
  [ "$output" = "https://tok@example.com/o/r.git" ]
}

@test "la redacción tapa el userinfo y deja el host" {
  run bash -c 'printf %s "fatal: no anduvo https://ghp_secreto@github.com/o/r.git" | gitops_redact'
  [[ "$output" != *ghp_secreto* ]]
  [[ "$output" == *"https://***@github.com/o/r.git"* ]]
}

@test "la redacción NO se come una barra del path" {
  run bash -c 'printf %s "https://github.com/o/r.git" | gitops_redact'
  [ "$output" = "https://github.com/o/r.git" ]
}

@test "la redacción NO se come un arroba que está en el path" {
  run bash -c 'printf %s "https://github.com/o/r.git@v1" | gitops_redact'
  [ "$output" = "https://github.com/o/r.git@v1" ]
}

@test "la redacción tapa hasta el ÚLTIMO arroba, no el primero" {
  run bash -c 'printf %s "fatal: https://us@er:secreto_real@github.com/o/r.git" | gitops_redact'
  [[ "$output" != *secreto_real* ]]
  [[ "$output" == *"https://***@github.com/o/r.git"* ]]
}

@test "una URL con transporte ext:: se RECHAZA sin clonar" {
  export GITOPS_REPO_URL='ext::sh -c whoami'
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no tiene una forma aceptada"* ]]
}

@test "una URL que arranca con guión se RECHAZA: seria una opción de git" {
  export GITOPS_REPO_URL='--upload-pack=whoami'
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no tiene una forma aceptada"* ]]
}

@test "una URL que no es https se RECHAZA" {
  export GITOPS_REPO_URL='http://ghp_tok@github.com/o/r.git'
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no tiene una forma aceptada"* ]]
}

@test "una URL con .. se RECHAZA, igual que el path prefix" {
  # El path local se usa como origen de un clone. GITOPS_PATH_PREFIX ya rechaza '..' con su propio
  # chequeo; sin esto el validador de URL era la única puerta que lo dejaba pasar.
  run gitops_valid_repo_url "/a/../../../etc/passwd"
  [ "$status" -ne 0 ]
  run gitops_valid_repo_url "https://host/o/../../r.git"
  [ "$status" -ne 0 ]
  # Y un path local legítimo sigue entrando: el remoto de estos mismos tests es uno.
  run gitops_valid_repo_url "/tmp/remote.git"
  [ "$status" -eq 0 ]
}

@test "una URL con barra en la credencial se RECHAZA en vez de filtrarla" {
  export GITOPS_REPO_URL='https://x-access-token:gh_p/secreto_con_barra@github.com/o/r.git'
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" != *secreto_con_barra* ]]
}

@test "el rechazo de una URL inválida no imprime la URL" {
  export GITOPS_REPO_URL='ssh://ghp_secreto999@github.com/o/r.git'
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" != *ghp_secreto999* ]]
}

@test "un NAMESPACE con .. ABORTA antes de cualquier rm -rf" {
  armar_remoto
  export NAMESPACE='../../../etc'
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"path del repo"* ]]
}

@test "un GITOPS_PATH_PREFIX absoluto ABORTA" {
  armar_remoto
  export GITOPS_PATH_PREFIX='/etc'
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"path del repo"* ]]
}

@test "los objetos de namespace quedan en el nivel del namespace" {
  make_render EKS "$(dos_reglas)"
  gitops_render_tree "$CTX" "$MDIR" "$BATS_TEST_TMPDIR/tree"
  [ -f "$BATS_TEST_TMPDIR/tree/10-gateway.yaml" ]
  [ -f "$BATS_TEST_TMPDIR/tree/20-authpolicy.yaml" ]
  [ -f "$BATS_TEST_TMPDIR/tree/30-destinationrule-peer.yaml" ]
  [ -f "$BATS_TEST_TMPDIR/tree/40-destinationrule-local-ingress.yaml" ]
}

@test "cada regla queda en su propia hoja, con su propia route" {
  make_render EKS "$(dos_reglas)"
  gitops_render_tree "$CTX" "$MDIR" "$BATS_TEST_TMPDIR/tree"
  [ -f "$BATS_TEST_TMPDIR/tree/reports/50-httproute-egress.yaml" ]
  [ -f "$BATS_TEST_TMPDIR/tree/checkout/50-httproute-egress.yaml" ]
  run objetos "$BATS_TEST_TMPDIR/tree/reports/50-httproute-egress.yaml"
  [ "$output" = "HTTPRoute/payments/s2s-egress-reports" ]
}

@test "la hoja de un servicio NO trae la route de otro" {
  make_render EKS "$(dos_reglas)"
  gitops_render_tree "$CTX" "$MDIR" "$BATS_TEST_TMPDIR/tree"
  run grep -c checkout "$BATS_TEST_TMPDIR/tree/reports/50-httproute-egress.yaml"
  [ "$output" -eq 0 ]
}

@test "los objetos de namespace NO se duplican en las hojas" {
  make_render EKS "$(dos_reglas)"
  gitops_render_tree "$CTX" "$MDIR" "$BATS_TEST_TMPDIR/tree"
  [ ! -f "$BATS_TEST_TMPDIR/tree/reports/10-gateway.yaml" ]
  [ ! -f "$BATS_TEST_TMPDIR/tree/reports/20-authpolicy.yaml" ]
  [ ! -f "$BATS_TEST_TMPDIR/tree/reports/30-destinationrule-peer.yaml" ]
}

@test "desde OpenShift la hoja trae además la route de ingreso" {
  make_render OS "$(dos_reglas)"
  gitops_render_tree "$CTX" "$MDIR" "$BATS_TEST_TMPDIR/tree"
  [ -f "$BATS_TEST_TMPDIR/tree/reports/60-httproute-ingress.yaml" ]
  [ ! -f "$BATS_TEST_TMPDIR/tree/40-destinationrule-local-ingress.yaml" ]
  run objetos "$BATS_TEST_TMPDIR/tree/reports/60-httproute-ingress.yaml"
  [ "$output" = "HTTPRoute/gateways/s2s-ingress-reports" ]
}

@test "sin ninguna regla quedan el Gateway y su AuthPolicy, y ninguna hoja" {
  make_render EKS '[]'
  gitops_render_tree "$CTX" "$MDIR" "$BATS_TEST_TMPDIR/tree"
  [ -f "$BATS_TEST_TMPDIR/tree/10-gateway.yaml" ]
  [ -f "$BATS_TEST_TMPDIR/tree/20-authpolicy.yaml" ]
  [ ! -d "$BATS_TEST_TMPDIR/tree/reports" ]
}

@test "un contexto de render ilegible ABORTA en vez de rendir cero hojas" {
  make_render EKS "$(dos_reglas)"
  printf 'esto no es json {{{' >"$BATS_TEST_TMPDIR/roto.json"
  run gitops_render_tree "$BATS_TEST_TMPDIR/roto.json" "$MDIR" "$BATS_TEST_TMPDIR/tree"
  [ "$status" -ne 0 ]
}

@test "un contexto de render ilegible NO borra las hojas ya publicadas" {
  armar_remoto
  make_render EKS "$(dos_reglas)"
  gitops_publish "$CTX" "$MDIR"
  printf 'esto no es json {{{' >"$BATS_TEST_TMPDIR/roto.json"
  run gitops_publish "$BATS_TEST_TMPDIR/roto.json" "$MDIR"
  [ "$status" -ne 0 ]
  run remoto_ls
  [[ "$output" == *"payments/reports/50-httproute-egress.yaml"* ]]
  [[ "$output" == *"payments/checkout/50-httproute-egress.yaml"* ]]
}

@test "los objetos publicados son los MISMOS que los aplicados, desde los dos orígenes" {
  # Es el test que impide que el fan-out se desincronice del apply. Va por los dos orígenes porque
  # no emiten el mismo juego: EKS agrega 40-destinationrule-local-ingress a nivel namespace y
  # OpenShift agrega 60-httproute-ingress a nivel servicio. Con uno solo, media clasificación de
  # GITOPS_*_MANIFESTS queda sin ejercitar.
  local origin aplicados publicados
  for origin in OS EKS; do
    make_render "$origin" "$(dos_reglas)"
    rm -rf "$BATS_TEST_TMPDIR/tree"
    gitops_render_tree "$CTX" "$MDIR" "$BATS_TEST_TMPDIR/tree"
    aplicados=$(objetos "$MDIR"/*.yaml | sort)
    publicados=$(find "$BATS_TEST_TMPDIR/tree" -name '*.yaml' -print0 \
      | xargs -0 -n1 yq -r '[.kind, (.metadata.namespace // ""), .metadata.name] | join("/")' | sort)
    [ "$aplicados" = "$publicados" ] || {
      echo "origen $origin:" >&2; diff <(echo "$aplicados") <(echo "$publicados") >&2; return 1
    }
  done
}

@test "la clasificación de manifiestos cubre TODOS los templates" {
  local tpl base clasificados
  clasificados=$(printf '%s\n' $GITOPS_NAMESPACE_MANIFESTS $GITOPS_PER_SERVICE_MANIFESTS)
  for tpl in "${BATS_TEST_DIRNAME}/../manifests/egress"/*.yaml.tpl; do
    base=$(basename "$tpl" .tpl)
    printf '%s\n' "$clasificados" | grep -qx "$base" || {
      echo "template sin clasificar en gitops_lib: $base" >&2
      return 1
    }
  done
}

@test "publica el subárbol completo en el branch configurado" {
  armar_remoto
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" == *"eks/payments/10-gateway.yaml"* ]]
  [[ "$output" == *"eks/payments/reports/50-httproute-egress.yaml"* ]]
  [[ "$output" == *"eks/payments/checkout/50-httproute-egress.yaml"* ]]
}

@test "sin URL configurada no publica y NO falla" {
  unset GITOPS_REPO_URL
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -eq 0 ]
}

@test "un namespace vacío ABORTA: el subárbol quedaría sin hoja" {
  armar_remoto
  export NAMESPACE=""
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"path del repo"* ]]
}

@test "una URL que no se puede clonar ABORTA" {
  export GITOPS_REPO_URL="$BATS_TEST_TMPDIR/no-hay-repo-aca"
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no se pudo clonar"* ]]
}

@test "el token no aparece en la salida cuando el clone falla" {
  export GITOPS_REPO_URL="https://ghp_secreto123@127.0.0.1:1/o/r.git"
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" != *ghp_secreto123* ]]
  [[ "$output" == *"***@127.0.0.1"* ]]
}

@test "una segunda corrida sin cambios no crea commit" {
  armar_remoto
  make_render EKS "$(dos_reglas)"
  gitops_publish "$CTX" "$MDIR"
  local antes despues
  antes=$(remoto_commits)
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -eq 0 ]
  despues=$(remoto_commits)
  [ "$antes" = "$despues" ]
}

@test "sacar una regla borra su hoja del repo" {
  armar_remoto
  make_render EKS "$(dos_reglas)"
  gitops_publish "$CTX" "$MDIR"
  make_render EKS "$(una_regla)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" == *"payments/reports/50-httproute-egress.yaml"* ]]
  [[ "$output" != *checkout* ]]
}

@test "el delete borra el subárbol entero" {
  armar_remoto
  make_render EKS "$(dos_reglas)"
  gitops_publish "$CTX" "$MDIR"
  run gitops_publish_removal
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" != *"eks/payments"* ]]
}

@test "el delete de algo nunca publicado es un no-op que no falla" {
  armar_remoto
  run gitops_publish_removal
  [ "$status" -eq 0 ]
}

@test "un push rechazado se reintenta y termina publicando" {
  armar_remoto
  rechazar_un_push
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" == *"payments/reports/50-httproute-egress.yaml"* ]]
}

@test "agotados los intentos, ABORTA" {
  armar_remoto
  export GITOPS_PUSH_RETRIES=2
  rechazar_todo_push
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"después de 2 intentos"* ]]
  # Que haya reintentado de verdad, y exactamente las veces configuradas: sin esto, un bug que
  # saliera del loop en el primer rechazo daría el mismo mensaje final. (GITOPS_SLEEPS no sirve
  # para esto: `run` corre en un subshell y el contador no vuelve.)
  [ "$(grep -c 'push rechazado' <<<"$output")" -eq 2 ]
}

@test "dos instancias en paralelo sobre el mismo repo aterrizan las DOS" {
  armar_remoto
  make_render EKS "$(una_regla)"
  local ctx_a="$BATS_TEST_TMPDIR/ctx-a.json" mdir_a="$BATS_TEST_TMPDIR/m-a"
  cp "$CTX" "$ctx_a"
  cp -r "$MDIR" "$mdir_a"
  make_render EKS '[{"service_name":"checkout","scope":"eks","scope_fqdn":"checkout.example.io","percent":50}]'
  ( export NAMESPACE=payments; gitops_publish "$ctx_a" "$mdir_a" ) &
  ( export NAMESPACE=billing;  gitops_publish "$CTX" "$MDIR" ) &
  wait
  run remoto_ls
  [[ "$output" == *"eks/payments/reports/50-httproute-egress.yaml"* ]]
  [[ "$output" == *"eks/billing/checkout/50-httproute-egress.yaml"* ]]
}
