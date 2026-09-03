# Demo egress-interceptor — verificación E2E por terminal (0% → 50% → 100%)

> ⚠️ **Guión de la etapa de Kong: NO describe el modelo actual.** Quedó de dos pivotes atrás —
> hoy no hay Kong ni OpenResty, el JWT lo acuña Kuadrant/Authorino sobre un Gateway de egreso, el
> `cluster` de la app en EKS es `eks-kuadrant`, y el form declara `service_name`/`scope`/`percent`.
> Para la demo vigente: `accounts/galicia/demo-kuadrant-s2s/GUIA-DEMO.md` y su `RUNBOOK-PRUEBAS.md`.

Demuestra el traffic-split del interceptor variando `% hacia EKS` y verificando el **origen
de cada response** con tres señales independientes:

| Señal | Local (on-prem CRC) | Nube (EKS/Kong) |
|---|---|---|
| Header `X-Egress-Route` (lo pone el gateway) | `local` | `cloud` |
| Campo `cluster` del body `/whoami` (lo pone la app) | `crc-openshift` | `eks-kong` |
| Headers `X-Kong-*` / `Via: kong` (los pone Kong) | ausentes | presentes |

## Prerequisitos

- CRC + OpenShift arriba (`crc status`), agente CRC corriendo con KUBECONFIG
  (`./services/egress-interceptor/start-agent-crc.sh`).
- EKS/Kong vivo sirviendo `reports` con `SERVICE_NAME=reports`, `CLUSTER_NAME=eks-kong`,
  Kong en `enforce` (token inválido → 401).
- Instancia del service **Egress Interceptor** creada sobre ns `payments`, interceptando
  `reports` (FQDN de Kong en `FQDN en EKS`).
- Shell con `oc`: `eval "$(crc oc-env)"`.

## Helper de probe (pegar una vez en la terminal)

```bash
NS=payments
probe() {  # $1 = cantidad de requests
  local pod; pod=$(oc -n "$NS" get pod -l app=reports -o jsonpath='{.items[0].metadata.name}')
  oc -n "$NS" exec "$pod" -- sh -c '
    for i in $(seq 1 '"${1:-20}"'); do
      wget -S -qO- http://reports.'"$NS"'.svc.cluster.local:8080/whoami 2>&1 \
        | grep -iE "X-Egress-Route:|\"cluster\"" | tr -d "\r"
    done' 2>/dev/null
}
tally() { probe "${1:-20}" | grep -i "X-Egress-Route:" | awk "{print \$NF}" | sort | uniq -c; }
detalle() {  # 1 request: headers completos + body (muestra X-Egress-Route, X-Kong-*, cluster)
  local pod; pod=$(oc -n "$NS" get pod -l app=reports -o jsonpath='{.items[0].metadata.name}')
  oc -n "$NS" exec "$pod" -- wget -S -qO- http://reports."$NS".svc.cluster.local:8080/whoami 2>&1 | tr -d '\r'
}
```

## Toggle del `%`

Editá la instancia en la UI → **% hacia EKS** = `N` → Save. Eso dispara el `update` →
el agente re-renderiza el nginx y hace rollout del gateway. Esperá el rollout antes de probar:

```bash
oc -n payments rollout status deploy/egress-gateway --timeout=120s
```

> (Alternativa por API: patch del attribute `interceptions[].percent` + disparar la acción
> `update` del service; la UI hace ambos en un click.)

## Paso 1 — `% hacia EKS = 0`  (todo on-prem)

```bash
oc -n payments rollout status deploy/egress-gateway --timeout=120s
detalle      # esperado: X-Egress-Route: local | body cluster: crc-openshift | sin X-Kong-*
tally 20     # esperado: 20 local
```

## Paso 2 — `% hacia EKS = 50`  (split ~mitad y mitad)

```bash
oc -n payments rollout status deploy/egress-gateway --timeout=120s
tally 20     # esperado: ~10 cloud / ~10 local (binomial, no exacto)
detalle      # repetí un par: vas a ver alternar local/cloud y el cluster del body acompañar
```

## Paso 3 — `% hacia EKS = 100`  (todo en la nube)

```bash
oc -n payments rollout status deploy/egress-gateway --timeout=120s
detalle      # esperado: X-Egress-Route: cloud | body cluster: eks-kong | CON X-Kong-* / Via: kong
tally 20     # esperado: 20 cloud
```

## Prueba de identidad/enforcement (opcional, prueba que Kong valida)

Bypasseando el gateway, pegarle directo a Kong sin JWT debe dar **401** (enforce):

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<FQDN-de-Kong>/whoami   # 401
```

El `200` que ves en `% = 100` (vía gateway) prueba que el JWT firmado por el interceptor
(`iss=payments`) pasó la validación de Kong. Mismo `reports`, distinto cluster según la perilla.

## Reversibilidad

Borrar la instancia (UI o `np service delete --id <id>`) dispara el `delete`: revierte el
selector de `reports` a los pods reales y borra gateway + `reports-local`. `reports` vuelve a
la normalidad sin rastro.
