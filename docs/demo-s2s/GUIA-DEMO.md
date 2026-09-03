# Guía rápida de la demo S2S

Identidad servicio-a-servicio entre OpenShift y EKS **sin malla en los pods de aplicación**:
Kuadrant/Authorino acuña un JWT (wristband RS256) en un Gateway de egreso por namespace, firmado con
la clave privada de ese namespace, y lo valida en el ingreso del destino, que rutea por header. No
hay ningún pod de imagen propia en el camino del dato.

Un comando por paso: `./demo.sh <paso>`. Detalle de qué hace cada uno y por qué: `GUIA-DEMO-DETALLE.md`.

**Prerequisitos:** los dos clusters arriba y las dos instancias del service (`egress-eks` y
`egress-crc`) creadas por UI — `demo.sh` sólo las reconfigura. Para el lado de OpenShift hay
instalador: `./scripts/crc-up.sh`. Qué más hace falta (AWS, tailnet, key de nullplatform) y con
qué config van las instancias: `GUIA-DEMO-DETALLE.md`.

## Antes de empezar

Si los clusters ya están arriba, sólo esto:

```bash
cd accounts/galicia/demo-kuadrant-s2s
./demo.sh preflight          # los 2 clusters listos + JWKS cruzado + qué agente está prendido
```

**Desde cero**, en una laptop que nunca corrió esto, van dos pasos más adelante. Son
one-time y los dos son idempotentes, así que se pueden volver a correr sin miedo:

```bash
./scripts/crc-up.sh          # el OpenShift local: instala, dimensiona y arranca
./scripts/up.sh              # el resto del sustrato (~20 min de cero)
./demo.sh preflight
```

`crc-up.sh` te va a pedir un **pull secret de Red Hat** (personal, gratis, se baja de
[console.redhat.com](https://console.redhat.com/openshift/create/local)) y ~24 GB de RAM
física. Al terminar imprime **qué falta todavía**: CRC es una de cinco dependencias y las
otras cuatro —AWS, tailnet, key de nullplatform y los CLIs— no se pueden automatizar. El
desglose está en `GUIA-DEMO-DETALLE.md`.

Si el preflight corta, la demo no va a andar: resolvelo antes. Lo único manual es el **agente**, que
hace falta sólo para *cambiar* configuración (el tráfico no lo usa) y corre **uno a la vez**.
Va en **otra terminal** y **desde la raíz del repo** — el `cat` es una ruta relativa:

```bash
cd "$(git rev-parse --show-toplevel)"
export NP_API_KEY="$(cat accounts/galicia/np-api-skill.key)"
./services/egress-interceptor/start-agent-eks.sh    # o start-agent-crc.sh
```

Ese `export` es **sólo para el agente**: `demo.sh` usa siempre la key del repo, así que una key de
otra org exportada en tu shell ya no lo desvía.

**Uno a la vez, no los dos.** El channel filtra sólo por `role=egress-interceptor` (sin `cluster`),
así que con los dos vivos la acción la puede tomar el agente del cluster equivocado y reconciliar el
gateway que no es, sin fallar. Los pasos abortan si detectan más de uno; `preflight` y `estado` te
avisan. Tener los dos lados simultáneos requiere un channel por cluster — está evaluado, no hecho.

## Los pasos

| Paso | Agente | Qué prueba | ~ |
|---|---|---|---|
| `preflight` | — | Sesión SSO viva, Gateway `Programmed`, AuthPolicy **`Enforced`** en los 2 clusters, y que cada validador alcance la clave pública del peer | 30 s |
| `esc1` | eks | **El contrato completo sin cruzar la red.** El request sale del pod, entra por el Gateway del mismo cluster y vuelve al destino: firma, validación y ruteo por header. Cada request muestra quién firmó y quién validó | 2 min |
| `esc2` | crc | **La misma identidad sobre la topología real.** Origen OpenShift, destino EKS: el token lo valida la regla del *peer*, con la clave que viajó por el overlay | 2 min |
| `esc3` | eks | **El header de ruteo lo decide el destino.** Hacia OpenShift viaja `X-NP-SVC` en vez de `X-NP-Scope`; el resto del contrato no cambia | 2 min |
| `barrido` | eks | **La perilla de migración.** `percent` 0 / 50 / 100 con 20 requests por punto: todo local → mezcla → todo remoto | 4 min |
| `aislamiento` | — | **Que la identidad no se pueda falsificar.** Sin token 401; con la clave de otro namespace 403; y con esa clave declarando ser `payments`, **también 403** | 1 min |
| `estado` | — | Instancias, gateways y agente, para saber dónde quedó todo | 10 s |

## El guión ágil (~10 min)

```bash
./demo.sh preflight
./demo.sh esc1          # agente eks
./demo.sh aislamiento   # no necesita agente: se puede mostrar acá sin cambiar nada
./demo.sh barrido       # agente eks
# — cambiar al agente de CRC en la otra terminal —
./demo.sh esc2          # agente crc
# — volver al agente de EKS —
./demo.sh esc3          # agente eks
./demo.sh estado
```

Si hay poco tiempo: **`esc1` + `aislamiento`** ya cuentan la historia completa (el contrato y la
propiedad de seguridad). `esc2`/`esc3` agregan la topología cross-cluster, y `barrido` el argumento de
migración gradual.

## Lo que hay que saber antes de mostrarlo

- **El primer request cross-cluster después de arrancar Authorino da 500.** El JWKS del peer se trae por
  demanda y ese fetch cruza el overlay. Los scripts ya hacen un calentamiento y lo descartan; si corrés
  a mano, tirá un request y descartalo. El log dice `UNAVAILABLE`, que **no** es "token inválido".
- **Al cambiar el `percent`, esperá el pod nuevo.** El pod viejo sigue recibiendo tráfico un rato
  después de que `rollout status` vuelve, y una medición inmediata mezcla configuraciones. `demo.sh` ya
  espera; a mano, verificá que cambió el nombre del pod.
- **Si el agente se cae, el tráfico sigue.** El agente no está en el camino del dato: lo que se pierde
  es poder cambiar la configuración (las acciones quedan colgadas o fallan con "no channel"). Un agente
  muerto sigue figurando un rato con su último heartbeat; si `demo.sh` dice "registrados pero sin latir",
  es eso: relanzalo.
- **Si `esc2` falla con "el gateway no convergió", sospechá de CRC antes que de la demo.** Con uptime
  largo, el pod de multus se queda con un token vencido y **ningún pod nuevo puede nacer** — cluster-wide,
  y los cluster operators igual reportan todo sano. Se confirma en 20 s y se arregla sin bajar CRC:

  ```bash
  kubectl --context crc-admin run canario --image=busybox:1.36 -n default --command -- sleep 30
  # si queda en ContainerCreating, es el cluster:
  kubectl --context crc-admin delete pod -n openshift-multus -l app=multus
  ```

  Después del fix **reintentá `esc2` una vez más**: el CNI tarda unos minutos en estabilizarse y el
  primer intento puede agotar la espera aunque ya esté todo bien.
- **`verify.sh` y `scripts/split.sh` fueron eliminados** (eran de la etapa anterior: wristband de
  Authorino y split por `VirtualService`). Si los ves referenciados en `README.md`, esa parte quedó
  vieja — lo vigente es `./demo.sh`.
