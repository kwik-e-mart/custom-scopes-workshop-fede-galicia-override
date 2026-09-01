# Runbook de pruebas — service Api Manager (EKS)

Recorrido **paso por paso** para probar a mano cada funcionalidad del service `Api Manager` contra el
cluster **EKS del POC**. Cada paso dice qué correr, **qué tenés que ver** para darlo por bueno, y qué
hacer si no da eso.

> Para correrlo contra el CRC local, ver [`RUNBOOK-CRC.md`](./RUNBOOK-CRC.md), que documenta sólo las
> diferencias del entorno local.

## El contexto, primero

Todos los comandos usan `$CTX`. Definilo antes de arrancar:

```bash
export CTX=arn:aws:eks:us-east-1:984449730514:cluster/gal-kuadrant-poc
export AWS_PROFILE=galicia-1

kubectl --context "$CTX" get nodes --no-headers | wc -l
```

**Qué asume:** Kuadrant, Authorino y Gateway API instalados; el Gateway `s2s-ingress` y la
`AuthPolicy` `s2s-validator` en el namespace `gateways`; el `DestinationRule` de loopback
`s2s-ingress-loopback` ya aplicado (Paso 5.1); y los workloads de la demo S2S en `payments`
(`ledger`, usado como pod cliente). Ese sustrato lo provee el layer `demo-kuadrant-s2s/clusters/eks`
— este documento no lo reprovisiona.

**Qué NO cubre:** la instalación de Kuadrant ni de Gateway API (eso es `specs/prerequisites/` del
service, ya resuelto en este cluster).

**Datos de este cluster**, verificados el 2026-09-01:

| | |
|---|---|
| Gateway | `s2s-ingress` en `gateways`, un listener HTTPS/443 `mode: Terminate`, cert `s2s-gateway-tls`, sin restricción de hostname, `allowedRoutes: All` |
| Service del gateway | `s2s-ingress-istio.gateways.svc.cluster.local:443` — es el `backendRef` de las routes |
| `s2s-validator` | nivel Gateway, exige `x-np-token` con wristband, autoriza `ns=payments` |
| Clave de firma | `payments-wristband-key` en `kuadrant-system` |
| `DestinationRule` de loopback | `s2s-ingress-loopback` en `gateways` — **ya aplicado** |
| Scope de prueba (con release real) | route `k-8-s-eks-1049050904-internal`, scope `eks` de `hello-world-poc`, dominio `galicia-poc-hello-world-poc-eks-arcuy.galicia-poc.nullapps.io` |
| Pod cliente | `ledger` en `payments`, contenedor `app` — tiene `wget`, **no** `curl` |

**No hay DNS público** para esa zona: la delegación de `galicia-poc.nullapps.io` apunta a
nameservers que responden `REFUSED`. Se prueba mandando el `Host` header, no resolviendo por DNS.

**Los resultados que figuran como "tenés que ver" son salidas reales**, medidas contra este cluster
el 2026-09-01. Lo que se marca como **BLOQUEADO** es exactamente eso: se intentó, se documenta la
causa, y no se inventó una salida.

---

> ⚠️ **Los Pasos 3, 4 y 6 todavía no se corrieron.** Dependen de un notification channel que aún no
> existe. Sus comandos están derivados de `demo-kuadrant-s2s/demo.sh`, que hace exactamente esto para
> el `egress-interceptor` y está probado — pero acá no se ejecutaron. El resto del documento sí son
> salidas reales medidas contra este cluster.

## Índice

| # | Paso |
|---|---|
| 0 | **¿Se puede arrancar?** — prerrequisitos y estado de partida limpio |
| 1 | Registrar el service specification (Terraform, `specs/install/`) |
| 2 | Levantar el agente **reusando el del `egress-interceptor`** — un agente, dos services |
| 3 | **Crear la instancia** — `np service create` + la acción que dispara al agente |
| 4 | Ver qué hizo el agente |
| 5 | Verificar lo materializado (`Enforced`, no `Accepted`) |
| 6 | Linkear una app consumidora y obtener su API key |
| 7 | Los cinco códigos de respuesta |
| 8 | Colisión de dominios |
| 9 | Revocar el link |
| 10 | Teardown |
| A | Apéndice: invocar los scripts a mano (debugging) |

## Paso 0 — ¿Se puede arrancar?

**Qué valida:** que estén los prerrequisitos y que el punto de partida esté **limpio**. Si algo de
esto falla, los pasos siguientes fallan más tarde con un síntoma que no señala la causa.

```bash
cd ~/nullplatform/galicia/galicia-banco
export SVC=~/nullplatform/galicia/custom-scopes-workshop-fede-galicia-override/api-manager
export NP_API_KEY="$(cat accounts/galicia/np-api-skill.key)"
export NRN="organization=1636958496:account=1374028000"
```

### 1. Herramientas y sesión AWS

```bash
for b in kubectl jq yq gomplate np aws openssl; do
  printf '%-10s %s\n' "$b" "$(command -v $b || echo 'FALTA')"
done
/opt/homebrew/bin/bash --version | head -1
aws sts get-caller-identity --profile galicia-1 --query Account --output text
```

```
kubectl    /usr/local/bin/kubectl
jq         /usr/bin/jq
yq         /opt/homebrew/bin/yq
gomplate   /opt/homebrew/bin/gomplate
np         /Users/federico.maleh/.local/bin/np
aws        /opt/homebrew/bin/aws
openssl    /usr/bin/openssl
GNU bash, version 5.3.15(1)-release (aarch64-apple-darwin24.6.0)
984449730514
```

`bash` tiene que ser **>= 4**: el de `/bin` en macOS es 3.2 y no corre ni los tests del service
(`${level,,}` en `logging`) ni `mapfile` (usado por `reconcile`). Cada bloque de este runbook que
corre un script del service lo hace explícitamente con `/opt/homebrew/bin/bash` o con
`PATH=/opt/homebrew/bin:$PATH` por delante. Si la sesión de AWS venció: `aws sso login --profile
galicia-1` (dura 1 hora).

### 2. El cluster responde

```bash
kubectl --context "$CTX" get ns kuadrant-system payments gateways -o name
```

```
namespace/kuadrant-system
namespace/payments
namespace/gateways
```

### 3. El sustrato compartido está sano

**Qué valida:** que el Gateway de ingreso, su `AuthPolicy` y el `DestinationRule` de loopback —que
este service NO instala, ver Paso 2 y Paso 5.1— estén arriba.

```bash
kubectl --context "$CTX" -n gateways get gateway s2s-ingress \
  -o jsonpath='Programmed: {.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
kubectl --context "$CTX" -n gateways get gateway s2s-ingress \
  -o jsonpath='Listener: {.spec.listeners[0].protocol}/{.spec.listeners[0].tls.mode}  cert={.spec.listeners[0].tls.certificateRefs[0].name}{"\n"}'
kubectl --context "$CTX" -n gateways get destinationrule s2s-ingress-loopback -o name
```

```
Programmed: True
Listener: HTTPS/Terminate  cert=s2s-gateway-tls
destinationrule.networking.istio.io/s2s-ingress-loopback
```

### 4. El punto de partida está limpio

```bash
kubectl --context "$CTX" -n payments get httproute,authpolicy,serviceaccount --no-headers 2>&1 | grep -i api-manager || echo "payments: limpio de api-manager"
kubectl --context "$CTX" -n kuadrant-system get secret -l api-manager.nullplatform.io/managed=true
kubectl --context "$CTX" get clusterrole,clusterrolebinding 2>&1 | grep -i api-manager || echo "clusterroles: limpio"
```

**Qué tenés que ver:**

```
payments: limpio de api-manager
No resources found in kuadrant-system namespace.
clusterroles: limpio
```

⚠️ **Este cluster ya tiene tráfico S2S real corriendo (`egress-interceptor`), así que
`s2s-validator`/`s2s-ingress` NO arrancan "vacíos"** como en un cluster de prueba nuevo. A diferencia
de CRC (`RUNBOOK-CRC.md`), acá el punto de partida limpio **ya** tiene `attachedRoutes >= 1` y
`s2s-validator Enforced: True`, porque ya hay al menos un `HTTPRoute` de otro scope colgado del mismo
Gateway compartido (verificado: `attachedRoutes: 1`, el de la route `k-8-s-eks-1049050904-internal`).
Lo que hay que verificar limpio es específicamente lo que **este service** deja — los tres chequeos
de arriba — no el estado global del Gateway compartido. Este cluster tampoco tiene el echo server
`reports` de la demo CRC — no existe acá, y este runbook no lo necesita (Paso 5 usa un scope real).

Si algo de esto no da lo esperado, hay resto de una corrida anterior: repetí el Paso 13 antes de
seguir.

---

## Paso 1 — Registrar el service specification

**Qué valida:** que `specs/install/` registre el service en la cuenta real. Es una acción **de
cuenta nullplatform**, no de cluster — no depende de si el destino es EKS o CRC, y a diferencia de
las instancias que se crean y se borran en cada corrida (Paso 6 y Paso 13), el service specification
**queda registrado de forma permanente**, igual que `egress-interceptor`.

**Este paso ya se corrió** (commit `5a1d385` de este repo): el service `Api Manager` está registrado
(`service_specification_slug = "api-manager"`, id `f0ff57e2-29db-4c1f-8fb6-9fd94a27e8a6`). No hace
falta repetirlo — el comando de abajo es de **verificación**, no de creación:

```bash
NP_API="$HOME/.claude/plugins/marketplaces/nullplatform-internal/src/skills/np-api/scripts/np-api.sh"
[ -x "$NP_API" ] || NP_API=$(find "$HOME/.claude" -path '*np-api/scripts/np-api.sh' | head -1)
"$NP_API" fetch-api "/service_specification?nrn=$NRN" | jq -c '.results[]|select(.slug=="api-manager")|{id,name,slug,type}'
```

```
# →
{"id":"f0ff57e2-29db-4c1f-8fb6-9fd94a27e8a6","name":"Api Manager","slug":"api-manager","type":"dependency"}
```

---

## Paso 2 — Levantar el agente reusando el del `egress-interceptor`

**Qué hace:** un `np-agent` en runtime host que atiende **los dos services a la vez**. No se levanta
un agente propio para Api Manager: se reusa el que ya existe, porque el objetivo es probar los dos
corriendo simultáneamente.

El script es `services/egress-interceptor/start-agent-eks.sh` en este repo. Advierte a un agente con
estos tags:

```
environment:eks-kuadrant-poc, cluster:eks, role:egress-interceptor
```

### Cómo un solo agente atiende dos services

El channel de cada service selecciona por tags, y **el selector tiene que ser un subconjunto de los
tags del agente**. El del `egress-interceptor` incluye `role:egress-interceptor`. Para que el mismo
agente atienda también a Api Manager, su `tags_selectors` **no debe incluir `role`**:

```hcl
tags_selectors = {
  environment = "eks-kuadrant-poc"
  cluster     = "eks"
}
```

Así los dos channels matchean el mismo agente. Api Manager no discrimina por `cluster` desde la
instancia —se le sacó esa property a propósito— así que su selector es estático y apunta al cluster
donde corre este agente.

> **No levantes un segundo agente.** Los dos scripts bindean puertos fijos (8182 el de EKS, 8181 el
> de CRC) y el canal selecciona por tags sin discriminar proceso: dos agentes con tags que matcheen
> el mismo channel se pisan. Un agente por cluster, N services.

### El código del service, en el disco del agente

El agente no clona este repo: lo lee de un **symlink al working copy**, igual que hace el
`egress-interceptor` con `galicia-banco`. Así ejecuta el código tal como está en tu disco, sin
commitear ni esperar un clone.

El channel arma el comando como `<base_clone_path>/<org>/<repo>/api-manager/entrypoint/entrypoint`.
Con `base_clone_path = ~/.np` (el del agente host-runtime, igual que el egress), el symlink va así:

```bash
mkdir -p ~/.np/kwik-e-mart
ln -sfn ~/nullplatform/galicia/custom-scopes-workshop-fede-galicia-override \
        ~/.np/kwik-e-mart/custom-scopes-workshop-fede-galicia-override
```

Verificalo antes de arrancar el agente:

```bash
ls -l ~/.np/kwik-e-mart/custom-scopes-workshop-fede-galicia-override/api-manager/entrypoint/entrypoint
# → tiene que existir y ser ejecutable
```

**Ya está creado en esta máquina** (2026-09-01). Al lado queda el del egress:

```
~/.np/nullplatform-implementations/galicia-banco            -> ~/nullplatform/galicia/galicia-banco
~/.np/kwik-e-mart/custom-scopes-workshop-fede-galicia-override -> ~/nullplatform/galicia/custom-scopes-workshop-fede-galicia-override
```

Los dos services conviven bajo el mismo `~/.np`, cada uno en el path que su channel espera. **No hace
falta tocar `GIT_COMMAND_REPOS`** para esto: esa lista es para repos que el agente sí clona (el de
`scopes`, que trae los scope types), no para el código de los services que se leen del symlink.

### Arrancarlo

En una terminal aparte, que queda ocupada mientras el agente corre:

```bash
cd ~/nullplatform/galicia/galicia-banco
export NP_API_KEY="$(cat accounts/galicia/np-api-skill.key)"
./services/egress-interceptor/start-agent-eks.sh
```

El script se encarga solo de validar que la sesión SSO del perfil `galicia-1` esté viva, generar el
kubeconfig dedicado (`~/.kube/gal-kuadrant-poc.config`, para no depender del `current-context` de tu
shell), y chequear que los repos de `GIT_COMMAND_REPOS` sean alcanzables antes de arrancar.

```
# →
repo para el agente: https://github.com/nullplatform/scopes.git#main
kubectl context: gal-kuadrant-poc  (kubeconfig: /Users/…/.kube/gal-kuadrant-poc.config)
gitops: sin GITOPS_REPO_URL, el publisher queda apagado.
…arranca y queda escuchando…
```

Si la sesión SSO expiró, sale antes de arrancar y dice qué correr:

```
ERROR: la sesión SSO del perfil 'galicia-1' no es válida. Corré:
  aws sso login --profile galicia-1
```

El log queda en `/tmp/np-agent-eks.log`. Para seguir qué notificaciones toma, desde otra terminal:

```bash
tail -f /tmp/np-agent-eks.log
```

**Dejalo corriendo** durante todo el resto del runbook: es el que ejecuta las acciones cuando crees la
instancia y el link.

### El `base_clone_path` tiene que coincidir

Si el channel se crea con el default del módulo (`/root/.np`) en vez de `~/.np`, el comando apunta a
una ruta que en macOS no existe y hace falta `sudo` para crear. El egress lo resuelve pasando
`base_clone_path = pathexpand("~/.np")` cuando el agente es host-runtime — ver
`accounts/galicia/nullplatform-bindings/egress_interceptor.tf`. El channel de Api Manager tiene que
hacer lo mismo.

> ⚠️ **No verificado.** Este paso está construido sobre cómo funciona el script del
> `egress-interceptor` (leído) y sobre cómo selecciona el channel (documentado), pero **no se corrió
> un agente atendiendo los dos services a la vez**. Si al hacerlo el channel de Api Manager no
> matchea, lo primero a revisar es que su `tags_selectors` no tenga `role` y que sea subconjunto
> exacto de los tags que el script advierte.

## Paso 3 — Crear la instancia del service

**Acá empieza la prueba de verdad.** Todo lo anterior fue preparar el terreno; de acá en adelante se
usa el service como lo usaría un dev, y el agente ejecuta las acciones.

### Los ids que vas a necesitar

```bash
export NP_API=~/.claude/plugins/cache/nullplatform-internal/np-developer/1.2.15/skills/np-api/scripts/np-api.sh
export NP_API_KEY="$(cat accounts/galicia/np-api-skill.key)"
export APP_NRN="organization=1636958496:account=1374028000:namespace=824774832:application=142495574"

"$NP_API" fetch-api "/service_specification?nrn=$APP_NRN&type=dependency" \
  | jq -r '.results[] | select(.slug=="api-manager") | .id'
```

```
# →
f0ff57e2-29db-4c1f-8fb6-9fd94a27e8a6
```

```bash
export SPEC_ID=f0ff57e2-29db-4c1f-8fb6-9fd94a27e8a6
"$NP_API" fetch-api "/service_specification/$SPEC_ID/action_specification" \
  | jq -r '.results[] | "\(.type)  \(.id)"'
```

```
# →
archive  a4aff681-c0be-4fbf-83c2-04700bf36517
delete   8a261bb7-243e-4793-a0aa-798d0e2f6f58
update   b80e77b9-794a-4223-9dd4-03345a222126
create   f9fc6705-b176-42e5-ada9-0b9508413b7b
```

### Crear la instancia

Lo que declara el dev: los dominios y las rutas. El backend **no** se declara — sale del scope.

```bash
export ATTRS='{"hosts":["api-publica.galicia-poc.nullapps.io"],
               "routes":[{"path":"/whoami","methods":["GET"],"scope":"eks"}]}'

np service create --body "$(jq -n \
  --arg n "api-manager-hello" --arg sp "$SPEC_ID" --arg nrn "$APP_NRN" \
  --argjson a "$ATTRS" \
  '{name:$n, specification_id:$sp, entity_nrn:$nrn, linkable_to:[$nrn],
    attributes:$a, dimensions:{environment:"sbx"}}')"
```

```
# →
id: <uuid de la instancia>
status: pending
```

> **`np service create` NO provisiona nada.** Deja la instancia en `pending`. Lo que dispara la
> notificación al agente es la **acción**, el paso siguiente. Si te quedás acá, no va a pasar nada en
> el cluster y el síntoma es "no se creó ninguna HTTPRoute" sin ningún error.

### Disparar la acción de create

```bash
export SERVICE_ID=<el uuid de arriba>

np service action create --serviceId "$SERVICE_ID" --body "$(jq -n \
  --arg n "create-api-manager-hello" \
  --arg sp "f9fc6705-b176-42e5-ada9-0b9508413b7b" \
  --argjson p "$ATTRS" \
  '{name:$n, specification_id:$sp, parameters:$p}')"
```

En la terminal del agente (Paso 2) tenés que ver que toma la notificación y ejecuta el entrypoint.
Si no aparece nada, el channel no está matcheando — ver el Troubleshooting.

---

## Paso 4 — Ver qué hizo el agente

```bash
tail -40 /tmp/np-agent-eks.log | grep -iE "api-manager|reconcile|error"
```

```
# →
api-manager: exponiendo payments.hello-world-poc
  dominio: api-publica.galicia-poc.nullapps.io
  ruta: GET /whoami → scope eks = galicia-poc-hello-world-poc-eks-arcuy.galicia-poc.nullapps.io
api-manager gitops: sin repo configurado, no se publica.
api-manager: payments.hello-world-poc expuesto.
```

Y el estado de la acción en la plataforma:

```bash
"$NP_API" fetch-api "/service/$SERVICE_ID/action" | jq -r '.results[] | "\(.type)  \(.status)"'
```

```
# →
create  success
```

---

## Paso 5 — Verificar lo materializado

```bash
kubectl --context "$CTX" -n payments get httproute,authpolicy -l api-manager.nullplatform.io/managed=true
```

```
# →
httproute.gateway.networking.k8s.io/api-manager-<service-id>
authpolicy.kuadrant.io/api-manager-<service-id>
```

**La señal que importa es `Enforced`, no `Accepted`:**

```bash
kubectl --context "$CTX" -n payments get authpolicy -l api-manager.nullplatform.io/managed=true \
  -o jsonpath='{range .items[*]}{.metadata.name}  Accepted={.status.conditions[?(@.type=="Accepted")].status}  Enforced={.status.conditions[?(@.type=="Enforced")].status}{"\n"}{end}'
```

```
# →
api-manager-<service-id>  Accepted=True  Enforced=True
```

Kuadrant no enforcea una policy que no esté en el camino de ninguna route, y **no falla ruidosamente**:
`Accepted=True` con `Enforced=False` significa que no está protegiendo nada.

El `backendRef` va al gateway, y el dominio del scope viaja como `Host`:

```bash
kubectl --context "$CTX" -n payments get httproute -l api-manager.nullplatform.io/managed=true \
  -o jsonpath='{.items[0].spec.rules[0]}' | jq '{filters, backendRefs}'
```

```
# →
{
  "filters": [{"type":"URLRewrite","urlRewrite":{"hostname":"galicia-poc-hello-world-poc-eks-arcuy.galicia-poc.nullapps.io"}}],
  "backendRefs": [{"group":"networking.istio.io","kind":"Hostname","name":"s2s-ingress-istio.gateways.svc.cluster.local","port":443}]
}
```

> **`ResolvedRefs=False (BackendNotFound)` es esperado** en estas routes y no es un síntoma. Istio no
> marca como resueltos los `backendRefs` de `kind: Hostname` aunque el cluster exista — verificado.
> La señal es el tráfico.

---

## Paso 6 — Linkear una app consumidora

El link es lo que le da su API key al consumidor. Se crea contra la instancia del service:

```bash
export LINK_SPEC_ID=30332b58-598a-4fa5-a5a3-820d59037426

np link create --body "$(jq -n \
  --arg sp "$LINK_SPEC_ID" --arg svc "$SERVICE_ID" --arg nrn "$APP_NRN" \
  '{specification_id:$sp, service_id:$svc, entity_nrn:$nrn}')"
```

Y como con el service, la acción es lo que dispara la emisión:

```bash
export LINK_ID=<el uuid del link>
"$NP_API" fetch-api "/link_specification/$LINK_SPEC_ID/action_specification" \
  | jq -r '.results[] | select(.type=="create") | .id'
```

```bash
np link action create --linkId "$LINK_ID" --body "$(jq -n \
  --arg n "connect" --arg sp "<el action spec de create del link>" '{name:$n, specification_id:$sp}')"
```

La key queda en el Secret que crea el agente, y la plataforma la expone como
`API_MANAGER_API_KEY` en el consumidor:

```bash
kubectl --context "$CTX" -n kuadrant-system get secret "api-manager-$LINK_ID" \
  -o jsonpath='{.metadata.labels}' | jq
```

```
# →
{
  "apimgr-target": "payments.hello-world-poc",
  "api-manager.nullplatform.io/managed": "true",
  "authorino.kuadrant.io/managed-by": "authorino"
}
```

Para las pruebas de tráfico necesitás el valor:

```bash
export KEY=$(kubectl --context "$CTX" -n kuadrant-system get secret "api-manager-$LINK_ID" \
  -o jsonpath='{.data.api_key}' | base64 -d)
```

---

## Paso 7 — Los cinco códigos, verificados end-to-end contra EKS real

**Tercer aviso de este runbook, y el que más importa: probar el 200 no es opcional.** Un selector de
`authorization` mal escrito rechaza a TODAS las keys con 403 — indistinguible de "la key es de otra
app" si sólo se mira 401/403. El 200 es el único caso que separa ambos.

El pod cliente es `ledger` en `payments` (contenedor `app`) — tiene **`wget`, no `curl`**:

```bash
kubectl --context "$CTX" -n payments exec deploy/ledger -c app -- sh -c 'command -v curl; command -v wget'
```

```
# →
/usr/bin/wget
```

```bash
INGRESS="https://s2s-ingress-istio.gateways.svc.cluster.local/whoami"
HOSTH="Host: api-test.local"

echo "== 1. sin header =="
kubectl --context "$CTX" -n payments exec deploy/ledger -c app -- \
  wget -S -qO- --timeout=15 --no-check-certificate --header="$HOSTH" "$INGRESS" \
  2>&1 | grep -oE "HTTP/[0-9.]+ [0-9]+" | head -1

echo "== 2. key inventada =="
kubectl --context "$CTX" -n payments exec deploy/ledger -c app -- \
  wget -S -qO- --timeout=15 --no-check-certificate --header="$HOSTH" \
  --header="x-api-key: no-existe-esta-key-0000" "$INGRESS" \
  2>&1 | grep -oE "HTTP/[0-9.]+ [0-9]+" | head -1

echo "== 3. key de otra app =="
kubectl --context "$CTX" -n payments exec deploy/ledger -c app -- \
  wget -S -qO- --timeout=15 --no-check-certificate --header="$HOSTH" \
  --header="x-api-key: $KEY2" "$INGRESS" \
  2>&1 | grep -oE "HTTP/[0-9.]+ [0-9]+" | head -1

echo "== 4. key propia =="
kubectl --context "$CTX" -n payments exec deploy/ledger -c app -- \
  wget -S -qO- --timeout=15 --no-check-certificate --header="$HOSTH" \
  --header="x-api-key: $KEY1" "$INGRESS"

echo "== 5. path no declarado =="
kubectl --context "$CTX" -n payments exec deploy/ledger -c app -- \
  wget -S -qO- --timeout=15 --no-check-certificate --header="$HOSTH" \
  --header="x-api-key: $KEY1" "https://s2s-ingress-istio.gateways.svc.cluster.local/no-declarada" \
  2>&1 | grep -oE "HTTP/[0-9.]+ [0-9]+" | head -1
```

**Qué tenés que ver** (salida real, medida el 2026-09-01):

```
== 1. sin header ==
HTTP/1.1 401
== 2. key inventada ==
HTTP/1.1 401
== 3. key de otra app ==
HTTP/1.1 403
== 4. key propia ==
  HTTP/1.1 200 OK
  server: istio-envoy
  content-type: application/json; charset=utf-8
  x-envoy-upstream-service-time: 15
{"service":"reports","namespace":"payments","cluster":"eks-kong","pod":"d-1049050904-...","vpc_ip":"10.60.2.52","spoke":"galicia-1"}
== 5. path no declarado ==
HTTP/1.1 404
```

| # | Header | Código | Qué prueba |
|---|---|---|---|
| 1 | ninguno | **401** | sin credencial, Kuadrant corta antes de autorizar |
| 2 | key que no existe | **401** | ninguna key con ese valor está registrada como `Secret` |
| 3 | key válida, de `other.otra-app` | **403** | autenticó (la key existe), pero `apimgr-target` no matchea |
| 4 | key válida, propia | **200**, body real del scope | control positivo, atravesando los dos saltos completos |
| 5 | key propia, path no declarado | **404** | ningún `match` del `HTTPRoute` cubre `/no-declarada` |

El caso 4 atraviesa la cadena completa: `x-api-key` válida → la `AuthPolicy` de este service
autentica y **acuña un wristband** (`x-np-token`, firmado con `payments-wristband-key`) → el
request rebota al mismo gateway con el `Host` reescrito al dominio del scope → la route del scope
(que exige wristband, vía `s2s-validator`) lo acepta → responde el pod real.

### Lo que hizo falta resolver para llegar al 200 (histórico, ya resuelto)

Tres problemas distintos, en el orden en que se encontraron: el `backendRef` apuntaba directo al
dominio del scope y daba `500` (`kind: Hostname` no resuelve un dominio externo — resuelto ruteando
por el gateway local, Paso 5); faltaba el `DestinationRule` de loopback y daba `503` (resuelto, Paso
5.1); y la route del scope exige `x-np-token` (hereda `s2s-validator`) y daba `401` en el segundo
salto hasta que la `AuthPolicy` de este service empezó a acuñar el wristband (commit `d849411`).

### Dato verificado: la `AuthPolicy` a nivel `HTTPRoute` sobreescribe la del `Gateway`

Medido con un `200` usando **sólo** `x-api-key` contra `s2s-ingress` —que tiene su propia
`AuthPolicy` `s2s-validator` exigiendo wristband en el **primer** salto— sin ningún wristband en ese
primer request. El primer salto (el que agrega este service) **no** exige el wristband S2S del
gateway compartido; su propia regla de `authentication` (`apiKey`) es la que manda para las rutas
que declara. El wristband recién hace falta en el **segundo** salto (el loopback hacia la route del
scope), y lo pone la `AuthPolicy` de este service, no el cliente.

---

## Paso 8 — Colisión de dominios

**Qué valida:** que declarar el mismo `(host, path)` que ya declaró otra app se rechace, y que
compartir el mismo host con un path distinto no. `check_collisions` comparte `find_route_conflicts`
con el re-chequeo post-apply del Paso 6, y detecta **solapamiento por prefijo**, no sólo match
exacto: un path que es subárbol de otro ya declarado también colisiona.

`SERVICE_ID` acá sólo sirve para que `find_route_conflicts` se auto-excluya — no hace falta que sea
real, a diferencia de `build_context`/`mint_key`:

```bash
export SERVICE_ID=otra-instancia-uuid
export HOSTS_JSON='["api-test.local"]'
export ROUTES_JSON='[{"path":"/whoami","methods":["GET"],"scope":"eks"}]'

KUBECONFIG=/tmp/kubeconfig-sa PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/check_collisions"
'
echo "EXIT=$?"
```

```
# →
api-manager: hay dominios y paths que se solapan con los de otra aplicación.
  api-test.local/whoami se solapa con api-test.local/whoami, ya tomado por galicia-poc.hello-world-poc
  Compartir un dominio está permitido: lo que no se puede es solapar el mismo subárbol de path con otra app. La barra final y el '*' de subárbol no cuentan como una ruta distinta.
EXIT=1
```

Mismo host, path que no es prefijo ni sufijo del existente — sin colisión (`EXIT=0`, sin salida de
error). Verificado con `ROUTES_JSON='[{"path":"/otro-path",...}]'`.

---

## Paso 9 — Revocar el link

**Qué valida:** que borrar el link corte el acceso **de inmediato**. Se mintea una key nueva para
no depender de la del Paso 9/10, se confirma el 200, se revoca, se confirma el 401 con la misma key:

```bash
export NP_ACTION_CONTEXT='{"notification":{"link":{"id":"linktest0002"},"service":{"id":"ec53bf2c-5831-4a85-ab4c-b16762ddd861"}}}'
export KEYS_NAMESPACE=kuadrant-system
KUBECONFIG=/tmp/kubeconfig-sa PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/mint_key"
' 2>&1 | head -1

KEY3=$(kubectl --context "$CTX" -n kuadrant-system get secret api-manager-linktest0002 -o jsonpath='{.data.api_key}' | base64 -d)

echo "== 200 antes de revocar =="
kubectl --context "$CTX" -n payments exec deploy/ledger -c app -- \
  wget -S -qO- --timeout=15 --no-check-certificate --header="Host: api-test.local" \
  --header="x-api-key: $KEY3" "https://s2s-ingress-istio.gateways.svc.cluster.local/whoami" \
  2>&1 | grep -oE "HTTP/[0-9.]+ [0-9]+" | head -1

export NP_ACTION_CONTEXT='{"notification":{"link":{"id":"linktest0002"}}}'
KUBECONFIG=/tmp/kubeconfig-sa PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/revoke_key"
'

echo "== la misma key, revocada =="
kubectl --context "$CTX" -n payments exec deploy/ledger -c app -- \
  wget -S -qO- --timeout=15 --no-check-certificate --header="Host: api-test.local" \
  --header="x-api-key: $KEY3" "https://s2s-ingress-istio.gateways.svc.cluster.local/whoami" \
  2>&1 | grep -oE "HTTP/[0-9.]+ [0-9]+" | head -1
```

```
# →
secret/api-manager-linktest0002 created
== 200 antes de revocar ==
HTTP/1.1 200
secret "api-manager-linktest0002" deleted from kuadrant-system namespace
api-manager: credencial del link linktest0002 revocada.
== la misma key, revocada ==
HTTP/1.1 401
```

Sin expiración que esperar: el 200 pasa a 401 en cuanto el Secret desaparece.

---

## Paso 10 — Teardown

**Qué valida:** que borrar la instancia no deje `HTTPRoute`, `AuthPolicy` ni Secrets colgando.

```bash
export NAMESPACE=payments
export APP_TARGET=galicia-poc.hello-world-poc
export SERVICE_ID=ec53bf2c-5831-4a85-ab4c-b16762ddd861
export KEYS_NAMESPACE=kuadrant-system
export ARGS=delete

PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/reconcile"
'
```

```
# →
api-manager gitops: sin repo configurado, no se publica.
authpolicy.kuadrant.io "api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861" deleted from payments namespace
httproute.gateway.networking.k8s.io "api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861" deleted from payments namespace
api-manager: galicia-poc.hello-world-poc dado de baja.
```

`np link list --service-id ec53bf2c-...` es una llamada real contra un service real y responde
vacía (`imagenes` no tiene links reales registrados, Paso 3) — no borra el Secret de `linktest0001`
del Paso 9 (ya revocado a mano si se corrió el Paso 12 con ese link) ni `api-manager-otraapp` (nunca
pasó por un link real). Se borra lo que quede a mano:

```bash
kubectl --context "$CTX" -n kuadrant-system delete secret api-manager-otraapp --ignore-not-found
kubectl --context "$CTX" delete -f /tmp/rbac.rendered.yaml --ignore-not-found
kubectl --context "$CTX" -n payments delete serviceaccount api-manager-agent --ignore-not-found
```

### Verificar que quedó limpio

```bash
kubectl --context "$CTX" -n payments get httproute,authpolicy,serviceaccount --no-headers 2>&1 | grep -i api-manager || echo "payments: limpio"
kubectl --context "$CTX" -n kuadrant-system get secret -l api-manager.nullplatform.io/managed=true
kubectl --context "$CTX" get clusterrole,clusterrolebinding 2>&1 | grep -i api-manager || echo "clusterroles: limpio"
```

**Qué tenés que ver** (igual al Paso 0):

```
payments: limpio
No resources found in kuadrant-system namespace.
clusterroles: limpio
```

El service specification "Api Manager" del Paso 1 **sigue registrado** — es el estado esperado, es
una entidad de cuenta, no de cluster.

---

## Los avisos que no pueden faltar

1. **`Accepted=True` no es enforcement.** La señal válida de la `AuthPolicy` es **`Enforced=True`**
   (Gotcha #22, Paso 8). Kuadrant no enforcea una policy que no esté en el camino de ningún
   `HTTPRoute`, y no falla ruidosamente.

2. **`ResolvedRefs=False (BackendNotFound)` no hay que leerlo como una falla** (Paso 8). Verificado
   en los dos clusters (EKS y CRC): da `False` incluso apuntando a un `Service` real de otro
   namespace. En ningún caso afecta `Enforced` ni el resultado de auth.

3. **Probar el 200 es obligatorio, no opcional** (Paso 10). Un selector de `authorization` mal
   escrito rechaza a TODAS las keys con 403, indistinguible de "la key es de otra app" si sólo se
   mira 401/403.

4. **Los tests unitarios no pueden cubrir RBAC.** El suite mockea `kubectl`. Esta misma corrida
   encontró un `Role` desactualizado (Paso 4): falta `get` sobre el Secret de firma en
   `kuadrant-system`, y sin él `reconcile apply` no funciona bajo la identidad restringida —
   ningún test lo hubiese visto.

5. **GitOps es fail-closed, en los dos sentidos** (Paso 7). Un push que falla no deja nada aplicado
   ni nada borrado.

6. **La `AuthPolicy` de este service, no la del Gateway, decide el primer salto** (Paso 10). El
   wristband S2S del gateway compartido no hace falta para hablarle a este service; lo que este
   service agrega es su propia capa de `apiKey`, y es él quien acuña el wristband para el segundo
   salto.

---

## Troubleshooting

| Síntoma | Causa | Qué hacer |
|---|---|---|
| `api-manager: no existe el Secret de firma '...'` con el Secret realmente existiendo | falta `get` en el `Role` de `kuadrant-system` (Paso 4) | correr `reconcile apply` con el `kubeconfig` admin hasta que se actualice el `Role`; no es RBAC de más, es un verbo que falta |
| `HTTP 503` en el caso 200 | falta el `DestinationRule` `s2s-ingress-loopback` (Paso 5.1) | confirmar que está aplicado; si no, aplicar el módulo `kuadrant-s2s` |
| `HTTP 401` en el segundo salto (no en el primero) | falta el wristband, o la route del scope no lo acepta | confirmar que la `AuthPolicy` de este service tiene el bloque `response.success.headers["x-np-token"].wristband` (commit `d849411`) y que `WRISTBAND_SECRET` apunta a un Secret real |
| `HTTP 500` en el caso 200 (modelo de ruteo anterior) | el `backendRef` apuntaba directo al dominio del scope | ya no aplica — desde el 2026-09-01 el `backendRef` va siempre al gateway local (Paso 5) |
| `404` en vez de 401/403/200 | el `Host` no matchea ningún `HTTPRoute`, o el path no está declarado | confirmar `--header="Host: ..."` contra los `hosts` declarados |
| `403` en TODOS los casos, incluida la key propia | el selector de `authorization` está mal | probar el caso 200 (Paso 10) antes de asumir que el 403 "funciona" |
| `ResolvedRefs=False (BackendNotFound)` | esperado con `kind: Hostname` cross-namespace (Paso 8) | no es un síntoma por sí solo; mirar `Enforced` |
| Secret con las labels correctas pero todo da 401 | el Secret está en el namespace de la app, no en `kuadrant-system` | recrearlo en `kuadrant-system` (Paso 9) |
| `mint_key` falla en `np service action update` | se está probando fuera de una acción real (Paso 3) | esperado; el Secret creado sí es real |
| `reconcile ARGS=delete` no borra un Secret que se esperaba | ese Secret nunca pasó por `mint_key` (Paso 9) | borrarlo a mano por nombre (Paso 13) |
| `curl: not found` dentro de un pod de `payments` | los pods de esta demo sólo traen `wget` | usar `wget -S -qO-` con `--header`, no `curl -H` |
| `reconcile` aborta con "falló la publicación... NO se aplicó nada" | `GITOPS_REPO_URL` mal, o el push se rechazó (Paso 7) | fail-closed a propósito; el cluster no se tocó |
| El agente no arranca / `cmdline` apunta a un archivo que no existe | `/root/.np/...` no existe en runtime host sobre macOS (Paso 2) | correr el agente en runtime k8s (pod) |
| `mapfile: command not found` o `${level,,}` falla | corriendo con el `bash` 3.2 de macOS en vez de uno >= 4 | anteponer `PATH=/opt/homebrew/bin:$PATH` |


---

## Apéndice A — Invocar los scripts a mano

Todo lo de arriba pasa por la plataforma, que es como se usa el service. Esta sección invoca los
scripts directamente, alimentando el contexto a mano. **No es la forma de probar el service**: sirve
para depurar un script puntual cuando algo del flujo real falla y querés aislar dónde.

Requiere exportar a mano todo lo que normalmente arma `build_context` desde la notificación.

### Cómo se prueba sin un agente vivo

Sin agente, crear una instancia real (`np service create` + la acción `create`) dejaría la instancia
en `pending` para siempre — nadie la procesa —, y una instancia `pending`/`failed` **no la puede
borrar la API key del repo** (403; hace falta un token de usuario o la consola). Crear una así
habría sido la manera más rápida de ensuciar la cuenta sin poder limpiarla después.

**Lo que se hace en cambio:** correr los scripts reales del service (`build_context`,
`check_collisions`, `reconcile`, `mint_key`, `revoke_key`) directamente, con un `NP_ACTION_CONTEXT`
armado a mano que respeta exactamente la forma que el código espera. Esto NO es un mock — es el
código de producción, corriendo contra el cluster real, con las mismas llamadas `kubectl` y `np` que
haría el agente. Lo único que cambia es *quién* invoca el script.

El contrato que cada script espera:

| Variable | Quién la pone | Quién la consume |
|---|---|---|
| `NP_ACTION_CONTEXT` | la plataforma (acá: a mano) | `entrypoint`, `build_context`, `mint_key`, `revoke_key` |
| `CONTEXT` (= `.notification` de `NP_ACTION_CONTEXT`) | `entrypoint` (acá: a mano) | `build_context` |
| `NAMESPACE`, `APP_TARGET`, `SERVICE_ID`, `HOSTS_JSON`, `ROUTES_JSON` | `build_context` | `check_collisions`, `reconcile` |
| `GATEWAY_NAME`, `GATEWAY_NAMESPACE`, `KEYS_NAMESPACE`, `API_KEY_HEADER`, `LOCAL_INGRESS_HOST`, `WRISTBAND_SECRET`, `TOKEN_DURATION` | la `configuration:` del workflow | `build_context`, `reconcile`, `mint_key` |
| `GITOPS_*` (Paso 7) | la `configuration:` del workflow + el entorno del agente | `reconcile` (vía `gitops_lib`) |

**`APP_TARGET` no se puede pasar a mano.** `build_context` y `mint_key` lo derivan cada uno por su
cuenta, llamando a `resolve_app_target_from_service "$SERVICE_ID"` — que hace
`np service read --id $SERVICE_ID` contra la plataforma, saca el `namespace`/`application` del
`entity_nrn`, y resuelve sus slugs con `np namespace read`/`np application read`. Es correcto por
construcción (deriva la identidad de un dato real de la plataforma), no por lo que alguien haya
puesto en un JSON — el link que emite la credencial lo crea la app **consumidora**, que vive en otro
namespace, así que sacar `APP_TARGET` del contexto de la acción daría el label equivocado.

**Consecuencia: `SERVICE_ID` tiene que ser el `id` de un service real de la cuenta.** Como Api
Manager no tiene ninguna instancia real (Paso 2), este runbook reutiliza el `id` de un service
**real pero no relacionado**, ya existente (`imagenes`, un endpoint-exposer sobre la aplicación real
`hello-world-poc`) — es una entidad de la cuenta nullplatform, no del cluster, así que el mismo `id`
sirve tanto para EKS como para CRC:

```bash
np service read --id ec53bf2c-5831-4a85-ab4c-b16762ddd861 --format json | jq '{id,name,status,entity_nrn}'
```

```
# →
{
  "id": "ec53bf2c-5831-4a85-ab4c-b16762ddd861",
  "name": "imagenes",
  "status": "active",
  "entity_nrn": "organization=1636958496:account=1374028000:namespace=824774832:application=142495574"
}
```

⚠️ **Ojo con los dos "namespace":** el `namespace` del `entity_nrn` (`824774832`, slug
`galicia-poc`) es una entidad de **nullplatform**; el `NAMESPACE` que controla dónde se crean el
`HTTPRoute`/`AuthPolicy` (Paso 6, `payments`) es el **namespace de Kubernetes**. No tienen por qué
coincidir, y acá no coinciden.

Dos consecuencias más de probar así:

- `mint_key` termina con `np service action update --results ...`, que necesita una acción real en
  curso. Sin ella, el `kubectl create` del Secret sale bien pero esa última línea falla — es
  **esperado**, no un bug.
- `reconcile ARGS=delete` resuelve qué Secrets borrar vía `np link list --service-id $SERVICE_ID`.
  Con el `id` real de `imagenes` la llamada **sale bien** — pero devuelve una lista vacía, porque
  `imagenes` no tiene ningún link real registrado (los que mintea este runbook a mano no lo son). El
  borrado de Secrets del Paso 13 sigue siendo manual por ese motivo, no porque la llamada falle.

---

### RBAC de prueba

**Qué valida** el cuarto aviso de este runbook: los tests unitarios del service mockean `kubectl`,
así que no ven RBAC. La única manera de saber si el `Role` real alcanza es correr los scripts reales
**impersonando** una identidad que sólo tenga esos permisos, ni uno más.

```bash
kubectl --context "$CTX" -n payments create serviceaccount api-manager-agent
```

```bash
export NAMESPACE=payments
export KEYS_NAMESPACE=kuadrant-system
export AGENT_SA=api-manager-agent
export AGENT_NAMESPACE=payments
gomplate -f "$SVC/manifests/rbac.yaml.tpl" -o /tmp/rbac.rendered.yaml
kubectl --context "$CTX" apply -f /tmp/rbac.rendered.yaml
```

```
# →
role.rbac.authorization.k8s.io/api-manager created
rolebinding.rbac.authorization.k8s.io/api-manager created
role.rbac.authorization.k8s.io/api-manager-keys created
rolebinding.rbac.authorization.k8s.io/api-manager-keys created
clusterrole.rbac.authorization.k8s.io/api-manager-httproutes-read created
clusterrolebinding.rbac.authorization.k8s.io/api-manager-httproutes-read created
```

Confirmar los límites, ANTES de usarlos:

```bash
SA="system:serviceaccount:payments:api-manager-agent"
kubectl --context "$CTX" --as="$SA" auth can-i create httproutes -n payments
kubectl --context "$CTX" --as="$SA" auth can-i patch authpolicies -n payments
kubectl --context "$CTX" --as="$SA" auth can-i create secrets -n kuadrant-system
kubectl --context "$CTX" --as="$SA" auth can-i get secrets -n kuadrant-system
kubectl --context "$CTX" --as="$SA" auth can-i get secret/payments-wristband-key -n kuadrant-system
```

```
# →
yes
yes
yes
no
no
```

### El `Role` restringido alcanza para todo el ciclo — verificado

El `get secret/payments-wristband-key` de arriba da **`no`**, y está bien que así sea: `get` sobre
secrets en `kuadrant-system` permitiría **leer la clave de firma del wristband** del
`egress-interceptor`, que vive en ese namespace.

> **Historia, por si te la cruzás en un log viejo.** El commit `d849411` había agregado una
> precondición en `reconcile apply` que hacía `kubectl get secret` sobre la clave de firma. Bajo este
> `Role` esa precondición fallaba **siempre**, con un mensaje que decía "no existe el Secret" cuando
> el problema era de permisos. Se sacó en `4272bd1`: la restricción de RBAC gana, y una clave faltante
> o mal formada se manifiesta como `401` en el tráfico (Paso 10), no en el apply — consistente con el
> gotcha #25, que dice que una clave mal formada falla con todo reportando verde.

**Verificado el 2026-09-01:** `reconcile ARGS=apply` corre completo bajo la identidad restringida.

```bash
TOKEN=$(kubectl --context "$CTX" create token api-manager-agent -n payments --duration=2h)
SERVER=$(kubectl --context "$CTX" config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl --context "$CTX" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
cat > /tmp/kubeconfig-sa <<EOF
apiVersion: v1
kind: Config
clusters: [{name: apimgr-sa, cluster: {server: ${SERVER}, certificate-authority-data: ${CA}}}]
contexts: [{name: apimgr-sa, context: {cluster: apimgr-sa, namespace: payments, user: api-manager-agent}}]
current-context: apimgr-sa
users: [{name: api-manager-agent, user: {token: ${TOKEN}}}]
EOF
```

```
# →
api-manager gitops: sin repo configurado, no se publica.
httproute.gateway.networking.k8s.io/api-manager-<service-id> created
authpolicy.kuadrant.io/api-manager-<service-id> created
api-manager: <app-target> expuesto.
```

**Todo el runbook corre con `/tmp/kubeconfig-sa`**, no con el admin. Si algún paso falla por permisos,
es un hallazgo real del RBAC, no un artefacto del setup.

---

### `build_context` contra un scope real y alcanzable

**Qué valida:** que `build_context` resuelva el backend de una ruta contra un scope **real y con
tráfico real** (a diferencia de CRC, donde ningún scope de la cuenta resolvía) y que resuelva
`APP_TARGET` contra un service real (Paso 3).

El scope de prueba en este cluster es `eks` (de `hello-world-poc`), con una release real: route
`k-8-s-eks-1049050904-internal` en `payments`, dominio
`galicia-poc-hello-world-poc-eks-arcuy.galicia-poc.nullapps.io`. Ese dominio no tiene DNS público —
no importa: viaja como `Host` reescrito dentro de la malla, nunca se resuelve por DNS.

```bash
export NP_ACTION_CONTEXT='{
  "notification": {
    "service": {
      "id": "ec53bf2c-5831-4a85-ab4c-b16762ddd861",
      "attributes": {
        "hosts": ["api-test.local"],
        "routes": [{"path": "/whoami", "methods": ["GET"], "scope": "eks"}]
      }
    },
    "application": {"id": 142495574},
    "parameters": {}
  }
}'
export CONTEXT=$(echo "$NP_ACTION_CONTEXT" | jq '.notification')
export ARGS=apply
export NAMESPACE_OVERRIDE=payments
export LOCAL_INGRESS_HOST=s2s-ingress-istio.gateways.svc.cluster.local

PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  source "'"$SVC"'/scripts/k8s/build_context"
  echo "APP_TARGET=$APP_TARGET"
'
```

```
# →
api-manager: exponiendo galicia-poc.hello-world-poc key=payments-wristband-key
  dominio: api-test.local
  ruta: GET /whoami → scope eks = galicia-poc-hello-world-poc-eks-arcuy.galicia-poc.nullapps.io
APP_TARGET=galicia-poc.hello-world-poc
```

`WRISTBAND_SECRET` sale `payments-wristband-key` por default (`{namespace}-wristband-key` con
`NAMESPACE=payments`) — la misma clave con la que `egress-interceptor` firma para `payments`,
reusada acá. `APP_TARGET` sale namespace-slug-de-nullplatform punto application-slug (ver el aviso
del Paso 3), no algo derivado del namespace de Kubernetes.

**Dos guardas más, también contra la cuenta real:**

```bash
# scope que no existe entre los activos de la aplicación
export NP_ACTION_CONTEXT='{"notification":{"service":{"id":"ec53bf2c-5831-4a85-ab4c-b16762ddd861","attributes":{"hosts":["h.local"],"routes":[{"path":"/","methods":["GET"],"scope":"no-existe"}]}},"application":{"id":142495574},"parameters":{}}}'
export CONTEXT=$(echo "$NP_ACTION_CONTEXT" | jq '.notification')
PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  source "'"$SVC"'/scripts/k8s/build_context"
'
```

```
# →
api-manager: el scope 'no-existe' no está entre los scopes activos de la aplicación 142495574.
```

```bash
# LOCAL_INGRESS_HOST sin forma de host
export LOCAL_INGRESS_HOST="no un host"
PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  source "'"$SVC"'/scripts/k8s/build_context"
' 2>&1
```

```
# →
api-manager build_context: valor inválido para local_ingress_host: 'no un host'
```

**El ruteo va vía loopback, no directo al scope.** El `backendRef` del `HTTPRoute` no apunta al
dominio del scope (`kind: Hostname` no resuelve un dominio externo — Envoy no le arma cluster, daba
`500`); apunta siempre al gateway de ingreso local (`LOCAL_INGRESS_HOST`, puerto 443 fijo), y un
filtro `URLRewrite` reescribe el `Host` al dominio del scope. El request rebota contra el mismo
gateway con el `Host` correcto, y de ahí lo toma el `HTTPRoute` propio del scope. Eso exige que el
segundo salto pueda hablar TLS consigo mismo — el prerequisito del Paso 5.1.

---

### Prerequisito: TLS de origen en el loopback del gateway (APLICADO)

**Qué hace falta y por qué:** el listener de `s2s-ingress` es HTTPS/`Terminate` (Paso 0). El salto
de vuelta del Paso 5 es un cliente más de ese listener, así que también tiene que hablarle en TLS —
sin eso da `503`. Lo provee un `DestinationRule` (`s2s-ingress-loopback`, namespace `gateways`,
`trafficPolicy.tls.mode=SIMPLE` contra el propio Service del gateway), del módulo `kuadrant-s2s`
(`accounts/galicia/demo-kuadrant-s2s/modules/kuadrant-s2s/gateway.tf`, recurso
`kubectl_manifest.ingress_loopback`, commit `627d9a7`), gateado por `var.validate_identity`.

**Estado: aplicado.**

```bash
kubectl --context "$CTX" -n gateways get destinationrule s2s-ingress-loopback \
  -o jsonpath='{.metadata.name}   host={.spec.host}{"\n"}'
```

```
# →
s2s-ingress-loopback   host=s2s-ingress-istio.gateways.svc.cluster.local
```

Sin este `DestinationRule` el segundo salto da `503` (falla la conexión TLS); con él aplicado y sin
el wristband correcto daría `401` (la conexión TLS funciona, pero la route del scope exige
`x-np-token`); con la `AuthPolicy` de este service acuñando el wristband después de validar la API
key (Paso 9), el segundo salto autoriza — es la cadena completa que el Paso 10 confirma.

---

### Crear la instancia: `reconcile apply`

**Qué valida:** el camino de `create` — renderizar los manifiestos (`HTTPRoute` + `AuthPolicy`) y
aplicarlos —, **sin GitOps** todavía (Paso 7 lo agrega: es opcional). Corrido con el `kubeconfig`
`/tmp/kubeconfig-sa` del Paso 4, o sea con la identidad restringida.

```bash
export NAMESPACE=payments
export APP_TARGET=galicia-poc.hello-world-poc
export SERVICE_ID=ec53bf2c-5831-4a85-ab4c-b16762ddd861
export HOSTS_JSON='["api-test.local"]'
export ROUTES_JSON='[{"path":"/whoami","methods":["GET"],"scope":"eks","backend":"galicia-poc-hello-world-poc-eks-arcuy.galicia-poc.nullapps.io"}]'
export GATEWAY_NAME=s2s-ingress
export GATEWAY_NAMESPACE=gateways
export KEYS_NAMESPACE=kuadrant-system
export API_KEY_HEADER=x-api-key
export LOCAL_INGRESS_HOST=s2s-ingress-istio.gateways.svc.cluster.local
export WRISTBAND_SECRET=payments-wristband-key
export TOKEN_DURATION=300
export ARGS=apply

kubectl config use-context "$CTX"   # el script no usa --context; corre contra el current-context
PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/reconcile"
'
```

```
# →
api-manager gitops: sin repo configurado, no se publica.
httproute.gateway.networking.k8s.io/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 created
authpolicy.kuadrant.io/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 created
api-manager: galicia-poc.hello-world-poc expuesto.
```

Los nombres de los objetos son `api-manager-${SERVICE_ID}`, con las labels
`api-manager.nullplatform.io/managed=true` y `apimgr-target=galicia-poc.hello-world-poc`, más
`nullplatform=true`. La línea `sin repo configurado, no se publica.` confirma que **GitOps es
opcional** (Paso 7).

Después de `created`, `reconcile` corre un **re-chequeo de colisiones posterior al apply**
(`find_route_conflicts`, la misma función de `check_collisions`, Paso 11) — mitigación de una
carrera real: el agente puede ejecutar notificaciones en paralelo, y la ventana entre
`check_collisions` y este `apply` es de segundos. Si dos `create` concurrentes declaran el mismo
`(host, path)`, los dos pasan el chequeo previo; el re-chequeo post-apply detecta y **revierte** el
que acaba de crear, fail-closed en las dos puntas. Acá no hay nadie más aplicando nada, así que pasa
en silencio.

---

### GitOps: publicar antes de aplicar

**Qué valida:** que los manifiestos se publiquen a un repo git **antes** de tocar el cluster, y que
un push que falla no deje nada aplicado — ni al crear, ni al borrar, ni al revertir una carrera. Es
el mismo contrato que ya cumple `egress-interceptor` (reusa su `gitops_lib`). **El mecanismo no
depende del cluster destino** — ya se verificó con un repo git local de prueba; no se re-corrió en
esta pasada contra EKS porque no cambia con el cluster.

### Es opcional

Ya quedó demostrado en el Paso 6: con `GITOPS_REPO_URL` sin setear, `gitops_enabled()` da falso y
`reconcile` sigue de largo sin publicar nada.

### De dónde salen las variables `GITOPS_*`

**Lo que es por cluster viene del entorno del agente, sin declararse en el workflow; lo que es por
service, del `configuration:` de `create.yaml`/`delete.yaml`.** Mismo criterio que
`egress-interceptor` usa para `ORIGIN`/`GITOPS_REPO_URL`.

| Variable | De dónde sale | Por qué |
|---|---|---|
| `GITOPS_REPO_URL` | **entorno del agente**, nunca el workflow | es por cluster, puede llevar un token embebido |
| `ORIGIN` | **entorno del agente**, nunca el workflow | de ahí sale la carpeta del cluster: `EKS` → `eks`, cualquier otra cosa → `openshift`. Ya lo exporta `start-agent-eks.sh` |
| `GITOPS_BRANCH` | **entorno del agente** (default `main` si no está) | es del repo gitops, no del service |
| ~~`GITOPS_PATH_PREFIX`~~ | — | no se usa: `cross-namespace-rules` es constante del service (`API_MANAGER_GITOPS_PREFIX` en `gitops_lib`) |
| `GITOPS_PUSH_RETRIES` | `configuration:` del workflow (`5`) | decisión del service |

⚠️ **`ORIGIN` no va en `configuration:` del workflow, ni siquiera vacía.** El env del agente le gana
al `configuration:`, así que declararla ahí no la pisa — pero queda como único valor si el agente no
la trae, y el service publica bajo la carpeta del cluster equivocado sin avisar.

⚠️ **Nunca poner una URL con credencial real en este documento.** Un repo git local
(`file://`/path absoluto) alcanza para probar el mecanismo.

### Separación por carpetas: dos services, un repo

`egress-interceptor` publica bajo `intra-namespace-rules/`; este service, bajo
`cross-namespace-rules/`. El subárbol es por **service**, no por namespace
(`<prefix>/<eks|openshift>/<namespace>/<route_name>`) — varias apps expuestas pueden compartir el mismo
namespace de Kubernetes, así que copiar el criterio del egress (subárbol por namespace entero)
habría hecho que publicar la ruta de una app se llevara puesta la de su vecina.

### Fail-closed, verificado (repo de prueba local)

Con una URL de repo inválida, ni el `apply` ni el `delete` tocan el cluster —
`gitops_publish`/`gitops_publish_removal` corre antes de cualquier `kubectl apply`/`delete`, y si
falla, `reconcile` aborta ahí. Verificado con el `resourceVersion` del `HTTPRoute` idéntico
antes/después de un intento fallido, y con el objeto todavía presente después de un intento de
`delete` fallido. El comando, para reproducirlo:

```bash
export GITOPS_REPO_URL="/no/existe/en/este/filesystem.git"
export ORIGIN=EKS
export GITOPS_BRANCH=main
# resto de las variables del Paso 6 sin cambios
PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/reconcile"
'
```

```
# →
fatal: repository '/no/existe/en/este/filesystem.git' does not exist
api-manager gitops: no se pudo clonar /no/existe/en/este/filesystem.git (branch main).
api-manager: falló la publicación de los manifiestos al repo gitops. NO se aplicó nada.
```

---

### Verificar lo materializado

**Qué valida:** que el `HTTPRoute` esté `Accepted` y que la `AuthPolicy` esté **`Enforced`** — la
señal que de verdad importa (Gotcha #22, primer aviso de este runbook).

```bash
kubectl --context "$CTX" -n payments get httproute api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 \
  -o jsonpath='{range .status.parents[*]}{.parentRef.name}: {range .conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}'
kubectl --context "$CTX" -n payments get authpolicy api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

```
# →
s2s-ingress: Accepted=True(Accepted) ResolvedRefs=False(BackendNotFound)
s2s-ingress: kuadrant.io/AuthPolicyAffected=True(Accepted) kuadrant.io/RateLimitPolicyAffected=True(Accepted)
Accepted=True Accepted
Enforced=True Enforced
```

**`ResolvedRefs=False` sale incluso apuntando a `s2s-ingress-istio`, un `Service` real y existente
del namespace `gateways`.** Verificado en dos clusters (EKS y CRC) con el mismo resultado — no es
una particularidad de uno de los dos. Hipótesis no confirmada: `kind: Hostname` podría no resolver
un `Service` de **otro namespace** que el `HTTPRoute` (acá el `HTTPRoute` vive en `payments`, el
`Service` en `gateways`). No cambia el aviso #2 de este runbook: **`Enforced` es la señal a mirar,
no `ResolvedRefs`** — acá mismo, con `ResolvedRefs=False`, el Paso 10 prueba el 200 real.

`kuadrant.io/RateLimitPolicyAffected` aparece porque este Gateway ya tiene una `RateLimitPolicy` de
la demo S2S — no la agrega ni la usa este service.

---

### Linkear una app consumidora: `mint_key`

**Qué valida:** que linkear emita una credencial nueva, con las tres labels exactas que Authorino
necesita para resolverla como `apiKey` válida, en `kuadrant-system` (no el namespace de la app).

`mint_key` no toma `APP_TARGET` de una variable de entorno — la notificación trae `.service.id` (el
service **expuesto**, no la app consumidora) y `mint_key` llama a `resolve_app_target_from_service`,
la misma función de `build_context` (Paso 3/5). No necesita el `Role` con `get` sobre el Secret de
firma (Paso 4) — corre bien bajo el `kubeconfig` restringido.

```bash
export NP_ACTION_CONTEXT='{"notification":{"link":{"id":"linktest0001"},"service":{"id":"ec53bf2c-5831-4a85-ab4c-b16762ddd861"}}}'
export KEYS_NAMESPACE=kuadrant-system

KUBECONFIG=/tmp/kubeconfig-sa PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/mint_key"
'
```

```
# →
secret/api-manager-linktest0001 created
error: 'missing required flags: service-action-id, use --help for more details'
api-manager: falló la escritura de los resultados del link.
```

El `error` final es **esperado** (Paso 3): `np service action update` necesita una acción real en
curso. El Secret sí se creó:

```bash
kubectl --context "$CTX" -n kuadrant-system get secret api-manager-linktest0001 -o yaml
```

```
# →
apiVersion: v1
data:
  api_key: <base64 de 64 hex chars, openssl rand -hex 32>
kind: Secret
metadata:
  labels:
    api-manager.nullplatform.io/managed: "true"
    apimgr-target: galicia-poc.hello-world-poc
    authorino.kuadrant.io/managed-by: authorino
  name: api-manager-linktest0001
  namespace: kuadrant-system
type: Opaque
```

| Label | Para qué |
|---|---|
| `authorino.kuadrant.io/managed-by=authorino` | marca el Secret como gestionado por Authorino |
| `api-manager.nullplatform.io/managed=true` | matchea el `apiKey.selector.matchLabels` de la `AuthPolicy` — común, no filtra por app |
| `apimgr-target=galicia-poc.hello-world-poc` | la identidad que la `AuthPolicy` compara en `authorization`, vía notación de punto |

⚠️ **El Secret tiene que vivir en `kuadrant-system`, no en el namespace de la app** — Kuadrant
traduce toda `AuthPolicy` a un `AuthConfig` en el namespace de la `AuthPolicy`, y Authorino resuelve
`apiKey` contra ESE namespace.

```bash
KEY1=$(kubectl --context "$CTX" -n kuadrant-system get secret api-manager-linktest0001 -o jsonpath='{.data.api_key}' | base64 -d)
```

En un link real, este valor es el que la plataforma exporta como `API_MANAGER_API_KEY` a la app
consumidora (`specs/links/connect.json.tpl`) — acá no hay una app consumidora real desplegada, así
que ese último tramo (la env var llegando al pod) sigue sin ejercitarse.

### La key de la "otra app", para el caso 403

`mint_key` resuelve siempre desde un `SERVICE_ID` real (arriba); no hay un segundo service real que
resuelva a una app distinta sin crear infraestructura nueva. Para el 403 hace falta una key
**válida pero de otra identidad** — se crea el Secret directo, aislando lo que ese caso prueba:

```bash
kubectl --context "$CTX" -n kuadrant-system create secret generic api-manager-otraapp \
  --from-literal=api_key="$(openssl rand -hex 32)" --dry-run=client -o yaml \
  | kubectl label --local -f - -o yaml \
      authorino.kuadrant.io/managed-by=authorino \
      api-manager.nullplatform.io/managed=true \
      apimgr-target=other.otra-app \
  | kubectl --context "$CTX" apply -f -
KEY2=$(kubectl --context "$CTX" -n kuadrant-system get secret api-manager-otraapp -o jsonpath='{.data.api_key}' | base64 -d)
```

```
# →
secret/api-manager-otraapp created
```

Este Secret **no** pasó por `mint_key` — el Paso 13 lo borra a mano.

---
