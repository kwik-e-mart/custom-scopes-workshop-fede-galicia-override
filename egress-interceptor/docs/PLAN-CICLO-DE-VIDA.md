# Plan — qué pasa con una regla cuando la migración ya terminó

**Estado: abierto, sin decidir.** Esto no es un plan de implementación todavía: es el planteo de un
problema que hay que pensar antes de escribir código. Surgió el 2026-08-27 mientras se redactaba la
descripción del service en la UI.

## El problema

Una regla del `egress-interceptor` nace como mecanismo de **transición**: mueve tráfico de OpenShift
a EKS de a poco. Pero cuando llega a `percent=100` y el servicio se apaga en OpenShift, esa regla
deja de ser transitoria: pasa a ser **lo único que hace que las aplicaciones que quedaron en
OpenShift puedan seguir llamando al servicio**.

Y ahí el ciclo de vida se vuelve contraintuitivo: lo que parece basura para limpiar —"ya migramos,
borremos la regla"— es en realidad infraestructura de producción.

### Qué pasa hoy si alguien la borra

Verificado leyendo `services/egress-interceptor/scripts/k8s/reconcile` el 2026-08-27:

1. Al quitar la regla, el reconcile detecta el Service como *stale* (lo delata su annotation
   `egress-interceptor/original-selector`).
2. Llama a `revert_service`, que **restaura el selector original** del Service.
3. Con el workload ya borrado de OpenShift, ese selector no matchea ningún pod.
4. El Service queda **sin endpoints**. Los llamadores de OpenShift dejan de funcionar.

No es una degradación gradual: es un corte. Y el borrado de la **instancia** entera hace lo mismo
por el camino del `delete`.

Hoy no hay ninguna protección: el chequeo de endpoints que existe en el reconcile sólo corre para
`percent < 100`, que es exactamente el caso contrario a éste.

## Lo que ya se hizo

Sólo documentarlo. El bloque markdown del service specification tiene un párrafo que lo explica
("Cuando la migración termina, la regla se queda"), publicado en la UI el 2026-08-27.

Es una mitigación por documentación, no por diseño. Alcanza para la demo; no alcanza para producción.

## Las preguntas a resolver

Ninguna tiene respuesta todavía. Están ordenadas de más concreta a más de fondo.

### 1. ¿El `delete` tiene que protegerse?

La opción barata: antes de revertir, chequear si el selector original dejaría al Service sin
endpoints. Si es así, abortar con un error que explique qué iba a pasar, y exigir algo explícito
para forzarlo.

- **A favor:** convierte un corte silencioso en un error legible. Es el mismo patrón que ya usa el
  reconcile para `percent < 100`, así que no introduce un concepto nuevo.
- **En contra:** un guard que se puede forzar termina forzándose. Y no resuelve el caso de alguien
  que borra la regla *antes* de apagar el workload, que es igual de destructivo y no lo detectaría.
- **A pensar:** ¿qué pasa si el namespace de destino está caído en ese momento? El chequeo daría
  falso positivo y bloquearía un delete legítimo.

### 2. ¿Una regla al 100% debería poder borrarse?

Quizás el estado "migrado" tenga que ser **terminal**: la regla se puede bajar de 100, pero no
eliminar mientras esté ahí. Volver atrás sería bajar el porcentaje, no borrar.

- Implica que el `delete` de la instancia también tendría que negarse, o al menos advertir.
- Choca con la reversibilidad que promete el service. Hay que ver si es una contradicción real o
  sólo aparente: bajar el porcentaje sigue estando disponible.

### 3. ¿La regla es realmente el lugar donde esto vive?

Es la pregunta de fondo. Una vez migrado, lo que la regla expresa ya no es "estoy migrando", es
**"este servicio vive en EKS y así se lo alcanza desde OpenShift"**. Eso se parece más a un alias
permanente, o a un service discovery, que a una regla de migración.

Posibilidades a explorar:

- Que al llegar a 100 la regla **se transforme** en otra cosa (otro tipo de service, o un flag que
  cambie su semántica y su UI).
- Que se quede como está y sólo cambie el discurso: el service no es "de migración", es "de
  resolución de nombres entre sustratos", y la migración es un caso de uso.
- Que en el Banco esto lo cubra otra pieza —el DNS corporativo, un service mesh federado— y el
  interceptor sea explícitamente andamiaje con fecha de vencimiento.

### 4. ¿Qué pasa cuando OpenShift se apaga del todo?

El final del camino de M5. Si ya no queda nada en OpenShift, no hay quien llame desde ahí y la regla
sí sobra. ¿Cómo se sabe que se llegó a ese punto? ¿Quién lo declara? Hoy nada lo modela.

## Qué hace falta para decidir

- Entender cómo piensa el Banco el **ciclo de vida de un servicio migrado**: ¿queda un registro
  permanente en el CMDB apuntando a AWS, o el servicio "se muda" y la Sigla sigue siendo la misma?
- Confirmar si en el diseño destino los llamadores de OpenShift van a seguir existiendo por mucho
  tiempo, o si la migración se hace por bloques que se mueven completos. Si es lo segundo, la
  ventana en la que esto importa es corta y la mitigación por documentación puede alcanzar.
- Decidir si el `egress-interceptor` es un producto o andamiaje. Casi todo lo de arriba depende de
  esa respuesta.

## Archivos que toca

- `services/egress-interceptor/scripts/k8s/reconcile` — `revert_service` y el bloque de stale
  services (opción 1).
- `services/egress-interceptor/specs/service-spec.json.tpl` — el markdown ya lo advierte; si el
  estado 100 pasa a ser terminal, cambia también el schema.
- `accounts/galicia/demo-kuadrant-s2s/RUNBOOK-PRUEBAS.md` y `GUIA-DEMO-DETALLE.md` — hoy **no**
  mencionan este caso. Decidido no tocarlos hasta que haya una decisión.
