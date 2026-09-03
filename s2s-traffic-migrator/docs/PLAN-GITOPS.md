# Plan — publicar los manifiestos del egress-interceptor a un repo GitOps

> ⚠️ **Registro histórico.** Los snippets de abajo usan `ORIGIN`, que ya no existe: la plataforma
> sale de la dimensión `site` de la instancia (`aws-*` → `eks`, `openshift-*` → `openshift`) y esa
> misma dimensión nombra la carpeta del sustrato. Se conservan como estaban para no falsear el
> registro de lo que se construyó.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Estado: implementado.** El código está en `services/s2s-traffic-migrator/scripts/k8s/gitops_lib`,
> wireado en `reconcile` y validado por `tests/gitops_publish.bats` (40 casos, incluida la carrera de
> dos instancias pusheando al mismo repo). **Los checkboxes de abajo quedaron sin marcar durante la
> implementación**: se dejan como estaban en vez de marcarlos en bloque, porque un `[x]` puesto sin
> verificar la tarea una por una es peor que uno faltante. El estado real es el código y sus tests.

**Goal:** que cada corrida del `reconcile` publique a un repo git configurable los manifiestos que va a aplicar, antes de aplicarlos, sin dejar de aplicarlos.

**Architecture:** un lib nuevo `scripts/k8s/gitops_lib` sourceado por `reconcile`, que clona el repo, reescribe el subárbol `<prefix>/<substrato>/<namespace>/` y pushea con retry. Las hojas por servicio se llenan re-invocando `render_manifests` con el contexto filtrado a una sola intercepción, así que no se toca el camino del apply ni los templates. La configuración se valida en `build_context`; la URL con el token nunca pasa por el plumbing de outputs del workflow.

**Tech Stack:** bash >= 4, git, gomplate, jq, yq (solo tests), BATS.

**Spec:** [`docs/s2s-gitops-publish.md`](./DISENO-GITOPS.md) — leerlo antes de la Task 1.

> **Estado: ejecutado, con una desviación posterior.** Las seis tasks están hechas. Después de
> terminarlas se decidió **sacar el segmento `<cluster>` del path**, que quedó en
> `<prefix>/<substrato>/<namespace>/<svc>/`, y con eso desapareció la variable `GITOPS_CLUSTER_NAME`.
> Los bloques de código de abajo la siguen mencionando porque son el registro de lo que se planeó, no
> del estado actual. Para el estado actual, la fuente de verdad es el diseño y el código; el
> razonamiento del cambio y cuándo hay que revertirlo está en la sección "El substrato hace de
> identificador del cluster, y eso caduca" del diseño.
>
> También salieron del quality gate dos correcciones de seguridad que el plan no anticipaba
> (validación de la URL del repo y el regex de redacción hasta el último `@`) y un fix de fallo
> silencioso en `gitops_render_tree`.

## Global Constraints

- **Cero comentarios en el código.** Ni en los scripts nuevos ni en los tests. El razonamiento va al cuerpo del PR. El resto del service está fuertemente comentado; eso **no** es permiso para agregar comentarios.
- **bash >= 4.** Correr la suite con `PATH=/opt/homebrew/bin:$PATH bats tests/` desde `services/egress-interceptor/`.
- **Español rioplatense** en logs y docs, términos técnicos en inglés.
- **`local x; x=$(cmd)` en dos líneas** cuando el fallo de `cmd` importa: `local` es un comando y su exit status enmascara el de la sustitución.
- **Nada de `set -e` como red.** El runner del CLI neutraliza `errexit`; todo fallo que importe se guarda a mano con `|| die` o `|| return 1`.
- **`GIT_TERMINAL_PROMPT=0` en toda invocación de git.** Colgarse esperando un prompt es el peor modo de fallar dentro de un agente.
- **El token no aparece en ninguna salida.** Ni en logs propios, ni en el stderr de git.
- **En los tests, las variables de entorno van con `export` explícito** antes de llamar al helper. Un prefijo de asignación sobre una llamada a función no llega al proceso hijo si la variable no estaba ya exportada.
- **Commits de una sola línea**, prefijo convencional, sin cuerpo y sin atribución a Claude.
- **No hay `CHANGELOG.md` en este repo** — no se crea uno.
- **Los 115 tests existentes tienen que seguir en verde.** El publisher apagado es un no-op.

## File Structure

| archivo | responsabilidad |
|---|---|
| `services/s2s-traffic-migrator/scripts/k8s/gitops_lib` (crear) | todo el publisher: resolución de config, path del subárbol, fan-out del render, clone/commit/push con retry |
| `services/s2s-traffic-migrator/scripts/k8s/build_context` (modificar) | validar la config GitOps y exportar la parte no secreta |
| `services/s2s-traffic-migrator/scripts/k8s/reconcile` (modificar) | sourcear el lib y llamarlo antes del apply y al principio del delete |
| `services/s2s-traffic-migrator/workflows/openshift/create.yaml` (modificar) | `configuration:` y `output:` de las vars nuevas |
| `services/s2s-traffic-migrator/workflows/openshift/delete.yaml` (modificar) | idem |
| `services/s2s-traffic-migrator/tests/gitops_publish.bats` (crear) | la suite del publisher, con git de verdad |
| `services/s2s-traffic-migrator/tests/build_context.bats` (modificar) | validación de la config GitOps |
| `services/s2s-traffic-migrator/tests/fail_fast.bats` (modificar) | el orden: publisher que falla ⇒ no se aplica nada |
| `services/s2s-traffic-migrator/README.md` (modificar) | layout, configuración y gaps de la pata 2 |

---

### Task 1: Config, path del subárbol y redacción del token

**Files:**
- Create: `services/s2s-traffic-migrator/scripts/k8s/gitops_lib`
- Test: `services/s2s-traffic-migrator/tests/gitops_publish.bats`

**Interfaces:**
- Consumes: `log` (de `logging`); `NAMESPACE` y `site` del env.
- Produces: `gitops_enabled` (0 = prendido), `gitops_repo_url` (imprime la URL), `gitops_redact` (filtro de stdin), `gitops_substrate` (`eks`|`openshift`), `gitops_subtree` (el path relativo), `gitops_sleep <segundos>`. Constantes `GITOPS_NAMESPACE_MANIFESTS` y `GITOPS_PER_SERVICE_MANIFESTS`.

- [ ] **Step 1: Escribir los tests que fallan**

Crear `services/s2s-traffic-migrator/tests/gitops_publish.bats`:

```bash
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
  export GITOPS_CLUSTER_NAME=gal-poc-eks-dev
  export GITOPS_PATH_PREFIX=""
  export GITOPS_PUSH_RETRIES=5
  unset GITOPS_REPO_URL GITOPS_REPO_URL_FILE
}

@test "el path del subárbol es substrato/cluster/namespace" {
  run gitops_subtree
  [ "$output" = "eks/gal-poc-eks-dev/payments" ]
}

@test "el substrato sale de ORIGIN, no de la configuración" {
  ORIGIN=OS
  run gitops_subtree
  [ "$output" = "openshift/gal-poc-eks-dev/payments" ]
}

@test "el prefix se cuelga adelante y no duplica la barra" {
  GITOPS_PATH_PREFIX="clusters/"
  run gitops_subtree
  [ "$output" = "clusters/eks/gal-poc-eks-dev/payments" ]
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

@test "la URL se lee del archivo antes que del env" {
  echo "https://tok@example.com/desde-archivo.git" >"$BATS_TEST_TMPDIR/url"
  export GITOPS_REPO_URL_FILE="$BATS_TEST_TMPDIR/url"
  export GITOPS_REPO_URL=https://tok@example.com/desde-env.git
  run gitops_repo_url
  [ "$output" = "https://tok@example.com/desde-archivo.git" ]
}

@test "un archivo de URL ilegible ABORTA en vez de caer al env" {
  export GITOPS_REPO_URL_FILE="$BATS_TEST_TMPDIR/no-existe"
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  run gitops_repo_url
  [ "$status" -ne 0 ]
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
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

```bash
cd services/egress-interceptor
PATH=/opt/homebrew/bin:$PATH bats tests/gitops_publish.bats
```
Esperado: FAIL los 9, con `gitops_lib: No such file or directory` en el `setup`.

- [ ] **Step 3: Escribir `gitops_lib` con la base**

Crear `services/s2s-traffic-migrator/scripts/k8s/gitops_lib`:

```bash
#!/usr/bin/env bash

GITOPS_NAMESPACE_MANIFESTS="10-gateway.yaml 20-authpolicy.yaml 30-destinationrule-peer.yaml 40-destinationrule-local-ingress.yaml"
GITOPS_PER_SERVICE_MANIFESTS="50-httproute-egress.yaml 60-httproute-ingress.yaml"

: "${GITOPS_COMMITTER_NAME:=nullplatform egress-interceptor}"
: "${GITOPS_COMMITTER_EMAIL:=egress-interceptor@nullplatform.io}"

if ! type -t gitops_redact >/dev/null 2>&1; then
gitops_redact() { sed 's#//[^@/]*@#//***@#g'; }
fi

if ! type -t gitops_enabled >/dev/null 2>&1; then
gitops_enabled() { [ -n "${GITOPS_REPO_URL_FILE:-}${GITOPS_REPO_URL:-}" ]; }
fi

if ! type -t gitops_repo_url >/dev/null 2>&1; then
gitops_repo_url() {
  if [ -n "${GITOPS_REPO_URL_FILE:-}" ]; then
    if [ ! -r "$GITOPS_REPO_URL_FILE" ]; then
      log error "egress-interceptor gitops: no se puede leer GITOPS_REPO_URL_FILE ('$GITOPS_REPO_URL_FILE')."
      return 1
    fi
    tr -d '[:space:]' <"$GITOPS_REPO_URL_FILE"
    return 0
  fi
  printf %s "${GITOPS_REPO_URL:-}"
}
fi

if ! type -t gitops_substrate >/dev/null 2>&1; then
gitops_substrate() {
  if [ "${ORIGIN:-OS}" = "EKS" ]; then printf eks; else printf openshift; fi
}
fi

if ! type -t gitops_subtree >/dev/null 2>&1; then
gitops_subtree() {
  local prefix="${GITOPS_PATH_PREFIX:-}"
  prefix="${prefix%/}"
  [ -n "$prefix" ] && prefix="$prefix/"
  printf '%s%s/%s/%s' "$prefix" "$(gitops_substrate)" "${GITOPS_CLUSTER_NAME:-}" "${NAMESPACE:-}"
}
fi

if ! type -t gitops_sleep >/dev/null 2>&1; then
gitops_sleep() { sleep "$1"; }
fi
```

- [ ] **Step 4: Correr los tests y verificar que pasan**

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/gitops_publish.bats
```
Esperado: PASS 9/9.

- [ ] **Step 5: Commit**

```bash
git add services/s2s-traffic-migrator/scripts/k8s/gitops_lib services/s2s-traffic-migrator/tests/gitops_publish.bats
git commit -m "feat(egress-interceptor): base del publisher gitops (config y path)"
```

---

### Task 2: Fan-out del render a hojas por servicio

**Files:**
- Modify: `services/s2s-traffic-migrator/scripts/k8s/gitops_lib`
- Test: `services/s2s-traffic-migrator/tests/gitops_publish.bats`

**Interfaces:**
- Consumes: `render_manifests <ctx> <outdir>` de `manifests_lib`; `GITOPS_NAMESPACE_MANIFESTS` y `GITOPS_PER_SERVICE_MANIFESTS` de la Task 1.
- Produces: `gitops_render_one <ctx> <svc> <outdir>` y `gitops_render_tree <ctx> <manifest_dir> <dest>`, que deja el árbol completo bajo `<dest>`. Las dos devuelven 0 = ok, 1 = fallo.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/gitops_publish.bats`:

```bash
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

@test "los objetos publicados son los MISMOS que los aplicados" {
  make_render OS "$(dos_reglas)"
  gitops_render_tree "$CTX" "$MDIR" "$BATS_TEST_TMPDIR/tree"
  local aplicados publicados
  aplicados=$(objetos "$MDIR"/*.yaml | sort)
  publicados=$(find "$BATS_TEST_TMPDIR/tree" -name '*.yaml' -print0 \
    | xargs -0 -n1 yq -r '[.kind, (.metadata.namespace // ""), .metadata.name] | join("/")' | sort)
  [ "$aplicados" = "$publicados" ]
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
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/gitops_publish.bats
```
Esperado: los 7 que llaman a `gitops_render_tree` FAIL con `command not found`. El de clasificación pasa desde ya: las constantes existen desde la Task 1 y hoy cubren los seis templates. Es una red para el futuro, no un test rojo.

- [ ] **Step 3: Implementar el fan-out**

Agregar al final de `scripts/k8s/gitops_lib`:

```bash
if ! type -t gitops_render_one >/dev/null 2>&1; then
gitops_render_one() {
  local ctx="$1" svc="$2" out="$3" one
  one=$(mktemp) || return 1
  if ! jq --arg s "$svc" '.interceptions = [.interceptions[] | select(.service_name == $s)]' "$ctx" >"$one"; then
    rm -f "$one"
    log error "egress-interceptor gitops: no se pudo filtrar el contexto de render para '$svc'."
    return 1
  fi
  if ! mkdir -p "$out"; then
    rm -f "$one"
    return 1
  fi
  if ! render_manifests "$one" "$out" >/dev/null; then
    rm -f "$one"
    log error "egress-interceptor gitops: falló el render de la hoja de '$svc'."
    return 1
  fi
  rm -f "$one"
  return 0
}
fi

if ! type -t gitops_render_tree >/dev/null 2>&1; then
gitops_render_tree() {
  local ctx="$1" mdir="$2" dest="$3" file svc leaf
  mkdir -p "$dest" || return 1
  for file in $GITOPS_NAMESPACE_MANIFESTS; do
    [ -f "$mdir/$file" ] || continue
    cp "$mdir/$file" "$dest/$file" || return 1
  done
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    leaf=$(mktemp -d) || return 1
    if ! gitops_render_one "$ctx" "$svc" "$leaf"; then
      rm -rf "$leaf"
      return 1
    fi
    if ! mkdir -p "$dest/$svc"; then
      rm -rf "$leaf"
      return 1
    fi
    for file in $GITOPS_PER_SERVICE_MANIFESTS; do
      [ -f "$leaf/$file" ] || continue
      if ! cp "$leaf/$file" "$dest/$svc/$file"; then
        rm -rf "$leaf"
        return 1
      fi
    done
    rm -rf "$leaf"
  done < <(jq -r '.interceptions[]?.service_name' "$ctx")
  return 0
}
fi
```

- [ ] **Step 4: Correr los tests y verificar que pasan**

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/gitops_publish.bats
```
Esperado: PASS 17/17.

- [ ] **Step 5: Commit**

```bash
git add services/s2s-traffic-migrator/scripts/k8s/gitops_lib services/s2s-traffic-migrator/tests/gitops_publish.bats
git commit -m "feat(egress-interceptor): render de las hojas por servicio para gitops"
```

---

### Task 3: Clone, commit y push con retry

**Files:**
- Modify: `services/s2s-traffic-migrator/scripts/k8s/gitops_lib`
- Test: `services/s2s-traffic-migrator/tests/gitops_publish.bats`

**Interfaces:**
- Consumes: `gitops_subtree`, `gitops_repo_url`, `gitops_enabled`, `gitops_redact`, `gitops_render_tree`, `gitops_sleep`.
- Produces: `gitops_publish <render_ctx> <manifest_dir>` y `gitops_publish_removal`. Ambas: 0 = publicado, apagado o no-op; 1 = fallo. Internas: `gitops_git <dir> <args...>`, `gitops_clone <url> <dest>`, `gitops_stage <work> <subtree>` (0 = hay cambios staged, 1 = nada que hacer, 2 = error), `gitops_sync <apply|delete> [ctx] [mdir]`.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/gitops_publish.bats`:

```bash
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

remoto_ls() {
  local check="$BATS_TEST_TMPDIR/check-$$-$RANDOM"
  git clone --quiet "$REMOTE" "$check"
  git -C "$check" ls-files
  rm -rf "$check"
}

remoto_commits() {
  local check="$BATS_TEST_TMPDIR/count-$$-$RANDOM"
  git clone --quiet "$REMOTE" "$check"
  git -C "$check" rev-list --count HEAD
  rm -rf "$check"
}

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

@test "publica el subárbol completo en el branch configurado" {
  armar_remoto
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -eq 0 ]
  run remoto_ls
  [[ "$output" == *"eks/gal-poc-eks-dev/payments/10-gateway.yaml"* ]]
  [[ "$output" == *"eks/gal-poc-eks-dev/payments/reports/50-httproute-egress.yaml"* ]]
  [[ "$output" == *"eks/gal-poc-eks-dev/payments/checkout/50-httproute-egress.yaml"* ]]
}

@test "sin URL configurada no publica y NO falla" {
  unset GITOPS_REPO_URL GITOPS_REPO_URL_FILE
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -eq 0 ]
}

@test "con URL y sin GITOPS_CLUSTER_NAME ABORTA" {
  armar_remoto
  export GITOPS_CLUSTER_NAME=""
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *GITOPS_CLUSTER_NAME* ]]
}

@test "una URL que no se puede clonar ABORTA" {
  export GITOPS_REPO_URL="$BATS_TEST_TMPDIR/no-hay-repo-aca"
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
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
  [[ "$output" != *"eks/gal-poc-eks-dev/payments"* ]]
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
  cat >"$REMOTE/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo "rechazo permanente" >&2
exit 1
HOOK
  chmod +x "$REMOTE/hooks/pre-receive"
  make_render EKS "$(dos_reglas)"
  run gitops_publish "$CTX" "$MDIR"
  [ "$status" -ne 0 ]
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
  [[ "$output" == *"eks/gal-poc-eks-dev/payments/reports/50-httproute-egress.yaml"* ]]
  [[ "$output" == *"eks/gal-poc-eks-dev/billing/checkout/50-httproute-egress.yaml"* ]]
}
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/gitops_publish.bats
```
Esperado: los 12 nuevos FAIL con `gitops_publish: command not found`.

- [ ] **Step 3: Implementar el sync**

Agregar al final de `scripts/k8s/gitops_lib`:

```bash
if ! type -t gitops_git >/dev/null 2>&1; then
gitops_git() {
  local dir="$1" err rc=0
  shift
  err=$(mktemp) || return 1
  GIT_TERMINAL_PROMPT=0 git -C "$dir" \
    -c "user.name=$GITOPS_COMMITTER_NAME" \
    -c "user.email=$GITOPS_COMMITTER_EMAIL" \
    "$@" 2>"$err" || rc=$?
  if [ -s "$err" ]; then gitops_redact <"$err" >&2; fi
  rm -f "$err"
  return "$rc"
}
fi

if ! type -t gitops_clone >/dev/null 2>&1; then
gitops_clone() {
  local url="$1" dest="$2" err rc=0
  err=$(mktemp) || return 1
  GIT_TERMINAL_PROMPT=0 git clone --quiet --depth=1 \
    --branch "${GITOPS_BRANCH:-main}" "$url" "$dest" 2>"$err" || rc=$?
  if [ -s "$err" ]; then gitops_redact <"$err" >&2; fi
  rm -f "$err"
  return "$rc"
}
fi

if ! type -t gitops_stage >/dev/null 2>&1; then
gitops_stage() {
  local work="$1" subtree="$2" tracked
  tracked=$(gitops_git "$work" ls-files -- "$subtree") || return 2
  if [ -z "$tracked" ] && [ ! -d "$work/$subtree" ]; then return 1; fi
  gitops_git "$work" add -A -- "$subtree" || return 2
  if gitops_git "$work" diff --cached --quiet -- "$subtree"; then return 1; fi
  return 0
}
fi

if ! type -t gitops_sync >/dev/null 2>&1; then
gitops_sync() {
  local mode="$1" ctx="${2:-}" mdir="${3:-}"
  local url work subtree branch rc
  local attempt=1 espera=1
  local max="${GITOPS_PUSH_RETRIES:-5}"

  if ! gitops_enabled; then
    log info "egress-interceptor gitops: sin repo configurado, no se publica."
    return 0
  fi

  url=$(gitops_repo_url) || return 1
  if [ -z "$url" ]; then
    log error "egress-interceptor gitops: la URL del repo está vacía."
    return 1
  fi
  if [ -z "${GITOPS_CLUSTER_NAME:-}" ]; then
    log error "egress-interceptor gitops: falta GITOPS_CLUSTER_NAME; sin él el path del repo sería inservible."
    return 1
  fi

  branch="${GITOPS_BRANCH:-main}"
  subtree=$(gitops_subtree)
  work=$(mktemp -d) || return 1

  if ! gitops_clone "$url" "$work"; then
    log error "egress-interceptor gitops: no se pudo clonar $(printf %s "$url" | gitops_redact) (branch $branch)."
    rm -rf "$work"
    return 1
  fi

  while [ "$attempt" -le "$max" ]; do
    rm -rf "${work:?}/${subtree:?}"
    if [ "$mode" = apply ] && ! gitops_render_tree "$ctx" "$mdir" "$work/$subtree"; then
      rm -rf "$work"
      return 1
    fi

    gitops_stage "$work" "$subtree"
    rc=$?
    if [ "$rc" -eq 1 ]; then
      log info "egress-interceptor gitops: $subtree ya estaba al día, no se commitea."
      rm -rf "$work"
      return 0
    fi
    if [ "$rc" -ne 0 ]; then
      log error "egress-interceptor gitops: no se pudo preparar el commit de $subtree."
      rm -rf "$work"
      return 1
    fi

    if ! gitops_git "$work" commit --quiet -m "egress-interceptor: $subtree ($mode)"; then
      log error "egress-interceptor gitops: no se pudo commitear $subtree."
      rm -rf "$work"
      return 1
    fi

    if gitops_git "$work" push --quiet origin "HEAD:refs/heads/$branch"; then
      log info "egress-interceptor gitops: publicado $subtree en $branch."
      rm -rf "$work"
      return 0
    fi

    log info "egress-interceptor gitops: push rechazado (intento $attempt/$max), se reintenta sobre $branch actualizado."
    if ! gitops_git "$work" fetch --quiet --depth=1 origin "$branch" \
       || ! gitops_git "$work" reset --hard --quiet FETCH_HEAD; then
      log error "egress-interceptor gitops: no se pudo resincronizar con $branch."
      rm -rf "$work"
      return 1
    fi
    gitops_sleep "$espera.$(( RANDOM % 900 + 100 ))"
    [ "$espera" -lt 8 ] && espera=$(( espera * 2 ))
    attempt=$(( attempt + 1 ))
  done

  log error "egress-interceptor gitops: no se pudo pushear $subtree después de $max intentos."
  rm -rf "$work"
  return 1
}
fi

if ! type -t gitops_publish >/dev/null 2>&1; then
gitops_publish() { gitops_sync apply "$1" "$2"; }
fi

if ! type -t gitops_publish_removal >/dev/null 2>&1; then
gitops_publish_removal() { gitops_sync delete; }
fi
```

- [ ] **Step 4: Correr los tests y verificar que pasan**

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/gitops_publish.bats
```
Esperado: PASS 29/29.

- [ ] **Step 5: Commit**

```bash
git add services/s2s-traffic-migrator/scripts/k8s/gitops_lib services/s2s-traffic-migrator/tests/gitops_publish.bats
git commit -m "feat(egress-interceptor): push gitops con retry resiliente a carreras"
```

---

### Task 4: Validar la configuración en `build_context`

**Files:**
- Modify: `services/s2s-traffic-migrator/scripts/k8s/build_context`
- Modify: `services/s2s-traffic-migrator/workflows/openshift/create.yaml`
- Modify: `services/s2s-traffic-migrator/workflows/openshift/delete.yaml`
- Test: `services/s2s-traffic-migrator/tests/build_context.bats`

**Interfaces:**
- Consumes: `require_match <valor> <regex> <campo>` y el helper de test `run_bc`, los dos ya existentes.
- Produces: `GITOPS_BRANCH`, `GITOPS_PATH_PREFIX`, `GITOPS_CLUSTER_NAME`, `GITOPS_PUSH_RETRIES` exportadas y validadas. La URL **no** se exporta ni se imprime.

- [ ] **Step 1: Escribir los tests que fallan**

Agregar a `tests/build_context.bats`. `run_bc` invoca `run bash "$BC"`, así que las vars van con `export` en el cuerpo del test:

```bash
@test "sin repo gitops configurado no se exige nada más" {
  run_bc
  [ "$status" -eq 0 ]
}

@test "con repo gitops y sin GITOPS_CLUSTER_NAME ABORTA" {
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  run_bc
  [ "$status" -ne 0 ]
  [[ "$output" == *GITOPS_CLUSTER_NAME* ]]
}

@test "GITOPS_CLUSTER_NAME no hereda CLUSTER_LABEL" {
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  export CLUSTER_LABEL=eks-kuadrant
  run_bc
  [ "$status" -ne 0 ]
}

@test "un GITOPS_PATH_PREFIX con .. ABORTA" {
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  export GITOPS_CLUSTER_NAME=c1
  export GITOPS_PATH_PREFIX=../../etc
  run_bc
  [ "$status" -ne 0 ]
}

@test "un GITOPS_CLUSTER_NAME con barra ABORTA" {
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  export GITOPS_CLUSTER_NAME=a/../b
  run_bc
  [ "$status" -ne 0 ]
}

@test "la URL del repo NUNCA se imprime" {
  export GITOPS_REPO_URL=https://ghp_secreto123@example.com/o/r.git
  export GITOPS_CLUSTER_NAME=c1
  run_bc
  [ "$status" -eq 0 ]
  [[ "$output" != *ghp_secreto123* ]]
}

@test "la traza dice a qué path del repo se va a publicar" {
  export GITOPS_REPO_URL=https://tok@example.com/o/r.git
  export GITOPS_CLUSTER_NAME=gal-poc-eks-dev
  run_bc
  [ "$status" -eq 0 ]
  [[ "$output" == *"openshift/gal-poc-eks-dev/payments"* ]]
}

@test "un GITOPS_REPO_URL_FILE ilegible ABORTA antes de tocar el cluster" {
  export GITOPS_REPO_URL_FILE=/no/existe
  export GITOPS_CLUSTER_NAME=c1
  run_bc
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/build_context.bats
```
Esperado: FAIL los 6 que esperan aborto o traza — hoy `build_context` ignora esas vars y sale 0 sin decir nada.

- [ ] **Step 3: Implementar la validación**

En `scripts/k8s/build_context`, junto a la definición de `require_match`, agregar:

```bash
gitops_substrate_hint() {
  if [ "${ORIGIN:-OS}" = "EKS" ]; then printf eks; else printf openshift; fi
}
```

Y después del bloque de `WRISTBAND_SECRET`, antes de la normalización de nombres:

```bash
GITOPS_BRANCH="${GITOPS_BRANCH:-main}"
GITOPS_PATH_PREFIX="${GITOPS_PATH_PREFIX:-}"
GITOPS_CLUSTER_NAME="${GITOPS_CLUSTER_NAME:-}"
GITOPS_PUSH_RETRIES="${GITOPS_PUSH_RETRIES:-5}"

if [ -n "${GITOPS_REPO_URL_FILE:-}${GITOPS_REPO_URL:-}" ]; then
  if [ -n "${GITOPS_REPO_URL_FILE:-}" ] && [ ! -r "${GITOPS_REPO_URL_FILE}" ]; then
    log error "egress-interceptor: GITOPS_REPO_URL_FILE apunta a un archivo que no se puede leer."
    exit 1
  fi
  if [ -z "$GITOPS_CLUSTER_NAME" ]; then
    log error "egress-interceptor: falta GITOPS_CLUSTER_NAME y hay un repo gitops configurado."
    log error "  Es el segmento <cluster> del path del repo. No se hereda de CLUSTER_LABEL a propósito:"
    log error "  CLUSTER_LABEL defaultea a ORIGIN, y eso daría paths como 'openshift/OS/'."
    exit 1
  fi
  require_match "$GITOPS_CLUSTER_NAME" '^[a-zA-Z0-9]([a-zA-Z0-9_.-]{0,61}[a-zA-Z0-9])?$' "gitops_cluster_name"
  require_match "$GITOPS_BRANCH" '^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,127}$' "gitops_branch"
  require_match "$GITOPS_PUSH_RETRIES" '^[1-9][0-9]?$' "gitops_push_retries"
  if [ -n "$GITOPS_PATH_PREFIX" ]; then
    require_match "$GITOPS_PATH_PREFIX" '^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,127}$' "gitops_path_prefix"
    case "$GITOPS_PATH_PREFIX" in
      *..*)
        log error "egress-interceptor: GITOPS_PATH_PREFIX no puede contener '..'."
        exit 1 ;;
    esac
  fi
  log info "gitops: se publica en ${GITOPS_PATH_PREFIX:+${GITOPS_PATH_PREFIX%/}/}$(gitops_substrate_hint)/${GITOPS_CLUSTER_NAME}/${NAMESPACE} (branch ${GITOPS_BRANCH})"
fi

export GITOPS_BRANCH GITOPS_PATH_PREFIX GITOPS_CLUSTER_NAME GITOPS_PUSH_RETRIES
```

- [ ] **Step 4: Declarar las vars en los dos workflows**

En `workflows/openshift/create.yaml` y `workflows/openshift/delete.yaml`, agregar a `configuration:`:

```yaml
  GITOPS_REPO_URL_FILE: ""
  GITOPS_BRANCH: main
  GITOPS_PATH_PREFIX: ""
  GITOPS_CLUSTER_NAME: ""
  GITOPS_PUSH_RETRIES: "5"
```

y al `output:` del step `build context`:

```yaml
      - { name: GITOPS_BRANCH, type: environment }
      - { name: GITOPS_PATH_PREFIX, type: environment }
      - { name: GITOPS_CLUSTER_NAME, type: environment }
      - { name: GITOPS_PUSH_RETRIES, type: environment }
```

`GITOPS_REPO_URL_FILE` va en `configuration:` porque es un path, no un secreto, y **no** va en `output:`. `GITOPS_REPO_URL` no se declara en ningún lado: si se usa, llega por el env del agente.

`update.yaml` no se toca: importa `create.yaml`.

- [ ] **Step 5: Correr la suite completa y verificar que pasa**

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/
```
Esperado: PASS todo, incluidos los 115 previos.

- [ ] **Step 6: Commit**

```bash
git add services/s2s-traffic-migrator/scripts/k8s/build_context services/s2s-traffic-migrator/workflows services/s2s-traffic-migrator/tests/build_context.bats
git commit -m "feat(egress-interceptor): validar la configuracion del repo gitops"
```

---

### Task 5: Enganchar el publisher en el `reconcile`

**Files:**
- Modify: `services/s2s-traffic-migrator/scripts/k8s/reconcile`
- Test: `services/s2s-traffic-migrator/tests/fail_fast.bats`

**Interfaces:**
- Consumes: `gitops_publish` y `gitops_publish_removal` de la Task 3.
- Produces: nada nuevo.

- [ ] **Step 1: Escribir los tests que fallan**

En `tests/fail_fast.bats`, sumar las dos vars a la lista de asignaciones que `correr()` pasa al `bash -c`:

```bash
  GITOPS_REPO_URL="${GITOPS_REPO_URL:-}" GITOPS_CLUSTER_NAME="${GITOPS_CLUSTER_NAME:-}" \
```

Y agregar los tests:

```bash
@test "si la publicacion gitops falla, NO se aplica nada" {
  export GITOPS_REPO_URL="$BATS_TEST_TMPDIR/no-hay-repo"
  export GITOPS_CLUSTER_NAME=c1
  run correr
  [ "$status" -ne 0 ]
  run grep -c ' apply ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "si la publicacion gitops falla, tampoco se toca el selector" {
  export GITOPS_REPO_URL="$BATS_TEST_TMPDIR/no-hay-repo"
  export GITOPS_CLUSTER_NAME=c1
  run correr
  run grep -c ' patch svc ' "$KUBECTL_CALLS"
  [ "$output" -eq 0 ]
}

@test "sin repo gitops el reconcile anda igual que siempre" {
  run correr
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/fail_fast.bats
```
Esperado: los dos primeros FAIL — hoy el `reconcile` no publica, aplica igual y sale 0.

- [ ] **Step 3: Enganchar el lib**

En `scripts/k8s/reconcile`, junto al `source` que ya está:

```bash
source "$HERE/manifests_lib"
source "$HERE/gitops_lib"
```

Al principio de la rama del delete, como primera acción, antes del loop de `revert_service`:

```bash
if [ "$ACTION" = "delete" ]; then
  gitops_publish_removal \
    || die "falló la publicación del borrado al repo gitops. No se borró nada del cluster."
```

En la rama del apply, entre el guard de `MANIFESTS` vacío y el `apply_manifests`:

```bash
gitops_publish "$RENDER_CONTEXT" "$MANIFEST_DIR" \
  || die "falló la publicación de los manifiestos al repo gitops. NO se aplicó nada."
apply_manifests "${MANIFESTS[@]}" \
  || die "falló el apply de los manifiestos. El tráfico NO se desvió."
```

- [ ] **Step 4: Correr la suite completa y verificar que pasa**

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/
```
Esperado: PASS todo.

- [ ] **Step 5: Commit**

```bash
git add services/s2s-traffic-migrator/scripts/k8s/reconcile services/s2s-traffic-migrator/tests/fail_fast.bats
git commit -m "feat(egress-interceptor): publicar al repo gitops antes de aplicar"
```

---

### Task 6: Documentar el contrato

**Files:**
- Modify: `services/s2s-traffic-migrator/README.md`

**Interfaces:**
- Consumes: el layout y la config de las Tasks 1-4.
- Produces: nada de código.

- [ ] **Step 1: Agregar la sección al README**

Después de la sección "Templating" de `services/s2s-traffic-migrator/README.md`, agregar una sección "Publicación a un repo GitOps" que cubra:

- que el `reconcile` **sigue aplicando** y que el repo es, por ahora, un registro del estado deseado que nadie consume;
- el árbol, con el ejemplo concreto de los dos substratos, copiado de `docs/s2s-gitops-publish.md`;
- la tabla de las seis variables (`GITOPS_REPO_URL_FILE`, `GITOPS_REPO_URL`, `GITOPS_BRANCH`, `GITOPS_PATH_PREFIX`, `GITOPS_CLUSTER_NAME`, `GITOPS_PUSH_RETRIES`), aclarando que sin URL el publisher está apagado y que con URL presente cualquier otro error es fallo duro;
- que `GITOPS_CLUSTER_NAME` no defaultea, y por qué (`CLUSTER_LABEL` cae a `site` y daría `openshift/OS/`);
- que la URL lleva el token y por eso no va en el `configuration:` de los workflows ni en sus `output:`;
- que el path es ownership y no el namespace del objeto —`60-httproute-ingress` declara un objeto en `gateways`— y que por eso un `Kustomization` sobre el subárbol **no puede** forzar el namespace;
- que una sola instancia por (cluster, namespace);
- link a `docs/s2s-gitops-publish.md` para el diseño completo y los gaps de la pata 2.

Agregar también `git` a la lista de dependencias de la sección "Tests".

- [ ] **Step 2: Verificar el link y el archivo**

```bash
grep -n 's2s-gitops-publish' services/s2s-traffic-migrator/README.md
ls docs/s2s-gitops-publish.md
```
Esperado: el grep encuentra el link y el `ls` encuentra el archivo.

- [ ] **Step 3: Commit**

```bash
git add services/s2s-traffic-migrator/README.md
git commit -m "docs(egress-interceptor): documentar la publicacion al repo gitops"
```

---

## Cierre

- [ ] Correr la suite completa: `PATH=/opt/homebrew/bin:$PATH bats tests/` desde `services/egress-interceptor/`. Esperado: 115 previos + 29 nuevos del publisher + 8 de `build_context` + 3 de `fail_fast`.
- [ ] Correr el `quality-gate`.
- [ ] Abrir el PR contra `feat/kuadrant-s2s-vuelta`.
