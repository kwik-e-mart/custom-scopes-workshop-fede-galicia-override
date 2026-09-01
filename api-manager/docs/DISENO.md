# Api Manager — diseño

> Estado: **aprobado, sin implementar**. Escrito y aprobado el 2026-08-31.
> Destino del código: repo de overrides (`custom-scopes-workshop-fede-galicia-override/`), PR nuevo,
> al lado de `egress-interceptor/`.
> Base conceptual: [`nullplatform/services-endpoint-exposer`](https://github.com/nullplatform/services-endpoint-exposer)
> (clonado en `~/nullplatform/apps/services-endpoint-exposer`, v0.2.3).

---

## 1. Qué problema resuelve

Hoy, en el cluster, la baseline de red es `allow-intra-namespace`: `podSelector: {}`, ingress
permitido sólo desde el propio namespace, egress sin filtrar. O sea:

- namespace A → namespace A: permitido, sin fricción.
- namespace A → namespace B: **bloqueado en L4**. El paquete se descarta, ni siquiera abre el TCP.

Ese default-deny es bueno y no se toca. El problema es que hoy no hay forma declarativa de abrir una
excepción: o se rompe el aislamiento a mano, o las apps no se hablan.

Este servicio es esa forma. Una app declara qué paths expone y por qué host, y eso —y sólo eso—
queda alcanzable desde otros namespaces, atravesando el Kuadrant Ingress global del cluster, con una
API key que identifica al consumidor.

**Lo que no se declara no existe.** El default-deny no es una regla que escribimos: es la ausencia de
regla. No hay `HTTPRoute` → no hay match → 404 del gateway.

---

## 2. El flujo

```
app X (ns A)
   │
   │  curl https://api.expuesta.com/ruta-1
   │       -H "x-api-key: $API_MANAGER_API_KEY"
   ▼
  DNS
   │
   ▼
Kuadrant Ingress GLOBAL del cluster
   │
   ├─ HTTPRoute      host api.expuesta.com + path /ruta-1
   ├─ AuthPolicy     valida la api key ────────────────► 401 / 403
   │
   ▼
backendRef kind: Hostname → appy.misappsinternas.com
   │
   │  (HTTPRoute interna del despliegue: acá vive el blue/green)
   ▼
pods reales
```

Dos cosas importantes de este dibujo:

**El gateway es uno solo y global.** No hay un Gateway por namespace. Todos los `HTTPRoute` de todas
las apps cuelgan del mismo. Esto es distinto del `egress-interceptor`, que sí monta un Gateway por
namespace, y es una fuente de confusión si se lee un servicio con la cabeza del otro.

**Nunca se apunta al Service del scope.** El nombre del Service cambia en cada deploy, así que
apuntarle rompe el blue/green. La indirección estable es la `HTTPRoute` del propio scope, que
nullplatform mantiene al día — hay que pasar por ahí.

**Pero el dominio del scope NO es el `backendRef`: es el `Host` header.** Medido contra el EKS real
el 2026-09-01, con una route referenciando cada opción:

| `backendRef` | ¿Envoy le crea cluster? | Tráfico |
|---|---|---|
| `s2s-ingress-istio.gateways.svc.cluster.local` (FQDN de Service) | **sí** | llega |
| el dominio del scope | **no** | 500 |

`kind: Hostname` sólo resuelve hosts del **registro de la malla**: Services y ServiceEntries. El
dominio de un scope no es ninguna de las dos cosas — es únicamente un valor de `hostnames:` en la
route del scope. Envoy no le construye cluster.

La forma correcta, la misma que usa el `egress-interceptor`:

- `backendRefs` → **FQDN del Service del gateway de ingreso**, puerto 443
- `filters.URLRewrite.hostname` → **el dominio del scope**, para que el gateway que recibe matchee
  la route correcta

Ojo con una lectura equivocada que ya hicimos: el egress hace ese `URLRewrite` *y además* acuña un
wristband, y es fácil concluir que la reescritura existe para la firma. Son independientes. Acá no se
firma nada —la API key ya se validó— y el `URLRewrite` hace falta igual.

**El salto de vuelta al gateway necesita TLS.** El listener es HTTPS con `mode: Terminate`, y el hop
sale en plano: da 503. Lo resuelve un `DestinationRule` que origine TLS hacia ese host. Vive en el
namespace del gateway (`gateways`) y **lo crea el módulo `kuadrant-s2s`**, no el service: el cliente
del salto es el gateway compartido, no un workload de la app. Una regla puesta en el namespace de la
app con `exportTo: ["."]` no la ve nadie — verificado.

**No hace falta tocar NetworkPolicies.** El gateway global ya alcanza a las apps —es como funciona el
ingreso normal hoy—, así que los agujeros ya existen. El aislamiento A→B directo sigue intacto: el
único camino es el gateway, y por el gateway sólo pasa lo declarado.

---

## 3. Lo que declara el dev

Tres bloques en el `service-spec.json.tpl`: un FAQ que explica el servicio, y dos de configuración.

### FAQ

Igual que en el `egress-interceptor`: un elemento `Label` con `options.format: markdown`, primero en
el `VerticalLayout`, antes de los `Control`.

```json
{
  "type": "Label",
  "text": "## Api Manager\n\n### FAQ\n\n**¿Cuándo tengo que usarlo?** ...",
  "options": { "format": "markdown" }
}
```

El texto se escribe con el mismo criterio que el del `egress-interceptor`: foco en lo funcional, no
en la implementación; el dev no tiene que enterarse de que atrás hay un Gateway, una AuthPolicy ni
Kuadrant. Preguntas a cubrir:

- **¿Cuándo tengo que usarlo?** Cuando otra aplicación, en otro namespace, necesita consumir la mía.
- **¿Qué hace el servicio?** Publica los paths que declaro bajo un dominio, y los deja alcanzables
  desde otros namespaces. Lo que no declaro sigue siendo inalcanzable.
- **¿Cómo hace otra app para consumirme?** Se linkea al servicio. En ese momento recibe su propia
  credencial, como variable de entorno, sin que nadie copie ni pegue nada.
- **¿Puedo cortarle el acceso a alguien?** Sí, borrando el link. Es inmediato.
- **¿Tengo que cambiar algo en mi código?** No. La app sigue escuchando donde escucha hoy.

### Hosts

Lista de dominios por los que la app se expone. Uno o varios.

```
api.expuesta.com
reports.galicia.ar
```

### Rutas

Una fila por path expuesto:

| Campo | Ejemplo | De dónde sale |
|---|---|---|
| **Path** | `/ruta-1`, `/v1/items/*` | lo tipea el dev |
| **Verbs** | `GET`, `POST` | los elige de un enum |
| **Scope** | `production` | dropdown con los scopes de la aplicación |

El backend **no se declara**. Se resuelve a partir del scope (ver 3.1). El dev nunca ve ni tipea una
URL interna: si la tipeara, tendríamos un campo que se puede equivocar y que nada puede validar
(ver §7.3, el falso negativo del `ResolvedRefs`).

El schema del `path` y el enum de `methods` se copian tal cual del endpoint-exposer upstream, que ya
los tiene resueltos con su regex y su `uniqueItems`.

### 3.1 Resolución del backend

Ya está probado en el `egress-interceptor` (`scripts/k8s/build_context`), así que se porta en lugar
de inventarse:

```bash
np scope list --application-id "$APPLICATION_ID" --status active --format json \
  --query '[ (.results? // .) | .[]? | {slug, domain} ]'
```

Con tres guardas que el `egress-interceptor` ya aprendió a la mala y que van igual acá:

1. **Scope inexistente o inactivo** → error explícito nombrando el scope y la aplicación.
2. **`domain == "To be defined"`** → un scope creado pero todavía sin desplegar devuelve ese
   literal, **no** `null` ni vacío. Dejarlo pasar rinde un `backendRef` con ese texto adentro y una
   ruta rota que aparenta estar bien.
3. **FQDN con forma válida** → regex anclado antes de meterlo en un manifiesto.

Ojo con el flag: es `--application-id` (con guión). El endpoint-exposer upstream usa
`--application_id` (guión bajo) en `build_httproute`. Uno de los dos está desactualizado; el que
corre en este repo y funciona es el del guión.

---

## 4. El link y la credencial

### Qué hace el link

Cuando una app consumidora se linkea al servicio expuesto, la acción `create` del link:

1. Genera un valor opaco aleatorio de 32 bytes.
2. Lo guarda como `Secret` en `kuadrant-system` con tres labels: el que lo hace visible a Authorino
   (`authorino.kuadrant.io/managed-by`), el marcador `api-manager.nullplatform.io/managed`, y la
   identidad `apimgr-target: <app-expuesta>` (sin prefijo de dominio, ver §7.4).
3. Lo devuelve en los results de la acción.

El `delete` del link borra el Secret. **Revocar es un `kubectl delete`**, inmediato y total.

### Cómo llega a la app

La property en el link spec lleva el `export`, y la plataforma hace el resto:

```json
"api_key": {
  "type": "string",
  "readOnly": true,
  "export": {
    "type": "environment_variable",
    "target": "API_MANAGER_API_KEY",
    "secret": true
  }
}
```

Con `secret: true` la plataforma genera un **secret parameter** en la aplicación consumidora, no una
env var en texto plano. El dev del consumidor no copia ni pega nada: se linkea y la variable aparece.

> **Nota sobre el upstream.** El endpoint-exposer declara `available_links = ["connect"]` y tiene un
> `specs/links/connect.json.tpl`, pero **no tiene `workflows/istio/link.yaml`** — sólo create,
> update, delete y read. La parte de generar credencial en el link no existe upstream. Hay que
> escribirla, no portarla.

### Por qué una key opaca y no el base64 firmado

La propuesta original era un base64 de un JSON tipo `{"allow": "payments.reports"}`, o un JWT.
Kuadrant trae un tercer mecanismo, `authentication.apiKey`, que ya probamos en
`poc-kuadrant/poc-mesh-kuadrant/`:

| | base64 JSON | JWT propio | **Key opaca + Secret** |
|---|---|---|---|
| Falsificable | **sí, trivial** | no | no |
| Revocable | **no** | sólo por expiración | sí, borrando el Secret |
| Infra extra | ninguna | JWKS + clave de firma | ninguna |
| Vence sola | no | sí, y rompe (ver abajo) | no |
| Ya probado acá | no | sí (wristband) | sí (poc-mesh) |

El base64 sin firma no es una simplificación: cualquiera arma el suyo y se autoriza solo, y no hay
forma de revocarlo. El JWT es seguro pero tiene un problema de encaje: el token viaja como env var
**estática**, y una env var no se auto-renueva. O el TTL es larguísimo —y entonces la expiración es
decorativa— o se rompe solo cuando vence.

La key opaca cuesta lo mismo de implementar que el base64, Authorino la valida nativo, y no es un
dummy que después haya que reemplazar cambiando el contrato con las apps.

**Si igual se prefiere el base64 para la demo**, cambia sólo el paso 1 de la lista de arriba. El
resto del diseño —link, export, AuthPolicy, ciclo de vida— no se entera.

---

## 5. Lo que se materializa en el cluster

Por aplicación expuesta, dos objetos en su namespace de Kubernetes.

### HTTPRoute

- `parentRefs` → el gateway global (cross-namespace).
- `hostnames` → los hosts declarados por el dev.
- Una `rule` por ruta declarada, cada una con su `matches` (path + methods), su `backendRefs` de
  `kind: Hostname` al **FQDN del Service del gateway de ingreso** (puerto 443), y un filtro
  `URLRewrite` cuyo `hostname` es el **dominio del scope de esa ruta** (ver §2).

Rutas de distintos scopes conviven en el mismo `HTTPRoute`: los filtros son por `rule`, así que cada
una reescribe al dominio de su propio scope. El `backendRef`, en cambio, es el mismo para todas — el
gateway de ingreso.

### AuthPolicy y la política del Gateway

**Una `AuthPolicy` a nivel route sobreescribe a la del Gateway.** Verificado contra el EKS real el
2026-09-01: sobre `s2s-ingress`, que tiene la `s2s-validator` exigiendo un wristband en `x-np-token`,
una route con su propia `AuthPolicy` de `apiKey` respondió **200 con sólo `x-api-key`**, sin wristband.

Importa porque despeja una duda razonable: el wristband del s2s **no aplica** a las routes de este
service. Cada uno valida lo suyo.

El segundo salto es distinto: aterriza sobre la route del **scope**, que no tiene política propia y
por lo tanto hereda `s2s-validator`. Ese es el punto donde los dos mecanismos se tocan, y es el que
hay que resolver si se quiere que el tráfico del api-manager llegue hasta el pod.

### AuthPolicy

Colgada del `HTTPRoute`, no del Gateway. Es a propósito: cada app necesita su propia lista de
consumidores habilitados, y una policy sobre el Gateway sería una sola para todos.

```yaml
rules:
  authentication:
    consumer-key:
      apiKey:
        selector:
          matchLabels:
            api-manager.nullplatform.io/managed: "true"
      credentials:
        customHeader:
          name: x-api-key
  authorization:
    allowed-target:
      patternMatching:
        patterns:
          - selector: auth.identity.metadata.labels.apimgr-target
            operator: eq
            value: "<app-expuesta>"
```

**El selector va en notación de punto, y por eso el label del target NO lleva prefijo de dominio.**
Verificado contra el cluster el 2026-08-31 (§7.4): Authorino **no soporta la notación de corchetes**
en ese campo. Un `labels['loquesea']` no resuelve, devuelve vacío, y la comparación falla en silencio
para **todas** las keys — con `Enforced=True` y todo en verde. La notación de punto no puede expresar
una clave con puntos ni con slash, así que `api-manager.nullplatform.io/target` queda descartada:
el label del target es `apimgr-target`. Guiones y guiones bajos sí funcionan; el **valor** puede
tener puntos sin problema, así que `payments.reports` es válido.

El otro label, `api-manager.nullplatform.io/managed`, **sí conserva el prefijo**: ese se usa en el
`matchLabels` del `apiKey`, que es un label selector común de Kubernetes y no pasa por el evaluador
de Authorino.

Dos decisiones más, las dos deliberadas:

**El selector matchea TODAS las keys del servicio, no sólo las de esta app.** Si filtrara por app,
una key ajena no autenticaría y daría 401. Queremos 403: autentica (es una key real del sistema),
falla la autorización (no es para esta app).

**`eq` y no `matches`.** `matches` es un regexp de Go sin anclar: `payments.reports` autorizaría
también a `payments.reports-evil`. Es el hallazgo #25 del `egress-interceptor`, ya pagado una vez.

### La semántica resultante

| Situación | Respuesta | Por qué |
|---|---|---|
| Sin header `x-api-key` | **401** | no autentica |
| Key que no existe | **401** | ningún Secret matchea |
| Key válida, pero de otra app | **403** | autentica, falla authorization |
| Key correcta, path no declarado | **404** | no hay `rule` que matchee |
| Key correcta, path declarado | **200** | pasa al backend |

Coincide con el comportamiento del `egress-interceptor`, así que las dos piezas se sienten iguales
desde afuera.

### Dónde viven los Secrets

En **`kuadrant-system`**, no en el namespace de la app.

Verificado contra el cluster el 2026-08-31, y el resultado **contradice la explicación** que traía
la PoC. Esa instancia de Authorino declara `clusterWide=true` —o sea que la razón no es que sea
namespaced—, y aun así los Secrets puestos en el namespace de la app (`payments`) **no se resuelven**:
las cuatro pruebas dieron 401, incluida la de la key correcta. Movidos a `kuadrant-system`, los
mismos Secrets con los mismos labels funcionan.

La conclusión operativa de la PoC era correcta; su explicación no. Importa porque invita a "arreglarlo"
poniendo `clusterWide: true` y descubrir que ya estaba puesto. Es el mismo límite que sufre el Secret
de firma del wristband, y es lo que obliga al RBAC de §7.2.

---

## 6. Ciclo de vida

| Acción | Qué hace |
|---|---|
| `create` | Resuelve backends, chequea colisiones (§7.1), **publica a GitOps (§6.1)**, aplica `HTTPRoute` + `AuthPolicy` |
| `update` | Re-renderiza, re-publica y re-aplica; borra las rutas que dejaron de estar declaradas |
| `delete` | **Publica el borrado**, borra `HTTPRoute` + `AuthPolicy` + **todos los Secrets de keys de esta app** |
| `link` | Genera la key, crea el Secret, la devuelve en los results |
| `unlink` | Borra el Secret de esa key |

El `delete` tiene que barrer las keys. Si no, quedan Secrets huérfanos en `kuadrant-system` que ya no
autorizan nada pero se acumulan para siempre — y si la app se vuelve a crear con el mismo slug,
consumidores viejos recuperan acceso sin haberse re-linkeado.

### 6.1 Publicación a GitOps — antes del apply, y fail-closed

Antes de tocar el cluster, los manifiestos renderizados se pushean a un repo git. **Si el push falla,
no se aplica nada.** Es el mismo contrato que ya cumple el `egress-interceptor`, y se reusa su
`gitops_lib`.

El orden importa y es deliberado: publicar primero significa que el repo es el registro de lo que se
intentó, y que un cluster no puede divergir del repo por un push fallido. Al revés —aplicar y después
publicar— el fallo del push deja el cluster con objetos que el repo no conoce, que es exactamente el
estado que un modelo GitOps existe para evitar.

Lo mismo en el `delete`: se publica la remoción antes de borrar del cluster.

**Los dos services comparten repo y se separan por carpeta:**

```
intra-namespace-rules/     <- egress-interceptor
cross-namespace-rules/     <- este service
```

Sale de `GITOPS_PATH_PREFIX`, que `gitops_subtree()` ya antepone: no hizo falta cambiar la lógica del
lib, sólo setear la variable distinto en cada service. Antes el egress usaba `""` y escribía en la
raíz.

**Todo esto es opcional.** Con `GITOPS_REPO_URL` sin setear, `gitops_enabled()` da falso y el flujo
corre igual, sin publicar. No es un requisito para usar el service.

Una cosa que hubo que tocar del lib al reusarlo, y que vale como advertencia para el próximo que lo
copie: `GITOPS_NAMESPACE_MANIFESTS` y `GITOPS_PER_SERVICE_MANIFESTS` estaban como **asignaciones
planas**, no con el idiom `: "${VAR:=default}"` que el propio archivo usa dos líneas más abajo.
Sourcear el lib pisaba lo que viniera del entorno, así que un segundo service no podía declarar sus
propios manifiestos.

`gitops_substrate()` queda igual que en el egress: la carpeta sale de `ORIGIN` (`EKS` → `eks`,
cualquier otra cosa → `openshift`). Los dos services corren bajo el mismo agente y ese agente ya
exporta `ORIGIN`.

### 6.2 De dónde sale cada variable

La división no es arbitraria y el `egress-interceptor` ya la sigue: **lo que es por cluster viene del
entorno del agente; lo que es por service, del `configuration:` del workflow.**

| Variable | De dónde | Por qué |
|---|---|---|
| `GITOPS_REPO_URL` | entorno del agente | Es por cluster, y puede llevar un token embebido |
| `ORIGIN` | entorno del agente | De ahí sale la carpeta del cluster (`EKS` → `eks`, cualquier otra cosa → `openshift`) |
| `GITOPS_BRANCH` | `configuration:` | Decisión del service |
| `GITOPS_PATH_PREFIX` | `configuration:` | Es lo que separa un service del otro |
| `GITOPS_PUSH_RETRIES` | `configuration:` | Decisión del service |

Las del agente **no se declaran en el workflow**, ni en `configuration:` ni en el `output:` del
`build context`: son ambientales y todos los steps las ven. Es como el egress trata `ORIGIN` y
`GITOPS_REPO_URL`.

Declararlas igual no es inocuo: un `ORIGIN: ""` en el `configuration:` **pisa** el valor que el
operador puso en el agente, y el service publica bajo la carpeta del cluster equivocado. Pasó
exactamente eso en la primera versión — con los tests en verde, porque el mock nunca ve la
diferencia.

---

## 7. Decisiones abiertas y riesgos

### 7.1 Colisión de hosts — agujero real, sin resolver upstream

Nada impide que la app `maliciosa` declare `api.expuesta.com` + `/ruta-1`, exactamente los mismos que
ya declaró `payments`. Gateway API resuelve por especificidad de path, y el que tenga el match más
específico se lleva el tráfico — **con su propia `AuthPolicy` y su propia lista de consumidores**.

O sea: una app puede secuestrar el tráfico de otra y quedarse con los requests, incluida la API key
que viaja en el header.

El endpoint-exposer upstream tampoco lo resuelve.

**Resuelto así:** el `create` y el `update` consultan las `HTTPRoute` existentes del cluster y
rechazan si el par `(host, path)` ya está tomado por otra aplicación. Es una consulta antes de
aplicar, y falla ruidosamente.

**Compartir host está explícitamente permitido.** La unidad de colisión es el par `(host, path)`, no
el host solo. Varias `HTTPRoute`, de aplicaciones distintas, pueden colgar del mismo `api.expuesta.com`
mientras sus paths no se pisen:

```
api.expuesta.com/pagos/*     → app payments      (HTTPRoute en ns payments)
api.expuesta.com/reportes/*  → app reports       (HTTPRoute en ns reports)
api.expuesta.com/pagos/*     → app maliciosa     ← RECHAZADO
```

Gateway API mergea rutas por hostname sin problema, así que esto no pelea con el protocolo.

Queda **descartada** la idea de restringir qué hosts puede declarar cada app (por ejemplo, forzando
un sufijo por namespace): sería más fuerte, pero rompe el caso de arriba, que es el que se quiere.

### 7.2 El RBAC toca `kuadrant-system`

Los Secrets de las keys tienen que vivir ahí (§5). Eso le da al agente permiso de escribir Secrets en
el mismo namespace donde vive **la clave de firma del wristband** del `egress-interceptor`.

**Propuesta:** `create` y `delete` sobre `secrets`, **sin `get` ni `list`**. Puede crear las suyas y
borrarlas por nombre; no puede leer la clave de firma. `create` no admite `resourceNames` en RBAC de
Kubernetes, pero `get`/`list` sí se pueden negar por completo, que es lo que importa acá.

### 7.3 `ResolvedRefs` no sirve como señal de salud — no esperarlo

Gotcha #27 de este repo dice que Istio no marca como resueltos los `backendRefs` de `kind: Hostname`,
y que la `HTTPRoute` reporta `ResolvedRefs=False (BackendNotFound)` con el tráfico funcionando.

**El gotcha original es correcto. Verificado contra el EKS real el 2026-09-01.**

Una corrección previa de este documento afirmaba que `False` aparece sólo cuando Istio desconoce el
hostname. Es falso, y se midió: con una route referenciando
`s2s-ingress-istio.gateways.svc.cluster.local`, el Envoy del gateway **sí tiene el cluster**
(`outbound|443||s2s-ingress-istio.gateways.svc.cluster.local` aparece en `/clusters`) y la condición
reporta `ResolvedRefs=False (BackendNotFound)` igual.

O sea: es un falso negativo constante para `kind: Hostname`, no un indicador de nada. **No sirve ni
como compuerta ni como diagnóstico.** La señal es el comportamiento del tráfico.

El `reconcile` del `egress-interceptor` espera esa condición para su route de ingreso. **Copiarlo tal
cual colgaría el apply.** La señal de la compuerta acá es `Accepted`, y nada más.

### 7.4 Verificado el 2026-08-31 — con una corrección

Authorino **sí** expone `metadata.labels` del Secret en `auth.identity`, así que la regla de
authorization de §5 es viable. Los cuatro casos dieron 401 / 401 / **403** / **200**, con el body del
200 confirmando que llegó al backend real.

Pero el selector del diseño original estaba mal, y falla del peor modo posible:

| Prueba | Selector | Resultado |
|---|---|---|
| A | `labels.apimgr-target`, valor `payments.reports` | **200** |
| B | `labels['apimgrtarget']` | 403 |
| C | `labels['api-manager.nullplatform.io/target']` (lo propuesto) | 403 |

La causa no son los puntos de la clave: es la **notación de corchetes**, que Authorino no soporta en
ese campo. Un selector que no resuelve devuelve vacío, y `eq` contra vacío da falso para **todas** las
keys — o sea que la AuthPolicy rechaza a todo el mundo con un 403 mientras reporta `Enforced=True`.
Es un modo de falla cerrado (no deja pasar a nadie), pero es indistinguible de "la key es de otra app"
sin hacer justamente este experimento: la primera lectura del 403 fue "funciona", y era al revés.

Correcciones que bajan a §4, §5 y al plan:

- El label del target es **`apimgr-target`**, sin prefijo de dominio, leído como
  `auth.identity.metadata.labels.apimgr-target`. Guiones y guiones bajos funcionan.
- El **valor** puede llevar puntos: `payments.reports` es válido.
- El label `api-manager.nullplatform.io/managed` conserva el prefijo — va en el `matchLabels` del
  `apiKey`, que es un selector de Kubernetes, no del evaluador de Authorino.
- Los Secrets van en `kuadrant-system` (ver §5): en el namespace de la app no se resuelven, ni
  siquiera con `clusterWide=true`.

---

## 8. Estructura de archivos

Sigue el `egress-interceptor`, que es la convención de la casa:

```
api-manager/
├── README.md
├── entrypoint/
│   ├── entrypoint
│   ├── service
│   └── link                     # no existe upstream, hay que escribirlo
├── workflows/
│   ├── create.yaml  update.yaml  delete.yaml
│   └── link.yaml    unlink.yaml
├── scripts/k8s/
│   ├── build_context            # resolución de scopes → dominios (§3.1)
│   ├── check_collisions         # §7.1
│   ├── reconcile
│   ├── mint_key                 # link
│   ├── revoke_key               # unlink
│   ├── manifests_lib
│   ├── gitops_lib               # copia del egress-interceptor (§6.1)
│   └── write_service_outputs
├── manifests/
│   ├── expose/
│   │   ├── 10-httproute.yaml.tpl
│   │   └── 20-authpolicy.yaml.tpl
│   └── rbac.yaml.tpl
├── specs/
│   ├── service-spec.json.tpl
│   ├── links/connect.json.tpl
│   ├── install/                 # registro del service + channel
│   └── prerequisites/           # ejemplo de instalación de Kuadrant
└── tests/                       # BATS
```

Un objeto de Kubernetes por archivo, con prefijo numérico que fija el orden de aplicación derivado
del glob.

La instalación replica el patrón del `egress-interceptor` tal cual: `specs/service-spec.json.tpl`
como fuente del registro, y `specs/install/` con el Terraform que crea el `service_definition` y su
notification channel. El registro se hace con `git_provider = "local"` y `local_specs_path`, así el
apply no necesita credenciales de ningún repo externo y lo que se registra es exactamente lo que está
versionado.

Ojo con el slug: la API lo calcula a partir del `name` y **no** sigue los renames. Con
`name = "Api Manager"` el slug queda `api-manager`. No declarar un campo `slug` en el spec — la API
lo ignora.

## 9. Qué me llevo y qué no del `egress-interceptor`

**Me llevo:**

- El `die()` en cada comando relevante. El runner de la CLI de nullplatform **neutraliza `errexit`**
  (sourcea los steps desde un contexto `if !`), así que sin `die()` explícito el script sigue después
  de un fallo y termina en verde. Costó caro descubrirlo.
- El helper de polling de condiciones. `kubectl wait --for=condition=` **no funciona** en `HTTPRoute`:
  mira `.status.conditions`, que siempre está vacío. Las condiciones viven en `.status.parents[]`, una
  entrada por controller.
- `render_manifests()` batcheando todos los pares `-f/-o` en **una sola** invocación de gomplate, con
  la guarda de directorio vacío (gomplate sin `-f` lee stdin para siempre: cuelga).
- La estructura de tests BATS, incluido correrlos contra el código sin arreglar antes de confiar en
  ellos.
- **`gitops_lib` entero** (§6.1), con el mismo contrato de publicar antes de aplicar y fallar cerrado.
  Va como copia y no como referencia compartida: cada service se registra con su propio
  `local_specs_path` y se despliega solo, así que no puede sourcear un archivo del vecino. Es la misma
  situación que `logging`.

**No me llevo:**

- La espera de `ResolvedRefs` (§7.3).
- El Gateway por namespace: acá el gateway es global (§2).
- El hijack de Services y su revert: no hace falta, el consumidor llama al host público, no al
  Service.

---

## 10. Plan de implementación

1. **Validar §7.4** contra el cluster: un Secret con labels, una AuthPolicy que autorice por
   `auth.identity.metadata.labels[...]`, y comprobar 401 / 403 / 200 a mano. Sin esto no se escribe
   nada más.
2. `service-spec.json.tpl` + `links/connect.json.tpl`, y registrarlos para verlos en la UI.
3. `build_context`: resolución de scopes y las tres guardas de §3.1, con sus tests.
4. Manifiestos + `reconcile` para `create` / `update` / `delete`.
5. `link` / `unlink`: generación y revocación de la key, y el export.
6. `check_collisions` (§7.1).
7. `specs/install/` + `specs/prerequisites/`, README, y PR en el repo de overrides.

---

## 11. Nombre

**Api Manager**. Definido.

El slug que calcula la API a partir de ese nombre es `api-manager`.
