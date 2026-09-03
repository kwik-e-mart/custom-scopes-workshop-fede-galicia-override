# Runbook de pruebas — demo S2S (Kuadrant acuña en el egreso, Kuadrant valida en el ingreso)

Recorrido **paso por paso** para probar a mano cada funcionalidad de la demo. Cada paso dice qué
correr, **qué tenés que ver** para darlo por bueno, y qué hacer si no da eso.

**Qué asume:** los dos clusters arriba con la demo aplicada (`gateways`, `istio-system`, `kuadrant-system`,
`payments`, `other`, y las apps `ledger`/`reports`/`intruso`). Las dos instancias del service
—`egress-eks` / `egress-crc`— **las crea el Paso 12**: el Paso 0 arranca exigiendo que no exista
ninguna.

**Qué NO cubre:** el provisioning. Si tenés que levantar de cero, eso es `./scripts/crc-up.sh` (el
OpenShift local) y `./scripts/up.sh` (el resto del sustrato) — ver `GUIA-DEMO.md`. Este documento
arranca donde termina aquél.

**Cómo está ordenado:** los pasos **1 a 10 no necesitan agente** y se pueden recorrer de corrido. El
agente aparece en el paso 11, y del 12 al 16 están los escenarios que cambian configuración. Todo lo
que un paso necesita se define en un paso anterior: no hay saltos hacia adelante.

Los resultados que figuran como "tenés que ver" son **salidas reales** medidas el 2026-08-20 contra
el POC, no expectativas teóricas.

---

## Índice

| # | Paso | Agente | Estado |
|---|---|---|---|
| 0 | **¿Se puede arrancar?** — prerrequisitos y estado limpio | no | — |
| 1 | **Levantar los dos agentes** — traen el repo de scopes | ambos | 🔄 |
| 2 | Preparar la terminal | no | — |
| 3 | Higiene del tailnet | no | ✅ |
| 4 | Sustrato sano en los dos clusters | no | ✅ |
| 5 | Cargar los helpers | no | — |
| 6 | Aislamiento entre namespaces (EKS) | no | ✅ |
| 7 | Aislamiento entre namespaces (OpenShift) | no | 🔄 |
| 8 | El JWT por dentro | no | ✅ |
| 9 | JWKS cruzado: cada validador ve la clave del peer | no | ✅ |
| 10 | El hop remoto, sin interceptor | no | ✅ |
| 11 | Rate limit (200 req / 60 s) | no | 🔄 |
| 12 | **Crear las instancias del service** | ambos | 🔄 |
| 13 | Escenario A — `reports` ya en EKS (`percent=100`), llamador en EKS | eks | ✅ |
| 14 | Escenario B — EKS → OpenShift (`percent=0`: sin migrar) | eks | ✅ |
| 15 | Escenario C — `reports` sin migrar (`percent=0`), llamador en OpenShift | crc | 🔄 |
| 16 | Escenario D — OpenShift → EKS (`percent=100`: migrado) | crc | ✅ |
| 17 | La perilla de migración (`percent`), desde EKS | eks | 🔄 |
| 18 | La misma perilla, desde OpenShift | crc | 🔄 |
| 19 | **Limpieza** | ambos | ✅ |

**✅** verificado y sin cambios · **🔄** reescrito para el modelo de `scope`, **sin ejercitar todavía**

Los ✅ que había antes eran contra el modelo viejo, donde la regla llevaba un `target_fqdn`. Todo lo
que toca el header de ruteo, el form o los escenarios se reescribió y hay que volver a correrlo.

---

## Paso 0 — ¿Se puede arrancar?

**Qué valida:** que estén los prerrequisitos y que el punto de partida esté **limpio**. Si algo de
esto falla, los pasos siguientes fallan más tarde y con un síntoma que no señala la causa.

```bash
cd ~/nullplatform/galicia/galicia-banco/accounts/galicia/demo-kuadrant-s2s
export EKS="arn:aws:eks:us-east-1:984449730514:cluster/gal-kuadrant-poc"
export CRC="crc-admin"
export NP_API_KEY="$(cat ../np-api-skill.key)"
# El scope destino del lado EKS. Hace falta desde el Paso 6, no sólo al crear las instancias:
# vacío, el header de ruteo va sin FQDN y TODO da 404 sin llegar a autenticar.
export SCOPE=eks
export APP_NRN="organization=1636958496:account=1374028000:namespace=824774832:application=142495574"
NP_API=$(ls "$HOME/.claude/plugins/marketplaces/nullplatform-internal/src/skills/np-api/scripts/np-api.sh")
export NP_API
```

### 1. Herramientas

```bash
for b in kubectl jq yq gomplate np crc aws bash; do
  printf '%-10s %s\n' "$b" "$(command -v $b || echo 'FALTA')"
done
bash --version | head -1
```

`bash` tiene que ser **>= 4** para los tests del service; el de `/bin` en macOS es 3.2. Si falta
alguno: `brew install jq yq gomplate bash`.

### 2. Sesión AWS

```bash
aws sts get-caller-identity --profile galicia-1 --query Account --output text
# → 984449730514
```

Si falla: `aws sso login --profile galicia-1`. **Dura 1 hora**, y cuando vence fallan de golpe
todos los pasos de EKS con un error de credenciales que parece un problema del cluster.

### 3. OpenShift local

```bash
crc status | head -2
# → CRC VM: Running · OpenShift: Running
```

Si está apagado: `crc start` (~3 min). Después de arrancarlo, **el Paso 3 es obligatorio**.

### 4. Los dos clusters responden

```bash
for c in "$EKS" "$CRC"; do
  printf '%-14s %s\n' "$(basename "$c" | cut -c1-14)" "$(kubectl --context "$c" get ns payments -o name 2>&1 | head -1)"
done
# → namespace/payments en los dos
```

### 5. El punto de partida está limpio

Esto es lo que hace que la corrida sea "de cero" y no "arriba de lo que quedó de ayer".

```bash
"$NP_API" fetch-api "/service?nrn=$APP_NRN" \
  | jq -r '[.results[]|select(.name|startswith("egress"))] | "instancias egress: \(length)"'

for c in "$EKS" "$CRC"; do
  echo "── $c"
  # -l por la label del interceptor: en `payments` también viven los HTTPRoute de los scopes de
  # nullplatform, que no son nuestros y siempre están.
  echo "  objetos del interceptor: $(kubectl --context "$c" get gateway,httproute,authpolicy,destinationrule -n payments -l egress-interceptor/managed=true --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  kubectl --context "$c" get svc -n payments reports -o jsonpath='  selector: {.spec.selector}{"\n"}'
done
```

**Qué tenés que ver:**

| | Esperado |
|---|---|
| Instancias `egress-*` | **0** |
| Objetos del interceptor en `payments` | **0** en los dos clusters |
| Selector de `reports` | `{"app":"reports"}` en los dos |

Si queda algo de una corrida anterior, **corré el Paso 19** para limpiarlo antes de seguir. Si hay
una instancia en `pending` o `failed`, la API key del repo no la puede borrar (403): hace falta un
token de usuario o la consola.

### 6. Ningún agente corriendo todavía

```bash
pgrep -fl "np-agent -api-key" || echo "ninguno ✓"
```

Los agentes se levantan en el **Paso 1**, que es el siguiente. Este chequeo es para arrancar de
cero: si quedó uno de una corrida anterior, va a estar sirviendo código viejo.

⚠️ La plataforma sigue mostrando un agente como "latiendo" hasta ~3 minutos después de que el
proceso murió. `pgrep` dice la verdad; `./demo.sh preflight` puede mentir en esa ventana.

---

## Paso 1 — Levantar los dos agentes

**Va primero por dos motivos.** El agente ejecuta todo cambio de configuración —del Paso 12 en
adelante— y además **clona el repo de scopes** (`nullplatform/scopes#main`) en su basepath al
arrancar, que es lo que hace falta para poder desplegar un scope en EKS. Sin el agente arriba no
hay de dónde sacar los scope types.

El agente **no está en el camino del dato**: si se cae, el tráfico sigue; lo que se pierde es poder
reconfigurar.

**Los dos pueden estar prendidos a la vez.** El channel elige por el atributo `cluster` de cada
instancia (`{$context.parameters.cluster // $context.service.attributes.cluster}`), así que la
acción de `egress-eks` la toma el agente de EKS y la de `egress-crc` la de CRC. Antes había que
prender uno por vez porque el selector era sólo `role=egress-interceptor` y la acción podía caer
en el cluster equivocado sin fallar.

### La config del publisher gitops sale del `.env`

Los launchers leen el **`.env` de la raíz del repo** — gitignoreado, porque la URL lleva el token
adentro— y de ahí sacan la configuración del publisher. No hay que exportar nada a mano:

| variable | qué es |
|---|---|
| `GITOPS_REPO_URL` | repo donde se publican los manifiestos, con la credencial en la URL. **Sin ella el publisher queda apagado** y el reconcile anda como siempre. |
| `GITOPS_BRANCH` | rama destino. Default `main`. |
| `GITOPS_PATH_PREFIX` | subdirectorio raíz. Opcional. |
| `GITOPS_PUSH_RETRIES` | reintentos ante contención. Opcional, default `5`. |

Dos detalles del mecanismo, los dos deliberados:

- **Lo que ya esté exportado en el shell gana sobre el archivo.** Sirve para apuntar a otro repo por
  una corrida sin editar nada.
- **El `.env` no se ejecuta**: los launchers leen sólo las asignaciones de esas cuatro claves. Una
  línea con un comando no corre, y `NP_TOKEN` u otras variables del archivo no se cargan.

⚠️ **La rama destino tiene que existir en el remoto.** El publisher clona con `--branch`, así que
una rama inexistente aborta el reconcile. El launcher lo chequea antes de arrancar el agente y te
dice cómo crearla:

```bash
git push origin HEAD:refs/heads/<rama>
```

### Levantar los agentes

Cada uno en **su propia terminal**, desde la raíz del repo:

```bash
cd "$(git rev-parse --show-toplevel)"
export NP_API_KEY="$(cat accounts/galicia/np-api-skill.key)"
./services/egress-interceptor/start-agent-eks.sh
```

```bash
cd "$(git rev-parse --show-toplevel)"
export NP_API_KEY="$(cat accounts/galicia/np-api-skill.key)"
kubectl config use-context crc-admin      # el de CRC valida el current-context y aborta si no coincide
./services/egress-interceptor/start-agent-crc.sh
```

Con el publisher configurado, cada launcher imprime al arrancar a dónde va a publicar, con la
credencial tapada:

```
gitops: config leída de /…/galicia-banco/.env
gitops: publicando a https://***@github.com/nullplatform/galicia-banco
gitops: branch feature/gitops, prefijo gitops_manifests
```

Si no ves esas líneas, el publisher está apagado y los manifiestos sólo se aplican al cluster.

Usan puertos distintos (8182 y 8181), así que no chocan. El de EKS se arma su propio kubeconfig y
no le importa el `current-context`; el de CRC sí lo mira.

El de EKS imprime, antes de arrancar, qué repos va a clonar:

```
repo para el agente: https://github.com/nullplatform/scopes.git#main
```

Si el repo o la rama no existen, **aborta ahí** en vez de dejarlo enterrado en su log. Se puede
cambiar con `GIT_COMMAND_REPOS="repo1#main,repo2#dev"`. Quedan en `~/.np/`, al lado del symlink
`nullplatform-implementations/galicia-banco` → este working copy, que es lo que hace que el agente
ejecute el código del service tal como está en disco.

**Validar que los dos laten**, desde la terminal principal:

```bash
NP_API="$NP_API" ./demo.sh preflight | tail -2
# → latiendo: eks, crc
```

⚠️ `preflight` lee el heartbeat de la plataforma, que sigue mostrando un agente como vivo hasta
~3 minutos después de que el proceso murió. Si dudás, `pgrep -fl "np-agent -api-key"` dice la
verdad: tienen que aparecer **dos** procesos.

---

## Paso 2 — Preparar la terminal

```bash
cd ~/nullplatform/galicia/galicia-banco/accounts/galicia/demo-kuadrant-s2s

export EKS="arn:aws:eks:us-east-1:984449730514:cluster/gal-kuadrant-poc"
export CRC="crc-admin"
export NP_API_KEY="$(cat ../np-api-skill.key)"

# El path de np-api.sh se mueve con cada reorganización de skills/plugins: se resuelve, no se
# hardcodea. Preferimos el del marketplace, que no lleva la versión pineada en la ruta.
# Tres statements de UNA línea a propósito: una continuación con `\` dentro de un `$(...)` no
# sobrevive bien al copy-paste y el path termina con un salto de línea adentro.
NP_API="$HOME/.claude/plugins/marketplaces/nullplatform-internal/src/skills/np-api/scripts/np-api.sh"
[ -x "$NP_API" ] || NP_API=$(find "$HOME/.claude" -path '*np-api/scripts/np-api.sh' | head -1)
export NP_API
```

**Qué tenés que ver:**

```bash
echo "EKS=[$EKS] CRC=[$CRC]"                                       # ninguno vacío
[ -x "$NP_API" ] && echo "np-api OK: $NP_API" || echo "FALTA np-api — el path quedó [$NP_API]"
aws sts get-caller-identity --profile galicia-1 | jq -r .Account    # → 984449730514
crc status | head -2                                               # → Running / Running
kubectl --context "$EKS" get ns istio-system -o name                # → namespace/istio-system
kubectl --context "$CRC" get ns istio-system -o name                # → namespace/istio-system
"$NP_API" fetch-api "/service?nrn=organization=1636958496:account=1374028000:namespace=824774832:application=142495574" \
  | jq -c '[.results[]?|select(.slug|startswith("egress"))|.slug]'  # → ["egress-crc","egress-eks"]
```

**Si no da eso:**

| Síntoma | Causa | Fix |
|---|---|---|
| `The config profile (galicia-1) could not be found` | el perfil no existe en esta máquina | agregar `[profile galicia-1]` a `~/.aws/config` (misma `sso-session`, cuenta `984449730514`, rol `Administrator`) |
| `Error when retrieving token` | sesión SSO vencida (dura 1 h) | `aws sso login --profile galicia-1` |
| CRC `Stopped` | la VM está apagada | `crc start` (~3 min con la VM ya creada) |
| `np-api.sh: No such file or directory` | el path se movió; `demo.sh` lo tiene hardcodeado a `np-developer/1.2.15` | usar el `export NP_API` de arriba y pasarlo siempre: `NP_API="$NP_API" ./demo.sh …` |

### La regla que más confunde: el header de ruteo lo decide el DESTINO

Contra el ingreso de **EKS** va `X-NP-Scope`; contra el de **OpenShift** va `X-NP-SVC`. Con el header
equivocado no matchea ninguna regla del `HTTPRoute` y da **404 antes de autenticar** — parece un
problema de identidad y no lo es.

### La segunda regla: un 200 no prueba que cruzó de cluster

La evidencia de cruce es que el **Authorino del cluster destino** registre la decisión. Un 200 con
los headers de ingreso pueden venir de un Envoy que todavía sirve configuración anterior. En los pasos 12-15 el
contador de Authorino va incorporado al flujo justamente por esto.

---

## Paso 3 — Higiene del tailnet

**Qué valida:** que ningún nombre del tailnet esté ocupado por una generación huérfana. Va **antes**
de cualquier prueba cross-cluster porque, si hay duplicados, las mediciones admiten dos
explicaciones y no se puede concluir nada.

```bash
./scripts/tailnet-prune.sh          # lista, no toca nada
```

**Qué tenés que ver:** los 8 devices vivos (4 por cluster), la sección de huérfanos **vacía**, y la
de "nombres canónicos servidos con sufijo" mostrando a lo sumo
`istio-system-s2s-remote-ingress-N`.

```
── Huérfanos (ningún pod los reporta como propios)
    (ninguno — el tailnet está limpio)
```

**Si aparecen huérfanos, o algún `s2s-*` está servido con sufijo** (lo normal después de recrear CRC,
o si alguien más levantó la PoC):

```bash
./scripts/tailnet-prune.sh --fix
```

⚠️ **No lo hagas a mano.** La secuencia es **cíclica** y romperla es fácil:

1. borrar los huérfanos → libera el nombre base;
2. borrar **Secret + pod** del proxy → re-registra y toma el nombre libre (borrar sólo el pod no
   alcanza: re-autentica con el node key de su Secret y conserva el sufijo);
3. borrar los **nuevos** huérfanos → el paso 2 abandonó el device con sufijo;
4. reciclar el proxy de egreso **y el operator** de EKS → el proxy resuelve la IP destino al
   arrancar y el forwarding lo programa el operator.

**Y el punto que más importa: reciclar un proxy que YA tiene el nombre canónico lo rompe.** Abandona
el device bueno y el registro nuevo agarra el sufijo — o sea que "por si acaso" te deja peor que como
estabas. `--fix` sólo re-registra lo que tiene sufijo, y hace las dos pasadas de limpieza en el orden
correcto.

**Qué tenés que ver al final** (salida real):

```
── Nombres después del re-registro
    ts-s2s-crc-jwks-54swd-0            s2s-crc-jwks.tail02303a.ts.net.
    ts-s2s-ingress-istio-hkgjq-0       s2s-crc-ingress.tail02303a.ts.net.
── Verificación: el hop tiene que llegar al validador del peer
    intento 1: HTTP 401   ·   authorino del peer: 5 → 6
    OK  el hop llega al validador del peer (401 sin token es el resultado correcto)
```

El `401` es el resultado **correcto** acá: prueba que el request llegó al validador del otro cluster
y fue rechazado por no llevar token. Lo que valida el fix no es el código sino que **el contador del
peer suba**.

La verificación reintenta hasta 4 veces espaciadas porque la convergencia del netmap tarda ~50 s: un
único intento inmediato devuelve `000` y hace parecer que el fix falló.

`s2s-crc-ingress` y `s2s-crc-jwks` **tienen** que quedar sin sufijo: son los nombres que
referencian los tfvars de EKS. El de `istio-system-s2s-remote-ingress` puede quedar con sufijo y es
esperable — colisiona entre los dos clusters por diseño (mismo namespace y nombre de Service en
ambos) y no lo referencia ningún tfvar.

Historia completa de por qué esto importa: **Apéndice C**.

---

## Paso 4 — Sustrato sano en los dos clusters

**Qué valida:** que el Gateway esté programado y que la AuthPolicy esté **aplicándose**.

```bash
for c in "$EKS" "$CRC"; do
  echo "── $c"
  kubectl --context "$c" -n gateways get gateway s2s-ingress \
    -o jsonpath='  Gateway Programmed: {.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
  kubectl --context "$c" -n gateways get authpolicy s2s-validator \
    -o jsonpath='  AuthPolicy Enforced: {.status.conditions[?(@.type=="Enforced")].status}{"\n"}'
  kubectl --context "$c" -n gateways get httproute -o name
  kubectl --context "$c" get pods -A | grep -vE "Running|Completed|NAME" || echo "  pods: todos arriba"
done
```

**Qué tenés que ver:** `Programmed: True` en los dos y ningún pod fuera de `Running`. `Enforced`
depende de si el Gateway ya tiene alguna route colgada, y **antes del Paso 12 los dos clusters no
están en el mismo estado**:

- **EKS:** la route del scope desplegado cuelga del Gateway de forma permanente, así que da
  `Enforced: True` desde el arranque.
- **OpenShift:** la route de ingreso la trae la intercepción, así que hasta que existan las
  instancias es legítimo ver `Enforced: False` con el mensaje `not in the path to any existing
  routes`. Ése —y sólo ése— es el `False` esperable.

**Por qué `Enforced` y no `Accepted`:** `Accepted=True` sólo dice que Kuadrant aceptó la política.
Kuadrant **no enforcea si no hay un `HTTPRoute` colgado del Gateway, y no falla ruidosamente** — la
política queda aceptada y el tráfico pasa sin autenticar (Gotcha #22).

⚠️ **El listado de `httproute` en `gateways` puede salir vacío, y no significa que no enforcee.**
Las routes de los scopes viven en el namespace de la app y apuntan al Gateway cross-namespace, así
que no aparecen ahí. No cuentes routes: leé `Enforced` de la propia AuthPolicy, que es lo que hace
`demo.sh preflight`.

---

## Paso 5 — Cargar los helpers

Estos helpers hacen **contabilidad**, no la prueba: esperar, contar y firmar tokens. Los requests y
las respuestas —que son la afirmación que hay que auditar— van siempre explícitos en cada paso.

Pegá el bloque **completo**, una vez por terminal.

```bash
# ── guarda contra el fallo silencioso más común: con $EKS o $CRC vacíos, `kubectl --context ""`
#    NO falla, cae al current-context y te consulta otro cluster
_ctx() { [ -n "$1" ] || { echo "ERROR: contexto vacío. ¿Exportaste \$EKS y \$CRC? (Paso 2)" >&2; return 1; }; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# ── `clave` devuelve la RUTA de un archivo con la privada de un namespace, y `mint` recibe esa
#    ruta. Nunca hay una variable global de clave: así ningún paso puede envenenar a otro.
#    La clave vive en `kuadrant-system` y NO en el namespace de la app: Kuadrant traduce toda
#    AuthPolicy a un AuthConfig en kuadrant-system y Authorino resuelve signingKeyRefs contra el
#    namespace del AuthConfig. El nombre del Secret es además el `kid` del token.
clave() {  # $1=contexto  $2=namespace
  _ctx "$1" || return 1
  local f; f=$(mktemp)
  kubectl --context "$1" get secret -n kuadrant-system "${2}-wristband-key" \
    -o jsonpath='{.data.key\.pem}' 2>/dev/null | base64 -d > "$f" || return 1
  [ -s "$f" ] || { echo "ERROR: no pude leer la clave de '$2' en ese cluster" >&2; return 1; }
  echo "$f"
}

mint() {  # $1=iss declarado  $2=ruta de la clave que FIRMA
  local now h p s; now=$(date +%s)
  [ -s "$2" ] || { echo "ERROR: usá  mint <iss> \"\$(clave \$CTX <ns>)\"" >&2; return 1; }
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  p=$(printf '{"iss":"%s","iat":%d,"exp":%d}' "$1" "$now" "$((now+180))" | b64url)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$2" | b64url)
  printf '%s.%s.%s' "$h" "$p" "$s"
}

# ── el nombre del pod atacante del namespace `other`, para no repetir el jsonpath
atacante() { _ctx "$1" || return 1
  kubectl --context "$1" get pod -n other -l app=intruso -o name | head -1 | cut -d/ -f2; }

# ── contador de decisiones del validador, anclado en un timestamp FIJO.
#    Con ventana relativa (`--since=20m`) el conteo puede quedar plano aunque haya habido
#    decisiones nuevas: si una línea vieja sale de la ventana justo cuando entra una nueva, antes y
#    después dan el mismo número y el escenario parece no haber cruzado. Falso negativo verificado.
marca() { date -u +%Y-%m-%dT%H:%M:%SZ; }   # tomar ANTES del request

desde() {  # $1=contexto  $2=marca
  _ctx "$1" || return 1
  kubectl --context "$1" -n kuadrant-system logs deploy/authorino --since-time="$2" 2>/dev/null \
    | grep -c "outgoing authorization response"; }

# ── esperar a que la config nueva esté EFECTIVAMENTE sirviendo, no a que el objeto exista.
#    Un `HTTPRoute` se actualiza al instante; que Envoy ya lo esté sirviendo va detrás. Y
#    `Running` no es `Ready`, ni `Ready` es "recibe tráfico": eso recién pasa cuando la IP está
#    en los endpoints del Service.
# ── El chequeo tiene DOS mitades y las dos hacen falta:
#      1. el objeto declara lo que se pidió;
#      2. un request real hace DECIDIR al validador del destino.
#    La segunda es la que vale. Y es el contador de Authorino, no un header: `x-s2s-cluster` lo
#    estampaba NUESTRO HTTPRoute del ingreso, y hacia EKS ya no existe — ahí se entra por el
#    HTTPRoute del propio scope, que lo maneja la plataforma y no sella nada. El contador además
#    prueba más: que el Authorino del otro lado autorizó, no que un proxy agregó un header.
esperar_local() {  # $1=contexto origen  $2=contexto del peer
  # La prueba de que NO cruzó es que el validador del peer no decidió nada. Mirar
  # `x-s2s-cluster` no sirve: con destino EKS ese header no llega ni cruzando.
  local ctx="$1" peer="$2" i code n t0
  _ctx "$ctx" || return 1
  for i in $(seq 1 40); do
    t0=$(marca)
    code=$(kubectl --context "$ctx" exec -n payments deploy/ledger -- \
      wget -S -qO- --timeout=20 http://reports.payments.svc.cluster.local:8080/whoami 2>&1 \
      | tr -d '\r' | grep -oE 'HTTP/1.1 [0-9]+' | head -1)
    n=$(desde "$peer" "$t0")
    if [ "${code##* }" = "200" ] && [ "${n:-0}" -eq 0 ]; then
      echo "    servido sin cruzar: $code, el validador del peer no decidió"; return 0
    fi
    sleep 5
  done
  echo "ERROR: no convergió a percent=0 — el tráfico sigue cruzando." >&2
  return 1
}

esperar() {  # $1=contexto origen  $2=patrón en la route  $3=contexto del DESTINO
  local ctx="$1" pat="$2" dst="$3"
  _ctx "$ctx" || return 1
  [ "$#" -eq 3 ] || { echo "ERROR: usá  esperar \$CTX '<patrón>' \$CTX_DESTINO" >&2; return 1; }
  local route i t0 n
  # 12 min: en CRC, tras el fix de multus, el pod nuevo tardó 8-9 min en nacer y entrar a
  # endpoints (medido). En EKS suele resolver en segundos.
  for i in $(seq 1 90); do
    route=$(kubectl --context "$ctx" get httproute -n payments s2s-egress-reports -o yaml 2>/dev/null || true)
    case "$route" in
      *"$pat"*)
        t0=$(marca)
        kubectl --context "$ctx" exec -n payments deploy/ledger -- \
          wget -qO- --timeout=20 http://reports.payments.svc.cluster.local:8080/whoami >/dev/null 2>&1 || true
        n=$(desde "$dst" "$t0")
        if [ "${n:-0}" -ge 1 ]; then
          echo "    confirmado: el validador del destino decidió $n"; return 0
        fi ;;
    esac
    sleep 8
  done
  echo "ERROR: 12 min sin confirmar que el destino valide. Se buscaba '$pat' en la route." >&2
  echo "  · ¿está latiendo el agente del cluster de ORIGEN?  ./demo.sh preflight | tail -2" >&2
  echo "  · ¿ejecutó la acción?  grep exec /tmp/np-agent-*.log | tail -3" >&2
  echo "  · ¿quedó una acción en 'in_progress'?  la API rechaza la siguiente con un 400" >&2
  echo "  · ¿el pod del gateway arranca?  kubectl --context $ctx -n payments get pods -l gateway.networking.k8s.io/gateway-name=s2s-egress" >&2
  echo "    si queda en Init y los eventos dicen 'Multus … Unauthorized', es el Gotcha #23:" >&2
  echo "    kubectl --context $ctx delete pod -n openshift-multus -l app=multus" >&2
  return 1
}
```

**Validá que quedaron cargadas:**

```bash
for f in clave mint atacante marca desde esperar esperar_local; do
  command -v "$f" >/dev/null || echo "FALTA la función $f"
done
T=$(marca); echo "authorino desde ahora: EKS=$(desde "$EKS" "$T")  CRC=$(desde "$CRC" "$T")"  # dos ceros
```

---

## Paso 6 — Aislamiento entre namespaces (EKS)

**Qué valida** la propiedad de seguridad central: la identidad **no se puede falsificar**, y sale de
qué clave verificó la firma, no del claim `iss`.

### El request, explícito

Los cuatro casos son **el mismo `curl`** cambiando sólo el token. Este es el comando completo:

```bash
POD_INTRUSO=$(atacante "$EKS")            # el pod `intruso` del namespace `other`
KEY_OTHER=$(clave "$EKS" other)   # la privada con la que firma el Gateway de egreso de `other`
KEY_PAY=$(clave "$EKS" payments)  # la privada de `payments`
# El FQDN del scope, resuelto por la API. `np scope list` del CLI da 403 con la API key del
# repo, y un SCOPE_FQDN vacío se manifiesta como 404 en los cuatro casos — que se lee como
# ruteo roto y manda el diagnóstico para el lado equivocado.
SCOPE_FQDN=$("$NP_API" fetch-api "/scope?nrn=$APP_NRN" \
  | jq -r --arg s "$SCOPE" '.results[] | select(.slug==$s and .status=="active") | .domain')
[ -n "$SCOPE_FQDN" ] || echo "ERROR: el scope '$SCOPE' no resolvió — sin esto todo da 404"

# Se entra por el HTTPRoute del PROPIO scope, que matchea por hostname y cuelga de nuestro
# Gateway (por eso queda bajo la AuthPolicy). O sea: el Host tiene que ser el FQDN del scope, no
# el nombre del Gateway. Con el nombre del Gateway no matchea ninguna route y da 404 antes de
# autenticar, que no es lo que este paso quiere probar.
INGRESS_URL="https://s2s-ingress-istio.gateways.svc.cluster.local/whoami"
# El TLS va contra el nombre del Gateway (es el que cubre el cert); el Host HTTP es el FQDN del
# scope, que es lo que matchea SU HTTPRoute. Con `Host:` y no con `--resolve`: el FQDN del scope
# no resuelve por DNS dentro del cluster, y `--resolve` además llega a curl como un solo
# argumento cuando se pasa por `kubectl exec`.
HOST_SCOPE="Host: $SCOPE_FQDN"
echo "scope=$SCOPE  fqdn=$SCOPE_FQDN"

# Me conecto a un pod dentro del cluster para probar las casuísticas
kubectl --context "$EKS"  exec -n other "$POD_INTRUSO" -- \
  curl -s -o /dev/null -w 'HTTP %{http_code}\n' -k --max-time 20 -H "$HOST_SCOPE" \
    "$INGRESS_URL"
```

Qué es cada parte:

| Parte | Por qué |
|---|---|
| `exec -n other "$POD_INTRUSO"` | el request sale de **otro namespace**: es el atacante |
| `-k` | el cert del Gateway lo firma la CA de la PoC, que el pod atacante no tiene. Acá no estamos probando TLS |
| `-H "$HOST_SCOPE"` | el `Host` es el **FQDN del scope**: así lo toma el `HTTPRoute` de ese scope, que cuelga de nuestro Gateway y queda bajo la `AuthPolicy`. Sin eso no matchea ninguna route y da 404 antes de autenticar |
| `/` | el path ya no participa del ruteo: el `HTTPRoute` del ingreso matchea sólo por el header, y quién pasa lo decide la `AuthPolicy`, que no mira el path |
| `-w 'HTTP %{http_code}'` | sólo interesa el código: 401, 403 o 200 |

### Los cuatro casos

```bash
# 1. sin credencial se obtiene http 401
kubectl --context "$EKS" exec -n other "$POD_INTRUSO" -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 20 -H "$HOST_SCOPE" \
  "$INGRESS_URL"

# 2. clave legítima de `other`, declarando iss=other: 403 porque `other` no está autorizado
kubectl --context "$EKS" exec -n other "$POD_INTRUSO" -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 20 -H "$HOST_SCOPE" -H "X-NP-Token: $(mint other "$KEY_OTHER")" \
  "$INGRESS_URL"

# 3. la MISMA clave de `other`, mintiendo iss=payments, se obtiene 403 porque firma no coincide con namespace origen
kubectl --context "$EKS" exec -n other "$POD_INTRUSO" -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 20 -H "$HOST_SCOPE" -H "X-NP-Token: $(mint payments "$KEY_OTHER")" \
  "$INGRESS_URL"

# 4. clave de payments, con iss=payments, se obtiene 200
kubectl --context "$EKS" exec -n other "$POD_INTRUSO" -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 20 -H "$HOST_SCOPE" -H "X-NP-Token: $(mint payments "$KEY_PAY")" \
  "$INGRESS_URL"
```

**Qué tenés que ver** (salida real):

| # | Token | Código | Qué prueba |
|---|---|---|---|
| 1 | ninguno | **401** | sin credencial no se entra: corta **antes** de autorizar |
| 2 | clave de `other`, `iss=other` | **403** | `authorized_namespaces` es lista blanca y `other` no está |
| 3 | clave de `other`, `iss=payments` | **403** | **identidad infalsificable**: el `iss` no participa de la autorización |
| 4 | clave de `payments` | **200** | control positivo — sin esto los 403 no prueban nada |

El caso 3 es el importante: cada regla de `authentication` del validador fija la identidad con
`overrides` según **qué clave verificó la firma**. Es más fuerte que atar la clave al `kid`, porque
nada obliga a que `iss == kid`.

### Qué ve el validador

Los códigos de arriba prueban **qué** decidió el gateway; esto prueba **quién** lo decidió. El bloque
incluye los requests: el ancla sin tráfico en el medio devuelve vacío, y eso no es un fallo.

```bash
# voy a contar la cantidad de request desde este timestamp para validar que el tráfico pasa por el validador
T0=$(marca) 

# caso 1 otra vez: sin token → 401
kubectl --context "$EKS" exec -n other "$POD_INTRUSO" -- curl -s -o /dev/null -w 'caso 1: HTTP %{http_code}\n' \
  -k --max-time 20 -H "$HOST_SCOPE" \
  "$INGRESS_URL"

# caso 4 otra vez: clave de payments → 200
kubectl --context "$EKS" exec -n other "$POD_INTRUSO" -- curl -s -o /dev/null -w 'caso 4: HTTP %{http_code}\n' \
  -k --max-time 20 -H "$HOST_SCOPE" -H "X-NP-Token: $(mint payments "$KEY_PAY")" \
  "$INGRESS_URL"

sleep 3
kubectl --context "$EKS" -n kuadrant-system logs deploy/authorino --since-time="$T0" \
  | grep "outgoing authorization response" | tail -2
```

**Qué tenés que ver** (salida real): los dos códigos y **dos** líneas de decisión.

```
{"level":"info","ts":"2026-08-21T12:39:20Z","logger":"authorino.service.auth","msg":"outgoing authorization response","request id":"3510d544-e4e8-4e12-b50d-f9e281b6b6a5","authorized":false,"response":"UNAUTHENTICATED","object":{"code":16,"message":"{\"local-other\":\"credential not found\",\"local-payments\":\"credential not found\",\"peer-other\":\"credential not found\",\"peer-payments\":\"credential not found\"}"}}
{"level":"info","ts":"2026-08-21T12:39:24Z","logger":"authorino.service.auth","msg":"outgoing authorization response","request id":"a1612349-164c-4551-966e-1813843e1691","authorized":true,"response":"OK"}
```

Cada línea trae su `request id` y su veredicto. Que haya **dos** cierra el círculo: el 401 y el 200
los decidió el validador, no un proxy que rechaza o acepta todo por su cuenta.

Si querés el veredicto explícito por línea:

```bash
kubectl --context "$EKS" -n kuadrant-system logs deploy/authorino --since-time="$T0" \
  | grep "outgoing authorization response" | jq -r '"\(.ts)  authorized=\(.authorized)"'
```

⚠️ **A nivel `info` Authorino registra el veredicto pero no la identidad que fijó.** Para ver el
namespace que quedó como identidad hay que subir el `logLevel` del CR de Authorino a `debug`.

**Lo que este test NO prueba:** el aislamiento es **entre claves**, no entre pods. El caso 4 dio 200
desde un pod de `other` porque le pasamos la clave de `payments`. El modelo no tiene noción de "de
qué pod vino el request"; el radio de daño de una clave filtrada es su namespace.

**Por qué el token se acuña afuera del cluster:** es equivalente a que lo firme un workload de
`other`, porque ese namespace **tiene su propia clave de firma**. No es un atajo del
test: es el modelo de amenaza real.

**Atajo:** `NP_API="$NP_API" ./demo.sh aislamiento`

---

## Paso 7 — Aislamiento entre namespaces (OpenShift)

Lo mismo del lado on-prem. **Cambian dos cosas:** el contexto y el header de ruteo, porque el destino
es OpenShift.

```bash
POD_INTRUSO_CRC=$(atacante "$CRC")
KEY_OTHER_CRC=$(clave "$CRC" other)
KEY_PAY_CRC=$(clave "$CRC" payments)
ROUTING_HEADER_CRC='X-NP-SVC: reports'

# 1. sin credencial se obtiene http 401
kubectl --context "$CRC" exec -n other "$POD_INTRUSO_CRC" -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 20 \
  -H "$ROUTING_HEADER_CRC" "$INGRESS_URL"

# 3. la MISMA clave de `other`, mintiendo iss=payments, se obtiene 403 porque firma no coincide con namespace origen
kubectl --context "$CRC" exec -n other "$POD_INTRUSO_CRC" -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 20 -H "X-NP-Token: $(mint payments "$KEY_OTHER_CRC")" \
  -H "$ROUTING_HEADER_CRC" "$INGRESS_URL"

# 4. clave de payments, con iss=payments, se obtiene 200
kubectl --context "$CRC" exec -n other "$POD_INTRUSO_CRC" -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 20 -H "X-NP-Token: $(mint payments "$KEY_PAY_CRC")" \
  -H "$ROUTING_HEADER_CRC" "$INGRESS_URL"
```

**Qué tenés que ver:** `401 / 403 / 200`. Verificado el 20/08.

Esto confirma que el flavour OpenShift de Istio (CNI sobre multus + SCC) enforcea igual que el
vanilla: la política es la misma y el sustrato no cambia el contrato.

**Atajo:** `NP_API="$NP_API" ./demo.sh aislamiento crc`

---

## Paso 8 — El JWT por dentro

**Qué valida:** qué claims viajan realmente.

```bash
T=$(mint payments "$(clave "$EKS" payments)")
echo "$T" | cut -d. -f1 | tr '_-' '/+' | awk '{ while (length($0)%4) $0=$0"="; print }' | openssl base64 -d -A | jq -c .
echo "$T" | cut -d. -f2 | tr '_-' '/+' | awk '{ while (length($0)%4) $0=$0"="; print }' | openssl base64 -d -A | jq .
```

**Qué tenés que ver:**

```json
{"alg":"RS256","typ":"JWT"}
{
  "iss": "payments",
  "iat": 1787239615,
  "exp": 1787239735
}
```

Lo interesante es **lo que no tiene**: ni `aud`, ni `jti`, y en el flujo real dura 60 s. Quien capture
un token puede reusarlo hasta que expire — es el pendiente de anti-replay.

El `awk` arregla el padding: base64url saca los `=` y `openssl base64 -d` los necesita.

Si querés ver el token **que emite el interceptor** en vez de uno acuñado a mano, no se puede: el
token nunca se loguea: ni el Envoy ni Authorino lo emiten. Un JWT en un log es
una credencial.

---

## Paso 9 — JWKS cruzado: cada validador ve la clave del peer

**Qué valida** la pieza de la que dependen los escenarios cross-cluster: que cada validador alcance
la clave pública del otro, **y que sea la del otro y no la propia**. Sin este chequeo, un "cruce"
exitoso podría ser un cluster validando con su propia clave.

```bash
P=/payments/jwks.json

echo -n "clave propia de EKS:    "
kubectl --context "$EKS" exec -n payments deploy/ledger -- \
  wget -qO- --timeout=10 "http://s2s-eks-jwks.kuadrant-system.svc.cluster.local:8080$P" | jq -r '.keys[0].n[0:32]'

echo -n "lo que EKS trae de CRC: "
kubectl --context "$EKS" exec -n payments deploy/ledger -- \
  wget -qO- --timeout=10 "http://s2s-crc-jwks.kuadrant-system.svc.cluster.local:8080$P" | jq -r '.keys[0].n[0:32]'

echo -n "clave real de CRC:      "
kubectl --context "$CRC" exec -n payments deploy/ledger -- \
  wget -qO- --timeout=10 "http://s2s-crc-jwks.kuadrant-system.svc.cluster.local:8080$P" | jq -r '.keys[0].n[0:32]'
```

**Qué tenés que ver:** las **dos últimas iguales** y **distintas de la primera**.

```
clave propia de EKS:    yjC0Xou3Yy9Fyl25otl7EgXP4bPzAyEm
lo que EKS trae de CRC: umRyMzxDcDoqQrzYo17ZTpf2yKft3IzG
clave real de CRC:      umRyMzxDcDoqQrzYo17ZTpf2yKft3IzG
```

El `s2s-crc-jwks` de EKS es un `ExternalName` que apunta al proxy de egreso de Tailscale, que a su vez
sale al tailnet. Podés ver la cadena:

```bash
kubectl --context "$EKS" -n kuadrant-system get svc s2s-crc-jwks -o jsonpath='{.spec.externalName}{"\n"}'
kubectl --context "$EKS" -n tailscale get pod -o jsonpath='{range .items[*]}{.metadata.name} {range .spec.containers[0].env[?(@.name=="TS_TAILNET_TARGET_FQDN")]}{.value}{end}{"\n"}{end}'
```

**Si la del medio falla o coincide con la primera:** es el mecanismo de nombres del tailnet — Paso 3.

---

## Paso 10 — El hop remoto, sin interceptor

**Qué valida:** que el validador del cluster **peer** reciba y decida, atravesando el overlay. Es el
test cross-cluster más limpio: **no depende del agente ni de la configuración de la instancia**,
porque le pega directo al ingreso remoto.

La diferencia con el Paso 6 es una sola: el host del `curl`. En vez del ingreso local
(`s2s-ingress-istio.gateways…`) va el del peer (`s2s-remote-gateway.tailscale…`), que cada
cluster resuelve al otro.

### EKS → OpenShift

```bash
POD_EKS=$(atacante "$EKS")
KEY_PAY_EKS=$(clave "$EKS" payments)
T0=$(marca)
GATEWAY_OPENSHIFT=https://s2s-remote-gateway.tailscale.svc.cluster.local
INGRESS_URL_OPENSHIFT="$GATEWAY_OPENSHIFT/"

# Me conecto a un pod de EKS para pegarle a OpenShift, sin token, obtengo 401
kubectl --context "$EKS" exec -n other "$POD_EKS" -- curl -s -o /dev/null -w 'HTTP %{http_code} en %{time_total}s\n' \
  -k --max-time 25 \
  -H "$ROUTING_HEADER_CRC" "$INGRESS_URL_OPENSHIFT"

# Me conecto a un pod de EKS para pegarle a OpenShift, con token, obtengo 200
kubectl --context "$EKS" exec -n other "$POD_EKS" -- curl -s -o /dev/null -w 'HTTP %{http_code} en %{time_total}s\n' \
  -k --max-time 25 -H "X-NP-Token: $(mint payments "$KEY_PAY_EKS")" \
  -H "$ROUTING_HEADER_CRC" "$INGRESS_URL_OPENSHIFT"

sleep 3
echo "decisiones de CRC desde T0: $(desde "$CRC" "$T0")     # tiene que ser 2"
kubectl --context "$CRC" -n gateways logs -l gateway.networking.k8s.io/gateway-name=s2s-ingress --since=2m | tail -2
```

**Qué tenés que ver** (salida real):

```
HTTP 401 en 1.283885s
HTTP 200 en 0.553776s
decisiones de CRC desde T0: 2
s2s code=401 path=/ wristband=-
s2s code=200 path=/ wristband=-
```

El `401` es un resultado **deseable** acá: prueba que el request llegó al validador del otro cluster.
Lo que valida el cruce no es el código sino que **el contador de CRC se mueva**: las dos líneas del
access log de CRC prueban que los dos requests llegaron hasta allá y que el validador decidió sobre
cada uno.

El 200 lo autoriza la regla **`peer-payments`** del validador de CRC: la clave es la de `payments` de
**EKS**, o sea el peer.

### OpenShift → EKS

```bash
POD_OPENSHIFT=$(atacante "$CRC")
KEY_PAY_CRC=$(clave "$CRC" payments)
T0=$(marca)
GATEWAY_EKS=https://s2s-remote-gateway.tailscale.svc.cluster.local
INGRESS_URL_EKS="$GATEWAY_EKS/whoami"
# El TLS va contra el nombre del overlay (es el que cubre el cert), pero el Host HTTP tiene que
# ser el FQDN del scope: es lo que hace que del otro lado lo tome SU HTTPRoute.
HOST_SCOPE="Host: $SCOPE_FQDN"

# Me conecto a un pod de OpenShift para pegarle a EKS, sin token, obtengo 401
kubectl --context "$CRC" exec -n other "$POD_OPENSHIFT" -- curl -s -o /dev/null -w 'HTTP %{http_code} en %{time_total}s\n' \
  -k --max-time 25 \
  -H "$HOST_SCOPE" "$INGRESS_URL_EKS"

# Me conecto a un pod de OpenShift para pegarle a EKS, con token, obtengo 200
kubectl --context "$CRC" exec -n other "$POD_OPENSHIFT" -- curl -s -o /dev/null -w 'HTTP %{http_code} en %{time_total}s\n' \
  -k --max-time 25 -H "X-NP-Token: $(mint payments "$KEY_PAY_CRC")" \
  -H "$HOST_SCOPE" "$INGRESS_URL_EKS"

sleep 3
echo "decisiones de EKS desde T0: $(desde "$EKS" "$T0")     # tiene que ser 2"
```

⚠️ **El primer request cross-cluster después de que arranca Authorino da 500.** El JWKS del peer se
trae por demanda y ese fetch cruza el overlay. Tirá uno, descartalo y repetí. El log dice
`UNAVAILABLE`, que **no** es "token inválido".

### Con verificación TLS real

Los `curl` de arriba usan `-k`. El camino real **sí** verifica: el `DestinationRule` del namespace
origina el TLS con `credentialName: s2s-remote-ca` y el FQDN viajando como SNI, así que el cert del
peer se valida contra la CA propia. No se puede replicar con un `exec` al pod del Gateway —el Envoy no
trae `curl` y la CA la consume por SDS, no como archivo— así que se verifica sobre el objeto y sobre
la cadena:

```bash
# 1. El DestinationRule pide verificación real (no insecureSkipVerify) y fija el SNI.
kubectl --context "$EKS" -n payments get destinationrule s2s-egress-reports \
  -o jsonpath='{.spec.trafficPolicy.tls}{"\n"}'
# → {"credentialName":"s2s-remote-ca","mode":"SIMPLE","sni":"s2s-remote-gateway.tailscale.svc.cluster.local"}

# 2. La CA que monta es la que firmó el cert del peer.
kubectl --context "$EKS" -n payments get secret s2s-remote-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/peer-ca.crt
kubectl --context "$CRC" -n gateways get secret s2s-gateway-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/peer.crt
openssl verify -CAfile /tmp/peer-ca.crt /tmp/peer.crt
# → /tmp/peer.crt: OK
```

Si (1) dijera `insecureSkipVerify` o (2) fallara, el hop remoto estaría aceptando cualquier cert: es
un fallo de la cadena TLS, no de la identidad.

---

## Paso 11 — Rate limit (200 req / 60 s)

**Qué valida:** que el `RateLimitPolicy` de Kuadrant corte en el ingreso del destino.

Primero, que exista y esté enforceando:

```bash
kubectl --context "$EKS" -n gateways get ratelimitpolicy s2s-smoke \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}{.spec.limits}{"\n"}'
kubectl --context "$CRC" get ratelimitpolicy -A     # → No resources found (CRC no lo declara)
```

Después, 260 requests con un token válido. **El loop corre adentro del pod, en un solo `exec`**: con
260 `kubectl exec` se te iría la ventana de 60 s antes de llegar al límite.

```bash
POD=$(atacante "$EKS")
TOK=$(mint payments "$(clave "$EKS" payments)")

kubectl --context "$EKS" exec -n other "$POD" -- env TOK="$TOK" FQDN="$SCOPE_FQDN" sh -c '
  for i in $(seq 1 260); do
    curl -s -o /dev/null -w "%{http_code}\n" -k --max-time 10 \
      -H "Host: $FQDN" -H "X-NP-Token: $TOK" \
      https://s2s-ingress-istio.gateways.svc.cluster.local/whoami
  done' | sort | uniq -c
```

**Qué tenés que ver** (salida real):

```
 200 200
  60 429
```

Exactamente 200 autorizados y el resto `429`. Si te da menos de 200, alguien ya consumió parte de la
ventana: esperá 60 s y repetí.

El límite es un **smoke global en el Gateway**, no una política por identidad — eso es un pendiente.
Y **sólo existe en EKS**: un escenario con destino CRC no lo toca.

---

## Paso 12 — Crear las instancias del service

**Qué valida:** el camino de `create`, que es el que provisiona el `Gateway` de egreso, su
`AuthPolicy` y las rutas **desde cero**. Los pasos 12-17 sólo reconfiguran lo que este paso creó.

Son **dos llamadas** y hacen falta las dos: `np service create` deja el registro en `pending`, y la
acción de tipo `create` es lo que dispara la notificación al agente. Sin la segunda no se
provisiona nada y la instancia queda colgada.

### Antes: el namespace está sin tocar

```bash
for CTX in "$EKS" "$CRC"; do
  echo "$CTX"
  kubectl --context "$CTX" get gateway,httproute,authpolicy,destinationrule -n payments --no-headers
  kubectl --context "$CTX" get svc -n payments reports -o jsonpath='{.spec.selector}{"\n"}'
done
# → sin objetos, y el selector en {"app":"reports"}
```

### Crear

```bash
NP_API="$NP_API" ./demo.sh crear eks
NP_API="$NP_API" ./demo.sh crear crc
```

Cada uno muestra el antes, crea, espera a que la `AuthPolicy` quede `Enforced=True` **y** a que el
Service ya apunte al Gateway, y recién ahí muestra el después.

**Qué tenés que ver:**

```
✓ instancia egress-eks creada (…) → scope=eks percent=0
✓ el Gateway y la AuthPolicy quedaron enforceando, y el Service ya apunta al Gateway
  gateway.gateway.networking.k8s.io/s2s-egress            istio   …   True
  httproute.gateway.networking.k8s.io/s2s-egress-reports  ["reports","reports.payments",…]
  authpolicy.kuadrant.io/s2s-egress
  destinationrule.networking.istio.io/s2s-egress-reports  s2s-remote-gateway.tailscale.svc.cluster.local
  selector de reports: {"gateway.networking.k8s.io/gateway-name":"s2s-egress"}
  AuthPolicy: Accepted=True Enforced=True
```

Las dos arrancan con **`percent: 0`**: `reports` todavía no está migrado, así que **todo se atiende
en OpenShift**. Es el punto de partida honesto de una migración, y el mismo valor significa lo mismo
para las dos instancias.

⚠️ Ojo con una asimetría que se sigue de eso: `percent=0` **no** quiere decir "nadie cruza". Para la
instancia de **OpenShift** es el estado que no depende del peer —el servicio está del mismo lado que
quien llama—, pero para la de **EKS** significa que todo su tráfico cruza a OpenShift, así que ahí sí
necesita el peer arriba. Quien no depende del peer del lado de EKS es `percent=100`.

### A mano, sin `demo.sh`

```bash
SPEC=$("$NP_API" fetch-api "/service_specification?nrn=$APP_NRN&type=dependency" \
  | jq -r --arg n "Migrador de tráfico service-to-service a EKS" \
       '.results[]|select(.slug=="egress-interceptor" or .name==$n)|.id')
CREATE_SPEC=$("$NP_API" fetch-api "/service_specification/$SPEC/action_specification" \
  | jq -r 'if type=="array" then .[] else .results[] end | select(.type=="create")|.id')

ID=$(np service create --body="$(jq -n --arg sp "$SPEC" --arg nrn "$APP_NRN" --arg scope "$SCOPE" '{
  name:"egress-eks", specification_id:$sp, entity_nrn:$nrn, linkable_to:[$nrn], dimensions:{},
  attributes:{cluster:"eks", interceptions:[{
    service_name:"reports",
    scope:$scope,
    percent:0}]}}')" --query '.id')

np service action create --serviceId="$ID" --body="$(jq -n --arg sp "$CREATE_SPEC" --arg scope "$SCOPE" '{
  name:"create-egress-eks", specification_id:$sp,
  parameters:{cluster:"eks", interceptions:[{
    service_name:"reports",
    scope:$scope,
    percent:0}]}}')"
```

⚠️ **Si un create falla, la instancia queda en `failed` y ocupa el nombre.** La API sólo acepta
acciones de tipo `create` sobre instancias en `pending`, así que no se puede reintentar: hay que
borrarla y volver a crear. Y la API key del repo **no tiene permiso** para borrar instancias en
`pending`/`failed` (da 403) — para eso hace falta un token de usuario o la consola.

⚠️ El atributo **`cluster` es temporal**. Existe sólo para que el channel elija agente, y muere
cuando exista una dimension que lo represente. Ningún script del service lo lee.

### Los identificadores

No hay ningún ID pegado en este runbook. Las instancias **las crea el Paso 12**, así que sus IDs
cambian cada vez que se levanta la demo de cero; y el `specification_id` de la acción también, si
alguien republica el spec. Todo se resuelve por nombre:

```bash
APP_NRN="organization=1636958496:account=1374028000:namespace=824774832:application=142495574"

# ID de cada instancia, por nombre
EKS_INSTANCE=$("$NP_API" fetch-api "/service?nrn=$APP_NRN" \
  | jq -r '.results[]|select(.name=="egress-eks")|.id')
CRC_INSTANCE=$("$NP_API" fetch-api "/service?nrn=$APP_NRN" \
  | jq -r '.results[]|select(.name=="egress-crc")|.id')

# ID del service_specification. Se acepta el slug viejo O el nombre: el slug lo fija la
# API al crear y no sigue al rename, así que un registro nuevo va a tener otro.
SPEC=$("$NP_API" fetch-api "/service_specification?nrn=$APP_NRN&type=dependency" \
  | jq -r --arg n "Migrador de tráfico service-to-service a EKS" \
       '.results[]|select(.slug=="egress-interceptor" or .name==$n)|.id')

# ID de la action spec de update, que es la que dispara el reconcile
UPDATE_SPEC=$("$NP_API" fetch-api "/service_specification/$SPEC/action_specification" \
  | jq -r 'if type=="array" then .[] else .results[] end | select(.type=="update")|.id')

# El scope destino en EKS ya viene exportado del Paso 0. NO es un id: la regla guarda el slug y
# el service resuelve el FQDN.
"$NP_API" fetch-api "/scope?nrn=$APP_NRN" | jq -r '.results[]|select(.status=="active")|"\(.slug)\t\(.domain)"'

echo "eks=$EKS_INSTANCE  crc=$CRC_INSTANCE  update=$UPDATE_SPEC  scope=$SCOPE"
```

Un scope con `domain: "To be defined"` está creado pero **sin desplegar**: el reconcile lo rechaza
en vez de rendir un `HTTPRoute` hacia un hostname inválido.

Si alguno sale vacío, la instancia no existe: volvé al Paso 12.

**En el body no va ninguna dirección.** La regla declara un **scope** —dónde corre `reports` del
lado EKS— y el service resuelve su FQDN con `np scope list`. La dirección del Kuadrant remoto, por
donde sale todo lo migrado, es configuración del workflow (`PEER_GATEWAY_HOST`), no un campo del
form.

El slug ya está exportado desde el Paso 0 (`SCOPE=eks`). Para ver los disponibles:

```bash
"$NP_API" fetch-api "/scope?nrn=$APP_NRN" | jq -r '.results[]|select(.status=="active")|"\(.slug)\t\(.domain)"'
```

⚠️ `np scope list` del CLI da **403** con la API key del repo — usá el helper de la API.

⚠️ Si el scope no existe o todavía no está desplegado (`domain: "To be defined"`), el reconcile
**aborta y te dice cuáles hay**. Es a propósito: dejarlo pasar rendiría un `HTTPRoute` apuntando a
un hostname inválido sin que nada se queje.

**Configurar es UNA sola llamada:** `np service action create`. Genera la notificación que el
agente consume y es lo único que dispara el reconcile.

No hace falta un `np service patch` previo: los `parameters` de la acción **pisan** a los
attributes guardados, y cuando la acción termina OK la API persiste los attributes sola. Hacer el
patch antes es peor, además: la consola mostraría el valor nuevo aunque la acción fallara.

Cada regla lleva **tres** campos y ninguno más:

| Campo | Qué es |
|---|---|
| `service_name` | la dirección de `reports` del lado **OpenShift**: un Service, este-oeste |
| `scope` | su dirección del lado **EKS**: un scope, del que sale el FQDN |
| `percent` | qué **% del tráfico se atiende en EKS**. `0` = todo en OpenShift, `100` = todo en EKS |

La regla describe **el servicio**, no la topología del que llama — por eso la misma sirve para los
dos orígenes. `percent` responde siempre a la misma pregunta, *"¿cuánto de este servicio ya se
atiende en EKS?"*, y no cambia de significado según desde dónde se lo invoque. Que eso implique
cruzar o no cruzar lo decide dónde corre el que llama, no el form.

### Los cuatro escenarios de un vistazo

La columna **Atiende** es el `cluster` que devuelve `/whoami`: lo reporta la app que sirvió el
request, así que es la comprobación directa de en qué sustrato terminó.

| # | `reports` está… | Llamador en | Instancia | `percent` | Agente | Atiende (`cluster` del body) |
|---|---|---|---|---|---|---|
| 13 | ya migrado a EKS | EKS | `egress-eks` | `100` | **eks** | `eks-kuadrant` — no cruza |
| 14 | todavía en OpenShift | EKS | `egress-eks` | `0` | eks | `crc-openshift` — cruza |
| 15 | todavía en OpenShift | OpenShift | `egress-crc` | `0` | **crc** | `crc-openshift` — no cruza |
| 16 | ya migrado a EKS | OpenShift | `egress-crc` | `100` | crc | `eks-kuadrant` — cruza |

Leída así la matriz se explica sola: **`percent` dice dónde vive el servicio y el llamador dice si
eso implica cruzar.** Los dos escenarios que no cruzan son aquellos en los que el servicio ya está
del mismo lado que quien lo invoca.

**El body es el mismo en los cuatro**: mismo `service_name`, mismo `scope`. Lo único que cambia
entre escenarios es `percent` y sobre qué instancia se dispara.

Eso no es una simplificación de la demo, es el modelo: la rama migrada va **siempre** al sustrato
opuesto, y "mismo sustrato" no es un destino sino la **rama local**, o sea `percent = 0`. Por eso
el header de ruteo se deriva del origen y no hace falta declararlo:

| Origen | Lo migrado corre en | Header |
|---|---|---|
| EKS | OpenShift → rutea por nombre de Service | `X-NP-SVC` |
| OpenShift | nullplatform → rutea por scope | `X-NP-Scope` |

**El orden está elegido para cambiar de agente una sola vez.** Los escenarios se agrupan por cluster
de **origen**, que es el que corre el reconcile: los dos de origen EKS primero (12 y 13), después los
dos de origen OpenShift (14 y 15). El único cambio de agente cae entre el 13 y el 14.

Los dos barridos de `percent` siguen la misma regla: el **16** es de origen EKS y el **17** de origen
OpenShift. Leído de corrido el runbook te hace cambiar de agente tres veces (12·13 → 14·15 → 16 →
17); si preferís uno solo, corré **12 · 13 · 16** con el agente de EKS y después **14 · 15 · 17** con
el de CRC.

---

> ⚠️ **Los pasos 12, 13, 15, 16 y 17 necesitan un scope desplegado en EKS.**
> El destino del lado EKS ya no es el Service `reports` del layer de Terraform sino el FQDN de un
> scope, y al 2026-08-25 no hay ninguno desplegado. Sin eso:
> - el reconcile **aborta** al resolver el slug (falla ruidosa, con la lista de los que hay);
> - `tofu plan` de `clusters/eks` **falla** por la precondition de `scope_backends`, que existe para
>   que la `AuthPolicy` del ingreso no deje de enforcear en silencio (Gotcha #22).
>
> El **Paso 15** es el único que corre sin eso: origen OpenShift con `percent=0`, todo este-oeste.
>
> Para destrabarlo: desplegar un scope de `reports` en EKS, poner su `domain` en `scope_backends`
> de `clusters/eks/terraform.tfvars`, aplicar, y exportar `SCOPE=<slug>`.

## Paso 13 — Escenario A: `reports` ya en EKS (`percent=100`), llamador en EKS

**Qué prueba:** que la intercepción es **transparente**. El request sale del pod, atraviesa el Gateway
de egreso —que le acuña el token igual— y se atiende sin cruzar al otro sustrato. Es el estado
seguro: no depende de que el peer esté arriba, y es donde arranca y vuelve toda migración.

⚠️ **"No cruzar" en EKS NO significa "se queda en un Service del cluster".** En EKS no hay tráfico
por `svc.cluster.local`: la rama que atiende EKS es el **FQDN del scope**, o sea norte-sur contra el
ingreso de la plataforma. Es el mismo destino al que llegaría cualquier caller, y su `HTTPRoute` es
el que reparte entre los deployments del scope (blue/green). El que sí tiene rama local este-oeste
—el Service `reports-local`— es OpenShift: eso se ve en el Paso 15.

Lo que este paso **no** ejercita: nada del ingreso S2S. Acá el request no atraviesa ningún
`s2s-ingress` del otro cluster, así que no hay validación de identidad ni ruteo por header en este
camino. Eso se ejercita en el Paso 14.

Todos los escenarios tienen la misma forma de cinco actos. Acá va explícito; en los siguientes se
repite igual, cambiando sólo el cluster de origen y el `percent`.

### 1. Configurar

```bash
np service action create --serviceId "$EKS_INSTANCE" --body '{
  "name": "update-manual",
  "specification_id": "'"$UPDATE_SPEC"'",
  "parameters": {
    "interceptions": [{
      "service_name": "reports",
      "scope":        "'"$SCOPE"'",
      "percent":      100
    }]
  }
}'
```

Es **una sola** llamada: la acción genera la notificación que el agente consume, y cuando termina OK
la API persiste los `attributes` sola. No hace falta un `np service patch` previo — los `parameters`
de la acción pisan a los attributes guardados.

Los escenarios que siguen repiten esta misma llamada cambiando sólo `--serviceId` y `percent` — la
fila de la tabla del Paso 12.

### 2. Esperar a que el reconcile aterrice de verdad

```bash
esperar_local "$EKS" "$CRC"
```

**No te saltees este paso ni lo reemplaces por `rollout status`.** `esperar_local` no vuelve hasta que
un request real llegue con `x-egress-gateway` y **sin** `x-s2s-cluster`: o sea que pasó por el Gateway
de egreso y se atendió local. Es lo que hay que confirmar, y por eso no sirve mirar sólo el objeto: el
`HTTPRoute` se actualiza al instante y la programación del Envoy va detrás.

Ojo con la asimetría de los dos helpers: en los escenarios que cruzan se usa `esperar`, cuyo criterio
es la **presencia** de `x-s2s-cluster` con el valor del cluster que tiene que atender. Acá el criterio
es justamente el contrario.

A mano, si querés ver el objeto y el request:

```bash
kubectl --context "$EKS" -n payments get httproute s2s-egress-reports \
  -o jsonpath='{.spec.rules[0].filters[0].requestHeaderModifier.set}{"\n"}{.spec.rules[0].backendRefs}{"\n"}'
kubectl --context "$EKS" exec -n payments deploy/ledger -- \
  wget -S -qO- --timeout=15 http://reports.payments.svc.cluster.local:8080/whoami 2>&1 \
  | tr -d '\r' | grep -iE '^ *x-(s2s-cluster|egress-gateway):'
```

⚠️ La `AuthPolicy` del egreso es un **punto único de falla del camino de la app**: si su `AuthConfig`
no reconcilia, el `ext_authz` falla cerrado y el namespace deja de responder, aunque el destino no
tenga nada que ver. Por eso el reconcile no desvía el tráfico hasta ver `Enforced=True`:

```bash
kubectl --context "$EKS" -n payments get authpolicy s2s-egress \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
# → Accepted=True Enforced=True     ← Accepted solo NO alcanza
```

### 3. Anclar el contador del validador

```bash
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

Se ancla **antes** del request. Contar con ventana relativa (`--since=20m`) puede dar un falso
negativo: si una línea vieja sale de la ventana justo cuando entra una nueva, el número no cambia.

### 4. El request, explícito

Entrá al pod de la app y pegale al Service interceptado, que es lo que haría el negocio:

```bash
kubectl --context "$EKS" exec -n payments deploy/ledger -- \
  wget -S -qO- --timeout=25 http://reports.payments.svc.cluster.local:8080/whoami 2>&1 | tr -d '\r'
```

- `deploy/ledger` — la app cliente, un pod cualquiera de `payments`.
- `reports.payments.svc.cluster.local:8080` — el Service **interceptado**. La app le pega al nombre
  de siempre; el reconcile le robó el selector para que apunte al interceptor.
- `wget -S` imprime los headers de respuesta, que es donde está la traza.

### 5. Revisar la respuesta: body, status y headers

**Body:**

```json
{"service":"reports","namespace":"payments","cluster":"crc-openshift","pod":"reports-…","vpc_ip":"10.217.0.67","spoke":null}
```

⚠️ **El campo `cluster` del body es la respuesta directa a "¿cruzó o no?".** Lo reporta la app que
efectivamente atendió, así que dice qué sustrato sirvió el request sin depender de ningún header:

| valor | quién atendió |
|---|---|
| `crc-openshift` | OpenShift (CRC) |
| `eks-kuadrant` | EKS |

Es la señal más fuerte del paso: `pod` y `vpc_ip` además identifican la instancia exacta, lo que
hace visible el reparto del blue/green cuando el destino es un scope de EKS.

⚠️ **`x-s2s-cluster` no llega cuando el destino es EKS.** Ese header lo estampa *nuestro*
`HTTPRoute` de ingreso, que existe sólo del lado OpenShift, así que acá la evidencia de quién
atendió es el `cluster` del body — y sale de `CLUSTER_NAME`, que el layer inyecta en la app con el
valor de `cluster_label` (`modules/kuadrant-s2s/workloads.tf`). En EKS es `eks-kuadrant`.

**Status:** `HTTP/1.1 200 OK`

**Headers** — los cuatro que importan a lo largo de todos los escenarios. En **este** paso llega sólo
el primero, y eso es el resultado correcto:

| Header | Valor esperado | Quién lo pone | ¿en el Paso 13? |
|---|---|---|---|
| `x-egress-gateway` | `s2s-egress.payments` | el Envoy del **origen**: prueba que el request pasó por el Gateway de egreso del namespace | **sí** |
| `x-egress-route` | `inbound` | el `HTTPRoute` del **ingreso** del destino: el request cruzó | no |
| `x-egress-target` | en EKS el FQDN del scope; en OpenShift `reports-local.payments.svc.cluster.local` | destino: a qué backend entregó | no |
| `x-s2s-cluster` | `crc-openshift` | destino: qué cluster atendió. **Sólo llega desde OpenShift** — ver abajo | no |

Los tres últimos los pone el **ingreso**, y con `percent=0` el request no atraviesa ninguno.

Todos llegan en minúscula: Envoy normaliza los nombres de header. Si comparás, bajá el case primero.

⚠️ **`x-s2s-cluster` NO llega cuando el destino es EKS, y no es una falla.** Ese header lo estampa
*nuestro* `HTTPRoute` del ingreso, que existe sólo en OpenShift. Hacia EKS se entra por el
`HTTPRoute` del **propio scope** —el que lleva los pesos del blue/green y el nombre del backend de
turno—, y ése lo maneja la plataforma: no sella nada. Entrar por ahí es justamente lo que evita
tener que actualizar el service en cada despliegue.

Para el caso EKS eso deja dos confirmaciones, y conviene leer las dos:

1. **El `cluster` del body** (`eks-kuadrant`) — quién atendió. Directo y sin ambigüedad.
2. **El contador de Authorino del destino** — que el validador del otro lado **autorizó**. Es lo
   que usan `esperar` y `esperar_local`.

Son preguntas distintas: la primera dice dónde se sirvió, la segunda que se validó la identidad al
entrar. Un 200 servido en EKS con el contador quieto significaría que se entró sin pasar por el
validador, que es exactamente lo que este diseño tiene que impedir.

El `HTTPRoute` se actualiza al instante pero la programación del Envoy va detrás, así que puede haber
unos segundos en que el objeto ya declara el destino nuevo y el proxy todavía sirve el anterior. Si el
`x-s2s-cluster` no es el que configuraste, esperá unos segundos y repetí: no es un fallo del escenario.

### 6. La evidencia: quién acuñó y quién validó

Con el OpenResty afuera, las dos puntas son decisiones de **Authorino**: la del origen acuña el
wristband, la del destino lo valida. Antes la evidencia era asimétrica —un log de Lua contra un log de
Authorino— y las dos mitades no se podían comparar.

```bash
# el Authorino del ORIGEN, que es el que acuña
desde "$EKS" "$T0"
```

**Qué tenés que ver:** un número que **avanzó** respecto del que tomaste antes del request, en **1**
por request.

⚠️ **Acá hay UNA sola decisión, no dos.** La `AuthPolicy` cuelga del Gateway y no de la rama, así que
el token se acuña igual — pero como el request no cruza, nunca llega al ingreso del otro cluster y
**nadie lo valida**. Las dos decisiones por request (acuñar + validar) aparecen recién cuando el
request cruza, y ahí son **1 de cada lado**: Paso 14.

**El contador es la prueba de que hubo decisión Y de dónde**: cada cluster tiene su propio
Authorino, así que un incremento en el del destino sólo puede venir de un request que llegó ahí.
Un 200 solo no alcanza: puede venir de un Envoy que todavía sirve la configuración anterior.

Los dos flags del `logs` no son decorativos: con `-l` (selector en vez de nombre de pod) `kubectl`
trunca a **10 líneas por pod** salvo que le pases `--tail=-1`, y durante un reconcile puede haber
dos pods con el label — el nuevo todavía en `PodInitializing` —, caso en el que sin `--ignore-errors`
el comando falla entero en vez de devolverte el log del pod que sí está sirviendo.

**Atajo del repo:** `NP_API="$NP_API" ./demo.sh esc1`

---

## Paso 14 — Escenario B: `reports` sin migrar (`percent=0`), llamador en EKS → cruza a OpenShift

**Qué prueba:** que el header de ruteo lo decide el destino — hacia OpenShift viaja `X-NP-SVC` en vez
de `X-NP-Scope`, y el resto del contrato no cambia.

Seguís con el **mismo agente de EKS** del Paso 13: no toques nada en la otra terminal.

**1. Configurar** — la instancia de **EKS**. Lo único que cambia contra el Paso 13 es el `percent`:
al bajarlo a **0** se declara que `reports` **todavía no está migrado**, así que lo que antes se
atendía en el FQDN del scope ahora cruza a OpenShift, que es donde sigue viviendo el servicio.

```bash
np service action create --serviceId "$EKS_INSTANCE" --body '{
  "name": "update-manual",
  "specification_id": "'"$UPDATE_SPEC"'",
  "parameters": {
    "interceptions": [{
      "service_name": "reports",
      "scope":        "'"$SCOPE"'",
      "percent":      0
    }]
  }
}'
```

**2 a 5:**

```bash
esperar "$EKS" 's2s-remote-gateway' "$CRC"

T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)

kubectl --context "$EKS" exec -n payments deploy/ledger -- \
  wget -S -qO- --timeout=25 http://reports.payments.svc.cluster.local:8080/whoami 2>&1 | tr -d '\r'

# decide CRC (el destino)
kubectl --context "$CRC" -n kuadrant-system logs deploy/authorino --since-time="$T0" \
  | grep -c "outgoing authorization response"
desde "$EKS" "$T0"    # decisiones del ORIGEN: acuñó el wristband
desde "$CRC" "$T0"    # decisiones del DESTINO: lo validó
```

**Qué tenés que ver:** `200`, `x-s2s-cluster: crc-openshift` (acá sí llega: el destino es
OpenShift) y los dos contadores en `1` — acuñó EKS, validó CRC.

Si el contador de CRC da `0`, no cruzó — sin importar el código de respuesta. Empezá por el **Paso 3**
(higiene del tailnet) y seguí por el Apéndice C.

Un `502` justo después del reconcile suele ser el pod nuevo todavía calentando el hop: repetí el
request una vez.

**Atajo:** `NP_API="$NP_API" ./demo.sh esc3`

---

## Paso 15 — Escenario C: `reports` sin migrar (`percent=0`), llamador en OpenShift → no cruza

**Qué prueba:** el espejo del Paso 13 del lado on-prem — que la intercepción es transparente también
con el flavour OpenShift de Istio (CNI sobre multus, SCC, UID 1337), sin tocar la red entre clusters.
**`demo.sh` no tiene este escenario**, así que no hay atajo.

Acá va el **único cambio de agente** del recorrido: bajá el de EKS y levantá el de CRC (Paso 1).
De acá hasta el Paso 16 no se vuelve a tocar.

**1. Configurar** — la instancia de **CRC**, destino el ingreso local del propio CRC:

```bash
np service action create --serviceId "$CRC_INSTANCE" --body '{
  "name": "update-manual",
  "specification_id": "'"$UPDATE_SPEC"'",
  "parameters": {
    "interceptions": [{
      "service_name": "reports",
      "scope":        "'"$SCOPE"'",
      "percent":      0
    }]
  }
}'
```

**2 a 5:**

```bash
esperar_local "$CRC" "$EKS"

T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)

kubectl --context "$CRC" exec -n payments deploy/ledger -- \
  wget -S -qO- --timeout=25 http://reports.payments.svc.cluster.local:8080/whoami 2>&1 | tr -d '\r'

kubectl --context "$CRC" -n kuadrant-system logs deploy/authorino --since-time="$T0" \
  | grep -c "outgoing authorization response"
```

**Qué tenés que ver:** `200`, **sin** `x-s2s-cluster` —se atendió local, no cruzó— y el contador de
**CRC** en `1`: se acuñó el token y nadie lo validó, igual que en el Paso 13.

Piezas verificadas de este escenario:

| Pieza | Verificación | Resultado |
|---|---|---|
| El `Gateway` de egreso levanta con el flavour OpenShift | `Programmed=True` + deploy `Available` | ✅ |
| La `AuthPolicy` de CRC enforcea (si no, el ns entero cae) | `Enforced=True` | ✅ |
| El Service `reports` quedó hijackeado y `reports-local` sirve | selector + endpoints | ✅ |
| Kuadrant de CRC enforcea en el ingreso | Paso 7 | ✅ |

Si falla, mirá el access log del Gateway de egreso de CRC antes de sospechar del contrato de
identidad: en este camino el contrato de identidad **no participa**.

**Por qué vale la pena aunque no esté en el relato de la demo:** es el único escenario que ejercita el
stack de egreso **con el flavour OpenShift de Istio** sin meter la red entre clusters. Si este anda y
el 15 falla, quedó probado que el problema es transporte y no el stack de OpenShift.

---

## Paso 16 — Escenario D: `reports` migrado (`percent=100`), llamador en OpenShift → cruza a EKS

**Qué prueba:** la topología real de la migración — origen on-prem, destino cloud. El token lo valida
la regla del *peer*, con la clave que viajó por el overlay.

Seguís con el **mismo agente de CRC** del Paso 15.

**1. Configurar** — la instancia de **CRC**, destino EKS por el overlay:

```bash
np service action create --serviceId "$CRC_INSTANCE" --body '{
  "name": "update-manual",
  "specification_id": "'"$UPDATE_SPEC"'",
  "parameters": {
    "interceptions": [{
      "service_name": "reports",
      "scope":        "'"$SCOPE"'",
      "percent":      100
    }]
  }
}'
```

**2 a 5** — esperar el render nuevo con un pod Ready en endpoints, anclar, pegar y mirar la evidencia:

```bash
# 2. esperar el render nuevo con un pod Ready en endpoints
esperar "$CRC" 's2s-remote-gateway' "$EKS"

# 3. anclar
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 4. el request, desde la app de OpenShift
kubectl --context "$CRC" exec -n payments deploy/ledger -- \
  wget -S -qO- --timeout=25 http://reports.payments.svc.cluster.local:8080/whoami 2>&1 | tr -d '\r'

# 5. evidencia: decide EKS (el destino), firma CRC (el origen)
kubectl --context "$EKS" -n kuadrant-system logs deploy/authorino --since-time="$T0" \
  | grep -c "outgoing authorization response"
desde "$CRC" "$T0"    # decisiones del ORIGEN: acuñó el wristband
desde "$EKS" "$T0"    # decisiones del DESTINO: lo validó
```

**Qué tenés que ver:**

```
HTTP/1.1 200 OK
  x-egress-gateway: s2s-egress.payments                               ← salió por el Gateway de egreso
{"cluster":"eks-kuadrant",...}                                        ← atendió EKS, o sea cruzó
1                                                                     ← EKS decidió
1                                                                     ← el origen (CRC) acuñó
1                                                                     ← el destino (EKS) validó
```

⚠️ **Acá NO llegan `x-s2s-cluster` ni `x-egress-target`, y no es una falla.** Los dos los estampa
*nuestro* `HTTPRoute` de ingreso, que existe sólo del lado OpenShift; con destino EKS el request
entra por el `HTTPRoute` del propio scope, que no sella nada. Mismo criterio que el Paso 13.

⚠️ **El egreso manda UN solo header de ruteo, derivado del origen.** Con origen OpenShift viaja
`X-NP-Scope`; con origen EKS, `X-NP-SVC`. Nunca los dos: con los dos puestos, el análisis de tráfico
por headers no distinguiría el sentido del salto. Como lo migrado corre siempre en el sustrato
opuesto al origen, el header se deriva del origen y nadie tiene que declarar en qué sustrato corre el
destino.

Y quién atendió se lee en el `cluster` del body (o en el contador de Authorino del destino), no en el
header de ruteo: ése dice a qué servicio va, no a qué cluster llegó.

⚠️ **El primer request cross-cluster después de que arranca Authorino da 500.** El JWKS del peer se
trae por demanda y ese fetch cruza el overlay. Tirá uno, descartalo y repetí. El log dice
`UNAVAILABLE`, que **no** es "token inválido".

**Atajo:** `NP_API="$NP_API" ./demo.sh esc2`

---

## Paso 17 — La perilla de migración (`percent`), desde EKS

**Qué valida:** que se pueda mover tráfico de a poco y volver atrás sin destruir nada. Acá el origen
es EKS, así que la parte migrada la atiende **OpenShift** — el sentido inverso al de la migración
real. El **Paso 18** corre la misma perilla con origen OpenShift y destino EKS, que es el que le
importa al Banco.

Con el **agente de EKS**. Explícito, punto por punto:

Es la misma llamada del Paso 13 — misma instancia, mismo destino — con `percent` como única
variable, así que acá el body lo arma `jq` para interpolar `$pct` sin romper el JSON:

```bash
for pct in 0 50 100; do
  np service action create --serviceId "$EKS_INSTANCE" --body "$(jq -n --argjson pct "$pct" --arg scope "$SCOPE" '{
    name: "update-manual",
    specification_id: "'"$UPDATE_SPEC"'",
    parameters: {
      interceptions: [{
        service_name: "reports",
        scope:        $scope,
        percent:      $pct
      }]
    }
  }')"

  # Acá NO sirve `esperar`: su confirmación es que un request vuelva con `x-s2s-cluster`, y con
  # percent=0 justamente no tiene que volver con eso. Se espera sobre el peso del HTTPRoute y
  # después se deja asentar la programación del Envoy.
  for i in $(seq 1 60); do
    kubectl --context "$EKS" -n payments get httproute s2s-egress-reports \
      -o jsonpath='{.spec.rules[0].backendRefs[*].weight}' 2>/dev/null | grep -qw "$pct" && break
    sleep 5
  done
  sleep 8
  echo "── percent=$pct"
  # Se cuenta el `cluster` que reporta la app QUE ATENDIÓ. Es la señal más directa: no la pone un
  # proxy sobre lo que cree haber hecho, la pone el proceso que sirvió el request. Y a diferencia
  # de `x-s2s-cluster`, funciona en las dos direcciones (ese header sólo lo estampa OpenShift).
  kubectl --context "$EKS" exec -n payments deploy/ledger -- sh -c \
    'for i in $(seq 1 20); do
       wget -qO- --timeout=10 http://reports.payments.svc.cluster.local:8080/whoami 2>/dev/null \
         | tr "," "\n" | grep cluster || echo sin-respuesta
     done' | sort | uniq -c
done
```

**Qué tenés que ver** (valores medidos, 20 requests por punto):

La salida son los `cluster` que reportaron las apps que atendieron, contados:

| `percent` | `"cluster":"crc-openshift"` (sigue en OpenShift) | `"cluster":"eks-kuadrant"` (ya en EKS) |
|---|---|---|
| 0 | 20 | 0 |
| 50 | ~11 | ~9 |
| 100 | 0 | 20 |

El reparto lo hace Envoy con `backendRefs[].weight`, así que con 50 la proporción es aproximada, no
exacta: **medido 9/20 remotos** en la corrida del 24/08. Antes lo sorteaba el interceptor por request;
el resultado observable es equivalente y los valores de referencia siguen valiendo.

⚠️ **Con origen EKS, `local` no significa "se quedó en un Service del cluster".** Significa que el
request fue al **FQDN del scope** —norte-sur, contra el ingreso de la plataforma— en vez de cruzar a
OpenShift. La sonda es la misma porque ese camino tampoco atraviesa `s2s-ingress`, así que tampoco
lleva `x-s2s-cluster`. La rama local este-oeste, con el Service `reports-local`, sólo existe del lado
OpenShift: eso es lo que mide el **Paso 18**.

**Reversibilidad:** `percent = 0` deja todo local sin destruir nada. Y borrar la instancia dispara el
`delete`, que restaura el selector del Service desde la annotation
`egress-interceptor/original-selector` y elimina el `Gateway`, la `AuthPolicy`, la `HTTPRoute` y el
`DestinationRule` — y también el alias `-local` y la route de ingreso de OpenShift, que desde el
2026-08-26 los crea el propio service y no el layer de Terraform.

**Atajo:** `NP_API="$NP_API" ./demo.sh barrido`

---

## Paso 18 — La misma perilla, desde OpenShift

**Qué valida:** el barrido que le importa al Banco. El Paso 17 mueve tráfico en el sentido inverso
—origen EKS, y lo migrado lo atiende OpenShift—; acá el origen es **on-prem** y el destino es
**cloud**, así que `percent` es literalmente el dial de la migración: cuánto de `reports` sigue
atendiéndose en OpenShift y cuánto ya lo atiende EKS.

Con el **agente de CRC**, así que va pegado al Paso 16 — misma instancia y mismo destino que ese
paso, con `percent` como única variable.

⚠️ **Con `percent < 100` el destino local tiene que tener endpoints.** El reconcile lo chequea y
**aborta** (`'reports' tiene percent=N (<100) pero su destino local no tiene endpoints`) en vez de
mandar una fracción del tráfico a un backend vacío. En OpenShift es donde más pasa: si los pods de
`reports` quedaron trabados en `Init` por el Gotcha #23, el barrido falla en el primer punto.
Comprobalo antes de arrancar:

```bash
kubectl --context "$CRC" -n payments get endpoints reports-local reports
```

```bash
for pct in 0 50 100; do
  np service action create --serviceId "$CRC_INSTANCE" --body "$(jq -n --argjson pct "$pct" --arg scope "$SCOPE" '{
    name: "update-manual",
    specification_id: "'"$UPDATE_SPEC"'",
    parameters: {
      interceptions: [{
        service_name: "reports",
        scope:        $scope,
        percent:      $pct
      }]
    }
  }')"

  case $pct in
    0|*) for i in $(seq 1 60); do
         kubectl --context "$CRC" -n payments get httproute s2s-egress-reports \
           -o jsonpath='{.spec.rules[0].backendRefs[*].weight}' 2>/dev/null | grep -qw "$pct" && break
         sleep 5
       done; sleep 8 ;;
  esac
  echo "── percent=$pct"
  kubectl --context "$CRC" exec -n payments deploy/ledger -- sh -c \
    'for i in $(seq 1 20); do
       wget -qO- --timeout=10 http://reports.payments.svc.cluster.local:8080/whoami 2>/dev/null \
         | tr "," "\n" | grep cluster || echo sin-respuesta
     done' | sort | uniq -c
done
```

**Qué tenés que ver** — la misma forma que el Paso 17, sólo que acá `remoto` significa *lo atendió
AWS*:

**La tabla es idéntica a la del Paso 17, y eso es exactamente lo que prueba el paso:** `percent`
significa lo mismo desde los dos orígenes. Lo único que cambia es cuál de las dos columnas implica
cruzar de sustrato — desde OpenShift es la de EKS, desde EKS es la de OpenShift.

| `percent` | `"cluster":"crc-openshift"` (sigue en OpenShift) | `"cluster":"eks-kuadrant"` (ya en EKS) |
|---|---|---|
| 0 | 20 | 0 |
| 50 | ~10 | ~10 |
| 100 | 0 | 20 |

⚠️ **Este paso medía mal hasta el 2026-08-27.** Contaba la presencia de `x-s2s-cluster`, y ese
header lo estampa **sólo el ingreso de OpenShift**. Acá el destino es EKS, donde se entra por el
`HTTPRoute` del propio scope, que no sella nada — así que el header **no llega nunca**, cruce o no
cruce. Verificado: 8 requests con la instancia en `percent=50`, 5 atendidos por `eks-kuadrant` y ninguno
con el header. Con ese método el barrido daba `20 local` en los tres puntos y la tabla de arriba era
inalcanzable.

El `cluster` del body lo escribe el proceso que sirvió el request, así que funciona en las dos
direcciones y no depende de que ningún proxy agregue nada. Un request que falla sale como
`sin-respuesta` en vez de contarse como rama local. Para separar 200 de 5xx igual conviene el
status:

```bash
kubectl --context "$CRC" exec -n payments deploy/ledger -- sh -c \
  'for i in $(seq 1 20); do
     wget -S -qO- --timeout=10 http://reports.payments.svc.cluster.local:8080/whoami 2>&1 \
       | grep -o "HTTP/1.1 [0-9]*"
   done' | sort | uniq -c
```

⚠️ **El primer request cross-cluster puede dar 500** si Authorino de EKS todavía no se trajo el JWKS
del peer (mismo caso del Paso 16). Descartá el primero y repetí el punto.

**La lectura para el Banco:** `percent = 0` es "todo sigue on-prem", `100` es "ya está todo en AWS" —y eso vale para los dos orígenes—, y
cualquier valor intermedio es la ventana de convivencia. La vuelta atrás es poner `0` de nuevo — no
hay que redeployar nada ni tocar la app, que le sigue pegando a `reports.payments.svc.cluster.local`
en los tres casos.

**Sin atajo:** `demo.sh barrido` corre sólo el del Paso 17 (instancia de EKS).

---

## Paso 19 — Limpieza

**Qué valida:** que el `delete` devuelva el namespace al estado original. No es sólo higiene: es
la mitad reversible de la migración, y si no funciona el `percent` deja de ser una perilla.

```bash
NP_API="$NP_API" ./demo.sh borrar eks
NP_API="$NP_API" ./demo.sh borrar crc
```

Va por la **acción** de delete, no por `np service delete`: la API rechaza el borrado directo
cuando el service tiene un delete action spec, justamente para que corra el workflow que revierte
el namespace. `--force` lo saltea y deja el Service hijackeado apuntando a un Gateway que ya no
existe, sin la annotation para recuperar el selector original.

**Qué tenés que ver, por cada uno:**

```
✓ delete disparado sobre egress-eks (…)
✓ el Service reports que inventó el interceptor se fue, junto con sus objetos
  alias reports-local: borrado
```

En **CRC** la salida es distinta, porque ahí `reports` sí preexiste:

```
✓ delete disparado sobre egress-crc (…)
✓ selector de reports restaurado y objetos del interceptor borrados
  alias reports-local: borrado
{"service":"reports","namespace":"payments","cluster":"crc-openshift","pod":"reports-…","vpc_ip":"10.217.0.67","spoke":null}
```

### Verificar que quedó limpio

```bash
"$NP_API" fetch-api "/service?nrn=$APP_NRN" \
  | jq -r '[.results[]|select(.name|startswith("egress"))]|length'
# → 0

# Lo que tiene que estar vacío en los DOS clusters: objetos del interceptor en payments, y su
# route de ingreso en el namespace del Gateway.
for CTX in "$EKS" "$CRC"; do
  echo "== $CTX"
  kubectl --context "$CTX" get gateway,httproute,authpolicy,destinationrule -n payments --no-headers
  kubectl --context "$CTX" get httproute -n gateways -l egress-interceptor/managed=true --no-headers
  kubectl --context "$CTX" get svc -n payments reports reports-local --no-headers 2>&1
done
```

Los Services de la última línea se leen distinto en cada cluster — ver el cuadro de abajo. En CRC
además tiene que volver a andar el tráfico directo:

```bash
kubectl --context "$CRC" exec -n payments deploy/ledger -- \
  wget -qO- --timeout=15 http://reports.payments.svc.cluster.local:8080/whoami
# → {"service":"reports","namespace":"payments","cluster":"crc-openshift","pod":"reports-…","vpc_ip":"10.217.0.67","spoke":null}
```

⚠️ **El estado limpio NO es el mismo en los dos clusters.** Es el punto que más confunde:

| | CRC (OpenShift) | EKS |
|---|---|---|
| Objetos del interceptor | **ninguno** | **ninguno** |
| Service `reports` | `{"app":"reports"}` — restaurado | **no existe** |
| `reports-local` | **borrado** | nunca existió |
| Route `s2s-ingress-reports` en `gateways` | **borrada** | nunca existió |
| Tráfico a `reports.payments.svc` | 200 con `"cluster":"crc-openshift"` | **falla, y está bien** |

El renglón de EKS es el contraintuitivo: **allá `reports` no es un servicio del namespace**. El
destino de EKS es el FQDN de un scope, norte-sur. El Service `reports` lo **inventa el interceptor**
para capturar el tráfico este-oeste que la app manda a ese nombre, así que cuando la intercepción se
va, el Service se va con ella. Verlo desaparecer es la señal de que quedó limpio, no de que se
rompió algo.

En **OpenShift** es al revés: `reports` es de la app y preexiste, así que tiene que volver con su
selector original. Lo que ahí sí desaparece es el alias `<svc>-local` y la route de ingreso — desde
el 2026-08-26 los crea el service junto con la intercepción, no el layer de Terraform, y por eso se
borran con ella.

### Bajar los agentes

```bash
pkill -f "np-agent -api-key"
```

Ya no hacen falta: el tráfico nunca los usó.

### Lo que NO se borra, a propósito

La PKI, los Gateway de **ingreso**, las NetworkPolicies, los Secrets de firma en `kuadrant-system`
y los workloads de la demo (`ledger`, `orders`, y `reports` sólo en CRC) son del layer de Terraform,
no del service. Bajar eso es un `destroy` de OpenTofu en `clusters/eks` y en `clusters/crc`, y
`crc stop` para apagar el OpenShift local.

⚠️ Con el Gateway de ingreso **sin ninguna route** colgando —que es el estado sin intercepciones—
Kuadrant no enforcea sobre él y su `AuthPolicy` figura como no-enforceada (Gotcha #22). Es esperable:
la route de ingreso ahora la trae la intercepción. No hay tráfico S2S que proteger en ese estado,
pero si mirás la `AuthPolicy` suelta, ese `Enforced=False` no es una falla.

---

## Apéndice A — Atajos de `demo.sh`

```bash
NP_API="$NP_API" ./demo.sh preflight        # sustrato + JWKS cruzado + qué agentes laten
NP_API="$NP_API" ./demo.sh crear  eks       # crea la instancia DESDE CERO  = Paso 12
NP_API="$NP_API" ./demo.sh crear  crc
NP_API="$NP_API" ./demo.sh estado           # instancias, gateways y agentes
NP_API="$NP_API" ./demo.sh aislamiento      # los 3 curls contra EKS        (sin agente)
NP_API="$NP_API" ./demo.sh aislamiento crc  # los 3 curls contra OpenShift  (sin agente)
NP_API="$NP_API" ./demo.sh esc1             # percent=100 desde EKS   = Paso 13
NP_API="$NP_API" ./demo.sh esc3             # EKS → OpenShift         = Paso 14
NP_API="$NP_API" ./demo.sh esc2             # OpenShift → EKS         = Paso 16
NP_API="$NP_API" ./demo.sh barrido          # percent 0/50/100 en EKS = Paso 17
NP_API="$NP_API" ./demo.sh borrar eks       # revierte el namespace         = Paso 19
NP_API="$NP_API" ./demo.sh borrar crc
```

⚠️ **Los nombres `esc1/esc2/esc3` quedaron con la numeración vieja**: `esc2` es el Paso 16 y `esc3`
el Paso 14. Guiate por el escenario, no por el número del atajo. Los Pasos 14 y 17 (los de origen
OpenShift que no cruzan) no tienen atajo.

⚠️ **El control positivo de `aislamiento crc` miente.** Muestra `HTTP 200` con veredicto
`✗ rechazado (PERMISSION_DENIED)`. Son dos artefactos sumados, ninguno del contrato de identidad:
la correlación con el log de Authorino es **temporal, no por request-id**, así que levanta la
decisión del 403 anterior; y `cmd_aislamiento` llama a `probe "$ctx"` sin pasar el contexto destino,
así que etiqueta el veredicto como OpenShift cuando `egress-crc` puede estar apuntando a EKS.

---

## Apéndice B — Fallas conocidas y cómo se ven

| Síntoma | Causa | Qué hacer |
|---|---|---|
| Todos los pasos de EKS fallan de golpe | sesión SSO vencida (`kubectl` saca el token con `aws eks get-token`) | `aws sso login --profile galicia-1` |
| `Error from server (NotFound): namespaces "payments" not found` | **`$EKS` o `$CRC` vacíos.** `kubectl --context ""` no falla: cae al `current-context` | `echo "EKS=[$EKS] CRC=[$CRC]"` y repetir el Paso 2 |
| Un contador de Authorino en `0` cuando debería tener historia | mismo caso: estás mirando otro cluster | idem |
| `clave: command not found` (o `mint`, `golpe`, `probe`, `n`) | los helpers se pierden al abrir otra terminal | repetir el Paso 5 completo |
| Primer request cross-cluster da **500** | el JWKS del peer se trae por demanda y ese fetch cruza el overlay | tirar uno y descartarlo. `UNAVAILABLE` **no** es "token inválido" |
| **404** en vez de 401/200 | header de ruteo equivocado para el sustrato destino | `X-NP-Scope` para EKS, `X-NP-SVC` para OpenShift |
| `200` pero ningún Authorino registra la decisión | el request no pasó por ningún Gateway; puede ser un pod con config anterior | esperar el pod nuevo (`esperar`) y revisar el Paso 3 |
| `wget: download timed out` / `exit 28` en el probe | el interceptor apunta a un destino inalcanzable | ver a dónde apunta (`kubectl -n payments get httproute s2s-egress-reports -o yaml`, sus `backendRefs`) y el Apéndice C |
| `FATAL … listen tcp :8182: bind: address already in use` | ya hay un `np-agent` corriendo | `pkill -f "np-agent -api-key"` y levantar **uno** |
| `ERROR: el current-context es '…', no 'crc-admin'` | `start-agent-crc.sh` usa `oc` contra el `current-context` | `kubectl config use-context crc-admin` |
| `ERROR: ninguna de las rutas de KUBECONFIG existe` | ninguna de las rutas de la lista apunta a un archivo real | `echo $KUBECONFIG` y dejar al menos una válida, o `unset KUBECONFIG` para usar `~/.kube/config` |
| `command not found in any allowed paths [~/.np]` en el log del agente | el `cmdline` del channel apunta al `~/.np` de **otra** máquina | ver abajo |
| En CRC no nace **ningún** pod nuevo | con uptime largo el pod de multus se queda con un token vencido — cluster-wide, y los cluster operators reportan todo sano | canario con `busybox`; si queda en `ContainerCreating`: `kubectl delete pod -n openshift-multus -l app=multus`, y reintentar unos minutos después |

### El `cmdline` del channel es propiedad de una laptop

Con `git_provider = "local"` y agente en runtime host, el módulo renderiza el path del entrypoint con
el `pathexpand("~/.np")` de la máquina que corre el apply. Consecuencia: **una sola laptop a la vez**
puede manejar la demo, y el handoff entre personas requiere un apply dirigido:

```bash
mkdir -p ~/.np/nullplatform-implementations
ln -s "$(git rev-parse --show-toplevel)" ~/.np/nullplatform-implementations/galicia-banco

cd accounts/galicia/nullplatform-bindings
tofu init -reconfigure -upgrade=false
tofu plan -var-file=../common.tfvars -var-file=./terraform.tfvars \
  -target=module.egress_interceptor_channel -out=chan.tfplan
tofu apply chan.tfplan
```

⚠️ **Ir dirigido, no completo.** El plan completo de ese layer hoy quiere **destruir 4 recursos del
Endpoint Exposer** (drift preexistente, coherente con que el exposer se haya movido a `galicia-3`) y
falla leyendo un remote state con perfil `galicia-3`.

---

## Apéndice C — El hop EKS → OpenShift: causa raíz

**Resuelto el 2026-08-20.** Se documenta porque el mecanismo se repite cada vez que alguien recrea
CRC o levanta la PoC en otra laptop.

**El síntoma:** con `egress-eks` en `kind=OS`, el request se firmaba en EKS, salía al overlay y **CRC
no registraba nada** — ni su access log de Envoy ni su Authorino. Según el momento, la respuesta era
un timeout o un `200` engañoso servido por un pod con configuración anterior.

**Causa, parte 1 — generaciones huérfanas ocupando el nombre canónico.** El operator de Tailscale
registra un device por proxy y **guarda su identidad en un Secret homónimo del pod**. Cada `crc
delete` + apply, o cada persona que levanta la PoC, deja un device huérfano con el nombre base; el
nuevo se registra con sufijo (`s2s-crc-ingress-1`). Los tfvars referencian el nombre **sin** sufijo.

Lo contraintuitivo: los huérfanos **seguían respondiendo** — `tailscale ping` daba `pong` y el hop
devolvía `401` en 1 s con headers de Authorino. Por eso la primera hipótesis ("device muerto") era
falsa y costó descartarla.

**Causa, parte 2 — el lado EKS cacheaba la IP del destino.** El proxy de egreso resuelve su
`TS_TAILNET_TARGET_FQDN` a una IP del tailnet al arrancar, y quien programa el forwarding es el
**operator**. Con el device destino recreado hay que reciclar los dos: el pod del proxy no alcanza.

**El fix** está en el Paso 3. La secuencia que lo resolvió, con sus salidas:

| Acción | Resultado |
|---|---|
| Borrar los 5 huérfanos | el hop pasó de `401` a **timeout** (exit 28) — confirmó que *eran ellos* los que atendían |
| Borrar sólo los pods de CRC | volvieron **con el mismo sufijo**: re-autentican con el node key de su Secret |
| Borrar Secret + pod | tomaron `s2s-crc-ingress` y `s2s-crc-jwks`, **sin sufijo** |
| Reciclar el proxy de egreso de EKS | pasó a `connection refused` (exit 7) — cambió el modo de falla |
| Reiniciar el operator de EKS | **`401` en 0.93s y `authorino CRC: 1 → 3`** ✅ |

**Prevención:** correr `./scripts/tailnet-prune.sh` después de cada recreación de CRC, antes de dar
por bueno cualquier test cross-cluster. Lista sin tocar nada, así que es barato como rutina.

**Lo que sigue sin explicación:** los huérfanos reportaban `lastSeen` del minuto anterior y
respondían `pong` sin que ningún pod los reclamara, y el `401` que servían no aparecía en el
Authorino de **ninguno** de los dos clusters aunque traía sus headers `www-authenticate`. Qué proceso
los mantenía vivos quedó sin diagnosticar.

---

## Apéndice D — Estado verificado (2026-08-20)

**Verificado end-to-end, con evidencia del validador:**

- Gateway `Programmed` + AuthPolicy **`Enforced`** en EKS y en OpenShift.
- Aislamiento en **los dos** clusters: 401 / 403 / 403 + control positivo 200.
- Rate limit en EKS: 200 × `200`, luego 60 × `429`.
- JWKS cruzado: cada validador alcanza la clave del peer, y son claves distintas.
- Hop **EKS → OpenShift**: 401 sin token y 200 con token, con la decisión registrada en CRC —
  también con verificación TLS real desde el pod del Gateway de egreso.
- Hop **OpenShift → EKS**: 401 / 200 con la decisión registrada en EKS.
- Escenario EKS→EKS completo por el interceptor: 200 con `x-s2s-cluster` y veredicto confirmado.

**No verificado:**

- **Escenario C (OpenShift → OpenShift, Paso 15)**: piezas verificadas, escenario sin correr.
- La identidad que fija Authorino no es observable a nivel `info`: haría falta subir su `logLevel` a
  `debug`.
- Anti-replay: el token no tiene `aud` ni `jti` y dura 60 s. Reusable dentro de la ventana.

**Andamiaje que no existe en producción:** todo Tailscale (en el Banco es Direct Connect), la CA
autofirmada con la privada en el state de Terraform, la app `hello-world`, el pod `intruso`, y el
agente corriendo como proceso host en una laptop.
