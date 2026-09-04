# Prerequisitos de cluster

Dos cosas distintas viven acá:

| | qué es | alcance |
|---|---|---|
| `*.tf` | instala **Gateway API** y **Kuadrant** (con el CR `Kuadrant`, que levanta Authorino) | por cluster |
| `manifests/` | el **layer de plataforma** que el service da por hecho y **no crea**: el Gateway de ingreso contra el que cuelga sus `HTTPRoute`, su certificado, la clave de firma del wristband, la `AuthPolicy` del ingreso con su endpoint de JWKS, y la NetworkPolicy que hace que "cross-namespace" sea un agujero controlado y no el default | por cluster + por namespace |

Sin el CR `Kuadrant` las `AuthPolicy` quedan **aceptadas y nunca enforceadas**: los objetos se ven
en verde y el tráfico pasa sin credencial.

Los valores concretos (`gateways`, `s2s-ingress`, `kuadrant-system` como `KEYS_NAMESPACE`,
`<ns>-wristband-key`, el header `x-api-key`) son el **contrato con el service**: son los defaults del
`configuration:` de `workflows/istio/*.yaml`. Cambiar uno acá obliga a cambiarlo también allá.

Lo que el service **sí** crea y no hay que aplicar a mano: el `HTTPRoute` y la `AuthPolicy` de cada
aplicación expuesta, el par catch-all por dominio, y el `Secret` de la credencial de cada consumidor
en `KEYS_NAMESPACE` al linkear.

## Qué aplica cada archivo

| archivo | objeto | alcance | cuándo |
|---|---|---|---|
| `00-namespace-gateways.yaml` | `Namespace gateways` | cluster | siempre. El label `kubernetes.io/metadata.name` es lo que selecciona la NetworkPolicy |
| `10-gateway-tls.yaml` | `Secret s2s-gateway-tls` | cluster | siempre: es el cert de servidor del listener 443 |
| `20-ingress-gateway.yaml` | `Gateway s2s-ingress` | cluster | siempre |
| `30-jwks-endpoint.yaml` | `ConfigMap` + `Deployment` + `Service` del JWKS | cluster | sólo si el ingreso valida identidad (ver "El segundo salto") |
| `40-authpolicy-validator.yaml` | `AuthPolicy s2s-validator` | cluster | ídem |
| `50-wristband-signing-key.yaml` | `Secret <ns>-wristband-key` en `kuadrant-system` | por namespace | **siempre**, incluso si nadie valida el token |
| `60-networkpolicy.yaml` | `NetworkPolicy allow-intra-namespace` | por namespace | siempre |

`50-` es obligatorio aunque no haya validador: la `AuthPolicy` de cada ruta expuesta acuña un
wristband en `x-np-token`, y si el Secret de firma no está donde vive el `AuthConfig` el
`AuthConfig` no reconcilia, el `ext_authz` falla cerrado y se cae el camino de la app entera.

Si este cluster también corre el **s2s-traffic-migrator**, `00-` a `50-` son los mismos objetos:
se aplican **una sola vez**, no una vez por service.

## El segundo salto

Una `AuthPolicy` a nivel route **sobreescribe** la del Gateway (verificado sobre EKS el 2026-09-01):
una ruta de este service responde 200 con sólo `x-api-key`, sin wristband, aunque `s2s-ingress`
tenga la `s2s-validator` exigiéndolo. O sea: el primer salto lo gobierna la policy del service.

El segundo salto es distinto. El `backendRef` de la ruta vuelve a entrar por el Gateway
(`LOCAL_INGRESS_HOST`) y aterriza sobre la route del **scope**, que no tiene policy propia y por lo
tanto hereda `s2s-validator`. Ahí es donde el wristband que acuña este service hace falta de verdad,
y por eso `30-` y `40-` van si el cluster valida identidad en el ingreso. En un cluster sin
`s2s-validator` el segundo salto no valida nada y alcanza con `50-`.

## Placeholders

| token | qué es | valor de la PoC |
|---|---|---|
| `__APP_NAMESPACE__` | namespace de la aplicación que expone rutas | `payments` |
| `__INGRESS_CERT_PEM__` / `__INGRESS_KEY_PEM__` | cert y clave de servidor del Gateway de ingreso | emitidos por la CA propia del PoC |
| `__ALLOWED_SOURCE_CIDRS__` | CIDRs que pueden llegar al NLB, separados por coma | los CIDRs on-premise de Plaza y Centro |
| `__LOCAL_JWKS_NAME__` | nombre de los objetos del JWKS de este cluster | `s2s-eks-jwks` |
| `__APP_NAMESPACE_JWKS__` | el JWKS (una sola clave) de la pública de ese namespace | ver abajo |
| `__APP_NAMESPACE_SIGNING_KEY_PKCS1_PEM__` | la privada RSA 2048 en PKCS#1 | ver abajo |

## Generar el material de firma

Una clave por namespace.

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
   Authorino resuelve `signingKeyRefs` contra el namespace del `AuthConfig`.
2. **RSA 2048 en PKCS#1.** El verificador `jwt` de Authorino está fijado a RS256 y el firmador sólo
   parsea PKCS#1. Con PKCS#8 falla con `invalid signing key algorithm`, que culpa al algoritmo
   cuando el problema es el encoding.
3. **El `kid` es el nombre del Secret.** Authorino lo deriva de ahí, y `go-oidc` sólo prueba una
   clave del JWKS si el `kid` coincide.

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

Los dos archivos que llevan material criptográfico (`10-`, `50-`) tienen el PEM como placeholder de
una sola línea. Se completa pegando el PEM indentado dentro del bloque `|`, o se crea el mismo
objeto con el `kubectl create secret` equivalente, que es lo que se muestra acá.

Por cluster, una vez (y una sola vez si el cluster también corre el s2s-traffic-migrator):

```bash
kubectl apply -f manifests/00-namespace-gateways.yaml

kubectl -n gateways create secret tls s2s-gateway-tls \
  --cert=ingress.crt --key=ingress.key

kubectl apply -f manifests/20-ingress-gateway.yaml
kubectl -n gateways wait --for=condition=Programmed gateway/s2s-ingress --timeout=180s
```

El `Programmed=True` del Gateway es la puerta: hasta que el controller no le auto-provisiona su
Service y su Deployment de Envoy, lo que se aplique después no tiene dónde colgarse.

Por namespace:

```bash
NS=payments
JWKS=$(cat "$NS.jwks.json")

kubectl -n kuadrant-system create secret generic "$NS-wristband-key" \
  --from-file=key.pem="$NS.key"

sed "s/__APP_NAMESPACE__/$NS/g" manifests/60-networkpolicy.yaml | kubectl apply -f -
```

Y sólo si el ingreso de este cluster valida identidad:

```bash
sed -e "s/__APP_NAMESPACE__/$NS/g" \
    -e "s/__LOCAL_JWKS_NAME__/s2s-eks-jwks/g" \
    -e "s|__APP_NAMESPACE_JWKS__|$JWKS|" \
    manifests/30-jwks-endpoint.yaml | kubectl apply -f -

sed -e "s/__APP_NAMESPACE__/$NS/g" \
    -e "s/__LOCAL_JWKS_NAME__/s2s-eks-jwks/g" \
    manifests/40-authpolicy-validator.yaml | kubectl apply -f -
```

El JWKS entra por `sed` con delimitador `|` y no `/`: es base64url, que usa `-` y `_` pero nunca `/`.

Con más de un namespace, `30-` y `40-` **no se aplican una vez por namespace**: hay que sumarle una
entrada al `ConfigMap` y a los `items` del volumen, y una regla `local-<ns>` a la `AuthPolicy`.
Aplicar el archivo tal cual con otro `$NS` reemplaza el anterior y deja al primero sin JWKS ni regla.

El RBAC del agente es un template del propio service y se rendea aparte, una vez por namespace
target:

```bash
NAMESPACE=payments KEYS_NAMESPACE=kuadrant-system AGENT_SA=np-agent AGENT_NAMESPACE=nullplatform \
  gomplate -f ../../manifests/rbac.yaml.tpl | kubectl apply -f -
```

El `ClusterRole` de lectura de `httproutes` que trae ese template no es opcional: es lo que usa la
detección de colisiones `(dominio, path)` entre aplicaciones de distintos namespaces.

## Verificar

```bash
kubectl -n gateways get gateway s2s-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
kubectl -n gateways get authpolicy s2s-validator -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
kubectl -n kuadrant-system get secret payments-wristband-key -o jsonpath='{.data.key\.pem}' | base64 -d | head -1
```

`Accepted=True` **no** alcanza: la señal que importa es `Enforced=True`. Y las `HTTPRoute` de este
service reportan `ResolvedRefs=False (BackendNotFound)` **estando bien**: usan `backendRefs` de
`kind: Hostname`, una extensión de Istio que Gateway API no sabe resolver.
