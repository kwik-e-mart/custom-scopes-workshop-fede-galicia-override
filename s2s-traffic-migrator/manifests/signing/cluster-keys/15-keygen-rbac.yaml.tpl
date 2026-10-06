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
  init.sh: |
    #!/usr/bin/env bash
    set -euo pipefail

    : "${ORIGIN_NS:?falta ORIGIN_NS}"
    : "${CLUSTER:?falta CLUSTER}"
    : "${KEYS_NS:?falta KEYS_NS}"

    VAULT_KV_BASE="ocp/${CLUSTER}/${ORIGIN_NS}"
    KID="${ORIGIN_NS}-wristband-key-gen1"
    SELECTOR="egress-interceptor/wristband-key=true,egress-interceptor/origin-namespace=${ORIGIN_NS}"

    if [ -n "$(kubectl get secret -n "${KEYS_NS}" -l "${SELECTOR}" -o name)" ]; then
      echo "${ORIGIN_NS} ya tiene clave de firma en ${KEYS_NS}, no se toca"
      exit 0
    fi

    vault write -field=token auth/approle/login \
      role_id="${VAULT_ROLE_ID}" secret_id="$(cat /var/run/secrets/vault/secret-id)" \
      > /tmp/vault-token
    export VAULT_TOKEN
    VAULT_TOKEN="$(cat /tmp/vault-token)"

    if vault kv get "kv/${VAULT_KV_BASE}/signing-key-gen1" > /dev/null 2>&1; then
      echo "signing-key-gen1 de ${ORIGIN_NS} ya está en Vault, se reutiliza"
    else
      openssl genrsa -traditional -out /tmp/gen1.pem 2048
      head -1 /tmp/gen1.pem | grep -q "BEGIN RSA PRIVATE KEY"
      openssl rsa -in /tmp/gen1.pem -pubout -out /tmp/gen1.pub
      vault kv put "kv/${VAULT_KV_BASE}/signing-key-gen1" private_key=@/tmp/gen1.pem
      python3 /scripts/build-jwks.py --old /tmp/gen1.pub --old-kid "${KID}" > /tmp/jwks.json
      vault kv put "kv/${VAULT_KV_BASE}/jwks" jwks=@/tmp/jwks.json
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

    VAULT_KV_BASE="ocp/${CLUSTER}/${ORIGIN_NS}"
    SECRET_PREFIX="${ORIGIN_NS}-wristband-key-gen"

    log() { echo "[$(date -Iseconds)] $*"; }

    vault_login() {
      vault write -field=token auth/approle/login \
        role_id="${VAULT_ROLE_ID}" secret_id="$(cat /var/run/secrets/vault/secret-id)" \
        > /tmp/vault-token
      export VAULT_TOKEN
      VAULT_TOKEN="$(cat /tmp/vault-token)"
    }

    current_signing_key() {
      kubectl get authpolicy "${AUTH_POLICY_NAME}" -n "${ORIGIN_NS}" \
        -o jsonpath='{.spec.rules.response.success.filters.wristband.wristband.signingKeyRefs[0].name}'
    }

    cleanup_orphans() {
      log "limpiando ExternalSecret/Secret huérfanos de corridas anteriores interrumpidas"
      local current
      current="$(current_signing_key)"
      for es in $(kubectl get externalsecret -n "${KEYS_NS}" -o name | grep "${SECRET_PREFIX}" || true); do
        name="${es#externalsecret.external-secrets.io/}"
        if [ "${name}" != "${current}" ]; then
          log "borrando ExternalSecret huérfano: ${name}"
          kubectl delete externalsecret "${name}" -n "${KEYS_NS}" --ignore-not-found
          kubectl delete secret "${name}" -n "${KEYS_NS}" --ignore-not-found
          vault kv delete "kv/${VAULT_KV_BASE}/signing-key-gen${name##${SECRET_PREFIX}}" || true
        fi
      done
    }

    generate_keypair() {
      local gen="$1"
      openssl genrsa -out "/tmp/gen${gen}.pem" 2048
      openssl rsa -in "/tmp/gen${gen}.pem" -pubout -out "/tmp/gen${gen}.pub"
    }

    publish_private_key() {
      local gen="$1"
      vault kv put "kv/${VAULT_KV_BASE}/signing-key-gen${gen}" \
        private_key=@"/tmp/gen${gen}.pem"
    }

    publish_jwks_with_both_keys() {
      local old_gen="$1" new_gen="$2"
      python3 /scripts/build-jwks.py \
        --old "/tmp/gen${old_gen}.pub" --old-kid "${SECRET_PREFIX}${old_gen}" \
        --new "/tmp/gen${new_gen}.pub" --new-kid "${SECRET_PREFIX}${new_gen}" \
        > /tmp/jwks-both.json
      vault kv put "kv/${VAULT_KV_BASE}/jwks" jwks=@/tmp/jwks-both.json
    }

    publish_jwks_single_key() {
      local gen="$1"
      python3 /scripts/build-jwks.py \
        --old "/tmp/gen${gen}.pub" --old-kid "${SECRET_PREFIX}${gen}" \
        > /tmp/jwks-single.json
      vault kv put "kv/${VAULT_KV_BASE}/jwks" jwks=@/tmp/jwks-single.json
    }

    wait_for_kid_in_jwks() {
      local kid="$1"
      [ -z "${LOCAL_JWKS_URL}" ] && return 0
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
      vault kv delete "kv/${VAULT_KV_BASE}/signing-key-gen${old_gen}"
      kubectl delete externalsecret "${SECRET_PREFIX}${old_gen}" -n "${KEYS_NS}" --ignore-not-found
      kubectl delete secret "${SECRET_PREFIX}${old_gen}" -n "${KEYS_NS}" --ignore-not-found
    }

    main() {
      vault_login
      cleanup_orphans

      local old_gen new_gen
      old_gen="$(current_signing_key | sed "s/${SECRET_PREFIX}//")"
      new_gen="$((old_gen + 1))"

      log "rotando ${ORIGIN_NS}: gen${old_gen} -> gen${new_gen}"

      generate_keypair "${old_gen}" 2>/dev/null || true
      generate_keypair "${new_gen}"
      publish_private_key "${new_gen}"
      publish_jwks_with_both_keys "${old_gen}" "${new_gen}"

      wait_for_kid_in_jwks "${SECRET_PREFIX}${new_gen}"
      [ "${EXTRA_WAIT}" != "0" ] && { log "EXTRA_WAIT=${EXTRA_WAIT}s para validadores remotos"; sleep "${EXTRA_WAIT}"; }

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

        keys = [jwk_from_pem(args.old, args.old_kid)]
        if args.new:
            keys.append(jwk_from_pem(args.new, args.new_kid))

        print(json.dumps({"keys": keys}))


    if __name__ == "__main__":
        main()
