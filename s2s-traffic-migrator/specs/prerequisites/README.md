# Prerequisitos de cluster

Dos cosas distintas viven acá:

| | qué es | alcance |
|---|---|---|
| `*.tf` | instala **Gateway API** y **Kuadrant** (con el CR `Kuadrant`, que levanta Authorino y el Limitador) | por cluster |
| `manifests/` | el **layer de plataforma** que el service da por hecho y **no crea**: el Gateway de ingreso, su certificado, la `AuthPolicy` que valida el token, el endpoint de JWKS, las claves de firma, la CA del peer y la NetworkPolicy | por cluster + por namespace |

Sin el CR `Kuadrant` las `AuthPolicy` quedan **aceptadas y nunca enforceadas**: los objetos se ven
en verde y el tráfico pasa sin validar. Sin lo de `manifests/` el service reconcilia, aplica sus
objetos y el tráfico que cruza muere con un 401 o un 503 que no señalan a ningún objeto en rojo.

Los valores concretos (`gateways`, `s2s-ingress`, `s2s-remote-ca`, `s2s-validator`, el header
`x-np-token`, el puerto 8080, y `<ns>-wristband-key` o `s2s-vault-token` según la estrategia) son el
**contrato con el service**: son los defaults del `configuration:` de `workflows/openshift/*.yaml` y
de lo que emiten sus templates. Cambiar uno acá obliga a cambiarlo también allá.

**Qué archivos de `manifests/` aplican depende de la estrategia de firma del service**
(`S2S_TRAFFIC_MIGRATOR_SIGNING_STRATEGY`, default `spiffe`). Ver
[Qué aplicar según la estrategia de firma](#qué-aplicar-según-la-estrategia-de-firma).

## Qué aplica cada archivo

| archivo | objeto | alcance | cuándo |
|---|---|---|---|
| `00-namespace-gateways.yaml` | `Namespace gateways` | cluster | siempre. El label `kubernetes.io/metadata.name` es lo que selecciona la NetworkPolicy |
| `10-gateway-tls.yaml` | `Secret s2s-gateway-tls` | cluster | siempre: es el cert de servidor del listener 443 |
| `20-ingress-gateway.yaml` | `Gateway s2s-ingress` | cluster | siempre |
| `30-jwks-endpoint.yaml` | `ConfigMap` + `Deployment` + `Service` del JWKS | cluster | **sólo `cluster-keys`** |
| `35-peer-jwks-service.yaml` | `Service` `ExternalName` al JWKS del cluster opuesto | cluster | **sólo `cluster-keys`**, y sólo con tráfico cruzado: es lo que hace que la `jwksUrl` del peer resuelva desde este cluster |
| `40-authpolicy-validator.yaml` | `AuthPolicy s2s-validator` | cluster | **sólo `cluster-keys`** |
| `45-authpolicy-validator-spiffe.yaml` | `AuthPolicy s2s-validator` | cluster | **sólo `spiffe`**. Mismo nombre de objeto que `40-`: se aplica uno o el otro, nunca los dos |
| `50-wristband-signing-key.yaml` | `Secret <ns>-wristband-key` en `kuadrant-system` | por namespace emisor | **sólo `cluster-keys`** |
| `55-vault-login-cronjob.yaml` | `Secret` del `client_token` + `Role` + `RoleBinding` + `CronJob` de login a Vault | cluster | **sólo `spiffe`** |
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
| `__NETWORKING_VAULT_ADDR__` | `https://host[:puerto]` del Vault que mintea (sólo `spiffe`) | el HCP Vault de noprod, puerto `8200` |
| `__NETWORKING_VAULT_NAMESPACE__` | namespace de Vault Enterprise/HCP (sólo `spiffe`) | `admin/spiffe` |
| `__NETWORKING_VAULT_SPIFFE_MOUNT__` | path del mount del secrets engine `spiffe` | `spiffe` |
| `__NETWORKING_VAULT_TRUST_DOMAIN__` | trust domain SPIFFE, la autoridad del `sub` | `s2s.bancogalicia.com.ar` |
| `__NETWORKING_VAULT_AUTH_MOUNT__` | mount del método de login del cluster | `auth/jwt` en EKS, `auth/jwt-ocp` en OpenShift |
| `__NETWORKING_VAULT_AUTH_ROLE__` | role de ese mount, bindeado a la SA de Authorino | `s2s-authorino-egress` |
| `__NETWORKING_VAULT_TOKEN_SECRET__` | Secret de `kuadrant-system` donde el CronJob deja el `client_token` | `s2s-vault-token` |
| `__LOCAL_CLUSTER_LABEL__` / `__PEER_CLUSTER_LABEL__` | el `CLUSTER_LABEL` de **este** cluster y del **opuesto**, tal como aparecen en el `sub` | `aws-us-east-1` / `openshift-crc` |
| `__VAULT_LOGIN_IMAGE__` | imagen del CronJob de login. Necesita `curl`, `jq` y `kubectl` | una imagen interna pineada por digest |

`__LOCAL_JWKS_NAME__` y `__PEER_JWKS_NAME__` **tienen que ser distintos**: cada cluster resuelve el
endpoint del peer en su propio `kuadrant-system`, así que un nombre compartido colisiona con el
endpoint propio.

## Qué aplicar según la estrategia de firma

El service elige con `S2S_TRAFFIC_MIGRATOR_SIGNING_STRATEGY` (default `spiffe`). El cluster tiene
que estar en la MISMA que las instancias que corren en él, y los dos clusters tienen que estar en la
misma entre sí: el que emite y el que valida no pueden diferir.

| | `spiffe` (default) | `cluster-keys` |
|---|---|---|
| por cluster | `55-` | `30-`, `35-` |
| por namespace emisor | `45-` (una vez por cluster, con un par de predicados por namespace) | `40-`, `50-` |
| material de firma que hay que generar | ninguno | una clave RSA por namespace |
| config fuera del cluster | mount `spiffe` en Vault + un role por namespace | ninguna |

`40-` y `45-` crean el **mismo objeto** (`AuthPolicy s2s-validator` en `gateways`), que es el que el
service espera ver `Enforced`. Se aplica uno o el otro. Aplicar el segundo encima del primero
funciona como cambio de estrategia, pero deja el tráfico en 401 hasta que las instancias
reconcilien con la estrategia nueva.

**El orden importa**: primero el cluster, después las instancias. Al revés, lo que cruza muere con
un 401 en el ingreso del peer.

### Lo que hay que configurar en Vault (sólo `spiffe`)

No lo hace ninguno de estos archivos ni el service: el service no tiene credenciales de Vault. Lo
provisiona quien administre el mount.

Por cluster:

```
sys/auth/<mount>                    # auth/jwt en EKS, auth/jwt-ocp en OpenShift
  oidc_discovery_url                # el issuer del cluster; en OpenShift el issuer es interno,
                                    # así que va con jwt_validation_pubkeys estáticas

auth/<mount>/role/s2s-authorino-egress
  bound_subject: system:serviceaccount:kuadrant-system:authorino-authorino
  token_policies: s2s-spiffe-mint-only

policy s2s-spiffe-mint-only
  path "spiffe/role/<cluster-label>-*/mintjwt" { capabilities = ["update"] }
```

El `*` de la policy es a propósito: acota un cluster comprometido a los namespaces de **ese**
cluster, y evita un token por namespace.

Por namespace emisor:

```
spiffe/role/<cluster-label>-<namespace>
  template: {"sub": "spiffe://<trust-domain>/<cluster-label>/<namespace>/s2s-egress"}
  ttl:      el TTL del JWT-SVID
```

El `template` tiene que ser un objeto JSON completo (`{"sub": "..."}`), no el fragmento
`"sub": "..."`. Y `spiffe/config` necesita el `jwt_issuer_url` con los **tres** componentes —host,
puerto y el path completo del mount— o el `jwks_uri` que publica el discovery no resuelve.

**El secrets engine `spiffe` es exclusivo de Vault Enterprise.** No está en la edición community.

### Dos cosas que rompen en silencio con `spiffe`

1. **`evaluatorCacheSize` del CR `Authorino`.** El default es 1 (MB), con un tope por entrada de
   1/1024 de eso (~1 KB), y el JWT-SVID pesa ~1 KB. Con el default, cada escritura al cache falla
   **sin loguear nada** salvo en `LogLevel: debug`, y la `AuthPolicy` mintea contra Vault en cada
   request: latencia completa por request y riesgo de pegarle al timeout de 200 ms del `ext_authz`
   de Kuadrant. Subirlo a `10` resuelve con margen. El chart de `kuadrant-operator` no lo expone,
   así que va como patch al CR:

   ```bash
   kubectl -n kuadrant-system patch authorino authorino --type=merge -p '{"spec":{"evaluatorCacheSize":10}}'
   kubectl -n kuadrant-system rollout status deployment authorino
   ```

   El `kuadrant-operator` no lo revierte: cuando el CR ya existe, su reconcile aplica por
   server-side apply un patch que sólo nombra `spec.oidcServer.tls`, `spec.listener.tls` y
   `spec.tracing`. Por eso el patch es sobre esos tres campos y no un `apply` del spec entero: un
   `apply` que reclame `listener.tls`/`oidcServer.tls` puede hacer que el operador ceda ownership de
   esos campos y deje de reconciliarlos.

2. **El `Secret` del `client_token` se rota cada 30 minutos.** El `55-` lo crea vacío a propósito:
   el `Role` queda con `get`/`update`/`patch` sobre ese nombre y **sin** `create`, porque `create` no
   se puede acotar por `resourceNames` y daría permiso sobre cualquier `Secret` del namespace. Hasta
   la primera corrida del CronJob el token está vacío y el mint da 403; para no esperar al horario:

   ```bash
   kubectl -n kuadrant-system create job --from=cronjob/s2s-vault-login s2s-vault-login-manual
   kubectl -n kuadrant-system logs job/s2s-vault-login-manual
   ```

   Si aparece un 403 con `no such key: data` en los logs de Authorino con el `Secret` poblado y
   Vault respondiendo bien a mano, es estado stale del pod de Authorino leyendo el
   `sharedSecretRef`: `kubectl -n kuadrant-system rollout restart deployment authorino`.

## Generar el material de firma (sólo `cluster-keys`)

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
```

El `Programmed=True` del Gateway es la puerta: hasta que el controller no le auto-provisiona su
Service y su Deployment de Envoy, lo que se aplique después no tiene dónde colgarse.

Y en cualquiera de las dos estrategias, por namespace emisor:

```bash
NS=payments
kubectl -n "$NS" create secret generic s2s-remote-ca --from-file=ca.crt=peer-ca.crt
sed "s/__APP_NAMESPACE__/$NS/g" manifests/70-networkpolicy.yaml | kubectl apply -f -
```

### Con `spiffe` (default)

Por cluster, una vez, con el mount y los roles de Vault ya creados:

```bash
sed -e "s|__NETWORKING_VAULT_ADDR__|https://vault-noprod.example.cloud:8200|g" \
    -e "s|__NETWORKING_VAULT_NAMESPACE__|admin/spiffe|g" \
    -e "s|__NETWORKING_VAULT_AUTH_MOUNT__|auth/jwt|g" \
    -e "s/__NETWORKING_VAULT_AUTH_ROLE__/s2s-authorino-egress/g" \
    -e "s/__NETWORKING_VAULT_TOKEN_SECRET__/s2s-vault-token/g" \
    -e "s|__VAULT_LOGIN_IMAGE__|registry.interna/s2s-vault-login@sha256:...|g" \
    manifests/55-vault-login-cronjob.yaml | kubectl apply -f -

kubectl -n kuadrant-system create job --from=cronjob/s2s-vault-login s2s-vault-login-manual
kubectl -n kuadrant-system logs job/s2s-vault-login-manual

kubectl -n kuadrant-system patch authorino authorino --type=merge -p '{"spec":{"evaluatorCacheSize":10}}'
kubectl -n kuadrant-system rollout status deployment authorino

sed -e "s/__APP_NAMESPACE__/payments/g" \
    -e "s|__NETWORKING_VAULT_ADDR__|https://vault-noprod.example.cloud:8200|g" \
    -e "s|__NETWORKING_VAULT_SPIFFE_MOUNT__|spiffe|g" \
    -e "s/__NETWORKING_VAULT_TRUST_DOMAIN__/s2s.bancogalicia.com.ar/g" \
    -e "s/__LOCAL_CLUSTER_LABEL__/aws-us-east-1/g" \
    -e "s/__PEER_CLUSTER_LABEL__/openshift-crc/g" \
    manifests/45-authpolicy-validator-spiffe.yaml | kubectl apply -f -
```

`55-` no lleva `__APP_NAMESPACE__`: es uno por cluster, no uno por namespace. El `45-` sí, y con más
de un namespace emisor **no se aplica una vez por namespace**: hay que sumarle un par de predicados
`sub` (el local y el del peer) al `any` de `allowed-namespaces`. Aplicar el archivo tal cual con otro
`$NS` reemplaza el anterior y deja al primero sin regla.

### Con `cluster-keys`

Por cluster, una vez:

```bash
sed -e "s/__PEER_JWKS_NAME__/s2s-crc-jwks/" \
    -e "s/__PEER_JWKS_EXTERNAL_HOST__/ts-s2s-crc-jwks-n4dm2.tailscale.svc.cluster.local/" \
    manifests/35-peer-jwks-service.yaml | kubectl apply -f -
```

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
```

El JWKS entra por `sed` con delimitador `|` y no `/`: es base64url, que usa `-` y `_` pero nunca `/`.

Con más de un namespace emisor, `30-` y `40-` **no se aplican una vez por namespace**: hay que
sumarle una entrada al `ConfigMap` y a los `items` del volumen, y un par de reglas
`local-<ns>` / `peer-<ns>` a la `AuthPolicy`. Aplicar el archivo tal cual con otro `$NS` reemplaza el
anterior y deja al primero sin JWKS ni regla. Lo mismo con el `value` de `allowed-namespaces`: es la
lista de quién puede entrar, no una plantilla por namespace.

El RBAC del agente se rendea aparte, **una vez por cluster**. Como el `s2s-traffic-migrator` y el
`api-manager-publisher` corren en el mismo pod y comparten ServiceAccount, el RBAC es uno solo y
combinado, en `rbac/` de la raiz del repo:

```bash
KEYS_NAMESPACE=kuadrant-system \
AGENT_SA=np-agent AGENT_NAMESPACE=nullplatform-tools \
  gomplate -f ../../../rbac/np-agent-rbac.yaml.tpl | kubectl apply -f -
```

No lleva `NAMESPACE`: el namespace de cada app sale del provider de la instancia y no se conoce al
instalar, asi que los permisos sobre los objetos de red van en un `ClusterRole`. Lo unico namespaced
es el `Role` de `KEYS_NAMESPACE`, que es un namespace fijo del cluster.

Si el cluster-wide no pasa la aprobación de seguridad, el template trae comentada una alternativa
con una lista explícita de namespaces (`TARGET_NAMESPACES`): mismo `ClusterRole`, pero bindeado con
un `RoleBinding` por namespace en vez de un `ClusterRoleBinding`. Las instrucciones para activarla
están en el propio archivo. Ojo con dos cosas: la lista tiene que incluir `gateways`, y onboardear
una app nueva pasa a requerir un `RoleBinding` más.

Con el apply delegado a un reconciler de GitOps va `rbac/np-agent-rbac-gitops.yaml.tpl` en su lugar:
solo lectura, salvo el Secret de la api key en `KEYS_NAMESPACE`, que se emite por link y no puede
publicarse en un repo.


## Verificar

```bash
kubectl -n gateways get gateway s2s-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
kubectl -n gateways get authpolicy s2s-validator -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
kubectl -n kuadrant-system get authconfig -o "custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status"
kubectl -n kuadrant-system run jwks-probe --rm -i --image=curlimages/curl --restart=Never -- \
  -s http://__LOCAL_JWKS_NAME__.kuadrant-system.svc.cluster.local:8080/payments/jwks.json
```

Con `spiffe`, además:

```bash
kubectl -n kuadrant-system get secret s2s-vault-token \
  -o jsonpath='{.data.client_token}' | wc -c
kubectl -n kuadrant-system get cronjob s2s-vault-login
kubectl -n kuadrant-system get authorino authorino -o jsonpath='{.spec.evaluatorCacheSize}{"\n"}'
kubectl -n kuadrant-system run jwks-probe --rm -i --image=curlimages/curl --restart=Never -- \
  -s __NETWORKING_VAULT_ADDR__/v1/__NETWORKING_VAULT_SPIFFE_MOUNT__/.well-known/keys
```

El primero cuenta bytes en vez de imprimir el token: es una credencial viva, no algo para dejar en
el scrollback de una terminal. Un `1` significa que el CronJob todavía no corrió.

Y que el validador quede `Enforced` con un token válido pasando **no prueba que rechace inválidos**.
La prueba negativa es aparte: cambiar temporalmente el `template` del `spiffe/role/...` a un `sub`
no autorizado, confirmar el 403, y revertirlo.

`Accepted=True` **no** alcanza: la señal que importa es `Enforced=True`. Y una `AuthPolicy` sobre un
Gateway sin ningún `HTTPRoute` colgado **no enforcea nada** — es el estado normal mientras no haya
ninguna intercepción declarada, porque las routes las emite el service.
