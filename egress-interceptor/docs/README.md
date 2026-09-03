# Documentación de trabajo

Material interno del desarrollo de este service, incluido acá para poder revisarlo junto con el
código. **No es documentación de uso**: para eso está el [`README.md`](../README.md) del service.

| Archivo | Qué es |
|---|---|
| [`DISENO-SIN-OPENRESTY.md`](./DISENO-SIN-OPENRESTY.md) | Por qué se sacó OpenResty y qué lo reemplaza, con la evidencia de la migración |
| [`DISENO-GITOPS.md`](./DISENO-GITOPS.md) | El diseño de la publicación a GitOps y sus gaps |
| [`PLAN-GITOPS.md`](./PLAN-GITOPS.md) | El plan con el que se construyó esa feature, tarea por tarea |
| [`PLAN-DESTINO-POR-SCOPE.md`](./PLAN-DESTINO-POR-SCOPE.md) | El pivote de destino por FQDN a destino por scope |
| [`PLAN-CICLO-DE-VIDA.md`](./PLAN-CICLO-DE-VIDA.md) | Qué pasa con la regla una vez que la migración terminó |
| [`PLAN-GATEWAY-POR-NAMESPACE.md`](./PLAN-GATEWAY-POR-NAMESPACE.md) | Un Gateway de egreso por namespace en vez de uno por regla |
| [`DEMO-KONG-OBSOLETO.md`](./DEMO-KONG-OBSOLETO.md) | ⚠️ Guión de la etapa de Kong, dos pivotes atrás. Se conserva como registro, no describe el modelo actual |

Los originales vivían en `nullplatform/galicia-banco` (`docs/`, `plans/` y `services/egress-interceptor/`),
que va a quedarse sólo con el terraform de instalación. Se copiaron acá después del merge de su
PR #60, que corrigió documentación que contradecía al código.

Lo que **no** se copió y sigue en ese repo es la infra de la demo, que no es código de este service:
`accounts/galicia/demo-kuadrant-s2s/` — su `GUIA-DEMO.md`, su `RUNBOOK-PRUEBAS.md`, la PKI, el
módulo de Kuadrant y las capas por cluster.

Si esta carpeta estorba en el entregable, se borra entera sin tocar nada más: ningún archivo del
service la referencia.
