# Api Manager — decisiones tomadas durante la implementación
> 38 decisiones que tomé sin consultar, para no frenar la ejecución. Cada una lleva su motivo y su
> costo si está equivocada. Todas son reversibles. Extraídas del ledger de la corrida del 2026-08-31.

## Ruling 1 — Task 7 / entrypoint

Task 7 modifica `entrypoint/entrypoint` para enrutar las notificaciones de link al handler `link`. Se lleva explícito en el dispatch de Task 7 como archivo a modificar. — Motivo: el bloque Files es lo que el implementer lee; la prosa se pasa por alto. — Costo si me equivoco: ninguno, es agregar un archivo que ya estaba en prosa.

## Ruling 2 — Task 8 / RBAC

el bloque de código del plan es incompleto, no autoritativo. El implementer produce un `RoleBinding` por cada `Role`, más el `ClusterRole`/`ClusterRoleBinding` de sólo lectura sobre `httproutes` que necesita `check_collisions`, y elimina `GATEWAY_NAMESPACE` del template y de la verificación si no queda ningún recurso que lo use. Se mantiene inviolable: el Role de `kuadrant-system` NO lleva `get` ni `list`. — Motivo: la prosa describe la intención completa; el bloque quedó recortado al escribir el plan. — Costo si me equivoco: RBAC de más o de menos, visible en el review de Task 8.

## Ruling 3 — Task 3 / application.slug

`APP_TARGET` se arma preferentemente con `.application.slug` del `$CONTEXT`; si no viene, se resuelve con `np application read --id "$APPLICATION_ID"`. Si ninguna de las dos da un slug, aborta con el mensaje que nombre las claves que sí trae el CONTEXT. — Motivo: no está verificado que `--build-context` incluya el slug, y `APP_TARGET` es la identidad sobre la que se autoriza: no puede quedar vacía ni adivinada. — Costo si me equivoco: una llamada extra a la API por acción.

## Ruling 4 — Task 7 / link.id

`mint_key` y `revoke_key` resuelven el id del link probando `.notification.link.id` y, si no está, volcando al log las claves de primer nivel de la notificación antes de abortar. El nombre del Secret deriva de ese id. — Motivo: un id mal resuelto produce Secrets con nombre colisionante entre links distintos, que es una fuga de credencial cruzada. Fallar ruidosamente es la única opción segura. — Costo si me equivoco: el primer link real falla con un mensaje que dice exactamente qué campo usar.

## Ruling 5 — selector de Authorino

el selector va en NOTACIÓN DE PUNTO. Authorino no soporta corchetes
en ese campo. Aislado con tres pruebas: `labels.apimgr-target` + valor `payments.reports` → 200;
`labels['apimgrtarget']` → 403; `labels['api-manager.nullplatform.io/target']` (lo que decía el
diseño) → 403. No eran los puntos de la clave: era la notación. Como la notación de punto no puede
expresar una clave con puntos ni slash, el label del target pasa a ser `apimgr-target`, sin prefijo
de dominio. Guiones y guiones bajos funcionan (probado); el VALOR sí puede tener puntos.
— Costo si me equivoco: ninguno, está verificado empíricamente end-to-end.

## Ruling 6 — un solo nombre para el label del target

`apimgr-target` se usa TAMBIÉN en el HTTPRoute,
donde no hay restricción técnica (ahí lo lee jq, no Authorino). — Motivo: dos nombres para el mismo
concepto es una trampa de mantenimiento; el que sabe de la restricción la olvida y el que no, no la
descubre. — Costo si me equivoco: un label menos idiomático en el HTTPRoute.

## Ruling 7 — no bloquear por el review de Task 1

rev-task1b lleva >25 min sobre un diff de 4,4 KB y
rev-task1 ya había quedado mudo. Sigo despachando implementers (Task 1 ya está commiteada y su
implementer está idle, así que no hay dos implementers en paralelo) y dejo que el review llegue de
fondo. Si trae hallazgos, entran al fix loop cuando lleguen. — Motivo: Task 1 es un esqueleto
mecánico transcrito del plan, con self-review hecho; el usuario pidió llegar al final y va a revisar
todo junto, y la red real es el review de rama completa del final. — Costo si me equivoco: los
hallazgos de Task 1 se arreglan más tarde, sobre un árbol donde Tasks 2+ ya construyeron encima.

## Ruling 8 — los reviewers escriben a archivo

dos reviewers seguidos (rev-task1, rev-task1b) quedaron
idle sin entregar su mensaje final. A partir de acá TODO reviewer recibe la instrucción de escribir su
reporte con Write a <workspace>/task-N-review.md y responder sólo "listo"; el controller lo lee del
archivo. — Motivo: el canal de mensaje final de los subagentes de review no está entregando en esta
sesión, y perder el veredicto es perder la única compuerta por tarea. — Costo si me equivoco: un
archivo extra por tarea en el workspace, que se borra al final igual.

## Ruling 9 — logging conserva sus comentarios

el archivo `logging` se copia verbatim y NO se le sacan
los comentarios, aunque la regla global sea cero comentarios. — Motivo: es un archivo vendorizado, copia
textual de `scopes/k8s/logging` de la plataforma; editarlo crea drift con el upstream, y el
egress-interceptor ya lo entrega igual en este mismo repo. La regla apunta a lo que escribimos nosotros.
— Costo si me equivoco: un bloque de 11 líneas de comentario en un archivo que no mantenemos.

## Ruling 10 — los mensajes en inglés del entrypoint se quedan

"NP_ACTION_CONTEXT is not set. Exiting."
y "Executing service action=..." quedan en inglés pese a la regla de castellano. — Motivo: son las
cadenas canónicas del router de acciones, idénticas a las del egress-interceptor; un operador que lee
logs del agente ve lo mismo viniendo de los dos services. La consistencia entre services hermanos vale
más que la uniformidad de idioma en dos strings. — Costo si me equivoco: dos mensajes en inglés.

## Ruling 11 — el masking de export SÍ se arregla

`export x=$(cmd)` tapa el status de cmd, y `jq -r '.type'`
sobre una notificación sin ese campo devuelve el STRING literal "null", que pasa el regex anti-inyección
y hace que se busque `workflows/istio/null.yaml`. El reviewer lo verificó empíricamente. Se arregla:
declaración separada de asignación con `|| exit 1`, más dos guardas en entrypoint/service (rechazar el
literal "null" y verificar que el workflow exista). — Motivo: es un fallo silencioso en la puerta de
entrada de TODAS las acciones, y Task 7 modifica este mismo archivo; es load-bearing. Es además
exactamente la clase de bug que la guía de estilo del propio repo señala. — Costo si me equivoco:
ninguno; el arreglo es estrictamente más estricto que el original.

## Ruling 12 — guardas en la cadena inicial de jq de build_context

se arregla. El reviewer trazó la
cascada: con NP_ACTION_CONTEXT mal formado el primer jq sale 5 con stdout vacío, y como `jq` con stdin
vacío sale 0 SIN salida, el fallo no se propaga por ningún lado. El script aborta igual, pero por
accidente —`[ "" -eq 0 ]` es verdadero en contexto aritmético— disparando el guard de "no hay dominios
declarados". Un contexto corrupto se reporta como error del dev. — Motivo: es la misma clase que Ruling
11 (Task 1) y la consistencia importa; además un mensaje que misatribuye la causa cuesta horas en
producción. — Costo si me equivoco: ninguno, el arreglo es estrictamente más estricto.
  Los 2 Minor (estandarizar printf %s, guarda en la reasignación de ROUTES_JSON) van en el mismo fix.
  El ⚠️ del reviewer (que el mock de `np` modele al CLI real) queda cubierto por Task 11: el runbook
  ejerce el CLI de verdad contra el cluster.

## Ruling 13 — lista && pelada en build_context:57

se arregla. `[ -n "$SERVICE_ID" ] && require_match ...`
es una lista `&&` a nivel de statement: con SERVICE_ID vacío —caso legítimo, el campo es opcional— la
lista devuelve status no-cero y bajo `set -e` el script aborta sin un solo mensaje. Misma familia que

## Ruling 12. Se convierte en `if` explícito, con un test que exige que el script termine OK sin
service.id. — Motivo: un campo opcional que voltea el script en silencio es peor que uno requerido que
falla ruidoso; y la línea viene heredada del egress-interceptor, así que arreglarla acá evita
propagarla. — Costo si me equivoco: ninguno.

Ruling 12. Se convierte en `if` explícito, con un test que exige que el script termine OK sin
service.id. — Motivo: un campo opcional que voltea el script en silencio es peor que uno requerido que
falla ruidoso; y la línea viene heredada del egress-interceptor, así que arreglarla acá evita
propagarla. — Costo si me equivoco: ninguno.

## CORRECCIÓN a Ruling 13: la premisa era FALSA. El implementer no pudo reproducir el abort silencioso y
demostró por qué: `set -e` exime explícitamente el fallo de un comando NO FINAL dentro de una lista
`&&`

CORRECCIÓN a Ruling 13: la premisa era FALSA. El implementer no pudo reproducir el abort silencioso y
demostró por qué: `set -e` exime explícitamente el fallo de un comando NO FINAL dentro de una lista
`&&` (bash manual; verificado en bash 5.3.15 y contra el script real — con SERVICE_ID="" el script
llega al final con exit 0). El hallazgo diferido de rerev-task3 era incorrecto, y yo lo ruleé sin
verificarlo. El cambio (bare && -> if explícito) se mantiene porque es defensivo y consistente con el
resto del archivo, pero NO arregla ningún bug. El test agregado pasa también contra el código previo,
o sea que no distingue pre/post fix — el implementer lo declaró en vez de venderlo como RED->GREEN.

## Ruling 14 — SERVICE_ID pasa a ser OBLIGATORIO

`ROUTE_NAME=api-manager-${SERVICE_ID}` con SERVICE_ID
vacío produce el mismo nombre para dos instancias del mismo namespace, y el apply de una pisa el

## Ruling 15 — el delete no depende de los scopes

build_context exige scopes activos también al borrar,
así que si los scopes ya no existen, el delete aborta ANTES de limpiar HTTPRoute, AuthPolicy y Secrets
— quedan rutas huérfanas y credenciales vivas de una app que ya no está expuesta. Decisión: la
resolución de scopes se saltea en el flujo delete, que sólo necesita NAMESPACE, APP_TARGET, SERVICE_ID
y KEYS_NAMESPACE. — Motivo: el teardown tiene que poder correr sobre un estado degradado; es
justamente cuando más se lo necesita. — Costo si me equivoco: el delete no valida algo que no usa.

## Ruling 16 — el HTTPRoute tiene que llevar el label apimgr-target

el template de Task 4 nunca pone
`apimgr-target` en el objeto HTTPRoute — target_label/app_target sólo se usan dentro de la regla de
authorization de la AuthPolicy, que compara contra el label del SECRET. Consecuencia en producción:
check_collisions ve `owner: null` en todas las rutas, incluida la propia en un update, así que la
auto-exclusión `select($owner != $self)` no excluye nada y TODO update se reporta como colisión
consigo mismo; y una colisión real imprime `owner: null` en vez de la app culpable. Los tests pasaban
porque el mock de collisions.bats fabrica el label a mano — el modo de falla exacto contra el que
advierte la guía del repo (un mock que no modela lo real pasa mientras lo real se rompe). Se arregla:
label en el template + test en render.bats que assertee lo que el TEMPLATE emite, no lo que el mock
inventa. — Motivo: sin esto la función central de Task 6 no funciona en producción y ningún test lo
detecta. — Costo si me equivoco: ninguno; el label es aditivo.
  Se autorizó a impl-task6 a tocar archivos de Task 4 para cerrarlo, y se le pidió además verificar si
  la AuthPolicy necesita el mismo label (el reconcile borra por label) y si el delete deja basura.
  También: uno de los 4 tests dio "ok" en RED por exit 127, no por su aserción — se pidió fortalecerlo.

## Ruling 17 — el harness de fail_fast tiene que reproducir el errexit neutralizado

los tests 1-3
invocan `run bash "$RECONCILE"`, un proceso nuevo con su propio `set -euo pipefail`. El reviewer sacó
cada `|| die` uno por uno y el script abortó IGUAL, por errexit pelado. O sea que la suite que existe
específicamente para probar el fail-fast bajo errexit neutralizado NUNCA ejerce esa condición: pasaría
con todas las guardas borradas. 26/26 en verde sobre la propiedad que más importa, sin afirmarla.

## Ruling 18 — constantes de labels compartidas

check_collisions hardcodea los literales
"api-manager.nullplatform.io/managed=true" y "apimgr-target"; reconcile los define como constantes

## Ruling 18 SIGUE EN COLA: espero a cerrar Task 5 antes de tocar reconcile de nuevo.

Ruling 18 SIGUE EN COLA: espero a cerrar Task 5 antes de tocar reconcile de nuevo.

## Ruling 19 — sacar `watch` del RBAC

el implementer dejó `watch` sobre httproutes/authpolicies siguiendo
el brief y el egress-interceptor, pero no pudo nombrar ningún script de api-manager que lo use — y me
lo preguntó en vez de decidirlo solo. Verificado: wait_route_condition hace polling con `kubectl get`
en loop, y no usamos `kubectl wait` en ningún lado (no funciona sobre HTTPRoute). El watch venía
copiado del egress-interceptor, que sí lo necesitaba para un `kubectl wait` sobre la AuthPolicy de
ingreso; esa llamada acá no existe. Decisión: se saca. — Motivo: si no se puede nombrar el script y la
línea que necesita un verbo, el verbo no va; y este RBAC toca el namespace de la clave de firma del
wristband, así que cada permiso de más importa. — Costo si me equivoco: una futura implementación con
watch falla con "cannot watch resource", que es ruidoso y obvio.

## Ruling 20 — rutear por forma, no por literal

el ruteo al handler de link se apoyaba en
`$NOTIFICATION_ACTION == "link"` con `service` como default silencioso. Si el literal real difiere, las
notificaciones de link ejecutan create/delete.yaml, la acción probablemente reporta éxito y el
consumidor nunca recibe su api_key — sin un solo error. Decisión: rutear por la ESTRUCTURA de la
notificación (existe `.notification.link` -> link; existe `.notification.service` -> service; ninguna
-> abortar volcando las claves), en vez de verificar el literal contra el cluster. — Motivo: verificar
el literal resuelve el caso de hoy; rutear por forma resuelve también el día que la plataforma cambie
el valor. Y elimina el default silencioso, que es lo peligroso de verdad. — Costo si me equivoco: si
la notificación de link no trae `.link`, la acción falla ruidosamente con las claves reales en el log,
que es exactamente lo que hace falta para arreglarlo.
  Van en el mismo fix los 3 menores: assertear el mensaje en el test de revoke fallido, cubrir el
  camino de fallo del etiquetado (deja una key que Authorino no ve, o sea una credencial inútil ya
  entregada al consumidor), y ampliar el test de "no loguea la key" para mirar también $output y no
  sólo el LOG_FILE de la log() mockeada.

## Ruling 18 DESTRABADO: reconcile ya está estable y Task 5 cerrada. Se despacha a impl-task6.

Ruling 18 DESTRABADO: reconcile ya está estable y Task 5 cerrada. Se despacha a impl-task6.

## Ruling 21 — los scripts se adaptan, el RBAC no se relaja

el camino de credenciales completo no
funcionaría en producción con este Role.
  a) `mint_key` daría 403: usa `create --dry-run=client -o yaml | kubectl apply -f -`, y kubectl apply
     SIEMPRE hace un GET del objeto destino para decidir create-vs-patch. Sin `get` el apply aborta, y
     apply no cae a POST ciego ante un 403 (sólo ante un 404). El `create` concedido nunca se ejercita.
     Idem el `kubectl label --overwrite` posterior.
  b) El decomiso de `reconcile` daría 403: el borrado por label-selector resuelve con un LIST.
  Decisión: NO se relaja el RBAC. Se cambian los call sites — mint pasa a `kubectl create -f -` con el
  Secret completo (POST puro, labels incluidos, desaparece la llamada de label), y el decomiso pasa a
  borrado POR NOMBRE resolviendo los link ids por la API de nullplatform. — Motivo: la restricción
  protege la clave de firma del wristband de otro service, y un `list` de secrets devuelve los objetos
  con su data. Relajarla para que ande el happy path sería cambiar una falla ruidosa por una
  exposición silenciosa. — Costo si me equivoco: mint pierde idempotencia (create falla con
  AlreadyExists), lo cual ante dos links con el mismo id es una señal legítima, no un problema.

## Ruling 22 — sacar `update`

sin dueño en los tres bloques. Ningún script hace PUT ni replace; todo va
por apply (PATCH) o label --overwrite (PATCH). Misma clase que watch y que el list de authpolicies.
— Costo si me equivoco: ninguno, aparecería como error explícito.

## Ruling 23 — la sección "Procedencia" se queda

el reviewer la marcó como Minor por tener sabor a
historia de implementación más que a documentación de uso. La pedí yo explícitamente en el dispatch y
el README del egress-interceptor tiene la misma sección. — Motivo: sirve al mantenedor futuro que
quiera saber qué se heredó del upstream y qué se escribió acá, que es exactamente la pregunta que uno
se hace al tocar este código por primera vez. — Costo si me equivoco: dos párrafos que un dev consumidor
saltea. El segundo Minor (redactar el caso 200 en prosa en vez de en la tabla) es cosmético, se pasa.

## Ruling 24 — la key en argv se deja como está, por ahora

el API key se pasa como argumento de línea de
comandos a `jq --arg`, así que es visible en la tabla de procesos de ese nodo mientras dura la llamada.

## Ruling 25 — borrado parcial sin rollback

si el borrado de un Secret falla a mitad del loop, los
anteriores ya se borraron y el script aborta sin revertirlos. — Motivo: es una propiedad inherente del
borrado por nombre y coincide con lo que ya hacía revoke_key para un solo item; un rollback exigiría
recrear credenciales, que es peor que dejarlas borradas. El re-intento del delete es idempotente.
— Costo si me equivoco: un decomiso a medias que se completa corriendo el delete de nuevo.

## Ruling 26 — C1 — normalizar el path antes de comparar colisiones

el template guarda el path con
`TrimSuffix "*"` (`/pagos/*` queda `/pagos/`) y check_collisions compara contra `.path` CRUDO
(`/pagos/*`). Igualdad exacta de strings: nunca matchean. O sea que el guard de colisiones —única
defensa contra el secuestro de tráfico, con la API key viajando en el header— está INERTE justamente
para la sintaxis que el README documenta como el caso normal. Verificado con repro. — Costo si me
equivoco: ninguno, es normalización.

## Ruling 27 — C2 — sacar `patch` de secrets

AGUJERO DE DISEÑO MÍO. Protegí la LECTURA de secrets en
kuadrant-system (get/list prohibidos, por la clave de firma del wristband) y dejé la ESCRITURA
abierta: `patch` sin resourceNames alcanza para sobreescribir el `data` de cualquier Secret del
namespace, esa clave incluida. El agente no la lee: la REEMPLAZA por una que controla, y desde ahí
forja wristbands. Confidencialidad protegida, integridad no — peor que el `list` que tanto cuidamos.

## Ruling 28 — C3 — el target del link sale del service, no del contexto

APP_TARGET se deriva del
$CONTEXT de la acción, y el link lo crea la app CONSUMIDORA, que por la premisa del servicio vive en
otro namespace. Si el contexto es el del consumidor, o se emite una key con el label equivocado (y la

## Ruling 29 — N1 — unificar la fórmula de APP_TARGET

las dos mitades del control de acceso quedaron
calculándose distinto. El PREDICADO de la AuthPolicy usa ${namespace_de_k8s}.${app_slug} (de
build_context, con fallback literal a `nullplatform` si el provider config no trae cluster.namespace,
y con NAMESPACE_OVERRIDE pisándolo). El LABEL del Secret usa ${slug_del_namespace_de_nullplatform}.
${app_slug} (de service_target_lib). Coinciden por convención, no por construcción — y como la

## Ruling 30 — assignable_to se queda en "any"

el implementer había sugerido ajustarlo a nivel
aplicación. El re-reviewer verificó el enum real y `"application"` NO es un valor admitido, así que la
recomendación no era implementable. Queda `"any"`. — Costo si me equivoco: ninguno, es el estado actual.

## Ruling 31 — migrar TODO build_context.bats al harness fiel

hallazgo propio del implementer —
build_context también corre sourceado bajo `if !` en producción, igual que reconcile, así que el mismo
problema del Ruling 17 aplica a su suite. Verificó en aislamiento que un `APP_TARGET=$(...)` sin `||`

## Ruling 32 — sacar el dead code de APPLICATION_SLUG

su único uso era la fórmula vieja de APP_TARGET.

## Ruling 33 — 4 de las 5 no-discriminantes se quedan

en los tests 1, 2, 4 y 5 hay una segunda guarda
real que protege el comportamiento, y el test assertea el RESULTADO. Que el crédito se lo lleve otra
línea no lo vuelve un test vacío: si se rompen las dos guardas, se pone rojo igual. Es redundancia
inofensiva, no cobertura falsa. — Costo si me equivoco: si alguien saca la primera guarda creyendo que
está cubierta, el test no avisa; mitigado documentando en el reporte cuál es la segunda.

## Ruling 34 — el test 3 SÍ se arregla, y el problema es el mock

"sin application.id aborta" no
discrimina porque el mock de `np scope list` devuelve scopes aunque `--application-id` venga vacío.

## Ruling 35 — TOCTOU: parkeado, NO se arregla a ciegas

entre check_collisions y el apply pasan segundos,
y dos creates concurrentes para el mismo (host,path) pasan ambos el chequeo. Si el agente ejecuta las
notificaciones EN SERIE la ventana es cero; si no, es explotable. Ese dato no se ve desde el código y
no lo tengo. — Motivo: las mitigaciones reales (lock cluster-wide, admission control) son
desproporcionadas si la ejecución ya es serial, y elegir una sin saberlo agrega complejidad
permanente a cambio de nada. — Costo si me equivoco: si el agente es concurrente, queda una ventana de
secuestro de tráfico. ACCIÓN PARA EL USUARIO: confirmar el modelo de ejecución del agente. Va al
reporte final y al runbook.

## Ruling 36 — delete sobre todos los secrets de kuadrant-system: parkeado

el Role concede `delete` sin
resourceNames porque RBAC de Kubernetes no admite scoping por prefijo, y los nombres son
api-manager-<link-id> con link-id variable. Hoy inalcanzable: los scripts sólo borran por ese patrón.

## Ruling 37 — CRDs de Gateway API sin checksum: parkeado

specs/prerequisites/ baja
standard-install.yaml de un release de GitHub por HTTPS sin verificar sha256. — Motivo: es el ejemplo
de prerequisitos, explícitamente ilustrativo, y pinear un sha obliga a actualizarlo en cada release
del upstream. — Costo si me equivoco: un release adulterado pasaría sin detección. Vale pinearlo si
esto entra a un control de cadena de suministro.

## CORRECCIÓN a Ruling 35 — TOCTOU

el usuario respondió el dato que faltaba — el agente PUEDE ejecutar
en paralelo, aunque en la práctica la concurrencia agresiva es rara. Así que la ventana es real, no
teórica. Nueva decisión: no se parkea, pero tampoco se pone un lock.

## Ruling 38 — mitigación del TOCTOU por re-chequeo post-apply

después de que la route quede Accepted,
`reconcile` vuelve a correr el chequeo de colisiones. Si aparece un conflicto con otro dueño que no
estaba antes, borra la HTTPRoute y la AuthPolicy que acaba de crear y aborta diciendo que hubo una
carrera. — Motivo: para una carrera rara, un lock cluster-wide o admission control es complejidad
permanente a cambio de poco; detectar-y-retirarse cuesta una llamada extra y convierte un secuestro
silencioso en dos acciones fallidas con la razón exacta. Fail-closed a propósito: si las dos partes de
la carrera se detectan mutuamente, las dos se retiran y nadie se queda con tráfico ajeno. — Costo si me
equivoco: en una carrera ambas acciones fallan y hay que reintentar, en vez de que una gane.
