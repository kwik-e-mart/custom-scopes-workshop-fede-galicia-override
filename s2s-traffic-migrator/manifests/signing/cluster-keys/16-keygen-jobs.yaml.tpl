apiVersion: batch/v1
kind: Job
metadata:
  name: wristband-init-{{ .namespace }}
  namespace: {{ .namespace }}
  labels:
    nullplatform: "true"
spec:
  backoffLimit: 1
  template:
    spec:
      serviceAccountName: wristband-rotator
      restartPolicy: Never
      containers:
        - name: init
          image: {{ .keygen_image }}
          env:
            - { name: ORIGIN_NS, value: "{{ .namespace }}" }
            - { name: KEYS_NS, value: "{{ .keys_namespace }}" }
            - { name: CLUSTER, value: "{{ .cluster_label }}" }
            - { name: VAULT_ADDR, value: "{{ .vault_addr }}" }
            - { name: VAULT_NAMESPACE, value: "{{ .vault_namespace }}" }
            - { name: VAULT_ROLE_ID, value: "{{ .vault_approle_role_id }}" }
          command: ["/bin/bash", "-c", "apk add --no-cache jq python3 py3-cryptography curl openssl vault > /dev/null && /bin/bash /scripts/init.sh"]
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
            - { name: vault-secret-id, mountPath: /var/run/secrets/vault, readOnly: true }
      volumes:
        - name: scripts
          configMap: { name: wristband-rotate-scripts, defaultMode: 0755 }
        - name: vault-secret-id
          secret: { secretName: {{ .vault_approle_secret }} }
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: wristband-rotate-{{ .namespace }}
  namespace: {{ .namespace }}
  labels:
    nullplatform: "true"
spec:
  schedule: "0 3 * * 0"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          serviceAccountName: wristband-rotator
          restartPolicy: Never
          containers:
            - name: rotate
              image: {{ .keygen_image }}
              env:
                - { name: ORIGIN_NS, value: "{{ .namespace }}" }
                - { name: KEYS_NS, value: "{{ .keys_namespace }}" }
                - { name: CLUSTER, value: "{{ .cluster_label }}" }
                - { name: AUTH_POLICY_NAME, value: "{{ .gateway_name }}" }
                - { name: TOKEN_DURATION, value: "300" }
                - { name: EXTRA_WAIT, value: "0" }
                - { name: LOCAL_JWKS_URL, value: "{{ .local_jwks_url }}" }
                - { name: VAULT_ADDR, value: "{{ .vault_addr }}" }
                - { name: VAULT_NAMESPACE, value: "{{ .vault_namespace }}" }
                - { name: VAULT_ROLE_ID, value: "{{ .vault_approle_role_id }}" }
              command: ["/bin/bash", "-c", "apk add --no-cache jq python3 py3-cryptography curl openssl vault > /dev/null && /bin/bash /scripts/rotate.sh"]
              volumeMounts:
                - { name: scripts, mountPath: /scripts }
                - { name: vault-secret-id, mountPath: /var/run/secrets/vault, readOnly: true }
          volumes:
            - name: scripts
              configMap: { name: wristband-rotate-scripts, defaultMode: 0755 }
            - name: vault-secret-id
              secret: { secretName: {{ .vault_approle_secret }} }
