# Demo S2S — identidad service-to-service entre OpenShift y EKS

Documentación de la PoC que sostiene a los dos services de este repo. No es de un service en
particular: el `egress-interceptor` es el lado emisor y el `api-manager` publica sobre el mismo
Gateway de ingreso, así que la demo los cruza.

## Para correrla

| Archivo | Qué es |
|---|---|
| [`GUIA-DEMO.md`](./GUIA-DEMO.md) | La guía rápida: qué mostrar y en qué orden |
| [`GUIA-DEMO-DETALLE.md`](./GUIA-DEMO-DETALLE.md) | El detalle, las decisiones y el camino a productivo |
| [`DEMO.md`](./DEMO.md) | El guión on-prem (OpenShift) → AWS |
| [`RUNBOOK-PRUEBAS.md`](./RUNBOOK-PRUEBAS.md) | Las pruebas paso a paso, con la salida esperada de cada una |

## Para entenderla

| Archivo | Qué es |
|---|---|
| [`README.md`](./README.md) | Qué problema resuelve la PoC y cómo está armada |
| [`CLUSTERS.md`](./CLUSTERS.md) | En qué se diferencian el EKS y el CRC, y qué implica cada diferencia |
| [`FIDELITY.md`](./FIDELITY.md) | Qué prueba esta PoC y qué **no** |
| [`BASELINE.md`](./BASELINE.md) | La línea base sin malla, para tener contra qué comparar |
| [`BIDIRECTIONAL.md`](./BIDIRECTIONAL.md) | El tráfico EKS → on-prem: qué faltaba y qué pasó |
| [`FINDINGS.md`](./FINDINGS.md) | Findings y smells, con los caminos post-PoC |
| [`SPIKES.md`](./SPIKES.md) | El registro de spikes de la fase 0 |

## Lo que estos documentos referencian y NO está acá

La infra vive en `nullplatform/galicia-banco`, bajo `accounts/galicia/demo-kuadrant-s2s/`, y se
queda ahí porque está acoplada al state y a los módulos de esa cuenta:

- `clusters/eks/` y `clusters/crc/` — las capas por cluster, incluidas las private hosted zones
- `modules/kuadrant-s2s/` — Istio, Kuadrant, el Gateway de ingreso y su `AuthPolicy` validadora
- `pki/` — la CA y los certs de servidor de los Gateways
- `demo.sh` y `scripts/` — bring-up y utilidades, que invocan tofu sobre esas capas

Los runbooks nombran esos paths cuando hay que aplicar algo. Si estás siguiendo uno y llegás a un
`tofu apply`, es en ese repo.
