# RBAC del agente nullplatform

Permisos que necesita el agente de nullplatform para operar los dos services de este entregable:
**`s2s-traffic-migrator`** (migración de tráfico este-oeste entre OpenShift y EKS) y
**`api-manager-publisher`** (publicación de APIs con api key y validación de identidad).

Los dos corren en el **mismo pod**, en el namespace `nullplatform-tools`, y comparten
ServiceAccount. Por eso el RBAC es uno solo: la unión de lo que hacen los dos.

## Los dos archivos

| Archivo | Cuándo |
|---|---|
| `np-agent-rbac.yaml.tpl` | El agente aplica los manifiestos en el cluster con `kubectl apply`. |
| `np-agent-rbac-gitops.yaml.tpl` | El agente sólo publica los manifiestos a un repo git; el `apply` lo hace un reconciler (Argo/Flux). El agente lee para verificar convergencia. |

El segundo es **subconjunto estricto** del primero: se puede migrar de uno a otro sin agregar nada.

## Instalación

Una vez por cluster:

```bash
KEYS_NAMESPACE=kuadrant-system \
AGENT_SA=np-agent AGENT_NAMESPACE=nullplatform-tools \
  gomplate -f rbac/np-agent-rbac.yaml.tpl | kubectl apply -f -
```

`AGENT_SA` / `AGENT_NAMESPACE` son el ServiceAccount del agente y el namespace donde corre su pod.

## Permisos solicitados — modo apply directo

### Cluster-wide (`ClusterRole/np-agent`)

| API group | Recurso | Verbos | Para qué |
|---|---|---|---|
| `gateway.networking.k8s.io` | `httproutes` | `get, list, watch, create, update, patch, delete` | Es el objeto central de los dos services: la ruta que expone una API y la que reparte el tráfico entre sustratos. Se crean, se actualizan al cambiar el porcentaje o los paths, y se borran al dar de baja la instancia. `list` cluster-wide además detecta colisiones de `(dominio, path)` entre aplicaciones de distintos namespaces. |
| `gateway.networking.k8s.io` | `gateways` | `get, list, watch, create, update, patch, delete` | El data plane de egreso del `s2s-traffic-migrator`. Istio lo auto-provisiona a partir de este objeto. `watch` es lo que usa `kubectl wait` para esperar a que quede `Programmed`. |
| `kuadrant.io` | `authpolicies` | `get, list, watch, create, update, patch, delete` | La política que firma el token de identidad en el egreso y la que valida la api key en el ingreso. `watch` para esperar `Enforced=True` antes de desviar tráfico. |
| `networking.istio.io` | `destinationrules` | `get, list, watch, create, update, patch, delete` | Cómo se origina el TLS hacia el ingreso del otro sustrato (CA, SNI, pool de conexiones). |
| `(core)` | `services` | `get, list, create, update, patch, delete` | En OpenShift el service redirige el `Service` existente al Gateway de egreso (`patch` del selector) y guarda el selector original en una annotation para poder revertir. En EKS crea el `Service` que captura el tráfico y el alias `<svc>-local`. |
| `(core)` | `endpoints` | `get, list` | **Sólo lectura.** Con un porcentaje menor a 100 parte del tráfico va al backend local: se verifica que tenga endpoints antes de repartir, o ese porcentaje se pierde en silencio. |
| `(core)` | `pods` | `get, list` | **Sólo lectura.** Diagnóstico: cuando el Gateway no llega a `Programmed`, se listan los pods del data plane para que el error diga por qué. |
| `apps` | `deployments` | `get, list, watch` | **Sólo lectura.** El Deployment del data plane lo crea y lo posee el controller de Istio. El agente únicamente espera a que quede `Available` antes de desviarle tráfico. |

### Acotado a un namespace (`Role/np-agent-keys` en `kuadrant-system`)

| API group | Recurso | Verbos | Para qué |
|---|---|---|---|
| `(core)` | `secrets` | `create, delete` | La api key que se emite cuando una aplicación se vincula a otra, y que se revoca al desvincularse. |

**Este es el único permiso namespaced, y es deliberado.** En `kuadrant-system` también viven las
claves de firma de los tokens. Cluster-wide, `create, delete` sobre `secrets` sería poder borrar
cualquier Secret de cualquier namespace del cluster.

## Permisos que NO se piden

- **`get` / `list` sobre `secrets`.** El agente crea y borra sus propias api keys, pero **no puede
  leer ninguna**. Ni las suyas ni las ajenas. La clave de firma de los tokens la referencia la
  `AuthPolicy` por nombre y la lee Kuadrant, nunca el agente.
- **Nada sobre `pods/exec`, `nodes`, `namespaces`, `configmaps`, `serviceaccounts`, `roles` ni
  `rolebindings`.** El agente no puede ejecutar en contenedores, ni crear namespaces, ni escalar
  sus propios privilegios.
- **Escritura sobre `deployments`, `endpoints` o `pods`.** Son sólo lectura: el agente no toca
  cargas de trabajo de las aplicaciones.

## Modo GitOps

Con el `apply` delegado a un reconciler, se caen las 24 escrituras sobre objetos de red y quedan
sólo lecturas:

| API group | Recurso | Verbos | Alcance |
|---|---|---|---|
| `gateway.networking.k8s.io` | `gateways`, `httproutes` | `get, list, watch` | cluster |
| `kuadrant.io` | `authpolicies` | `get, list, watch` | cluster |
| `networking.istio.io` | `destinationrules` | `get, list, watch` | cluster |
| `(core)` | `services`, `endpoints`, `pods` | `get, list` | cluster |
| `apps` | `deployments` | `get, list, watch` | cluster |
| `(core)` | `secrets` | `create, delete` | `kuadrant-system` |

**La api key es la única escritura que sobrevive.** Se genera por vínculo y se devuelve
sincrónicamente en el resultado de la acción: es una credencial y no puede viajar por un repo git.

Las lecturas siguen siendo necesarias porque el agente verifica que lo que publicó realmente se
haya aplicado: que la `HTTPRoute` quede `Accepted` y que la `AuthPolicy` quede `Enforced` antes de
reportar la acción como exitosa.

## Por qué cluster-wide

El namespace de cada aplicación sale del provider `container-orchestration` de la instancia: no se
conoce al momento de instalar el RBAC y aparece uno nuevo cada vez que se onboardea una aplicación.
Un `Role` sólo alcanza su propio namespace, así que expresar eso requiere un `ClusterRole`.

### Alternativa: lista explícita de namespaces

Si el alcance cluster-wide no pasa la revisión de seguridad, los dos templates traen **comentada**
una variante con `TARGET_NAMESPACES`: el mismo `ClusterRole`, pero bindeado con un `RoleBinding`
por namespace en vez de un `ClusterRoleBinding`. Las reglas se declaran una sola vez; lo que se
repite es el binding. Las instrucciones para activarla están dentro de cada archivo.

Dos consecuencias antes de elegirla:

1. **La lista tiene que incluir `gateways`**, donde el `s2s-traffic-migrator` escribe sus rutas de
   ingreso. Onboardear una aplicación nueva pasa a requerir un `RoleBinding` más; sin él, la
   instancia falla con `Forbidden` en el primer apply.
2. **No elimina del todo el alcance cluster.** La detección de colisiones de `(dominio, path)` hace
   `kubectl get httproutes --all-namespaces`, que es un `list` de alcance cluster: ningún
   `RoleBinding` puede autorizarlo, por muchos namespaces que se enumeren. La alternativa conserva
   un `ClusterRole` mínimo de `httproutes: [get, list]` — lectura, sobre un solo recurso.

Hay algo que el modo cluster-wide sí concede y la alternativa no: escritura sobre las
`AuthPolicy` del namespace `gateways`, que son del layer y que el agente sólo necesita leer. RBAC
no tiene reglas de negación, así que "escribo en todos los namespaces menos ése" no se puede
expresar con un `ClusterRoleBinding`.

## Verificar

Que el template renderiza y es válido:

```bash
KEYS_NAMESPACE=kuadrant-system AGENT_SA=np-agent AGENT_NAMESPACE=nullplatform-tools \
  gomplate -f rbac/np-agent-rbac.yaml.tpl | kubectl apply --dry-run=client -f -
```

Que los límites son los que dicen ser, una vez aplicado:

```bash
SA="system:serviceaccount:nullplatform-tools:np-agent"

kubectl --as="$SA" auth can-i create httproutes -A                    # yes
kubectl --as="$SA" auth can-i patch services -n payments              # yes
kubectl --as="$SA" auth can-i create secrets -n kuadrant-system       # yes

kubectl --as="$SA" auth can-i get secrets -n kuadrant-system          # no
kubectl --as="$SA" auth can-i list secrets -A                         # no
kubectl --as="$SA" auth can-i create pods -A                          # no
kubectl --as="$SA" auth can-i delete deployments -A                   # no
kubectl --as="$SA" auth can-i create rolebindings -A                  # no
```
