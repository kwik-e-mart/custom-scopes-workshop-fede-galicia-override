# PoC: identidad S2S entre OpenShift y EKS

> ⚠️ **Este README describe el sustrato (cómo levantar y destruir la infra), que sigue
> vigente.** Algunas secciones de más abajo —marcadas una por una— quedaron de la etapa
> anterior (OpenResty firmando en el egreso, split por `VirtualService`). Para el modelo
> actual y la demo: `GUIA-DEMO.md` y `GUIA-DEMO-DETALLE.md`.

Identidad service-to-service **cross-cluster**, sin malla en los pods de aplicación y sin ningún
pod de imagen propia en el camino del dato:

| Quién | Rol |
|---|---|
| **`AuthPolicy` sobre el Gateway de egreso** (uno por namespace) | acuña un JWT RS256 (wristband) con la clave privada de ese namespace |
| **`AuthPolicy` sobre el Gateway de ingreso** del destino | lo valida y rutea por header |

El mismo módulo de Terraform se aplica **dos veces**, una por cluster: OpenShift (CRC, emula
el on-prem) y EKS. Los dos corren en **rol dual** —emiten identidad para lo que sale y la
validan en lo que entra— así que el tráfico autenticado va en **ambas direcciones**.

**Alcance:** CRC ⇄ EKS. Qué prueba la PoC y qué está emulado —el sustrato de red es un stub
declarado— está en [`FIDELITY.md`](FIDELITY.md); **leerlo antes de sacar conclusiones**. El
análisis de la dirección inversa, con el contraste entre lo que se predijo y lo que pasó, en
[`BIDIRECTIONAL.md`](BIDIRECTIONAL.md).

**Hallazgos y smells** (33 entradas, con el camino post-PoC de cada uno):
[`FINDINGS.md`](FINDINGS.md). Empezá por el **#21**, que es un agujero de seguridad real
encontrado y cerrado durante la PoC.

**Diferencias entre los dos clusters:** [`CLUSTERS.md`](CLUSTERS.md).
**Guion de demo:** [`DEMO.md`](DEMO.md). **Registro de spikes:** [`SPIKES.md`](SPIKES.md).

---

## TL;DR

```bash
cd accounts/galicia/demo-kuadrant-s2s

./scripts/crc-up.sh      # paso 0: CRC listo (idempotente)
./scripts/up.sh          # levanta el resto (~20 min de cero, ~3 min si ya está arriba)

./demo.sh preflight      # los 2 clusters listos + JWKS cruzado
./demo.sh esc1           # el contrato completo, end-to-end
```

`verify.sh` y `scripts/split.sh` **ya no existen**: eran de la etapa anterior (aserciones
sobre el wristband y split por `VirtualService`). Los reemplaza `./demo.sh`, con un
subcomando por paso — ver `GUIA-DEMO.md`.

---

## Prerequisitos

- **CRC arriba**, contexto `crc-admin`. El on-prem de la PoC. Desde cero:

  ```bash
  ./scripts/crc-up.sh     # instala si falta, dimensiona la VM y arranca
  ```

  Dimensiona con **6 cpus / 16 GB / 80 GB**, que es lo medido sobre la instalación que
  corre la demo: con los 4 cpus del default de CRC los pods pedirían ~96% de lo asignable.
  Necesita un **pull secret de Red Hat** (personal, se baja de
  [console.redhat.com](https://console.redhat.com/openshift/create/local)) y ~24 GB de RAM
  física. Es idempotente: sobre un CRC ya corriendo verifica y no reinicia.
  - El gotcha de recargar `xt_REDIRECT`/`xt_owner`/`iptable_nat` tras un `crc stop`/`start`
    **ya no aplica**: eran para el `istio-init` que hacía la intercepción por iptables, y
    desde el pivote a OpenResty no hay sidecars (verificado: ningún pod tiene `istio-init`).
- **Credenciales AWS:** `aws sso login --sso-session galicia`. El token dura **1 hora**;
  si un `tofu` falla con `failed to refresh cached credentials`, es esto.
- **Credenciales del tailnet** en `infrastructure/tailscale/credentials.auto.tfvars`
  (gitignoreado; hay un `.example` al lado). Es el transporte entre los dos clusters.
- `tofu`, `kubectl`, `helm`, `jq`, `curl`.
- **`gomplate` NO hace falta acá.** Lo pide el módulo upstream
  `scope_definition_agent_association`, que este layer no usa.

`up.sh` chequea todo esto antes de tocar nada y aborta diciendo qué falta.

**Casi ningún layer toca entidades de nullplatform**, así que no necesitan `common.tfvars`
ni `-var-file`: cada uno trae su `terraform.tfvars` y Terraform lo auto-carga. La excepción
es `clusters/eks`, que crea la API key del agente in-cluster: ése sí declara el provider de
nullplatform y toma `nrn`/`np_api_key` de un `secrets.auto.tfvars` gitignoreado.

---

## Levantar

```bash
./scripts/crc-up.sh    # paso 0: CRC listo (idempotente)
./scripts/up.sh        # el resto del sustrato
```

Es **idempotente**: correrlo sobre una PoC ya levantada devuelve "No changes" en casi todo
y sirve para volver a un estado conocido.

**Aplica de corrido, sin frenar a confirmar cada plan.** Es una excepción deliberada a la
disciplina del repo, justificada porque este layer es descartable y no comparte state con
nada: **no es el patrón para los layers de verdad.**

### Qué hace, paso a paso

| # | Paso | Por qué existe |
|---|---|---|
| 0 | Pre-flight | Herramientas, credenciales AWS vigentes, CRC arriba, tailnet configurado. Falla acá o no falla en el medio. |
| 1 | `infrastructure/tailscale` | Auth keys, tags y la ACL del tailnet: el **transporte** entre los dos clusters. Emula la única propiedad de Direct Connect que hoy falta —que cualquiera de los dos lados inicie la conexión— y nada del mecanismo de identidad sabe que existe. |
| 2 | `infrastructure/aws` | El EKS throwaway (~15 min la primera vez). Después registra el contexto `kuadrant-eks`: no lo crea ningún layer, porque los providers de Terraform autentican por `exec` y nunca escriben un kubeconfig. |
| 3 | `pki` | Clave de firma y cert de servidor **por cluster**, más la CA que los firma. Sin cluster de por medio: es sólo material criptográfico. |
| 4 | `clusters/crc` | Istio (flavour OpenShift), Kuadrant, las apps, los dos Gateways y las dos AuthPolicies. |
| 5 | `clusters/eks` | Lo mismo del otro lado, con el flavour vanilla de Istio. **No hay orden obligatorio entre 4 y 5**: desde que cada emisor publica su propia clave pública, nada viaja de un cluster al otro por tfvars. |

**Por qué el ciclo del paso 6-7 y por qué no molesta.** Authorino sólo valida JWT por **OIDC
discovery**, así que la clave pública tiene que estar publicada en algún lado. La publica el
emisor, que es su dueño (`jwks_endpoint.tf`), y el validador la descubre resolviendo el
hostname del issuer. El ciclo extraer-y-reaplicar queda **contenido dentro de un solo
cluster**: en rol dual son dos ciclos independientes, no cuatro encadenados.

`fetch-jwks.sh` escribe `clusters/<cluster>/jwks.auto.tfvars`, que Terraform auto-carga.
Está **gitignoreado a propósito**: es material público, pero es estado derivado que tiene que
matchear la clave viva de Authorino. Commitearlo dejaría aplicar una copia vieja en silencio.

### Si algo falla

`up.sh` reintenta **una vez** cada apply antes de rendirse, porque hay dos carreras conocidas
y benignas que se resuelven solas al segundo intento:

- `resource [kuadrant.io/v1/RateLimitPolicy] isn't valid for cluster` — discovery de CRDs
  recién instalados por Helm (`FINDINGS.md` #14, gotcha #4 del repo).
- El token de pull de ECR en CRC dura **12 h**: vencido, un pod nuevo no arranca hasta un
  apply que lo refresque. Aparece siempre como 2 `ecr_pull` "will be updated".

Si falla dos veces, muestra las últimas 40 líneas del apply y corta diciendo en qué layer fue.

**CRC con mucho uptime:** si al crear cualquier pod aparece `Unauthorized` de Multus,
reciclar `kubectl -n openshift-multus delete pod --all` (`FINDINGS.md` #13).

---

## Probar

> ⚠️ **Sección de la etapa anterior.** `verify.sh` fue eliminado y sus aserciones eran sobre
> el wristband de Authorino. Hoy se prueba con **`./demo.sh`** (`preflight`, `esc1`, `esc2`,
> `esc3`, `barrido`, `aislamiento`, `estado`) — ver `GUIA-DEMO.md`. Lo de abajo queda como
> registro de qué cubría aquella verificación.

```bash
./verify.sh   # ELIMINADO
```

Sin argumentos ni variables de entorno: las sondas salen **desde adentro de los clusters**,
por el camino real, así que no dependen de la IP del laptop.

Son 15 aserciones — 1-10 de la ida (CRC→EKS), 11-12 transversales (enforcement por Gateway y
descubrimiento del issuer, en los **dos** clusters) y 13-15 de la vuelta (EKS→CRC). Corre a
cualquier peso del split: lee el peso **real** del `VirtualService` de cada cluster —no del
tfvars— y adapta lo que exige.

| Peso de los splits | Resultado | Qué se saltea |
|---|---|---|
| 0 (default del repo) | **13 OK / 0 FAIL** (medido) | 3, 4, 9, 10 y 13: no hay tráfico cross-cluster |
| 50 | las mismas 20 aserciones | nada; la 6 exige que **ambos** lados reciban tráfico (binomial, no exacto) |
| 100 | **20 OK / 0 FAIL** (medido) | nada |

**Correr como máximo una vez por minuto.** El rate limit del validador es 5/min a propósito
(es el smoke de la aserción 9) y las mediciones mandan más que eso. Si 3/4 fallan con
"presupuesto de rate limit quemado", esperá 60 s.

### Mover la perilla del split

> ⚠️ **Sección de la etapa anterior.** `scripts/split.sh` fue eliminado y el split ya no se
> hace con un `VirtualService`: hoy el peso vive en la instancia del service
> (`percent` de cada interception) y se mueve con **`./demo.sh barrido`**, que además mide.

```bash
./scripts/split.sh 50          # ELIMINADO
```

El valor va por `-var` y **no** se persiste: el estado default del repo es 0, así que un
`tofu apply` posterior sin flags devuelve la PoC al reposo en vez de dejarla en el peso de la
última demo.

### Dos resultados que engañan

**Un `200` sin credencial no siempre es un fallo de seguridad.** La `AuthPolicy` validadora
tiene `count` condicionado: mientras no exista, el Gateway responde 200 sin credencial. No es
un agujero, es que todavía no se instaló el enforcement — pero tampoco hay que asumir que
está puesto porque el layer aplicó sin error. `Accepted=True` **no alcanza**:

```bash
kubectl --context kuadrant-eks -n gateways \
  get authpolicy s2s-validator -o jsonpath='{.status.conditions}' | jq
```

Tiene que decir **`Enforced=True`**. Kuadrant no genera ningún enforcement si a la policy le
falta un `HTTPRoute` colgado del Gateway, y **no falla ruidosamente: no hace nada** (gotcha
#22 del repo, `FINDINGS.md` #2). La aserción 11 chequea esto en los dos clusters.

**Un `500` en el primer request cross-cluster no es un error.** La primera validación contra
un issuer recién levantado devuelve 500 —no 401— porque Authorino todavía está resolviendo su
JWKS por OIDC discovery (`FINDINGS.md` #31). El segundo request sale bien. Conviene un
request de calentamiento antes de mostrar la vuelta en vivo.

---

## Destruir

> ⚠️ **La infra está ARRIBA**, a pedido, para tener la demo lista: son **~$140/mo** mientras
> siga así. Es un layer **throwaway** — conviene destruirlo al cerrar una jornada con pausa
> larga.

Orden **inverso** al de creación: los layers de cluster primero, la infra al final.

```bash
cd accounts/galicia/demo-kuadrant-s2s
cd clusters/crc       && tofu plan -destroy && tofu destroy && cd ../..
cd clusters/eks       && tofu plan -destroy && tofu destroy && cd ../..
cd infrastructure/aws && tofu plan -destroy && tofu destroy && cd ../..
```

**`infrastructure/tailscale` y `pki` no se destruyen.** Los dos cuestan $0 y destruirlos sólo
agrega riesgo al rebuild:

- El layer de Tailscale **reescribe el policy file entero del tailnet** (el provider no
  mergea). Los `tagOwners` que ahí viven son de los que dependen los OAuth clients para poder
  emitir auth keys con sus propios tags — es el bootstrap que más costó armar.
- `pki` es sólo material criptográfico. Destruirlo significa claves y certs nuevos, o sea
  recert de los dos lados sin ninguna necesidad.

Los **dispositivos del tailnet sí desaparecen solos**: las auth keys son efímeras, así que los
nodos se dan de baja al desconectarse. Ojo con rearmar a los pocos minutos: si todavía figuran
registrados, el dispositivo nuevo toma el nombre con sufijo (`s2s-crc-jwks-1`) y los FQDN de
los tfvars quedan apuntando a uno muerto. Con horas de por medio no pasa.

**Acá sí va `plan -destroy` antes de cada `destroy`**, a diferencia del levantado: un destroy
no se deshace con un re-apply. Y conviene **no** filtrar la salida con `| tail`: el exit code
del pipe es el del filtro, así que un destroy fallido se lee como exitoso (`FINDINGS.md` #34).

### Si el destroy se cuelga en un Service

Los Services publicados en el overlay llevan `tailscale.com/finalizer`, y Terraform destruye el
operator **antes** que ellos: quedan en `Terminating` sin nadie que procese el finalizer. El
síntoma es un `Still destroying...` que no avanza y termina en `Error: Service (...) still
exists`. Se destraba sacando el finalizer —seguro, porque el controlador dueño ya no existe— y
reintentando:

```bash
kubectl get svc -A -o json | jq -r '.items[]
  | select((.metadata.finalizers // []) | length > 0)
  | "\(.metadata.namespace) \(.metadata.name)"' |
while read -r ns n; do
  kubectl -n "$ns" patch svc "$n" -p '{"metadata":{"finalizers":null}}' --type=merge
done
```

Es **intermitente**: depende del orden en que Terraform recorra recursos sin dependencia
declarada entre sí. Un teardown que salió limpio no garantiza el próximo.

### Si el destroy no avanza con los security groups o la VPC

GuardDuty se auto-provisiona un **VPC endpoint** (`guardduty-data`) dentro de la VPC del
cluster. No está en ningún state, pero sus ENIs usan los security groups del cluster y hacen
fallar el borrado con `DependencyViolation` — y como el provider reintenta, se ve como un
destroy que "no avanza" en vez de un error. Se destraba borrándolo a mano
(`FINDINGS.md` #35):

Son **dos** objetos, y aparecen uno después del otro: borrado el endpoint el destroy avanza y
se vuelve a trabar, ahora en el security group que GuardDuty también deja.

```bash
aws ec2 describe-vpc-endpoints  --region us-east-1 \
  --query 'VpcEndpoints[].{id:VpcEndpointId,svc:ServiceName}' --output table
aws ec2 delete-vpc-endpoints    --vpc-endpoint-ids <vpce-id> --region us-east-1

aws ec2 describe-security-groups --region us-east-1 --filters Name=vpc-id,Values=<vpc-id> \
  --query 'SecurityGroups[].{id:GroupId,name:GroupName}' --output table
aws ec2 delete-security-group    --group-id <sg-id> --region us-east-1
```

Verificar el retorno a $0:

```bash
aws eks list-clusters             --profile galicia-1 --region us-east-1 --query 'length(clusters)'
aws elbv2 describe-load-balancers --profile galicia-1 --region us-east-1 --query 'length(LoadBalancers)'
aws ec2 describe-instances        --profile galicia-1 --region us-east-1 \
  --filters Name=instance-state-name,Values=running --query 'length(Reservations)'
```

Todo en `0`. Los **ECR se preservan**: no los maneja este layer. El lado CRC no cuesta nada,
pero `crc stop` libera ~9 GB de RAM.
