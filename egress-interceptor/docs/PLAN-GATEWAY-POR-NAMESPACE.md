# Plan — reemplazar OpenResty por un Gateway de egreso por namespace

**Diseño:** [`docs/s2s-egress-sin-openresty.md`](./DISENO-SIN-OPENRESTY.md) — leerlo primero.
**Branch de trabajo:** `feat/kuadrant-s2s-vuelta` · **Estado:** **Fases 0-4 hechas y verificadas (2026-08-24)**

Objetivo: sacar el código propio del camino del dato del egreso, preservando las dos patas de la
garantía actual (clave por namespace + NetworkPolicy) y sin cambiar el contrato externo de la demo.

---

## Cómo retomar esto desde cero

```bash
cd ~/nullplatform/galicia/galicia-banco
aws sso login --profile galicia-1                     # la sesión dura 1 h
crc start                                             # ~3 min; CRC quedó apagado el 24/08
cd accounts/galicia/demo-kuadrant-s2s
./scripts/tailnet-prune.sh                            # OBLIGATORIO tras arrancar CRC (ver Gotcha del tailnet)
NP_API=$(ls "$HOME/.claude/plugins/marketplaces/nullplatform-internal/src/skills/np-api/scripts/np-api.sh") \
  ./demo.sh preflight
```

Estado al cierre del 24/08: los **dos** clusters arriba, con Gateway de egreso + AuthPolicy
enforceando en `payments`. `egress-eks` en EKS→EKS, `egress-crc` en OpenShift→EKS. Tailnet limpio.
El agente del host de EKS quedó corriendo (`/tmp/np-agent-eks.log`); para CRC se levanta el suyo y
**los dos conviven**: el channel selecciona por `{role, cluster}` con el cluster resuelto dinámicamente
desde la instancia, y los launchers bindean puertos distintos (CRC `8181`, EKS `8182`).

Si CRC estuvo apagado un rato, Authorino queda con conexiones viejas y el shim de Kuadrant tira
`gRPC status code is not OK` → todo da 500 con los objetos en verde:
`kubectl --context crc-admin rollout restart -n kuadrant-system deploy/authorino`.

---

## Fase 0 — Spikes: **cerrada, los tres en verde**

No se corrieron por separado. La contrapropuesta del cliente (`../poc-kuadrant/`) los había
ejercitado sobre su propio par de clusters, y la implementación los confirmó de punta a punta:

- **S1 — Service por selector a los pods de un Gateway.** Verde. La ClusterIP no cambia y el cliente
  no se entera. El cliente además documentó un fallback con `ExternalName` por si los pods del
  Gateway no caen en el namespace.
- **S2 — Kuadrant acuña el wristband sobre un Gateway de egreso.** Verde, `Enforced=True` en los dos
  clusters, **pero sólo con RSA 2048 en PKCS#1** (ver §10.2 del diseño).
- **S3 — hop remoto como `backendRef` con TLS y CA privada.** Verde con `kind: Hostname` +
  `DestinationRule` (`credentialName`, `sni`, `connectionPool`).

## Fase 1 — Render de los manifests (TDD)

- [x] Escribir primero los tests en `services/egress-interceptor/tests/render.bats`, **y correrlos
      contra el código viejo para confirmar que fallan**. Casos mínimos:
      un `HTTPRoute` por intercepción; `weight` = `percent` y su complemento; el header de ruteo
      correcto según `target_kind` (`X-NP-Scope` para `EKS`, `X-NP-SVC` para `OS`); rewrite a
      `/intra-namespace` **sólo** en la rama remota; y la validación anti-inyección de `_require_match`
      preservada (namespace, fqdn, percent, kind).
- [x] Reemplazar `render_server_blocks` / `render_nginx_conf` en `scripts/k8s/lib_render.sh` por el
      render de `Gateway` + `HTTPRoute` + `AuthPolicy`.
- [x] Borrar `openresty/nginx.conf.tpl` y `manifests/egress-gateway.yaml.tpl`.
- [x] Los headers de traza (`X-Egress-Route`, `X-Egress-Target`) con `ResponseHeaderModifier` por rama
      — **verificar antes** que Istio lo soporte en un `backendRefs` ponderado (riesgo abierto §5 del diseño).

## Fase 2 — Reconcile

- [x] `scripts/k8s/reconcile`: aplicar manifests declarativos en vez de ConfigMap + Deployment.
- [x] El hijack del `Service` cambia de `selector: app=egress-gateway` a
      `selector: gateway.networking.k8s.io/gateway-name=s2s-egress`. **Conservar** la annotation
      `egress-interceptor/original-selector`: es lo que hace reversible el `delete`.
- [x] El `delete` tiene que borrar también el `Gateway`, el `HTTPRoute` y la `AuthPolicy`, y dejar el
      Service restaurado. Probar el ciclo completo create → update → delete.
- [x] `ReferenceGrant` en `ns tailscale` para que el `HTTPRoute` pueda apuntar al Service del overlay.

## Fase 3 — Claves por namespace

- [x] Decidir quién emite las claves de wristband: hoy `pki/` genera las de firma y `clusters/*` crea
      los Secrets. El wristband necesita el Secret en `kuadrant-system` con el label de Authorino.
- [x] **Una clave por namespace**, no una por cluster. Es el invariante que sostiene el Paso 5.
- [x] Verificar que la `AuthPolicy` del **ingreso** siga validando: el JWKS que publica
      `jwks_endpoint.tf` tiene que corresponder a la clave del wristband, no a la vieja de OpenResty.
      Este es el punto de contacto más delicado del cambio.

## Fase 4 — Verificación con el runbook (criterio de aceptación)

Correr `accounts/galicia/demo-kuadrant-s2s/RUNBOOK-PRUEBAS.md` completo:

- [x] Paso 5 y 6 (aislamiento en los dos clusters): **401 / 403 / 403 / 200**. El tercer caso —clave de
      `other` declarando `iss=payments` → 403— es el que prueba que la identidad no sale del claim.
      **Si esto no da 403, el cambio es un downgrade de seguridad y no se mergea.**
- [x] Pasos 12 a 15 (los cuatro escenarios): 200 con la decisión registrada en el validador del destino.
- [x] Paso 16 (barrido): progresión 0 / ~50 / 100. Documentar los valores nuevos si cambian: Envoy
      pondera por upstream, el Lua sorteaba por request.
- [x] Actualizar el Paso 4 del runbook: `pod_gw` y `esperar` buscan `app=egress-gateway`; hay que
      reapuntarlos al label del Gateway. **Son los únicos cambios esperados en el runbook.**
- [x] Confirmar que no queda ningún pod con imagen propia en el camino del dato.

## Fase 5 — Cierre

- [x] `quality-gate` — corrido a mano (no por subagentes). Encontró y arregló: el render abortaba con
      la lista de intercepciones vacía (`seq 0 -1` cuenta hacia atrás en BSD) y una variable muerta
      en `reconcile`. Pasada de seguridad sobre el diff: sin material sensible, sin gitignoreados
      colados.
- [x] Actualizar `docs/s2s-egress-sin-openresty.md`: §10 registra veredictos, cambios y hallazgos.
- [x] Actualizar `project-status/README.md`: la decisión "Kuadrant sobre Istio reemplaza
      a Kong y a OpenResty" pasa de parcial a completa.
- [x] `docs/gotchas.md`: gotchas **25** (RS256/PKCS#1/kid), **26** (merge-patch de selector) y **27** (`ResolvedRefs` falso negativo).
- [ ] Commit.

---

## TODO — el atributo `cluster` tiene que morir

Es **andamiaje temporal**. Existe sólo para que el selector del notification channel
(`$context.attributes.cluster`) elija el agente correcto mientras no haya una **dimension** que
represente dónde corre la instancia.

Cuando la dimension exista:

- [ ] El selector del channel pasa a resolverse contra la dimension, no contra un atributo.
- [ ] Se borra `cluster` del `service-spec.json.tpl`. **No hay código que migrar**: ningún script
      del service lo lee, y hay un test (`tests/build_context.bats`) que falla si alguien lo
      vuelve a leer desde `scripts/`.
- [ ] `demo.sh` deja de mandarlo en el body del `create`.

Mientras tanto queda una debilidad conocida y aceptada: si un agente arranca con el tag
equivocado, el ruteo miente y no hay red de contención — el guard que compara el atributo contra
el `$CLUSTER` del launcher se sacó justamente para no acoplar código a un campo que se va.

## Invariantes que no se negocian

1. **Una clave de firma por (cluster × namespace)**, nunca una por cluster.
2. **La identidad se deriva de qué clave verificó la firma**, nunca del claim `iss`.
3. **El material de firma no sale de un `Secret`**: nunca en un `HTTPRoute`, un ConfigMap ni el state.
4. **La `NetworkPolicy allow-intra-namespace` sigue acotando quién puede pedir firma** — lo que exige
   que el firmante viva dentro del namespace.
5. El contrato externo (headers, atributos de la instancia, pasos del runbook) no cambia.

## Cosas que ya sabemos y conviene no volver a descubrir

- `Accepted=True` de una `AuthPolicy` **no** significa que enforcee: mirar `Enforced=True` (Gotcha #22).
- Kuadrant **no** se adjunta a un waypoint de ambient (`mesh-controller` vs `gateway-controller`).
- En CRC, con uptime largo, multus se queda con el token vencido y **ningún pod nuevo nace**:
  `kubectl delete pod -n openshift-multus -l app=multus` (Gotcha #23).
- Después de arrancar CRC hay que correr `./scripts/tailnet-prune.sh`: los proxies se re-registran y
  un nombre con sufijo rompe el hop cross-cluster en silencio.
- `kubectl` **no** soporta filtros anidados en jsonpath (`items[?(@.status.conditions[?(...)])]`).
- Para saber si un reconcile aterrizó, la única señal confiable es el **comportamiento**
  (`X-Egress-Target` de la respuesta), no `rollout status` ni el contenido del ConfigMap.
