# Línea base sin malla (2026-08-11)

> ⚠️ Documenta la **etapa anterior** del PoC: el wristband se acuñaba a partir de una apiKey sobre un Gateway compartido, y el split iba por `VirtualService` en la malla. Hoy el wristband se acuña sobre un **Gateway de egreso por namespace** y el split va por `backendRefs` ponderados de `HTTPRoute`; `mesh_routing.tf` ya no existe. Se conserva por el valor de sus hallazgos, no como instructivo. Vigente: `GUIA-DEMO.md`.

Registro del punto de partida de la Fase 0 (`docs/superpowers/plans/2026-08-11-openresty-egress-s2s.md`,
Task 2): sustrato verificado sano, **sin inyección de sidecars** en ningún pod de aplicación. A partir de
acá, lo que se rompa en las fases siguientes es del contrato de headers o del ruteo, no del sustrato.

## Qué cambió respecto al estado anterior

- `workloads.tf`: sacado el label `istio-injection = enabled` del namespace.
- `istio_openshift.tf`: sacado el `kubernetes_role_binding.apps_anyuid` (en EKS nunca existió — el
  `for_each` estaba gateado por `var.is_openshift`).
- Los pods de `payments`/`other` en los dos clusters corren con un solo contenedor (`app`), sin
  `istio-init`/`istio-proxy`. En EKS hizo falta un `kubectl rollout restart` explícito de los 3
  Deployments: la Task 1 los había creado *antes* del cambio de label, y el webhook de inyección solo
  actúa en la creación del pod — sacar el label no reinicia lo que ya está corriendo.

## Aserciones que corrieron (sustrato, sin malla)

Las 4 que no dependen del sidecar, corridas contra `crc-admin`:

| # | Chequeo | Resultado |
|---|---|---|
| 1 | Overlay: `ledger` (CRC) alcanza el ingreso de EKS vía `s2s-remote-gateway.tailscale.svc.cluster.local` (hostname in-cluster que resuelve por Tailscale, no el DNS público del NLB) | `401 Unauthorized` — **éxito**: el paquete llegó y la `AuthPolicy` actuó |
| 2 | JWKS del peer, `./scripts/fetch-jwks.sh crc` | OK, `kid=wristband-signing-key` |
| 3 | `Gateway s2s-ingress` en `istio-system` | `Accepted=True`, `Programmed=True` |
| 4 | `AuthPolicy` en `istio-system` | `s2s-issuer: True (Enforced)`, `s2s-validator: True (Enforced)` — **`Enforced`, no solo `Accepted`** (gotcha #22) |

## Aserciones que NO corrieron, y por qué

- **Split ponderado** (`mesh_routing.tf` / `VirtualService`) y **`X-Service-Identity`**: dependen del
  sidecar para el steering este-oeste y del contrato de headers viejo. Las dos cosas se van en la
  Fase 1/2 de este plan — no tiene sentido validarlas contra algo que se va a reemplazar.

## Gotcha nuevo, no documentado antes

El comando del plan usaba `tofu output -raw gateway_hostname` (el DNS público del NLB) para probar
conectividad "sin malla" desde CRC. Timeoutea: ese Gateway es `scheme: internal` desde el cierre del
incidente de seguridad previo (ver memoria `project_kuadrant_s2s_sg_incident`), así que no tiene IP
pública. La ruta correcta para probar conectividad cruda entre clusters es el hostname in-cluster que
publica `tailscale-transport.tf` (`remote_host` en `terraform.tfvars`, acá
`s2s-remote-gateway.tailscale.svc.cluster.local`), que resuelve vía el proxy del operator de Tailscale
hacia el overlay. `DEMO.md` todavía referencia el hostname público en su pre-flight — queda desalineado
con el estado actual (ya señalado como pendiente en la nota de cabecera del propio archivo).

De paso, la IP de origen (`clusters/eks/source-ranges.auto.tfvars`) había rotado — el propio archivo
predice este síntoma exacto ("si rota, `verify.sh` empieza a fallar por timeout y hace falta un apply").
Actualizada y aplicada (`190.224.168.88` → `190.137.118.197`).
