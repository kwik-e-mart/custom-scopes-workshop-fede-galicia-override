# Qué prueba esta PoC y qué no

> ⚠️ **La tabla de abajo se escribió en la etapa del split por `VirtualService`**, y sus "aserción N"
> referencian un `verify.sh` que ya no existe. Las propiedades siguen siendo las que la PoC ejercita;
> el mecanismo que las implementa cambió. La conclusión del final ("Lo que la PoC sí cerró") sí está
> al día.

Una PoC que corre en verde invita a leerla como "esto ya funciona". Este documento marca la
frontera: **qué propiedades de producción están realmente ejercitadas y cuáles están
emuladas**, para que nadie tome una decisión apoyándose en algo que acá es de mentira.

El criterio con el que se decidió qué emular y qué no:

> **Un sustrato se puede stubear mientras el stub no aparezca en el contrato.** Lo que no se
> stubea son las capas donde vive la decisión de seguridad.

En concreto: ningún recurso de Istio o Kuadrant referencia una IP del overlay, un hostname
`.ts.net` ni una feature del proveedor del túnel. Todo el mecanismo de identidad ve un
**hostname, un puerto y una CA**. El día del Direct Connect cambia a qué resuelve ese nombre y
el módulo no cambia una línea — de hecho el andamiaje del transporte vive **fuera** del módulo
reutilizable, en `clusters/*/tailscale-transport.tf`, para que eso sea verificable y no una
promesa.

---

## La tabla

| Propiedad en el Banco | En la PoC | ¿Se prueba? |
|---|---|---|
| **Identidad acuñada y validada** entre clusters | Kuadrant + Festival Wristband RS256, en ambas direcciones | **Sí — es lo que la PoC viene a probar** |
| **Identidad transparente para la app** | La credencial la inyecta la malla; los Deployments no mencionan nada de identidad (aserción 7) | **Sí** |
| **TLS con CA propia**, validado por el cliente | Igual que producción: `DestinationRule` con la CA por SDS y SNI explícito | **Sí** |
| **Aislamiento por namespace** | NetworkPolicy + `exportTo` + CA por namespace; un intruso de otro namespace no llega (aserciones 5, 8, 15) | **Sí** |
| **Rechazo de identidad ausente o ajena** | 401 sin wristband, 403 por namespace no autorizado (aserciones 1, 2, 14) | **Sí** |
| **Rotación de credencial** | Wristband de 5 min, distinto en cada request (aserción 10) | **Sí** |
| **Migración gradual de tráfico** | Split ponderado 0→100 por `backendRefs` de `HTTPRoute`, sin tocar la app | **Sí** |
| **Direct Connect**, L3 privado ruteado | Overlay WireGuard sobre internet (Tailscale) | **No.** Se emula la *simetría* —que cualquiera de los dos lados inicie— no el medio |
| **Security groups contra los CIDRs de Plaza y Centro** | CIDRs del tailnet; el NLB es `internal` y no se expone | **No.** El control existe y está puesto, los valores son de mentira (Gap #2: los CIDRs reales siguen pendientes) |
| **DNS on-prem vía Route53 Resolver** | MagicDNS del tailnet + Services de Kubernetes | **No.** El problema desaparece en vez de resolverse |
| **BGP, propagación de rutas, MTU** | Nada de eso | **No** |
| **Latencia y ancho de banda reales** | Un relay DERP en São Paulo en el camino | **No.** Los tiempos de la PoC no predicen nada |
| **OpenShift multi-nodo real** | CRC single-node, arm64, sin HA | **Parcial.** El sustrato es OpenShift de verdad (SCCs, Multus, CNI: findings #3, #13, #20, #28) pero varias fricciones son *de CRC*, no de OpenShift |
| **Sin terceros en el control plane** | La coordinación del tailnet es un SaaS externo | **No.** En producción no hay ningún tercero entre los dos clusters |
| **Escala de ~400-500 namespaces** | 2 namespaces, 3 workloads | **No.** Ver el obstáculo 4 de `BIDIRECTIONAL.md`: la CA por namespace crece linealmente |
| **PKI corporativa** | CA propia autofirmada, 90 días, generada por Terraform | **No.** Cambia quién emite y quién revoca |
| **Identidad per-workload** | Identidad **a nivel namespace** (el claim sale del namespace del Secret) | **No, y no es un atajo de la PoC:** es la granularidad del mecanismo. Misma que Kong. Si el requisito es per-workload, el camino es Ambient/SPIFFE (findings #1 y #3) |

---

## Dónde muerde cada emulación

Las tres primeras filas de "No" no son igual de graves. En orden de impacto:

**1. La identidad no depende del transporte, pero la operación sí.** El mecanismo es indiferente
a cómo viajan los bytes — eso es exactamente lo que la separación módulo/andamiaje demuestra.
Pero el andamiaje trajo una dependencia operativa que **no existe en producción y sí en la
demo**: el proxy de egreso del overlay sólo sirve a clientes de su propio nodo, así que el pod
del Gateway de egreso tiene que estar co-locado con él (finding #30, y el paso 8 de
`scripts/up.sh`). Si alguien ve ese requisito y concluye "el diseño necesita co-locación", está
leyendo el stub, no el diseño.

**2. Los controles de red existen pero están calibrados con valores falsos.** El NLB es
`internal` y hay `source-ranges`: la *forma* del control es la de producción. Lo que no se probó
es que los CIDRs reales del Banco funcionen, porque todavía no los tenemos (Gap #2). Es un
pendiente de datos, no de diseño — pero no está verificado.

**3. Los números de la PoC no son números.** Con un relay en el medio, cualquier medición de
latencia o throughput mide el túnel. Si aparece una pregunta de capacidad, la respuesta no está
en esta PoC.

---

## Lo que la PoC sí cerró y conviene no volver a discutir

- El mecanismo de identidad **no necesita ningún componente custom**: ni OpenResty firmando ni
  Kong validando. Authorino acuña, `AuthPolicy` valida.
- Funciona **en ambas direcciones y de forma simétrica**: cada cluster emite con su clave y
  valida contra el issuer del otro, sin que ninguna clave privada cruce y sin dependencia de
  orden entre clusters (finding #33).
- El mecanismo es **transparente para las aplicaciones**: la identidad se configura en la malla,
  no en el código ni en el Deployment.
- La **migración es gradual y reversible** con una perilla, sin tocar la app.

Todo eso se sostiene sobre el transporte que ponga el Banco, sea Direct Connect o lo que sea:
el módulo sólo pide un hostname alcanzable y una CA.
