# Prerequisitos de cluster

Dos cosas distintas viven acá:

| | qué es | alcance |
|---|---|---|
| `*.tf` | instala **Gateway API** y **Kuadrant** (con el CR `Kuadrant`, que levanta Authorino y el Limitador) | por cluster |
| `manifests/` | el **layer de plataforma** que el service da por hecho y **no crea**: el Gateway de ingreso, su certificado, la `AuthPolicy` que valida el token, el endpoint de JWKS, las claves de firma, la CA del peer y la NetworkPolicy | por cluster + por namespace |

Sin el CR `Kuadrant` las `AuthPolicy` quedan **aceptadas y nunca enforceadas**: los objetos se ven
en verde y el tráfico pasa sin validar. Sin lo de `manifests/` el service reconcilia, aplica sus
objetos y el tráfico que cruza muere con un 401 o un 503 que no señalan a ningún objeto en rojo.

Los valores concretos (`gateways`, `s2s-ingress`, `s2s-remote-ca`, `<ns>-wristband-key`, el header
`x-np-token`, el puerto 8080) son el **contrato con el service**: son los defaults del
`configuration:` de `workflows/openshift/*.yaml` y de lo que emiten sus templates. Cambiar uno acá
obliga a cambiarlo también allá.

## Qué aplica cada archivo

| archivo | objeto | alcance | cuándo |
|---|---|---|---|
| `00-namespace-gateways.yaml` | `Namespace gateways` | cluster | siempre. El label `kubernetes.io/metadata.name` es lo que selecciona la NetworkPolicy |
| `10-gateway-tls.yaml` | `Secret s2s-gateway-tls` | cluster | siempre: es el cert de servidor del listener 443 |
| `20-ingress-gateway.yaml` | `Gateway s2s-ingress` | cluster | siempre |
| `30-jwks-endpoint.yaml` | `ConfigMap` + `Deployment` + `Service` del JWKS | cluster | siempre que el ingreso valide identidad |
| `35-peer-jwks-service.yaml` | `Service` `ExternalName` al JWKS del cluster opuesto | cluster | sólo con tráfico cruzado: es lo que hace que la `jwksUrl` del peer resuelva desde este cluster |
| `40-authpolicy-validator.yaml` | `AuthPolicy s2s-validator` | cluster | siempre que el ingreso valide identidad |
| `50-wristband-signing-key.yaml` | `Secret <ns>-wristband-key` en `kuadrant-system` | por namespace emisor | siempre |
| `60-peer-ca.yaml` | `Secret s2s-remote-ca` en el namespace de la app | por namespace emisor | siempre que haya tráfico cruzado |
| `70-networkpolicy.yaml` | `NetworkPolicy allow-intra-namespace` | por namespace | siempre |

## Placeholders

| token | qué es | valor de la PoC |
|---|---|---|
| `__APP_NAMESPACE__` | namespace de la aplicación que emite identidad | `payments` |
| `__INGRESS_CERT_PEM__` / `__INGRESS_KEY_PEM__` | cert y clave de servidor del Gateway de ingreso | emitidos por la CA propia del PoC |
| `__ALLOWED_SOURCE_CIDRS__` | CIDRs que pueden llegar al NLB, separados por coma | los CIDRs on-premise de Plaza y Centro |
| `__LOCAL_JWKS_NAME__` | nombre de los objetos del JWKS de **este** cluster | `s2s-eks-jwks` / `s2s-crc-jwks` |
| `__PEER_JWKS_NAME__` | ídem del cluster **opuesto**, resuelto en el `kuadrant-system` de este | `s2s-crc-jwks` / `s2s-eks-jwks` |
| `__PEER_JWKS_EXTERNAL_HOST__` | host real del JWKS del peer, al que apunta el `ExternalName` | `ts-s2s-crc-jwks-n4dm2.tailscale.svc.cluster.local` (proxy del overlay) |
| `__APP_NAMESPACE_JWKS__` | el JWKS (una sola clave) de la pública de ese namespace | ver abajo |
| `__APP_NAMESPACE_SIGNING_KEY_PKCS1_PEM__` | la privada RSA 2048 en PKCS#1 | ver abajo |
| `__PEER_CA_PEM__` | CA con la que se valida el cert del ingreso del peer | la CA propia del PoC |

`__LOCAL_JWKS_NAME__` y `__PEER_JWKS_NAME__` **tienen que ser distintos**: cada cluster resuelve el
endpoint del peer en su propio `kuadrant-system`, así que un nombre compartido colisiona con el
endpoint propio.

## Generar el material de firma

Una clave por namespace emisor. La privada no cruza nunca al otro cluster: lo que cruza es el JWKS
de la pública.

```bash
NS=payments

openssl genrsa -traditional -out "$NS.key" 2048
head -1 "$NS.key"   # tiene que decir -----BEGIN RSA PRIVATE KEY-----
openssl rsa -in "$NS.key" -pubout -out "$NS.pub"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
n=$(openssl rsa -pubin -in "$NS.pub" -noout -modulus | sed 's/^Modulus=//' | xxd -r -p | b64url)
openssl rsa -pubin -in "$NS.pub" -text -noout | awk '/Exponent:/{print $2}'   # 65537 -> e=AQAB
jq -cn --arg n "$n" --arg kid "$NS-wristband-key" \
  '{keys:[{kty:"RSA",use:"sig",alg:"RS256",kid:$kid,n:$n,e:"AQAB"}]}'
```

Tres cosas que rompen en silencio si se hacen distinto:

1. **La privada va en `kuadrant-system`, no en el namespace de la app.** Kuadrant traduce toda
   `AuthPolicy` a un `AuthConfig` en `kuadrant-system` sin importar el namespace de la policy, y
   Authorino resuelve `signingKeyRefs` contra el namespace del `AuthConfig`. Mal ubicada, el
   `AuthConfig` no reconcilia, el `ext_authz` falla cerrado y se cae el camino de la app entera.
2. **RSA 2048 en PKCS#1.** El verificador `jwt` de Authorino está fijado a RS256 y el firmador sólo
   parsea PKCS#1. Con EC el destino rechaza el 100% de los tokens con un 401 idéntico a "falta el
   token"; con PKCS#8 el firmador falla con `invalid signing key algorithm`, que culpa al algoritmo
   cuando el problema es el encoding.
3. **El `kid` es el nombre del Secret.** Authorino lo deriva de ahí, y `go-oidc` sólo prueba una
   clave del JWKS si el `kid` coincide. Un typo se manifiesta como 401 en el destino, con todos los
   objetos en verde.

## Lo que no está ni en `*.tf` ni en `manifests/`

**Istio.** Todo esto cuelga de un `GatewayClass istio` con su controller aceptado
(`istio.io/gateway-controller`) y de un `istiod` corriendo. No lo instala este layer: en la PoC lo
pone el módulo `infrastructure/commons/istio` de `tofu-modules`, y en el cluster del cliente lo pone
quien sea dueño de la malla. Chequeo:

```bash
kubectl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}{"\n"}'
kubectl -n istio-system get deploy istiod
```

## Aplicar

Los tres archivos que llevan material criptográfico (`10-`, `50-`, `60-`) tienen el PEM como
placeholder de una sola línea. Se completa pegando el PEM indentado dentro del bloque `|`, o se crea
el mismo objeto con el `kubectl create secret` equivalente, que es lo que se muestra acá.

Por cluster, una vez:

```bash
kubectl apply -f manifests/00-namespace-gateways.yaml

kubectl -n gateways create secret tls s2s-gateway-tls \
  --cert=ingress.crt --key=ingress.key

kubectl apply -f manifests/20-ingress-gateway.yaml
kubectl -n gateways wait --for=condition=Programmed gateway/s2s-ingress --timeout=180s

sed -e "s/__PEER_JWKS_NAME__/s2s-crc-jwks/" \
    -e "s/__PEER_JWKS_EXTERNAL_HOST__/ts-s2s-crc-jwks-n4dm2.tailscale.svc.cluster.local/" \
    manifests/35-peer-jwks-service.yaml | kubectl apply -f -
```

El `Programmed=True` del Gateway es la puerta: hasta que el controller no le auto-provisiona su
Service y su Deployment de Envoy, lo que se aplique después no tiene dónde colgarse.

Por namespace emisor:

```bash
NS=payments
JWKS=$(cat "$NS.jwks.json")

sed -e "s/__APP_NAMESPACE__/$NS/g" \
    -e "s/__LOCAL_JWKS_NAME__/s2s-eks-jwks/g" \
    -e "s|__APP_NAMESPACE_JWKS__|$JWKS|" \
    manifests/30-jwks-endpoint.yaml | kubectl apply -f -

sed -e "s/__APP_NAMESPACE__/$NS/g" \
    -e "s/__LOCAL_JWKS_NAME__/s2s-eks-jwks/g" \
    -e "s/__PEER_JWKS_NAME__/s2s-crc-jwks/g" \
    manifests/40-authpolicy-validator.yaml | kubectl apply -f -

kubectl -n kuadrant-system create secret generic "$NS-wristband-key" \
  --from-file=key.pem="$NS.key"

kubectl -n "$NS" create secret generic s2s-remote-ca --from-file=ca.crt=peer-ca.crt

sed "s/__APP_NAMESPACE__/$NS/g" manifests/70-networkpolicy.yaml | kubectl apply -f -
```

El JWKS entra por `sed` con delimitador `|` y no `/`: es base64url, que usa `-` y `_` pero nunca `/`.

Con más de un namespace emisor, `30-` y `40-` **no se aplican una vez por namespace**: hay que
sumarle una entrada al `ConfigMap` y a los `items` del volumen, y un par de reglas
`local-<ns>` / `peer-<ns>` a la `AuthPolicy`. Aplicar el archivo tal cual con otro `$NS` reemplaza el
anterior y deja al primero sin JWKS ni regla. Lo mismo con el `value` de `allowed-namespaces`: es la
lista de quién puede entrar, no una plantilla por namespace.

El RBAC del agente es un template del propio service y se rendea aparte, una vez por namespace
target:

```bash
NAMESPACE=payments GATEWAY_NAMESPACE=gateways AGENT_SA=np-agent AGENT_NAMESPACE=nullplatform \
  gomplate -f ../../manifests/rbac.yaml.tpl | kubectl apply -f -
```

## Verificar

```bash
kubectl -n gateways get gateway s2s-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
kubectl -n gateways get authpolicy s2s-validator -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
kubectl -n kuadrant-system get authconfig -o "custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status"
kubectl -n kuadrant-system run jwks-probe --rm -i --image=curlimages/curl --restart=Never -- \
  -s http://__LOCAL_JWKS_NAME__.kuadrant-system.svc.cluster.local:8080/payments/jwks.json
```

`Accepted=True` **no** alcanza: la señal que importa es `Enforced=True`. Y una `AuthPolicy` sobre un
Gateway sin ningún `HTTPRoute` colgado **no enforcea nada** — es el estado normal mientras no haya
ninguna intercepción declarada, porque las routes las emite el service.
