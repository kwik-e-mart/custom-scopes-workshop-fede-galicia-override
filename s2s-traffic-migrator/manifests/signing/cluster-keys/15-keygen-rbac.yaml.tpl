apiVersion: v1
kind: ServiceAccount
metadata:
  name: wristband-rotator
  namespace: {{ .namespace }}
  labels:
    nullplatform: "true"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: wristband-rotator
  namespace: {{ .namespace }}
  labels:
    nullplatform: "true"
rules:
  - apiGroups: ["kuadrant.io"]
    resources: ["authpolicies"]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: wristband-rotator
  namespace: {{ .namespace }}
  labels:
    nullplatform: "true"
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: wristband-rotator }
subjects:
  - { kind: ServiceAccount, name: wristband-rotator, namespace: {{ .namespace }} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: wristband-rotator-{{ .namespace }}
  namespace: {{ .keys_namespace }}
  labels:
    nullplatform: "true"
rules:
  - apiGroups: ["external-secrets.io"]
    resources: ["externalsecrets"]
    verbs: ["get", "list", "create", "delete"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: wristband-rotator-{{ .namespace }}
  namespace: {{ .keys_namespace }}
  labels:
    nullplatform: "true"
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: wristband-rotator-{{ .namespace }} }
subjects:
  - { kind: ServiceAccount, name: wristband-rotator, namespace: {{ .namespace }} }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: wristband-rotate-scripts
  namespace: {{ .namespace }}
  labels:
    nullplatform: "true"
data:
  vault-lib.sh: |
    #!/usr/bin/env bash
    # Cliente de Vault sobre su HTTP API. No se usa el CLI a propósito: HashiCorp relicenció Vault
    # bajo BUSL y Alpine lo sacó de sus repos, así que `apk add vault` no existe y nunca va a
    # existir. curl y jq sí están, y la API es estable.

    VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-kv}"

    vault_curl() {  # <metodo> <ruta sin /v1> [cuerpo json]
      local metodo="$1" ruta="$2" cuerpo="${3:-}"
      local -a args=(--silent --show-error --fail-with-body -X "$metodo")
      if [ -n "${VAULT_TOKEN:-}" ]; then args+=(-H "X-Vault-Token: ${VAULT_TOKEN}"); fi
      if [ -n "${VAULT_NAMESPACE:-}" ]; then args+=(-H "X-Vault-Namespace: ${VAULT_NAMESPACE}"); fi
      if [ -n "$cuerpo" ]; then args+=(-H "Content-Type: application/json" --data-binary "$cuerpo"); fi
      curl "${args[@]}" "${VAULT_API}/${ruta}"
    }

    vault_login() {
      : "${VAULT_ADDR:?falta VAULT_ADDR: sin eso el keygen no puede hablar con Vault}"
      VAULT_API="${VAULT_ADDR%/}/v1"
      local respuesta
      if ! respuesta=$(vault_curl POST auth/approle/login \
          "$(jq -nc --arg r "${VAULT_ROLE_ID}" --arg s "$(cat "${SECRET_ID_FILE}")" \
              '{role_id:$r, secret_id:$s}')"); then
        echo "login a Vault (${VAULT_API}) fallido: ${respuesta}" >&2
        return 1
      fi
      VAULT_TOKEN=$(printf '%s' "$respuesta" | jq -r '.auth.client_token // empty')
      export VAULT_TOKEN
      if [ -z "${VAULT_TOKEN}" ]; then
        echo "Vault no devolvió client_token en el login de AppRole" >&2
        return 1
      fi
    }

    # KV v1 y v2 no comparten ni la ruta ni la forma de la respuesta, y elegir mal se manifiesta
    # como un 404 que parece "no existe la clave". Se consulta una vez y se cachea.
    vault_kv_version() {
      if [ -z "${VAULT_KV_VERSION:-}" ]; then
        VAULT_KV_VERSION=$(vault_curl GET "sys/internal/ui/mounts/${VAULT_KV_MOUNT}" \
          | jq -r '.data.options.version // "1"')
        export VAULT_KV_VERSION
      fi
      printf '%s' "${VAULT_KV_VERSION}"
    }

    vault_kv_path() {  # <ruta relativa al mount>
      if [ "$(vault_kv_version)" = "2" ]; then
        printf '%s/data/%s' "${VAULT_KV_MOUNT}" "$1"
      else
        printf '%s/%s' "${VAULT_KV_MOUNT}" "$1"
      fi
    }

    vault_kv_get_field() {  # <ruta> <campo>
      local filtro=".data.data"
      if [ "$(vault_kv_version)" != "2" ]; then filtro=".data"; fi
      vault_curl GET "$(vault_kv_path "$1")" \
        | jq -er --arg campo "$2" "${filtro}[\$campo] // empty"
    }

    vault_kv_exists() {  # <ruta>
      vault_curl GET "$(vault_kv_path "$1")" >/dev/null 2>&1
    }

    vault_kv_put_file() {  # <ruta> <campo> <archivo>
      local cuerpo
      cuerpo=$(jq -nc --arg k "$2" --rawfile v "$3" '{($k): $v}')
      if [ "$(vault_kv_version)" = "2" ]; then
        cuerpo=$(printf '%s' "$cuerpo" | jq -c '{data: .}')
      fi
      vault_curl POST "$(vault_kv_path "$1")" "$cuerpo" >/dev/null
    }

    vault_kv_delete() {  # <ruta>
      if [ "$(vault_kv_version)" = "2" ]; then
        vault_curl DELETE "${VAULT_KV_MOUNT}/metadata/$1" >/dev/null
      else
        vault_curl DELETE "${VAULT_KV_MOUNT}/$1" >/dev/null
      fi
    }
  init.sh: |
    #!/usr/bin/env bash
    set -euo pipefail

    : "${ORIGIN_NS:?falta ORIGIN_NS}"
    : "${CLUSTER:?falta CLUSTER}"
    : "${KEYS_NS:?falta KEYS_NS}"

    WORK="${WORK_DIR:-/tmp}"
    mkdir -p "${WORK}"
    SCRIPTS="${SCRIPTS_DIR:-/scripts}"
    SECRET_ID_FILE="${VAULT_SECRET_ID_FILE:-/var/run/secrets/vault/secret-id}"
    VAULT_KV_BASE="ocp/${CLUSTER}/${ORIGIN_NS}"
    KID="${ORIGIN_NS}-wristband-key-gen1"
    SELECTOR="egress-interceptor/wristband-key=true,egress-interceptor/origin-namespace=${ORIGIN_NS}"

    if [ -n "$(kubectl get secret -n "${KEYS_NS}" -l "${SELECTOR}" -o name)" ]; then
      echo "${ORIGIN_NS} ya tiene clave de firma en ${KEYS_NS}, no se toca"
      exit 0
    fi

    source "${SCRIPTS}/vault-lib.sh"

    vault_login

    if vault_kv_exists "${VAULT_KV_BASE}/signing-key-gen1"; then
      echo "signing-key-gen1 de ${ORIGIN_NS} ya está en Vault, se reutiliza"
    else
      openssl genrsa -traditional -out "${WORK}/gen1.pem" 2048
      head -1 "${WORK}/gen1.pem" | grep -q "BEGIN RSA PRIVATE KEY"
      openssl rsa -in "${WORK}/gen1.pem" -pubout -out "${WORK}/gen1.pub"
      vault_kv_put_file "${VAULT_KV_BASE}/signing-key-gen1" private_key "${WORK}/gen1.pem"
      python3 "${SCRIPTS}/build-jwks.py" --old "${WORK}/gen1.pub" --old-kid "${KID}" > "${WORK}/jwks.json"
      vault_kv_put_file "${VAULT_KV_BASE}/jwks" jwks "${WORK}/jwks.json"
    fi

    cat <<EOF | kubectl apply -f -
    apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: ${KID}
      namespace: ${KEYS_NS}
      labels:
        nullplatform: "true"
        egress-interceptor/wristband-key: "true"
        egress-interceptor/origin-namespace: ${ORIGIN_NS}
        egress-interceptor/key-generation: "1"
    spec:
      refreshInterval: 1m
      secretStoreRef:
        name: {{ .vault_secret_store }}
        kind: SecretStore
      target:
        name: ${KID}
        template:
          metadata:
            labels:
              nullplatform: "true"
              egress-interceptor/wristband-key: "true"
              egress-interceptor/origin-namespace: ${ORIGIN_NS}
              egress-interceptor/key-generation: "1"
      data:
        - secretKey: key.pem
          remoteRef:
            key: ${VAULT_KV_BASE}/signing-key-gen1
            property: private_key
    EOF
    kubectl wait --for=condition=Ready "externalsecret/${KID}" -n "${KEYS_NS}" --timeout=120s

    echo "bootstrap de ${ORIGIN_NS} listo: ${KID}"
  rotate.sh: |
    #!/usr/bin/env bash
    # Lógica de rotación de la clave de wristband de un namespace de origen.
    # Pendiente conocido: hoy corre sobre alpine/k8s instalando openssl/jq/vault con
    # apk en cada ejecución (depende de salida a internet); para producción conviene
    # una imagen propia con todo embebido.
    set -euo pipefail

    : "${ORIGIN_NS:?falta ORIGIN_NS}"
    : "${CLUSTER:?falta CLUSTER}"
    : "${KEYS_NS:?falta KEYS_NS}"
    : "${AUTH_POLICY_NAME:?falta AUTH_POLICY_NAME}"
    : "${TOKEN_DURATION:=300}"
    : "${EXTRA_WAIT:=0}"
    : "${LOCAL_JWKS_URL:=}"

    WORK="${WORK_DIR:-/tmp}"
    mkdir -p "${WORK}"
    SCRIPTS="${SCRIPTS_DIR:-/scripts}"
    SECRET_ID_FILE="${VAULT_SECRET_ID_FILE:-/var/run/secrets/vault/secret-id}"
    source "${SCRIPTS}/vault-lib.sh"
    VAULT_KV_BASE="ocp/${CLUSTER}/${ORIGIN_NS}"
    SECRET_PREFIX="${ORIGIN_NS}-wristband-key-gen"

    log() { echo "[$(date -Iseconds)] $*"; }

    current_signing_key() {
      kubectl get authpolicy "${AUTH_POLICY_NAME}" -n "${ORIGIN_NS}" \
        -o jsonpath='{.spec.rules.response.success.filters.wristband.wristband.signingKeyRefs[0].name}'
    }

    cleanup_orphans() {
      local current="$1"
      log "limpiando ExternalSecret/Secret huérfanos de corridas anteriores interrumpidas"
      for es in $(kubectl get externalsecret -n "${KEYS_NS}" -o name | grep "${SECRET_PREFIX}" || true); do
        name="${es#externalsecret.external-secrets.io/}"
        if [ "${name}" != "${current}" ]; then
          log "borrando ExternalSecret huérfano: ${name}"
          kubectl delete externalsecret "${name}" -n "${KEYS_NS}" --ignore-not-found
          kubectl delete secret "${name}" -n "${KEYS_NS}" --ignore-not-found
          vault_kv_delete "${VAULT_KV_BASE}/signing-key-gen${name##${SECRET_PREFIX}}" || true
        fi
      done
    }

    generate_keypair() {
      local gen="$1"
      openssl genrsa -traditional -out "${WORK}/gen${gen}.pem" 2048
      if ! head -1 "${WORK}/gen${gen}.pem" | grep -q "BEGIN RSA PRIVATE KEY"; then
        echo "la clave gen${gen} no salió en PKCS#1: Authorino no la va a poder usar" >&2
        exit 1
      fi
      openssl rsa -in "${WORK}/gen${gen}.pem" -pubout -out "${WORK}/gen${gen}.pub"
    }

    recover_public_key() {
      local gen="$1"
      if ! vault_kv_get_field "${VAULT_KV_BASE}/signing-key-gen${gen}" private_key \
          > "${WORK}/gen${gen}.pem"; then
        echo "no se pudo recuperar gen${gen} de Vault: sin su pública el JWKS de solape sería falso" >&2
        exit 1
      fi
      openssl rsa -in "${WORK}/gen${gen}.pem" -pubout -out "${WORK}/gen${gen}.pub"
    }

    publish_private_key() {
      local gen="$1"
      vault_kv_put_file "${VAULT_KV_BASE}/signing-key-gen${gen}" private_key "${WORK}/gen${gen}.pem"
    }

    publish_jwks_with_both_keys() {
      local old_gen="$1" new_gen="$2"
      python3 "${SCRIPTS}/build-jwks.py" \
        --old "${WORK}/gen${old_gen}.pub" --old-kid "${SECRET_PREFIX}${old_gen}" \
        --new "${WORK}/gen${new_gen}.pub" --new-kid "${SECRET_PREFIX}${new_gen}" \
        > "${WORK}/jwks-both.json"
      vault_kv_put_file "${VAULT_KV_BASE}/jwks" jwks "${WORK}/jwks-both.json"
    }

    publish_jwks_single_key() {
      local gen="$1"
      python3 "${SCRIPTS}/build-jwks.py" \
        --old "${WORK}/gen${gen}.pub" --old-kid "${SECRET_PREFIX}${gen}" \
        > "${WORK}/jwks-single.json"
      vault_kv_put_file "${VAULT_KV_BASE}/jwks" jwks "${WORK}/jwks-single.json"
    }

    wait_for_kid_in_jwks() {
      local kid="$1"
      if [ -z "${LOCAL_JWKS_URL}" ]; then
        log "LOCAL_JWKS_URL vacía: NO se verifica que kid=${kid} se haya propagado antes del switch"
        return 0
      fi
      log "esperando a que ${LOCAL_JWKS_URL} sirva kid=${kid}"
      for _ in $(seq 1 60); do
        if curl -fsS "${LOCAL_JWKS_URL}" | jq -e --arg kid "${kid}" '.keys[] | select(.kid == $kid)' > /dev/null; then
          return 0
        fi
        sleep 5
      done
      echo "timeout esperando propagación de kid=${kid}" >&2
      exit 1
    }

    apply_new_signing_secret() {
      local gen="$1"
      cat <<EOF | kubectl apply -f -
    apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: ${SECRET_PREFIX}${gen}
      namespace: ${KEYS_NS}
      labels:
        nullplatform: "true"
        egress-interceptor/wristband-key: "true"
        egress-interceptor/origin-namespace: ${ORIGIN_NS}
        egress-interceptor/key-generation: "${gen}"
    spec:
      refreshInterval: 1m
      secretStoreRef:
        name: {{ .vault_secret_store }}
        kind: SecretStore
      target:
        name: ${SECRET_PREFIX}${gen}
        template:
          metadata:
            labels:
              nullplatform: "true"
              egress-interceptor/wristband-key: "true"
              egress-interceptor/origin-namespace: ${ORIGIN_NS}
              egress-interceptor/key-generation: "${gen}"
      data:
        - secretKey: key.pem
          remoteRef:
            key: ${VAULT_KV_BASE}/signing-key-gen${gen}
            property: private_key
    EOF
      kubectl wait --for=condition=Ready "externalsecret/${SECRET_PREFIX}${gen}" -n "${KEYS_NS}" --timeout=60s
    }

    switch_signing_key_ref() {
      local gen="$1"
      log "apuntando ${AUTH_POLICY_NAME} a ${SECRET_PREFIX}${gen} (sin reiniciar Authorino)"
      kubectl patch authpolicy "${AUTH_POLICY_NAME}" -n "${ORIGIN_NS}" --type=merge -p \
        "{\"spec\":{\"rules\":{\"response\":{\"success\":{\"filters\":{\"wristband\":{\"wristband\":{\"signingKeyRefs\":[{\"name\":\"${SECRET_PREFIX}${gen}\",\"algorithm\":\"RS256\"}]}}}}}}}}"
    }

    retire_old_key() {
      local old_gen="$1"
      log "retirando clave vieja gen${old_gen}: JWKS, ExternalSecret y Secret"
      vault_kv_delete "${VAULT_KV_BASE}/signing-key-gen${old_gen}"
      kubectl delete externalsecret "${SECRET_PREFIX}${old_gen}" -n "${KEYS_NS}" --ignore-not-found
      kubectl delete secret "${SECRET_PREFIX}${old_gen}" -n "${KEYS_NS}" --ignore-not-found
    }

    main() {
      vault_login

      local current old_gen new_gen
      current="$(current_signing_key)"
      if [ -z "${current}" ]; then
        echo "la AuthPolicy ${AUTH_POLICY_NAME} de ${ORIGIN_NS} no declara ninguna clave de firma" >&2
        exit 1
      fi
      old_gen="${current#"${SECRET_PREFIX}"}"
      if ! [[ "${old_gen}" =~ ^[0-9]+$ ]]; then
        echo "la clave vigente '${current}' no sigue el patrón ${SECRET_PREFIX}<N>: no se rota a ciegas" >&2
        exit 1
      fi
      new_gen="$((old_gen + 1))"

      cleanup_orphans "${current}"

      log "rotando ${ORIGIN_NS}: gen${old_gen} -> gen${new_gen}"

      recover_public_key "${old_gen}"
      generate_keypair "${new_gen}"
      publish_private_key "${new_gen}"
      publish_jwks_with_both_keys "${old_gen}" "${new_gen}"

      wait_for_kid_in_jwks "${SECRET_PREFIX}${new_gen}"
      if [ "${EXTRA_WAIT}" != "0" ]; then
        log "EXTRA_WAIT=${EXTRA_WAIT}s para validadores remotos"
        sleep "${EXTRA_WAIT}"
      fi

      apply_new_signing_secret "${new_gen}"
      switch_signing_key_ref "${new_gen}"

      log "esperando ${TOKEN_DURATION}s a que expiren los tokens emitidos con la clave vieja"
      sleep "${TOKEN_DURATION}"

      publish_jwks_single_key "${new_gen}"
      retire_old_key "${old_gen}"

      log "rotación de ${ORIGIN_NS} completa: clave vigente = ${SECRET_PREFIX}${new_gen}"
    }

    main "$@"
  build-jwks.py: |
    #!/usr/bin/env python3
    """Arma un JWKS a partir de una o dos claves públicas RSA en PEM."""
    import argparse
    import base64
    import json

    from cryptography.hazmat.primitives import serialization


    def jwk_from_pem(path: str, kid: str) -> dict:
        with open(path, "rb") as f:
            pub = serialization.load_pem_public_key(f.read())
        numbers = pub.public_numbers()

        def b64url(n: int) -> str:
            length = (n.bit_length() + 7) // 8
            return base64.urlsafe_b64encode(n.to_bytes(length, "big")).rstrip(b"=").decode()

        return {
            "kty": "RSA",
            "use": "sig",
            "alg": "RS256",
            "kid": kid,
            "n": b64url(numbers.n),
            "e": b64url(numbers.e),
        }


    def main() -> None:
        parser = argparse.ArgumentParser()
        parser.add_argument("--old", required=True)
        parser.add_argument("--old-kid", required=True)
        parser.add_argument("--new")
        parser.add_argument("--new-kid")
        args = parser.parse_args()

        if bool(args.new) != bool(args.new_kid):
            parser.error("--new y --new-kid van juntas: un JWK sin kid no lo prueba ningún validador")

        keys = [jwk_from_pem(args.old, args.old_kid)]
        if args.new:
            keys.append(jwk_from_pem(args.new, args.new_kid))

        print(json.dumps({"keys": keys}))


    if __name__ == "__main__":
        main()
