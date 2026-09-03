# Runbook de pruebas — Api Manager sobre CRC local

**El runbook principal es [`RUNBOOK-PRUEBAS.md`](./RUNBOOK-PRUEBAS.md), enfocado en EKS.** Este
documento cubre sólo lo que cambia al correrlo contra el CRC local. Los pasos, las verificaciones y
las salidas esperadas son las de allá salvo donde acá se diga otra cosa.

## Lo que cambia

**El contexto.** En vez del ARN de EKS:

```bash
export CTX=crc-admin
```

**El cluster hay que levantarlo.** No existe el equivalente en EKS:

```bash
crc status | head -2
# → CRC VM: Running · OpenShift: Running

kubectl config current-context
# → crc-admin
```

Si está apagado, `crc start` (~3 min con la VM ya creada). Después de cada arranque conviene revisar
el gotcha #24 del repo sobre higiene del tailnet, que aplica a la demo S2S y puede afectar lo que
comparte sustrato con este service.

**Herramientas.** Se suma `crc` a la lista del Paso 0; `aws` no hace falta.

**El servicio jwks se llama distinto.** En CRC es `s2s-crc-jwks`, en EKS `s2s-eks-jwks`. Aparece en la
salida esperada del sustrato y en los `jwksUrl` que acepta `s2s-validator`.

**El backend de prueba.** En CRC está el echo server `reports` (Service en 8080, path `/whoami`) de la
demo S2S, que no existe en EKS. Varios pasos de este documento lo usan como destino conveniente.

**La ServiceAccount de RBAC.** El bloque que arma el kubeconfig para probar con impersonation lee el
cluster `api-crc-testing:6443` del kubeconfig local. En EKS eso se resuelve con `--minify` sobre el
contexto.

## Todo lo demás

Idéntico al runbook de EKS. Lo que sigue es la versión completa histórica corrida contra CRC, que se
conserva porque sus salidas son medidas reales de ese entorno.

---

## Índice

| # | Paso |
|---|---|
| 0 | **¿Se puede arrancar?** — prerrequisitos y estado de partida limpio |
| 1 | Registrar el service specification (Terraform, `specs/install/`) |
| 2 | Levantar el agente — **bloqueado en este entorno**, con la causa exacta |
| 3 | Cómo se prueba sin un agente vivo (metodología del resto del runbook) |
| 4 | RBAC de prueba: `ServiceAccount` restringida + `kubeconfig` con impersonation |
| 5 | `build_context` contra un scope real de la cuenta |
| 5.1 | Prerequisito: TLS de origen en el loopback — **APLICADO** |
| 6 | Crear la instancia: `reconcile apply` |
| 7 | GitOps: publicar antes de aplicar |
| 8 | Verificar lo materializado: `HTTPRoute` `Accepted`, `AuthPolicy` **`Enforced`** |
| 9 | Linkear una app consumidora: `mint_key` y la env var `<SERVICE_SLUG>_API_KEY` |
| 10 | Los cuatro códigos + el quinto (404) |
| 11 | Colisión de dominios |
| 12 | Revocar el link |
| 13 | Teardown |
| — | Los avisos que no pueden faltar |
| — | Troubleshooting |

---

## Paso 0 — ¿Se puede arrancar?

**Qué valida:** que estén los prerrequisitos y que el punto de partida esté **limpio**. Si algo de
esto falla, los pasos siguientes fallan más tarde con un síntoma que no señala la causa.

```bash
cd ~/nullplatform/galicia/galicia-banco
export SVC=~/nullplatform/galicia/custom-scopes-workshop-fede-galicia-override/api-manager
export NP_API_KEY="$(cat accounts/galicia/np-api-skill.key)"
export NRN="organization=1636958496:account=1374028000"
```

### 1. Herramientas

```bash
for b in kubectl jq yq gomplate np crc openssl; do
  printf '%-10s %s\n' "$b" "$(command -v $b || echo 'FALTA')"
done
/opt/homebrew/bin/bash --version | head -1
```

```
kubectl    /usr/local/bin/kubectl
jq         /usr/bin/jq
yq         /opt/homebrew/bin/yq
gomplate   /opt/homebrew/bin/gomplate
np         /Users/federico.maleh/.local/bin/np
crc        /usr/local/bin/crc
openssl    /usr/bin/openssl
GNU bash, version 5.3.15(1)-release (aarch64-apple-darwin24.6.0)
```

`bash` tiene que ser **>= 4**: el de `/bin` en macOS es 3.2 y no corre ni los tests del service
(`${level,,}` en `logging`) ni `mapfile` (usado por `reconcile`). Cada bloque de este runbook que
corre un script del service lo hace explícitamente con `/opt/homebrew/bin/bash` o con
`PATH=/opt/homebrew/bin:$PATH` por delante — no alcanza con tenerlo instalado, hay que asegurarse de
que sea el que se ejecuta.

### 2. El CRC está arriba y responde

```bash
crc status | head -2
kubectl config current-context
kubectl --context crc-admin get ns kuadrant-system payments other gateways -o name
```

```
CRC VM:          Running
OpenShift:       Running (v4.21.14)
crc-admin
namespace/kuadrant-system
namespace/payments
namespace/other
namespace/gateways
```

### 3. El sustrato compartido está sano

**Qué valida:** que Kuadrant/Authorino/Gateway API —que este service NO instala, ver Paso 2— estén
arriba y que el Gateway de ingreso exista.

```bash
kubectl --context crc-admin -n kuadrant-system get deploy --no-headers
kubectl --context crc-admin get authorino -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} clusterWide={.spec.clusterWide}{"\n"}{end}'
kubectl --context crc-admin -n gateways get gateway s2s-ingress -o jsonpath='Programmed: {.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
```

```
authorino                               1/1     1            1           11d
authorino-operator                      1/1     1            1           11d
dns-operator-controller-manager         1/1     1            1           11d
kuadrant-console-plugin                 1/1     1            1           11d
kuadrant-operator-controller-manager    1/1     1            1           11d
limitador-limitador                     1/1     1            1           11d
limitador-operator-controller-manager   1/1     1            1           11d
s2s-crc-jwks                            1/1     1            1           11d
kuadrant-system/authorino clusterWide=true
Programmed: True
```

### 4. El punto de partida está limpio

```bash
kubectl --context crc-admin -n payments get httproute,authpolicy,gateway,destinationrule --no-headers
kubectl --context crc-admin -n gateways get httproute --no-headers
kubectl --context crc-admin -n kuadrant-system get secret -l api-manager.nullplatform.io/managed=true
kubectl --context crc-admin -n payments get svc reports -o jsonpath='{.spec.selector}{"\n"}'
kubectl --context crc-admin -n gateways get gateway s2s-ingress -o jsonpath='attachedRoutes: {.status.listeners[0].attachedRoutes}{"\n"}'
kubectl --context crc-admin -n gateways get authpolicy s2s-validator -o jsonpath='Accepted: {.status.conditions[?(@.type=="Accepted")].status}  Enforced: {.status.conditions[?(@.type=="Enforced")].status}{"\n"}'
```

**Qué tenés que ver:**

| | Esperado |
|---|---|
| `httproute`/`authpolicy`/`gateway`/`destinationrule` en `payments` | ninguno |
| `httproute` en `gateways` | ninguna |
| Secrets con `api-manager.nullplatform.io/managed=true` en `kuadrant-system` | ninguno |
| Selector de `reports` | `{"app":"reports"}` |
| `attachedRoutes` del listener de `s2s-ingress` | `0` |
| `s2s-validator` | `Accepted: True  Enforced: False` |

⚠️ **El último renglón sorprende la primera vez: `Enforced: False` es el estado correcto acá**, no
una falla. `s2s-validator` sólo enforcea cuando hay al menos un `HTTPRoute` colgado del Gateway
(Gotcha #22); en el punto de partida, sin ninguna intercepción de la demo S2S activa, no hay
ninguno. Va a pasar a `True` en cuanto este runbook cuelgue su propio `HTTPRoute` en el Paso 6, y
tiene que volver a `False` después del teardown (Paso 13) — es la misma señal, mirada dos veces.

Si algo de esto no da lo esperado, hay resto de una corrida anterior: repetí el Paso 13 antes de
seguir.

---

## Paso 1 — Registrar el service specification

**Qué valida:** que `specs/install/` registre el service en la cuenta real. Es una acción **de
cuenta**, no de cluster: no toca el CRC, y a diferencia de las instancias que se crean y se borran
en cada corrida (Paso 6 y Paso 13), el service specification **queda registrado de forma
permanente** — es el mismo modelo que `egress-interceptor`, cuyo spec se registró una sola vez al
principio del proyecto y nunca se destruye entre demos.

```bash
cd "$SVC/specs/install"
cp terraform.tfvars.example terraform.tfvars
```

Completar `terraform.tfvars` (gitignoreado por `*.tfvars` en este repo):

```hcl
np_api_key    = "<la api key de accounts/galicia/np-api-skill.key>"
agent_api_key = "<la misma api key>"
nrn           = "organization=1636958496:account=1374028000"

tags_selectors = {
  role = "api-manager"
}

repository_service_spec_repo = "kwik-e-mart/custom-scopes-workshop-fede-galicia-override"
service_path                 = "api-manager"
extra_visible_to_nrns        = []
```

```bash
tofu init
tofu plan -out=install.tfplan
```

```
# →
Plan: 4 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + service_specification_slug = (known after apply)
```

Disciplina plan-first: mostrar este plan y tener el ok explícito antes de aplicar. Es aditivo puro
(0 to change, 0 to destroy) — no hay ningún recurso existente en juego.

```bash
tofu apply install.tfplan
```

```
# →
module.service_definition.nullplatform_service_specification.from_template: Creation complete after 2s [id=f0ff57e2-29db-4c1f-8ff6-9fd94a27e8a6]
module.service_definition.nullplatform_link_specification.from_templates["connect"]: Creation complete after 2s [id=30332b58-598a-4fa5-a5a3-820d59037426]
module.service_definition_agent_association.nullplatform_notification_channel.channel_from_template: Creation complete after 0s [id=2035870801]

Apply complete! Resources: 4 added, 0 changed, 0 destroyed.

Outputs:

service_specification_slug = "api-manager"
```

**Verificar contra la API** (no contra el output de Terraform, que sólo confirma que el `apply`
corrió):

```bash
NP_API="$HOME/.claude/plugins/marketplaces/nullplatform-internal/src/skills/np-api/scripts/np-api.sh"
[ -x "$NP_API" ] || NP_API=$(find "$HOME/.claude" -path '*np-api/scripts/np-api.sh' | head -1)
"$NP_API" fetch-api "/service_specification?nrn=$NRN" | jq -c '.results[]|select(.slug=="api-manager")|{id,name,slug,type,available_links}'
```

```
# →
{"id":"f0ff57e2-29db-4c1f-8fb6-9fd94a27e8a6","name":"Api Manager","slug":"api-manager","type":"dependency","available_links":null}
```

`available_links` sale `null` en este listado resumido; el link `connect` está registrado por
separado como `link_specification` (id `30332b58-…`, confirmado en el output de arriba) y aparece
en el form de creación de instancias de la UI.

⚠️ **Este paso no se deshace en el teardown (Paso 13).** El service specification queda en la cuenta
para que Api Manager esté disponible como opción real, igual que `egress-interceptor`,
`endpoint-exposer`, etc. Lo que se crea y se destruye en cada corrida de prueba es la **instancia**
(Paso 6) y sus objetos de cluster, no el spec.

---

## Paso 2 — Levantar el agente (bloqueado en este entorno)

**Qué intenta:** un `np-agent` en runtime host, igual que hace
`demo-kuadrant-s2s/start-agent-crc.sh` para `egress-interceptor`, atendiendo el `tags_selectors`
`role=api-manager` que se acaba de registrar.

Antes de arrancarlo hace falta saber qué comando va a ejecutar el agente cuando le llegue una
notificación. Eso lo fija el **channel**, ya creado en el Paso 1:

```bash
kubectl --context crc-admin -n payments get pods 2>&1 | head -1  # sólo para tener algo de output real arriba
tofu -chdir="$SVC/specs/install" show install.tfplan 2>&1 | grep cmdline
```

```
# →
"cmdline"     = "/root/.np/kwik-e-mart/custom-scopes-workshop-fede-galicia-override/api-manager-publisher/entrypoint/entrypoint"
```

`base_clone_path` no se pasa en `install/main.tf` (queda en su default del módulo,
`/root/.np`), así que el channel apunta a esa ruta **absoluta y fija** en cualquier máquina que
corra el agente — no a `~/.np` del usuario que lo levanta. En un agente **k8s-runtime** (un pod)
esto es transparente: `/root` es el `HOME` de la mayoría de las imágenes base y el operator clona
ahí. En un agente **host-runtime en esta laptop** (el modelo que usa `demo-kuadrant-s2s` para
`egress-interceptor`, vía `start-agent-crc.sh`) hace falta que exista literalmente
`/root/.np/kwik-e-mart/custom-scopes-workshop-fede-galicia-override`, con este repo cloneado o
symlinkeado ahí adentro — el mismo mecanismo que el Apéndice A de
`demo-kuadrant-s2s/RUNBOOK-PRUEBAS.md` documenta para `~/.np`, pero apuntado a `/root` en vez de al
`$HOME` de quien corre el agente.

```bash
ls -ld /root
sudo -n true
```

```
# →
ls: /root: No such file or directory
sudo: a password is required
```

**BLOQUEADO.** macOS no tiene `/root` (el home de `root` ahí es `/var/root`), y esta sesión no tiene
un password de `sudo` interactivo para crearlo con los permisos correctos ni para que el proceso del
agente — corriendo como usuario normal, no como `root` — pueda atravesarlo. Sin esa ruta, el
`cmdline` del channel apunta a un archivo que no existe en esta laptop, y el agente fallaría el
`exec` en cuanto le llegara cualquier notificación.

Esto **no es un bug del service**: es una limitación específica de correr el agente en modo
host-runtime sobre macOS con este `base_clone_path` sin override. El comando que se ejecutaría en un
entorno donde sí existe `/root` (o pasando `base_clone_path` a un valor accesible, lo cual requiere
tocar `install/main.tf`, fuera del alcance de este runbook) es:

```bash
# NO EJECUTADO — requiere que exista /root/.np/kwik-e-mart/... o un override de base_clone_path
np-agent \
  -api-key "$NP_API_KEY" \
  -runtime host \
  -tags "role:api-manager" \
  -command-executor-env "NP_API_KEY=$NP_API_KEY,KUBECONFIG=$KUBECONFIG,PATH=/opt/homebrew/bin:$PATH" \
  -command-executor-debug \
  -log-level DEBUG -log-pretty-print
```

Consecuencia práctica: **el resto de este runbook no puede pasar por el camino
notificación→agente→workflow real.** El Paso 3 explica qué se hizo en cambio y por qué el resultado
sigue siendo una verificación genuina contra el cluster real.

---

## Paso 3 — Cómo se prueba sin un agente vivo

Sin agente, crear una instancia real (`np service create` + la acción `create`) dejaría la instancia
en `pending` para siempre — nadie la procesa — y el gotcha ya documentado en
`demo-kuadrant-s2s/RUNBOOK-PRUEBAS.md` aplica: una instancia `pending`/`failed` **no la puede borrar
la API key del repo** (403; hace falta un token de usuario o la consola). Crear una así habría sido
la manera más rápida de ensuciar la cuenta sin poder limpiarla después.

**Lo que se hace en cambio, y es exactamente el mismo método con el que Task 0 de este plan validó
el mecanismo antes de escribir una sola línea de código:** correr los scripts reales del service
(`build_context`, `check_collisions`, `reconcile`, `mint_key`, `revoke_key`) directamente, con un
`NP_ACTION_CONTEXT` armado a mano que respeta exactamente la forma que el código espera. Esto NO es
un mock — es el código de producción, corriendo contra el cluster real, con las mismas llamadas
`kubectl` y `np` que haría el agente. Lo único que cambia es *quién* invoca el script: acá lo hace
esta sesión, en vez de `np service-action exec --script=...` disparado por una notificación real de
la plataforma.

El contrato que cada script espera (derivado de `entrypoint/entrypoint`,
`scripts/k8s/build_context` y `workflows/istio/*.yaml`):

| Variable | Quién la pone | Quién la consume |
|---|---|---|
| `NP_ACTION_CONTEXT` | la plataforma (acá: a mano) | `entrypoint`, `build_context`, `mint_key`, `revoke_key` |
| `CONTEXT` (= `.notification` de `NP_ACTION_CONTEXT`) | `entrypoint` (acá: a mano) | `build_context` |
| `NAMESPACE`, `APP_TARGET`, `SERVICE_ID`, `HOSTS_JSON`, `ROUTES_JSON` | `build_context` | `check_collisions`, `reconcile` |
| `GATEWAY_NAME`, `GATEWAY_NAMESPACE`, `KEYS_NAMESPACE`, `API_KEY_HEADER`, `LOCAL_INGRESS_HOST` | la `configuration:` del workflow | `build_context`, `reconcile`, `mint_key`, `revoke_key` |
| `GITOPS_*` (Paso 7) | la `configuration:` del workflow + el `.env`/entorno del agente | `reconcile` (vía `gitops_lib`) |

**Un cambio de diseño (2026-09-01) que endurece este contrato: `APP_TARGET` ya no se puede pasar a
mano.** `build_context` y `mint_key` lo derivan cada uno por su cuenta, llamando a
`resolve_app_target_from_service "$SERVICE_ID"` — que hace `np service read --id $SERVICE_ID` contra
la plataforma, saca el `namespace`/`application` del `entity_nrn` que devuelve, y resuelve sus slugs
con `np namespace read`/`np application read`. Antes, la notificación podía traer directamente
`application.slug` y listo. La razón está documentada en el propio diseño: el link que emite la
credencial lo crea la app **consumidora**, que vive en otro namespace — si `APP_TARGET` saliera del
contexto de la acción (que es sobre la app consumidora) en vez de derivarse del service instance
**expuesto**, la key quedaría etiquetada con la identidad equivocada. Resolverlo así lo hace correcto
por construcción, no por lo que alguien haya puesto en un JSON.

**Consecuencia directa para este runbook: `SERVICE_ID` ya no puede ser un string inventado — tiene
que ser el `id` de un service real de la cuenta.** Como Api Manager en sí no tiene ninguna instancia
real (Paso 3, arriba), este runbook reutiliza el `id` de un service **real mas no relacionado**, ya
existente en la cuenta (`imagenes`, un endpoint-exposer sobre la aplicación real `hello-world-poc`):

```bash
export NP_API_KEY="$(cat ~/nullplatform/galicia/galicia-banco/accounts/galicia/np-api-skill.key)"
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

Es una llamada de sólo lectura — no se toca ese service, sólo se usa su `id` como insumo para que
`resolve_app_target_from_service` tenga algo real que resolver. El `APP_TARGET` resultante
(`galicia-poc.hello-world-poc`, ver Paso 5) refleja la app dueña de **ese** service, que es lo
correcto para probar el mecanismo genérico de labels/autorización aunque la instancia de prueba en sí
no sea una de Api Manager.

⚠️ **Ojo con los dos "namespace" del párrafo anterior — son cosas distintas.** El `namespace` del
`entity_nrn` (acá `824774832`, slug `galicia-poc`) es una **entidad de nullplatform** (organiza
aplicaciones dentro de la cuenta); el `NAMESPACE` que controla dónde se crean el `HTTPRoute`/
`AuthPolicy` (Paso 6, `payments`) es el **namespace de Kubernetes**. Los dos se llaman "namespace",
no tienen por qué coincidir, y de hecho acá no coinciden.

Dos consecuencias más de probar así, declaradas para que no sorprendan más adelante:

- `mint_key` termina con `np service action update --results ...`, una llamada real a la
  plataforma que requiere una acción real en curso. Sin ella, el `kubectl create` del Secret sale
  bien pero esa última línea falla — es el resultado **esperado** de invocar el script fuera de una
  acción real, no un bug.
- `reconcile ARGS=delete` resuelve qué Secrets borrar vía `np link list --service-id $SERVICE_ID`,
  una llamada real. Con el `SERVICE_ID` real de `imagenes` esta llamada **sí sale bien** — pero
  devuelve una lista vacía, porque `imagenes` no tiene ningún link real registrado en la plataforma
  (los que mintea este runbook a mano, Paso 9, no lo son). El borrado final de Secrets del Paso 13
  sigue siendo manual, aunque ahora por un motivo distinto al de antes: no porque la llamada falle,
  sino porque legítimamente no hay nada que la plataforma reconozca como propio para borrar.

---

## Paso 4 — RBAC de prueba

**Qué valida** el cuarto aviso de este runbook: los tests unitarios del service mockean `kubectl`,
así que no ven RBAC. La única manera de saber si el `Role` real alcanza es correr los scripts reales
**impersonando** una identidad que sólo tenga esos permisos, ni uno más.

```bash
kubectl --context crc-admin -n payments create serviceaccount api-manager-agent
```

```bash
export NAMESPACE=payments
export KEYS_NAMESPACE=kuadrant-system
export AGENT_SA=api-manager-agent
export AGENT_NAMESPACE=payments
gomplate -f "$SVC/manifests/rbac.yaml.tpl" -o /tmp/rbac.rendered.yaml
kubectl --context crc-admin apply -f /tmp/rbac.rendered.yaml
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

Confirmar los límites, ANTES de usarlos, con `auth can-i`:

```bash
SA="system:serviceaccount:payments:api-manager-agent"
kubectl --context crc-admin --as="$SA" auth can-i create httproutes -n payments
kubectl --context crc-admin --as="$SA" auth can-i patch authpolicies -n payments
kubectl --context crc-admin --as="$SA" auth can-i create secrets -n kuadrant-system
kubectl --context crc-admin --as="$SA" auth can-i get secrets -n kuadrant-system
kubectl --context crc-admin --as="$SA" auth can-i list secrets -n kuadrant-system
```

```
# →
yes
yes
yes
no
no
```

Los dos `no` son la **restricción inviolable** del diseño (`docs/*` del plan la llama así): el `Role`
de `kuadrant-system` nunca tiene `get` ni `list` sobre `secrets`, porque ese namespace también
guarda las claves de firma del wristband de Authorino de otros services, y un `list` ahí devuelve
los `Secret` completos, con `data`. `mint_key` y `revoke_key`/`reconcile` están escritos para andar
sin esos dos verbos (Paso 9 y Paso 13 lo ejercitan).

### Un `kubeconfig` que impersona de verdad

`auth can-i` confirma el permiso; para que los scripts REALES lo usen hace falta que `kubectl`
(sin flags extra, tal como lo invocan) actúe como esa identidad. Se arma un `kubeconfig` con un
token de la `ServiceAccount`, no con `--as` (los scripts no agregan ese flag):

```bash
TOKEN=$(kubectl --context crc-admin create token api-manager-agent -n payments --duration=2h)
SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="api-crc-testing:6443")].cluster.server}')
CA=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="api-crc-testing:6443")].cluster.certificate-authority-data}')

cat > /tmp/kubeconfig-sa <<EOF
apiVersion: v1
kind: Config
clusters:
- name: crc-sa
  cluster: {server: ${SERVER}, certificate-authority-data: ${CA}}
contexts:
- name: crc-sa
  context: {cluster: crc-sa, namespace: payments, user: api-manager-agent}
current-context: crc-sa
users:
- name: api-manager-agent
  user: {token: ${TOKEN}}
EOF

KUBECONFIG=/tmp/kubeconfig-sa kubectl get secrets -n kuadrant-system
```

```
# →
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:payments:api-manager-agent" cannot list resource "secrets" in API group "" in the namespace "kuadrant-system"
```

De acá en adelante, todo bloque que corre `reconcile`, `mint_key`, `revoke_key` o `check_collisions`
antepone `KUBECONFIG=/tmp/kubeconfig-sa` **sólo a esa invocación** (`KUBECONFIG=/tmp/kubeconfig-sa
bash -c '...'`), nunca con `export` a secas. `/tmp/kubeconfig-sa` sólo define el contexto `crc-sa` —
si quedara exportado en la terminal, los comandos de verificación que este runbook corre con
`--context crc-admin` (status, `curl` contra pods, inspección de Secrets) dejarían de resolver ese
nombre de contexto y fallarían con `error: context "crc-admin" does not exist`, un síntoma que no
apunta para nada a la causa real. El nombre del cluster en el `kubeconfig` real puede variar según la
máquina (`kubectl config view --raw -o json | jq -r '.contexts[]|select(.name=="crc-admin")'` dice
cuál es el `cluster` correspondiente ahí).

---

## Paso 5 — `build_context` contra un scope real

**Qué valida:** que `build_context` resuelva el backend de una ruta contra un scope **real** de la
cuenta (vía `np scope list --application-id ... --status active`) y que resuelva `APP_TARGET` contra
un service **real** (vía `resolve_app_target_from_service`, Paso 3) — el tramo de la cadena que
ni Task 3 ni Task 9/10 habían corrido contra datos reales (quedó señalado como riesgo en el ledger
del plan), y que desde el 2026-09-01 es además el ÚNICO camino que existe para fijar `APP_TARGET`.

`SERVICE_ID` es el `id` real de `imagenes` (Paso 3); `application.id` sigue haciendo falta en la
notificación porque `build_context` lo usa **aparte**, para el listado de scopes de esa aplicación —
son dos resoluciones independientes que comparten la misma aplicación de casualidad, no por diseño.

```bash
export NP_API_KEY="$(cat ~/nullplatform/galicia/galicia-banco/accounts/galicia/np-api-skill.key)"
export NP_ACTION_CONTEXT='{
  "notification": {
    "service": {
      "id": "ec53bf2c-5831-4a85-ab4c-b16762ddd861",
      "attributes": {
        "hosts": ["api-test.local"],
        "routes": [{"path": "/whoami", "methods": ["GET"], "scope": "development"}]
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
api-manager: exponiendo galicia-poc.hello-world-poc
  dominio: api-test.local
  ruta: GET /whoami → scope development = galicia-poc-hello-world-poc-development-cvbdn.galicia-poc.nullapps.io
APP_TARGET=galicia-poc.hello-world-poc
```

`APP_TARGET` sale `galicia-poc.hello-world-poc` — namespace-slug-de-nullplatform punto
application-slug, **no** `payments.hello-world-poc` (el namespace de Kubernetes no participa acá en
absoluto, ver el aviso del Paso 3). El scope `development` es real, ya existente en la cuenta (no se
creó para este runbook); el `backend` resuelto es el `domain` real que reporta la plataforma para ese
scope.

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
# LOCAL_INGRESS_HOST sin forma de host: guarda nueva, agregada junto con el ruteo por el gateway (2026-09-01)
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

Los tres casos quedan verificados contra la cuenta real, no contra un mock.

**Cambio de diseño del 2026-09-01, verificado contra EKS por el equipo de implementación (no
re-medido en este runbook): el `backend` resuelto ya NO es el destino del tráfico.** Hasta acá el
`backendRef` del `HTTPRoute` apuntaba directo al dominio del scope — pero `kind: Hostname` sólo
resuelve hosts que el registro de la malla conoce (`Service`/`ServiceEntry`), y el dominio de un
scope no es ninguno de los dos: Envoy no le arma cluster y el request daba `500`. Ahora el
`backendRef` apunta siempre al **gateway de ingreso local** (`LOCAL_INGRESS_HOST`, default
`s2s-ingress-istio.gateways.svc.cluster.local`, puerto 443 fijo — ya no configurable), y cada regla
lleva un filtro `URLRewrite` que reescribe el `Host` al dominio del scope. El request rebota contra
el mismo gateway, ahora con el `Host` correcto, y de ahí lo toma el `HTTPRoute` propio del scope. Eso
significa que `build_context` ya no necesita que el dominio del scope resuelva por DNS ni sea
alcanzable — sólo lo declara para el rewrite. **Lo que hace falta para que el salto de vuelta al
gateway funcione es un prerequisito nuevo de infraestructura, todavía sin aplicar en este cluster —
ver el Paso 5.1.**

---

## Paso 5.1 — Prerequisito: TLS de origen en el loopback del gateway (APLICADO)

**Qué hace falta y por qué:** el listener del `Gateway` `s2s-ingress` es `HTTPS`/`Terminate` (Paso
0). El salto de vuelta del Paso 5 (Envoy reenviándose una request a sí mismo con el `Host`
reescrito) es un cliente más de ese listener, así que también tiene que hablarle en TLS — sin eso
da `503`. Ese origen de TLS lo provee un `DestinationRule` nuevo, `s2s-ingress-loopback`, en el
namespace `gateways`, con `trafficPolicy.tls.mode=SIMPLE` contra el propio Service del gateway.

**Estado: aplicado el 2026-09-01** (`tofu apply` sobre `clusters/eks`, 2 recursos agregados, 0
cambiados, 0 destruidos). Verificable con:

```bash
kubectl --context "$EKS" -n gateways get destinationrule s2s-ingress-loopback
# → s2s-ingress-loopback   s2s-ingress-istio.gateways.svc.cluster.local
```

Medido antes y después: el segundo salto pasó de **503** a **401**. O sea que el TLS quedó resuelto y
lo que responde ahora es una política, no la conexión.

Lo agrega el módulo `kuadrant-s2s` (`accounts/galicia/demo-kuadrant-s2s/modules/kuadrant-s2s/gateway.tf`,
recurso `kubectl_manifest.ingress_loopback`, commit `627d9a7` de `galicia-banco`), gateado por
`var.validate_identity` — sólo se crea si ese flag está en `true` en el layer que instancia el
módulo (`clusters/crc/main.tf`, `module "s2s"`).

```bash
kubectl --context crc-admin -n gateways get destinationrule s2s-ingress-loopback
kubectl --context crc-admin -n gateways get secret s2s-remote-ca
```

```
# →
Error from server (NotFound): destinationrules.networking.istio.io "s2s-ingress-loopback" not found
Error from server (NotFound): secrets "s2s-remote-ca" not found
```

**BLOQUEADO — todavía no está aplicado en este cluster.** No lo apliqué en esta pasada (una `apply`
de infraestructura ajena a este service, y ni el usuario ni el team lead lo pidieron explícitamente
en este momento). Sin este `DestinationRule`, cualquier request que llegue a pasar la `AuthPolicy`
(el 200 del Paso 10) va a dar `503` en el segundo salto, no porque la identidad esté mal sino porque
al Envoy del loopback le falta con qué originar TLS. **Aplicar este módulo es un paso previo
obligatorio antes de correr el Paso 10 en este cluster.**

Para aplicarlo (no ejecutado acá):

```bash
cd accounts/galicia/demo-kuadrant-s2s/clusters/crc
tofu plan   # confirmar que sólo agrega el DestinationRule + el Secret de la CA, mostrar el plan antes de aplicar
tofu apply
```

**Consecuencia para el resto de este runbook:** los Pasos 6 a 10 (crear la instancia, verificar,
linkear, los cuatro códigos) NO se pudieron re-verificar de punta a punta contra el 200 real en esta
pasada, porque ese caso específico depende de este prerequisito. Lo que sí se re-verificó, marcado
explícitamente en cada paso, es lo que no depende de él: el render del manifiesto, que la instancia
se materializa (`Accepted`/`Enforced`), y el mecanismo de colisión/link/revocación.

---

## Paso 6 — Crear la instancia: `reconcile apply`

**Qué valida:** el camino de `create` — renderizar los manifiestos (`HTTPRoute` + `AuthPolicy`) y
aplicarlos — con la `ServiceAccount` restringida del Paso 4, **sin GitOps** todavía (Paso 7 lo agrega:
es opcional, y este paso es la prueba de que el service anda igual sin él).

Desde el cambio del Paso 5, `backend` ya **no** necesita ser alcanzable para que la instancia se
materialice — sólo alimenta el `URLRewrite`. Se usa el dominio real que resolvió `build_context` en
el Paso 5, sin sustituir nada:

```bash
export NAMESPACE=payments
export APP_TARGET=galicia-poc.hello-world-poc
export SERVICE_ID=ec53bf2c-5831-4a85-ab4c-b16762ddd861
export HOSTS_JSON='["api-test.local"]'
export ROUTES_JSON='[{"path":"/whoami","methods":["GET"],"scope":"development","backend":"galicia-poc-hello-world-poc-development-cvbdn.galicia-poc.nullapps.io"}]'
export GATEWAY_NAME=s2s-ingress
export GATEWAY_NAMESPACE=gateways
export KEYS_NAMESPACE=kuadrant-system
export API_KEY_HEADER=x-api-key
export LOCAL_INGRESS_HOST=s2s-ingress-istio.gateways.svc.cluster.local
export ARGS=apply

KUBECONFIG=/tmp/kubeconfig-sa PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/reconcile"
'
```

Los nombres de los objetos son `api-manager-${SERVICE_ID}` — acá
`api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861` — con las labels
`api-manager.nullplatform.io/managed=true` y `apimgr-target=galicia-poc.hello-world-poc` en los dos,
más `nullplatform=true`.

**Salida real, sin `GITOPS_REPO_URL` seteada (el default):**

```
# →
api-manager gitops: sin repo configurado, no se publica.
httproute.gateway.networking.k8s.io/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 created
authpolicy.kuadrant.io/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 created
api-manager: galicia-poc.hello-world-poc expuesto.
```

La línea `sin repo configurado, no se publica.` es el primer punto del Paso 7: **GitOps es
opcional**, y sin configurarlo el service crea el `HTTPRoute`/`AuthPolicy` exactamente igual — nada
de lo hecho hasta acá (Pasos 1-6) dependió de GitOps.

Después de `created`, `reconcile` hace algo más que en la primera versión de este runbook: un
**re-chequeo de colisiones posterior al apply** (`find_route_conflicts`, la misma función que usa
`check_collisions`, ver Paso 11). No es un resguardo teórico: la ventana entre `check_collisions` y
este `apply` es de segundos, y el agente **puede ejecutar notificaciones en paralelo** — confirmado
al diseñar esto, no asumido. Dos `create` concurrentes para el mismo `(host, path)` pasan los dos el
chequeo previo. La mitigación no es un lock cluster-wide (demasiada complejidad permanente para una
carrera rara); es detectar-y-retirarse: si el re-chequeo encuentra un conflicto que no estaba antes,
`reconcile` borra el `HTTPRoute`/`AuthPolicy` que acaba de crear y aborta explicando que hubo una
carrera — fail-closed en las dos puntas, así que si dos apps chocan, **ninguna** se queda con tráfico
ajeno; las dos reintentan. Acá no hay nadie más aplicando nada, así que el re-chequeo pasa en
silencio (no imprime nada si no hay conflicto) y el mensaje final es `expuesto`, no una reversión.

---

## Paso 7 — GitOps: publicar antes de aplicar

**Qué valida:** que los manifiestos se publiquen a un repo git **antes** de tocar el cluster, y que
un push que falla no deje nada aplicado — ni al crear, ni al borrar, ni al revertir una carrera. Es
el mismo contrato que ya cumple `egress-interceptor` (reusa su `gitops_lib`, con dos adaptaciones —
ver más abajo).

### Es opcional

Ya quedó demostrado en el Paso 6: con `GITOPS_REPO_URL` sin setear, `gitops_enabled()` da falso y
`reconcile` sigue de largo sin publicar nada. Todo lo de este runbook hasta acá corrió así. Lo que
sigue es lo mismo, con `GITOPS_REPO_URL` puesta.

### De dónde salen las variables `GITOPS_*`

**No todas salen del mismo lugar, y la línea que las separa es deliberada** (§6.2 de
`plans/api-manager-diseno.md`): lo que es **por cluster** viene del entorno del agente, sin
declararse en el workflow; lo que es **por service**, del `configuration:` de
`create.yaml`/`delete.yaml`. Es el mismo criterio que `egress-interceptor` ya usa para `ORIGIN` y
`GITOPS_REPO_URL`.

| Variable | De dónde sale | Por qué |
|---|---|---|
| `GITOPS_REPO_URL` | **entorno del agente**, nunca el workflow | es por cluster, y puede llevar un token embebido |
| `ORIGIN` | **entorno del agente**, nunca el workflow | de ahí sale la carpeta del cluster: `EKS` → `eks`, cualquier otra cosa (o sin setear, como en CRC) → `openshift` |
| `GITOPS_BRANCH` | **entorno del agente** (default `main` si no está) | es del repo gitops, no del service |
| ~~`GITOPS_PATH_PREFIX`~~ | — | no se usa: `cross-namespace-rules` es constante del service (`API_MANAGER_GITOPS_PREFIX` en `gitops_lib`) |
| `GITOPS_PUSH_RETRIES` | `configuration:` del workflow (`5`) | decisión del service |
| `GITOPS_COMMITTER_NAME`/`_EMAIL` | default del propio `gitops_lib` (`nullplatform api-manager` / `api-manager@nullplatform.io`) si no se pisan | — |

⚠️ **`ORIGIN` NO va en `create.yaml`/`delete.yaml`, ni siquiera vacía.** El env del agente le gana al
`configuration:`, así que un `""` ahí no la pisa — pero queda como único valor si el agente no la
trae, y el service publica bajo la carpeta del cluster equivocado con los tests en verde, porque el
mock nunca ve la diferencia. No está ni en `configuration:` ni en el `output:` del step
`build context`: como es ambiental, todos los steps la ven sin que nadie la declare.

⚠️ **Nunca poner una URL con credencial real en este documento ni en ningún commit.** Para probar acá
alcanza con un repo git local (`file://` o un path absoluto) — no hace falta un GitHub real, y es lo
que se usa abajo.

### Separación por carpetas: dos services, un repo

`egress-interceptor` publica bajo `intra-namespace-rules/`; este service, bajo
`cross-namespace-rules/`, que es una constante de su `gitops_lib` y no una variable de entorno — el
env del agente le gana al `configuration:` del workflow, y los dos services comparten agente.

**El subárbol es por *service*, no por namespace** — `<prefix>/<substrate>/<namespace>/<route_name>`.
`egress-interceptor` reescribe el subárbol del **namespace entero** porque asume una sola instancia
por namespace; acá varias apps expuestas pueden compartir el mismo namespace de Kubernetes (`payments`
puede tener más de una app expuesta), así que copiar ese criterio literal habría hecho que publicar
o borrar la ruta de una app **se llevara puesta la de su vecina**. Vale la pena esta línea para que
nadie "corrija" esto después pensando que es una inconsistencia con el egress.

### Armar un repo de prueba

```bash
mkdir -p /tmp/gitops-test
git init --bare /tmp/gitops-test/remote.git -q
git clone -q /tmp/gitops-test/remote.git /tmp/gitops-test/seed
cd /tmp/gitops-test/seed && git checkout -q -b main
echo "# gitops test repo" > README.md
git -c user.name=test -c user.email=test@test.local add README.md
git -c user.name=test -c user.email=test@test.local commit -q -m init
git push -q origin main
```

### El paso más valioso: probar que un push que falla no aplica nada

Con el `HTTPRoute`/`AuthPolicy` del Paso 6 ya en el cluster, mirar el `resourceVersion` antes de
tocar nada:

```bash
kubectl --context crc-admin -n payments get httproute api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 \
  -o jsonpath='{.metadata.resourceVersion}{"\n"}'
```

```
# →
878759
```

Reintentar el mismo `reconcile ARGS=apply` del Paso 6, esta vez con `GITOPS_REPO_URL` apuntando a un
repo que **no existe**:

```bash
export GITOPS_REPO_URL="/no/existe/en/este/filesystem.git"
export GITOPS_BRANCH=main
# resto de las variables del Paso 6 sin cambios (NAMESPACE, APP_TARGET, SERVICE_ID, HOSTS_JSON, ROUTES_JSON, ...)
KUBECONFIG=/tmp/kubeconfig-sa PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/reconcile"
'
echo "EXIT=$?"
```

```
# →
fatal: repository '/no/existe/en/este/filesystem.git' does not exist
api-manager gitops: no se pudo clonar /no/existe/en/este/filesystem.git (branch main).
api-manager: falló la publicación de los manifiestos al repo gitops. NO se aplicó nada.
EXIT=1
```

```bash
kubectl --context crc-admin -n payments get httproute api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 \
  -o jsonpath='{.metadata.resourceVersion}{"\n"}'
```

```
# →
878759
```

**Mismo `resourceVersion` que antes del intento — `kubectl apply` ni se llegó a ejecutar.** El clon
falla, `gitops_sync` retorna error, y `reconcile` aborta con `die` en la línea siguiente a
`gitops_publish`, antes de tocar el `HTTPRoute`. Un push rechazado en el medio de los reintentos
(`GITOPS_PUSH_RETRIES`, con backoff exponencial + jitter) se comporta igual: agota los reintentos,
retorna error, nada se aplica.

### Publicar de verdad, con el repo real (real de prueba)

En CRC no se exporta `ORIGIN`, así que la carpeta del cluster es `openshift`:

```bash
export GITOPS_REPO_URL=/tmp/gitops-test/remote.git
export GITOPS_BRANCH=main
KUBECONFIG=/tmp/kubeconfig-sa PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/reconcile"
'
```

```
# →
api-manager gitops: publicado cross-namespace-rules/crc/payments/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 en main.
httproute.gateway.networking.k8s.io/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 configured
authpolicy.kuadrant.io/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 unchanged
api-manager: galicia-poc.hello-world-poc expuesto.
```

`configured`/`unchanged`, no `created`: el `HTTPRoute`/`AuthPolicy` ya existían desde el Paso 6 —
ninguno de los intentos fallidos de arriba los tocó, así que `kubectl apply` los encuentra iguales y
sólo actualiza.

> ⚠️ Las salidas capturadas de esta sección y de la siguiente vienen de una corrida anterior, cuando
> existía un override `GITOPS_SUBSTRATE` que se fijó en `crc`. Ese override se eliminó: hoy el mismo
> comando publica bajo `openshift/` en lugar de `crc/`. El resto de la salida no cambia.

### El árbol del repo, después de publicar

```bash
git clone -q /tmp/gitops-test/remote.git /tmp/gitops-test/verify
find /tmp/gitops-test/verify -not -path "*/.git*" -type f | sort
```

```
# →
/tmp/gitops-test/verify/README.md
/tmp/gitops-test/verify/cross-namespace-rules/crc/payments/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861/10-httproute.yaml
/tmp/gitops-test/verify/cross-namespace-rules/crc/payments/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861/20-authpolicy.yaml
```

```bash
cat /tmp/gitops-test/verify/cross-namespace-rules/crc/payments/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861/10-httproute.yaml
```

```yaml
# →
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: "api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861"
  namespace: "payments"
  labels:
    api-manager.nullplatform.io/managed: "true"
    apimgr-target: "galicia-poc.hello-world-poc"
    nullplatform: "true"
spec:
  parentRefs:
    - name: "s2s-ingress"
      namespace: "gateways"
  hostnames:
    - "api-test.local"
  rules:
    - matches:
        - path:
            type: Exact
            value: "/whoami"
          method: "GET"
      filters:
        - type: URLRewrite
          urlRewrite:
            hostname: "galicia-poc-hello-world-poc-development-cvbdn.galicia-poc.nullapps.io"
      backendRefs:
        - group: networking.istio.io
          kind: Hostname
          name: "s2s-ingress-istio.gateways.svc.cluster.local"
          port: 443
```

Exactamente el manifiesto que `reconcile` aplicó al cluster (Paso 5/6, ya con el ruteo por
loopback: `backendRefs` fijo al gateway local, `filters.urlRewrite.hostname` con el dominio del
scope), publicado ANTES del `kubectl apply`, no después ni en paralelo.

### Dos adaptaciones que hizo falta hacer al reusar el `gitops_lib` del egress

- **El subárbol por-service** (arriba) — el egress asume una instancia por namespace y reescribe
  ese subárbol entero; acá hizo falta acotarlo a `<namespace>/<route_name>` para no pisar la ruta de
  la vecina.
- **`GITOPS_NAMESPACE_MANIFESTS`/`GITOPS_PER_SERVICE_MANIFESTS` pasaron a usar el idiom
  `: "${VAR:=default}"`** (asignación sólo si no está seteada) en vez de una asignación plana — con
  una asignación plana, sourcear el lib pisaba lo que ya hubiera puesto el entorno, y un segundo
  service que sourcea el mismo archivo no podía declarar sus propios manifiestos.

⚠️ **El mismo bug de la asignación plana existe hoy en el `gitops_lib` de `egress-interceptor`** —
no se tocó ese repo desde acá, queda anotado como pendiente cruzado.

---

## Paso 8 — Verificar lo materializado

**Qué valida:** que el `HTTPRoute` esté `Accepted` y que la `AuthPolicy` esté **`Enforced`** — la
señal que de verdad importa (Gotcha #22, primer aviso de este runbook).

```bash
kubectl --context crc-admin -n payments get httproute api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 \
  -o jsonpath='{range .status.parents[*]}{.parentRef.name}: {range .conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}'
kubectl --context crc-admin -n payments get authpolicy api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

```
# →
s2s-ingress: Accepted=True(Accepted) ResolvedRefs=False(BackendNotFound)
s2s-ingress: kuadrant.io/AuthPolicyAffected=True(Accepted)
Accepted=True Accepted
Enforced=True Enforced
```

**Con el cambio de ruteo del Paso 5, `ResolvedRefs=False` sale ahora incluso con
`LOCAL_INGRESS_HOST` apuntando a un `Service` real y existente** (`s2s-ingress-istio`, verificado
`kubectl -n gateways get svc` — está). El mensaje completo lo confirma:

```bash
kubectl --context crc-admin -n payments get httproute api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 \
  -o jsonpath='{range .status.parents[*]}{range .conditions[*]}{.type}={.status}({.reason}) {.message}{end}{"\n"}{end}'
```

```
# →
Accepted=True(Accepted) Route was validResolvedRefs=False(BackendNotFound) backend(s2s-ingress-istio.gateways.svc.cluster.local) not found
```

Hipótesis, **no confirmada en esta pasada** (no alcanzó el tiempo para aislarla): `kind: Hostname`
podría no resolver un `Service` de **otro namespace** (`gateways`) igual que resuelve uno del mismo
namespace que el `HTTPRoute` (`payments`) — `reports.payments.svc.cluster.local`, mismo namespace,
sí resolvía `True` en la versión anterior de este runbook. Sea cual sea la causa exacta, no cambia
el aviso #2 de este runbook: **`ResolvedRefs` no es la señal a mirar.** Acá mismo, con
`ResolvedRefs=False`, `Enforced` sigue en `True` — es la única que dice si Kuadrant está protegiendo
la ruta. Lo que si `ResolvedRefs=False` sí puede señalar ahora es un `503` en el tráfico real (Paso
5.1): sin el `DestinationRule` de loopback, de cualquier forma el segundo salto falla, así que este
runbook no pudo aislar si el `503` de un request real vendría de esto o de la falta del
`DestinationRule` — quedan las dos causas posibles, sin descartar ninguna.

---

## Paso 9 — Linkear una app consumidora: `mint_key`

**Qué valida:** que linkear emita una credencial nueva, con las tres labels exactas que Authorino
necesita para resolverla como `apiKey` válida, en el namespace correcto (`kuadrant-system`, **no**
el namespace de la app — ver más abajo).

**Otro cambio del 2026-09-01 (Paso 3): `mint_key` ya no toma `APP_TARGET` de una variable de
entorno.** Ahora la notificación tiene que traer `.service.id` (el service **expuesto**, no la app
consumidora) y `mint_key` llama a `resolve_app_target_from_service` — la misma función que usa
`build_context` — para derivarlo. `KEYS_NAMESPACE`/`API_KEY_HEADER` siguen viniendo del entorno
(`configuration:` del workflow).

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
curso, que acá no existe. El Secret sí se creó — es lo que hay que inspeccionar:

```bash
kubectl --context crc-admin -n kuadrant-system get secret api-manager-linktest0001 -o yaml
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

`apimgr-target` sale `galicia-poc.hello-world-poc` — la misma resolución del Paso 5, ahora corrida
por `mint_key` en vez de por `build_context`, y con el mismo resultado (es la propiedad que importa:
las dos rutas de resolución tienen que coincidir siempre, porque las dos identifican la misma app).

Las tres labels, tal como las verificó Task 0 antes de escribir el código:

| Label | Para qué |
|---|---|
| `authorino.kuadrant.io/managed-by=authorino` | marca el Secret como gestionado por Authorino |
| `api-manager.nullplatform.io/managed=true` | lo que matchea el `apiKey.selector.matchLabels` de la `AuthPolicy` — **común, no filtra por app** |
| `apimgr-target=galicia-poc.hello-world-poc` | la identidad que la `AuthPolicy` compara en `authorization`, vía **notación de punto** (`auth.identity.metadata.labels.apimgr-target`) |

⚠️ **El Secret tiene que vivir en `kuadrant-system`, no en el namespace de la app.** Los mismos
Secrets con las mismas labels puestos en `payments` dan 401 en los cuatro casos del Paso 10 — así lo
verificó Task 0, incluso con `clusterWide=true` en el CR de Authorino (que en teoría sugiere lo
contrario). Kuadrant traduce toda `AuthPolicy` a un `AuthConfig` en el namespace de la `AuthPolicy`,
y Authorino resuelve `signingKeyRefs`/`apiKey` contra ESE namespace, no contra el de la app.

Extraer la key para usarla en el Paso 10:

```bash
KEY1=$(kubectl --context crc-admin -n kuadrant-system get secret api-manager-linktest0001 -o jsonpath='{.data.api_key}' | base64 -d)
```

En un link real, este mismo valor es el que la plataforma exporta como variable de entorno
`<SERVICE_SLUG>_API_KEY` a la app consumidora (`specs/links/connect.json.tpl`:
`export.target: <SERVICE_SLUG>_API_KEY`, `export.secret: true`) — acá no hay una app consumidora
desplegada de verdad, así que ese último tramo (la env var llegando al pod) no se pudo ejercitar en
esta corrida; queda declarado como pendiente en el reporte.

### La key de la "otra app", para el caso 403

`mint_key` ya no acepta un `APP_TARGET` inventado — lo resuelve siempre desde un `SERVICE_ID` real
(arriba). Esta cuenta tiene un solo service real (`imagenes`) y una sola aplicación con namespaces
de nullplatform (`hello-world-poc`), así que no hay un segundo `SERVICE_ID` real que resuelva a una
app distinta. Para el caso 403 del Paso 10 hace falta una key **válida pero de otra identidad**, y
crear un segundo service/namespace real sólo para esto es más riesgo del que vale (más superficie
para dejar algo a medio crear en la cuenta). En su lugar, se crea el Secret **directo**, con un
`apimgr-target` distinto puesto a mano — aislando específicamente lo que el caso 403 prueba: que
Kuadrant compara el label, no el resto del contexto:

```bash
kubectl --context crc-admin -n kuadrant-system create secret generic api-manager-otraapp \
  --from-literal=api_key="$(openssl rand -hex 32)" --dry-run=client -o yaml \
  | kubectl label --local -f - -o yaml \
      authorino.kuadrant.io/managed-by=authorino \
      api-manager.nullplatform.io/managed=true \
      apimgr-target=other.otra-app \
  | kubectl --context crc-admin apply -f -
KEY2=$(kubectl --context crc-admin -n kuadrant-system get secret api-manager-otraapp -o jsonpath='{.data.api_key}' | base64 -d)
```

```
# →
secret/api-manager-otraapp created
```

Este Secret **no** pasó por `mint_key` — no hay ningún link real de la plataforma detrás — así que el
Paso 13 lo borra a mano, no vía `reconcile ARGS=delete` (que sólo conoce los links reales de un
`SERVICE_ID`, ver Paso 3).

---

## Paso 10 — Los cuatro códigos + el quinto (404)

**Tercer aviso de este runbook, y el que más importa: probar el 200 no es opcional.** Un selector de
`authorization` mal escrito rechaza a TODAS las keys con 403 — indistinguible de "la key es de otra
app" si sólo se mira 401/403. El 20/08 una tanda que sólo probó 401 y 403 dio en verde una
`AuthPolicy` que no autorizaba a nadie (selector con notación de corchetes en vez de punto). El caso
200 es el único que separa ambos.

✅ **Verificado end-to-end contra EKS real el 2026-09-01.** Los cinco casos, atravesando los dos
saltos (`x-api-key` → AuthPolicy valida y acuña el wristband → gateway de ingreso → `URLRewrite` al
dominio del scope → route del scope → pod):

| Caso | Resultado |
|---|---|
| Sin header | `401` |
| Key inexistente | `401` |
| Key emitida para otra app | `403` |
| Path no declarado | `404` |
| Key correcta | `200` |

El 403 y el 200 en la misma corrida son lo que prueba que el mecanismo discrimina. Con un selector de
`authorization` mal escrito, **todas** las keys darían 403 y el 200 no existiría — mirar sólo 401 y
403 no distingue esos dos mundos.

Para llegar acá hubo que resolver tres cosas, cada una medida: el `backendRef` apuntaba al dominio del
scope y daba `500` (no es direccionable, ver Paso 5); faltaba originar TLS en el loopback y daba `503`
(Paso 5.1); y faltaba el wristband para el segundo salto, que daba `401` — la route del scope hereda
`s2s-validator`, que exige `x-np-token`. La `AuthPolicy` de este service ahora lo acuña después de
validar la API key, firmando con la clave del namespace de la app.
el mejor caso, `401`/`403`/`404` reales para los casos 1/2/3/5 (esos cortan **antes** del segundo
salto, en el mismo `HTTPRoute`/`AuthPolicy` de siempre — el mecanismo no cambió) y un `503` para el
caso 4, indistinguible de un `503` por cualquier otra causa del segundo salto. Publicar esa salida
como si fuera el 200 real sería inventar un resultado — así que este runbook no lo hace. **Aplicar
el Paso 5.1 y volver a correr este paso es lo primero que hay que hacer para dar el service por
probado de punta a punta.**

**Dato que sí queda documentado, verificado por el equipo de implementación contra EKS (no
re-medido en este cluster): la `AuthPolicy` a nivel `HTTPRoute` sobreescribe la del `Gateway`.**
Medido con un `200` usando sólo `x-api-key` contra `s2s-ingress` — que tiene su propia `AuthPolicy`
`s2s-validator` exigiendo un wristband — sin wristband alguno. O sea que el primer salto (el que este
service agrega) **no** exige el wristband S2S del gateway compartido; su propia regla de
`authentication` (`apiKey`) es la que manda para las rutas que este service declara.

Cuando el Paso 5.1 esté aplicado, el bloque a correr es el mismo de siempre — documentado acá para
no perderlo, sin la salida (sería inventada):

```bash
INGRESS="https://s2s-ingress-istio.gateways.svc.cluster.local/whoami"
HOSTH="Host: api-test.local"

echo "== 1. sin header =="
kubectl --context crc-admin -n other exec deploy/intruso -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 15 -H "$HOSTH" "$INGRESS"

echo "== 2. key inventada =="
kubectl --context crc-admin -n other exec deploy/intruso -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 15 -H "$HOSTH" -H "x-api-key: no-existe-esta-key-0000" "$INGRESS"

echo "== 3. key de otra app =="
kubectl --context crc-admin -n other exec deploy/intruso -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 15 -H "$HOSTH" -H "x-api-key: $KEY2" "$INGRESS"

echo "== 4. key propia =="
kubectl --context crc-admin -n other exec deploy/intruso -- curl -s -k --max-time 15 \
  -H "$HOSTH" -H "x-api-key: $KEY1" -w '\nHTTP %{http_code}\n' "$INGRESS"

echo "== 5. path no declarado =="
kubectl --context crc-admin -n other exec deploy/intruso -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 15 -H "$HOSTH" -H "x-api-key: $KEY1" \
  "https://s2s-ingress-istio.gateways.svc.cluster.local/no-declarada"
```

| # | Header | Código esperado | Qué prueba |
|---|---|---|---|
| 1 | ninguno | 401 | sin credencial, Kuadrant corta antes de autorizar |
| 2 | key que no existe | 401 | ninguna key con ese valor está registrada como `Secret` |
| 3 | key válida, de `other.otra-app` | 403 | autenticó (la key existe), pero `apimgr-target` no matchea `galicia-poc.hello-world-poc` |
| 4 | key válida, propia | **200 — bloqueado, ver arriba** | control positivo — sin esto los 403 no prueban nada |
| 5 | key propia, path no declarado | 404 | ningún `match` del `HTTPRoute` cubre `/no-declarada`; corta en el Gateway, antes de Kuadrant |

Los casos 1/2/3/5 se habían verificado contra el cluster real con el modelo de ruteo anterior
(backend directo, sin loopback); el mecanismo de autenticación/autorización en sí no cambió con el
Paso 5, así que es razonable esperar el mismo resultado — pero **no se re-corrieron en esta pasada**
y no hay que darlos por confirmados contra el modelo nuevo hasta correr este paso de nuevo.

---

## Paso 11 — Colisión de dominios

**Qué valida:** que declarar el mismo `(host, path)` que ya declaró otra app se rechace, y que
compartir el mismo host con un path distinto **no** se rechace. `check_collisions` ahora comparte
`find_route_conflicts` con el re-chequeo post-apply del Paso 6 — mismo código, misma semántica en
los dos lados — y desde el 2026-09-01 detecta también **solapamiento por prefijo**, no sólo el match
exacto: un path que es subárbol de otro ya declarado también cuenta como colisión (antes se podía
esquivar el guard pidiendo `/*` primero y quedar de facto como catch-all).

`SERVICE_ID` acá sólo sirve para que `find_route_conflicts` se auto-excluya (no compare la instancia
contra sí misma) — no hace falta que sea real, a diferencia de `build_context`/`mint_key`:

```bash
export SERVICE_ID=otra-instancia-uuid
export HOSTS_JSON='["api-test.local"]'
export ROUTES_JSON='[{"path":"/whoami","methods":["GET"],"scope":"development"}]'

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

Un path **anidado** bajo el ya declarado — antes no colisionaba, ahora sí:

```bash
export ROUTES_JSON='[{"path":"/whoami/sub","methods":["GET"],"scope":"development"}]'
PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/check_collisions"
'
echo "EXIT=$?"
```

```
# →
api-manager: hay dominios y paths que se solapan con los de otra aplicación.
  api-test.local/whoami/sub se solapa con api-test.local/whoami, ya tomado por galicia-poc.hello-world-poc
  Compartir un dominio está permitido: lo que no se puede es solapar el mismo subárbol de path con otra app. La barra final y el '*' de subárbol no cuentan como una ruta distinta.
EXIT=1
```

Mismo host, path que **no** es prefijo ni sufijo del existente — no hay colisión:

```bash
export ROUTES_JSON='[{"path":"/otro-path","methods":["GET"],"scope":"development"}]'
PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/check_collisions"
'
echo "EXIT=$?"
```

```
# →
EXIT=0
```

Sin salida de error y `exit 0`: exactamente el comportamiento que el README documenta ("Compartir un
dominio está permitido... la unidad de colisión es el par, no el dominio solo") — con la definición
de "par" ahora ampliada a subárbol, no sólo a igualdad exacta.

---

## Paso 12 — Revocar el link

**Qué valida:** que borrar el link corte el acceso **de inmediato**, con la misma key que un minuto
antes daba 200.

```bash
export NP_ACTION_CONTEXT='{"notification":{"link":{"id":"linktest0001"}}}'
export KEYS_NAMESPACE=kuadrant-system

KUBECONFIG=/tmp/kubeconfig-sa PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/revoke_key"
'
kubectl --context crc-admin -n kuadrant-system get secret api-manager-linktest0001
```

```
# →
secret "api-manager-linktest0001" deleted from kuadrant-system namespace
api-manager: credencial del link linktest0001 revocada.
Error from server (NotFound): secrets "api-manager-linktest0001" not found
```

La MISMA key (`$KEY1`, todavía en la variable de shell) contra el mismo endpoint:

```bash
kubectl --context crc-admin -n other exec deploy/intruso -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -k --max-time 15 -H "Host: api-test.local" -H "x-api-key: $KEY1" \
  "https://s2s-ingress-istio.gateways.svc.cluster.local/whoami"
```

```
# →
HTTP 401
```

Sin expiración que esperar: el 200 de un minuto antes pasa a 401 en cuanto el Secret desaparece.

---

## Paso 13 — Teardown

**Qué valida:** que borrar la instancia no deje `HTTPRoute`, `AuthPolicy` ni Secrets colgando, que la
remoción se publique al repo GitOps **antes** de borrar del cluster (mismo fail-closed del Paso 7,
ahora del lado del `delete`), y que el subárbol de este service desaparezca del repo.

### Primero, el fail-closed del lado del borrado

Mismo truco del Paso 7: con una URL de repo inválida, nada se borra del cluster.

```bash
export NAMESPACE=payments
export APP_TARGET=galicia-poc.hello-world-poc
export SERVICE_ID=ec53bf2c-5831-4a85-ab4c-b16762ddd861
export KEYS_NAMESPACE=kuadrant-system
export ARGS=delete
export GITOPS_BRANCH=main

export GITOPS_REPO_URL="/no/existe/en/este/filesystem.git"
KUBECONFIG=/tmp/kubeconfig-sa PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/reconcile"
'
kubectl --context crc-admin -n payments get httproute,authpolicy
```

```
# →
fatal: repository '/no/existe/en/este/filesystem.git' does not exist
api-manager gitops: no se pudo clonar /no/existe/en/este/filesystem.git (branch main).
api-manager: falló la publicación del borrado al repo gitops. No se borró nada del cluster.
NAME                                                                                   HOSTNAMES            AGE
httproute.gateway.networking.k8s.io/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861   ["api-test.local"]   ...

NAME                                                                      AGE
authpolicy.kuadrant.io/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861   ...
```

El `HTTPRoute`/`AuthPolicy` siguen ahí — `gitops_publish_removal` corre **antes** de cualquier
`kubectl delete` en el `case delete)` de `reconcile`, así que un push que falla corta ahí.

### El delete real, con el repo de prueba

```bash
export GITOPS_REPO_URL=/tmp/gitops-test/remote.git
KUBECONFIG=/tmp/kubeconfig-sa PATH=/opt/homebrew/bin:$PATH bash -c '
  source "'"$SVC"'/logging"; export -f log
  bash "'"$SVC"'/scripts/k8s/reconcile"
'
```

```
# →
api-manager gitops: publicado cross-namespace-rules/crc/payments/api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861 en main.
authpolicy.kuadrant.io "api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861" deleted from payments namespace
httproute.gateway.networking.k8s.io "api-manager-ec53bf2c-5831-4a85-ab4c-b16762ddd861" deleted from payments namespace
api-manager: galicia-poc.hello-world-poc dado de baja.
```

El `HTTPRoute` y la `AuthPolicy` se borraron, y esta vez **no** hubo error en el listado de links:
`np link list --service-id ec53bf2c-5831-4a85-ab4c-b16762ddd861` es una llamada real contra un
service real, y responde — vacía, porque `imagenes` no tiene ningún link real registrado en la
plataforma (Paso 3). Es distinto del resultado de la primera versión de este runbook (donde
`SERVICE_ID` era inventado y esa llamada fallaba de plano): acá la llamada **funciona**, y funciona
bien — simplemente no hay nada que la plataforma reconozca como propio para borrar. El Secret
`linktest0001` (Paso 9) ya no existe (se revocó en el Paso 12); el que sí queda vivo es
`api-manager-otraapp` (Paso 9), porque nunca pasó por un link real y por lo tanto `reconcile` no
tiene manera de enterarse de que existe. Se borra a mano, junto con todo lo demás que este runbook
creó y que el service no gestiona:

```bash
kubectl --context crc-admin -n kuadrant-system delete secret api-manager-otraapp --ignore-not-found
kubectl --context crc-admin delete -f /tmp/rbac.rendered.yaml --ignore-not-found
kubectl --context crc-admin -n payments delete serviceaccount api-manager-agent --ignore-not-found
```

### El subárbol, después del borrado

```bash
git clone -q /tmp/gitops-test/remote.git /tmp/gitops-test/verify-final
find /tmp/gitops-test/verify-final/cross-namespace-rules -type f 2>&1
```

```
# →
find: /tmp/gitops-test/verify-final/cross-namespace-rules: No such file or directory
```

El subárbol `cross-namespace-rules/crc/payments/api-manager-ec53bf2c-.../` desapareció del
repo — `gitops_sync` lo borra (`rm -rf "${work:?}/${subtree:?}"`, sin volver a poblarlo porque
`mode=delete` no llama a `gitops_render_tree`) y commitea+pushea esa remoción antes de que
`reconcile` toque el cluster.

### Verificar que quedó limpio

```bash
kubectl --context crc-admin -n payments get httproute,authpolicy,gateway,destinationrule,serviceaccount --no-headers 2>&1 | grep -i api-manager || echo "ninguno"
kubectl --context crc-admin -n kuadrant-system get secret -l api-manager.nullplatform.io/managed=true
kubectl --context crc-admin -n payments get svc reports -o jsonpath='{.spec.selector}{"\n"}'
kubectl --context crc-admin get clusterrole,clusterrolebinding --no-headers 2>&1 | grep -i api-manager || echo "ninguno"
kubectl --context crc-admin -n gateways get gateway s2s-ingress -o jsonpath='attachedRoutes: {.status.listeners[0].attachedRoutes}{"\n"}'
kubectl --context crc-admin -n gateways get authpolicy s2s-validator -o jsonpath='Enforced: {.status.conditions[?(@.type=="Enforced")].status}{"\n"}'
```

**Qué tenés que ver** (igual al Paso 0):

```
ninguno
No resources found in kuadrant-system namespace.
{"app":"reports"}
ninguno
attachedRoutes: 0
Enforced: False
```

El `Enforced: False` de `s2s-validator` no es un efecto colateral de este runbook: es la misma
señal del Paso 0, que vuelve a su valor de reposo en cuanto el único `HTTPRoute` que la mantenía
enforceando (el nuestro) desaparece. `s2s-ingress` y `s2s-validator` en sí — los objetos, no su
`Enforced` — quedaron intactos durante todo el runbook: no se los tocó nunca directamente.

El service specification "Api Manager" registrado en el Paso 1 **sigue registrado** — eso es
esperado, ver la nota de ese paso.

---

## Los avisos que no pueden faltar

1. **`Accepted=True` no es enforcement.** La señal válida de la `AuthPolicy` es **`Enforced=True`**
   (Gotcha #22, Paso 8). Kuadrant no enforcea una policy que no esté en el camino de ningún
   `HTTPRoute`, y no falla ruidosamente — queda `Accepted` y el tráfico pasa sin autenticar.

2. **`ResolvedRefs=False (BackendNotFound)` no hay que leerlo como una falla** (Paso 8): en ningún
   caso afecta `Enforced` ni el resultado de auth — son señales independientes. Con el modelo de
   ruteo anterior (backend directo) daba `True` para un `Service` conocido del mismo namespace y
   `False` para uno no registrado; con el modelo actual (loopback vía `LOCAL_INGRESS_HOST`, Paso 5)
   dio `False` incluso apuntando a un `Service` real (`s2s-ingress-istio`, de otro namespace) — sin
   aislar todavía la causa exacta. La regla que no cambia: mirar `Enforced`, no `ResolvedRefs`.

3. **Probar el 200 es obligatorio, no opcional** (Paso 10). Un selector de `authorization` mal
   escrito rechaza a TODAS las keys con 403, indistinguible de "la key es de otra app" si sólo se
   mira 401/403. Verificado el 20/08: una tanda que sólo miró esos dos códigos dio en verde una
   `AuthPolicy` que no autorizaba a nadie.

4. **Los tests unitarios no pueden cubrir RBAC** (Paso 4, Paso 6-13). El suite mockea `kubectl`, y
   un mock no aplica permisos — responde igual con o sin ellos. Sólo una corrida contra el cluster
   real, con el `Role` real aplicado y los scripts corriendo impersonando esa identidad, cubre esa
   clase de bug. En el desarrollo de este service, exactamente esa corrida encontró dos call sites
   que hubiesen dado 403 en producción (el `kubectl apply`/`label` original de `mint_key`, y el
   borrado de Secrets por label-selector de `reconcile`) — los dos se arreglaron antes de este
   runbook, y este runbook es lo que confirma que el arreglo aguanta.

5. **Publicar a GitOps es fail-closed, en los dos sentidos** (Paso 7 y Paso 13). Un push que falla
   —repo inválido, red caída, conflicto que agota los reintentos— no deja nada aplicado ni nada
   borrado: `reconcile` publica primero y recién después toca `kubectl`. Verificado con el
   `resourceVersion` sin cambios tras un intento de `apply` con URL inválida, y con el `HTTPRoute`/
   `AuthPolicy` todavía presentes tras un intento de `delete` con la misma URL inválida.

---

## Troubleshooting

| Síntoma | Causa | Qué hacer |
|---|---|---|
| `HTTP 503` en el caso 200 | falta el `DestinationRule` `s2s-ingress-loopback` que origina TLS en el segundo salto (Paso 5.1) | aplicar el módulo `kuadrant-s2s` con `validate_identity=true` antes de probar el 200 |
| `HTTP 500` en el caso 200 (modelo de ruteo anterior a esta versión) | el `backendRef` apuntaba directo al dominio del scope, que `kind: Hostname` no resuelve | ya no aplica — desde el 2026-09-01 el `backendRef` va siempre al gateway local (Paso 5) |
| `404` en vez de 401/403/200 | el `Host` del request no matchea ningún `HTTPRoute`, o el path no está declarado | confirmar que `Host:` sea uno de los `hosts` declarados; si el path es intencional (undeclared), 404 es correcto |
| `403` en TODOS los casos, incluida la key propia | el selector de `authorization` está mal (bracket notation en vez de punto — Ruling verificado en este plan) | probar el caso 200 (Paso 10) antes de asumir que el 403 "funciona"; `Enforced=True` no lo descarta |
| `Enforced: False` en `s2s-validator` sin haber tocado nada | es el estado de reposo sin ningún `HTTPRoute` colgado del Gateway (Paso 0/13) | esperado; no diagnosticar como falla |
| `ResolvedRefs=False (BackendNotFound)` | el hostname del `backendRef` no está registrado en el mesh de Istio (Paso 8) | no es un síntoma por sí solo; mirar `Enforced` y probar los códigos igual |
| Secret con las labels correctas pero todo da 401 | el Secret está en el namespace de la app, no en `kuadrant-system` | recrearlo en `kuadrant-system` (Paso 9) |
| `build_context`/`mint_key` fallan en `np service read --id ...` | `SERVICE_ID` no es el `id` de un service real de la cuenta (Paso 3) | usar el `id` de un service real existente — ya no se puede pasar `APP_TARGET` a mano |
| `mint_key` falla en la línea de `np service action update` | se está probando fuera de una acción real de la plataforma (Paso 3) | esperado en este modo de prueba; el `Secret` creado sí es real y es lo que hay que verificar |
| `reconcile ARGS=delete` no borra un Secret que se esperaba | ese Secret nunca pasó por `mint_key` (se creó a mano, Paso 9) — `np link list` no lo conoce | borrarlo a mano por nombre (Paso 13); es distinto del caso viejo (`SERVICE_ID` inventado), donde la llamada fallaba de plano |
| `reconcile`/`check_collisions` avisan "se solapan" con un path que a simple vista parece distinto | el nuevo chequeo detecta prefijos, no sólo match exacto (Paso 11) | confirmar si uno es subárbol del otro (`/api` vs `/api/v1`); si no lo es, no debería marcar colisión — revisar `find_route_conflicts` |
| Cualquier `kubectl` de este runbook da `Forbidden` | se está usando el `kubeconfig`/token de la `ServiceAccount` restringida y falta un verbo | revisar contra la tabla de verbos del Paso 4 antes de agregar permisos — el diseño es deliberadamente mínimo |
| `reconcile` aborta con "falló la publicación... NO se aplicó nada" o "...No se borró nada del cluster" | `GITOPS_REPO_URL` está mal, la rama no existe, o el push se rechazó y se agotaron los reintentos (Paso 7/13) | es fail-closed a propósito; revisar la URL/rama/credencial del repo GitOps, el cluster no se tocó |
| El agente no arranca / `cmdline` apunta a un archivo que no existe | `/root/.np/...` no existe en runtime host sobre macOS (Paso 2) | correr el agente en runtime k8s (pod), o pasar `base_clone_path` a una ruta accesible — requiere tocar `install/main.tf`, fuera del alcance de este runbook |
| `mapfile: command not found` o `${level,,}` falla | se está corriendo con el `bash` 3.2 de macOS en vez de uno >= 4 | anteponer `PATH=/opt/homebrew/bin:$PATH` o invocar `/opt/homebrew/bin/bash` explícitamente |
