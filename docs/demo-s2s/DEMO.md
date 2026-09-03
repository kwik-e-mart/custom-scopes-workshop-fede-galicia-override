# DEMO — Identidad S2S con Kuadrant: on-prem (OpenShift) → AWS

> ⚠️ Guión de la **etapa anterior** (emisor con wristband, split por `VirtualService`, aserciones de `verify.sh` — ya eliminado). Vigente: `GUIA-DEMO.md` + `./demo.sh`.


> **Nota (2026-08-07):** este guion se escribió cuando la PoC era one-way. Hoy los dos
> clusters corren en **rol dual** y el tráfico autenticado va en las dos direcciones: los
> seis actos siguen siendo válidos tal cual, pero se quedan cortos. La vuelta (EKS→CRC) está
> cubierta por las aserciones 13-15 de `verify.sh`. Actualizar este guion es parte de la
> tarea de documentación pendiente.


Lo mismo que la demo de Kong, **sin ningún componente custom en el camino**. Antes hacía
falta un OpenResty firmando JWTs y un Kong validando: dos procesos propios, con su código,
su imagen y su ciclo de vida. Ahora lo hace la malla más Kuadrant, declarativamente.

```
[OpenShift on-prem]                                    [AWS / EKS]
 ledger ──sidecar──► Gateway propio ──HTTPS──► Gateway ──► ledger
                     Authorino acuña             Kuadrant valida
                     el wristband                el wristband
```

- **Cluster A (on-prem emulado):** CRC, namespaces `payments` (`ledger`, `reports`) y
  `other` (`intruso`). Rol `issuer`.
- **Cluster B (AWS):** EKS `gal-kuadrant-poc`, Gateway con NLB. Rol `validator`, en
  **enforce**.

> Las diferencias de instalación entre los dos (Istio CNI, SCC, CRDs, pull de imágenes)
> están en [`CLUSTERS.md`](CLUSTERS.md).

**El titular no es dónde rechaza, es qué se eliminó.** Igual que con Kong, el rechazo es un
`401` de aplicación, no un corte de conexión. Lo que cambia es que **no hay proceso propio
firmando ni validando nada**.

---

## Pre-flight (una vez, antes de la demo)

```bash
crc start                                  # si CRC está detenido
eval $(crc oc-env)
aws sso login --profile galicia-1
cd "$(git rev-parse --show-toplevel)/accounts/galicia/demo-kuadrant-s2s"

HOST=$(cd clusters/eks && tofu output -raw gateway_hostname)
GW=s2s-istio.istio-system.svc.cluster.local     # Gateway propio de A, in-cluster
SPLIT=reports.payments.svc.cluster.local:8080   # host que atraviesa el split
echo "$HOST"
```

Chequeo de que B está enforceando de verdad (**`Accepted` no alcanza**):

```bash
# El contexto de B no lo crea ningún layer (los providers autentican por `exec`):
aws eks update-kubeconfig --name gal-kuadrant-poc --region us-east-1 \
  --profile galicia-1 --alias kuadrant-eks

# El contexto de B no lo crea ningún layer (los providers autentican por `exec`):
#   aws eks update-kubeconfig --name gal-kuadrant-poc --region us-east-1 \
#     --profile galicia-1 --alias kuadrant-eks
kubectl --context kuadrant-eks -n istio-system \
  get authpolicy s2s-validator -o jsonpath='{.status.conditions}' | jq -r '.[] | .type + "=" + .status'
# tiene que incluir Enforced=True
```

Arrancar con la perilla en **100** para que los actos 3-4 crucen de verdad:

```bash
cd clusters/crc && sed -i '' 's/^weight_remote = .*/weight_remote = 100/' terraform.tfvars \
  && tofu apply && cd ..
```

> Ojo con el rate limit: B está en **5/min** a propósito (es el smoke del anexo). Si en
> medio de la demo aparece un `429`, no es un error — esperá el minuto o mencionalo como
> feature.

---

## El relato, en 6 actos

### Acto 1 — Sin credencial, contra el Gateway del propio on-prem → rechazado

Ni sale del cluster A. Kuadrant rechaza en el borde de salida.

```bash
oc -n other exec deploy/intruso -c app -- \
  wget -S -qO- "http://$GW/anything" 2>&1 | grep 'HTTP/'
# -> HTTP/1.1 401 Unauthorized
```

En el log de Authorino: `credential not found`. **Es un 401, no un corte de TLS** — la vía
del handshake se exploró y quedó descartada (la versión de Gateway API que instala OpenShift no soporta `frontendValidation` —
ver `SPIKES.md`, spike C).

### Acto 2 — Sin wristband, contra el endpoint público de AWS → rechazado

```bash
curl -sk -o /dev/null -w "sin wristband -> HTTP %{http_code}\n" "https://$HOST/whoami"
# -> HTTP 401
```

Este es el mismo acto que en la demo de Kong. **Lo que cambió es quién lo hace:** antes
Kong, ahora la `AuthPolicy` de Kuadrant.

### Acto 3 — `ledger` entra, y la app no sabe nada

```bash
oc -n payments exec deploy/ledger -c app -- wget -qO- "http://$SPLIT/whoami"
# -> {"service":"ledger","namespace":"payments","cluster":"eks-kuadrant",...}
```

`cluster=eks-kuadrant`: el request cruzó a AWS. Y la app **no tiene nada de identidad**:

```bash
oc -n payments get deploy ledger -o yaml | grep -icE 'jwt|wristband|openresty|apikey|service-identity'
# -> 0
```

Cero. Ni una env var, ni un volumen, ni una annotation. La identidad la inyecta la malla en
un objeto aparte (`VirtualService`), no el pod. **Esto es lo que antes requería OpenResty.**

### Acto 4 — `reports`, mismo namespace, otra ServiceAccount → **también entra**

El acto honesto. No es el de venta.

```bash
oc -n payments exec deploy/reports -c app -- wget -qO- "http://$SPLIT/whoami"
# -> {"service":"ledger", ... "cluster":"eks-kuadrant",...}
#
# OJO: el body dice "ledger", no "reports". El HTTPRoute de B tiene un solo backendRef
# (a ledger), así que TODO lo que entra a B aterriza ahí. Lo que prueba el acto no es
# quién responde sino QUIÉN PUDO ENTRAR: el request salió del pod `reports`, con otra
# ServiceAccount, y B lo aceptó.
```

`reports` tiene una ServiceAccount **distinta** de `ledger` y entra igual, porque **la
identidad es a nivel namespace**: el claim del wristband dice `namespace=payments`, y las
dos comparten namespace.

**Misma granularidad que Kong.** Si alguien en la sala pregunta "¿puedo distinguir servicio
por servicio?", la respuesta honesta es **no, no en esta iteración** — y el camino para
lograrlo es Ambient/SPIFFE, no este mecanismo (`FINDINGS.md` #1 y #3).

Lo que **sí** mejora sobre un token estático: el wristband **rota en cada request** y dura
300s.

```bash
oc logs -n istio-system -l gateway.networking.k8s.io/gateway-name=s2s --tail=50 \
  | grep -o 'wristband=[A-Za-z0-9_.-]\{20,\}' | tail -2
# -> dos tokens DISTINTOS
```

### Acto 5 — La perilla, en vivo, sin tocar la app

```bash
cd clusters/crc
for W in 0 50 100; do
  sed -i '' "s/^weight_remote = .*/weight_remote = $W/" terraform.tfvars
  tofu apply -auto-approve >/dev/null
  echo "── weight_remote=$W"
  for i in $(seq 1 10); do
    oc -n payments exec deploy/ledger -c app -- wget -qO- "http://$SPLIT/whoami" 2>/dev/null \
      | grep -o '"cluster":"[^"]*"'
  done | sort | uniq -c
done
cd ..
```

`0` → todo `crc-openshift`. `100` → todo `eks-kuadrant`. `50` → reparto binomial. **El
Deployment nunca se tocó.**

> En una demo con público, `-auto-approve` está bien. En el repo la disciplina es
> plan-primero.

### Acto 6 — El intruso de otro namespace ni abre el TCP

```bash
oc -n other exec deploy/intruso -c app -- \
  wget -T 8 -qO- "http://$SPLIT/whoami" 2>&1 | tail -1
# -> wget: download timed out
```

Timeout, no `401`: la NetworkPolicy corta a **L4**, el request no llega ni a Kuadrant. Dos
barreras independientes.

**Vale contar la historia:** esto **no funcionaba** hasta que se encontró el bug. El
`VirtualService` del split no tenía `exportTo`, y por default un `VirtualService` es visible
para **toda la malla** — así que `intruso` se llevaba la apiKey de `payments` inyectada y
llegaba a AWS con identidad ajena (`FINDINGS.md` #21). Se cerró con `exportTo: ["."]`.

Es un buen momento para el punto de fondo: con la credencial inyectada por config de
ruteo, **la identidad queda atada al host que llamás, no a quién sos**. `exportTo` la reata
al namespace por *convención de configuración*, no por criptografía. Con identidad
criptográfica (Ambient/SPIFFE) esa clase de bug **no existe**.

---

## Anexo — para el escéptico de la sala

```bash
HOST="$HOST" ./verify.sh
```

Las 10 aserciones, con tráfico real. A peso 100: **13 OK / 0 FAIL**.

Incluye las dos que no son de venta: la **4** (identidad namespace-level, misma
granularidad que Kong) y la **5** (el intruso rechazado, **reportando qué barrera** lo
paró en vez de afirmar un código que no siempre es el mismo).

**Cerrar el ciclo:** dejar la perilla en 0 y, si no hay demo al día siguiente, destruir el
EKS (~$140/mo). Ver [`README.md`](README.md).
