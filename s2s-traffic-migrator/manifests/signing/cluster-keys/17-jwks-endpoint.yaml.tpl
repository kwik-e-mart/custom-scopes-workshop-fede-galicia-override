{{- $ns := .namespace -}}
{{- $name := .jwks_service -}}
{{- /*
Sirve por HTTP el JWKS de este namespace, que es lo que el validador de ingreso consulta para
verificar la firma del wristband. Cierra el ciclo que abre el keygen: el Job escribe el JWKS en
Vault, el ExternalSecret lo baja a un Secret, y httpd lo publica.

Todo vive en el namespace de la app y no en kuadrant-system: ahí cada instancia es dueña de lo
suyo y dos emisores no pueden pisarse el Deployment ni el Service.

El `optional: true` del volumen es lo que permite que el pod arranque antes de que exista la
clave. Sin eso el Deployment se queda en ContainerCreating hasta que el keygen termine, y como el
reconcile espera a que el endpoint responda, se traba contra sí mismo.
*/ -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ $name | quote }}
  namespace: {{ $ns | quote }}
  labels:
    nullplatform: "true"
spec:
  selector:
    app: {{ $name | quote }}
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ $name | quote }}
  namespace: {{ $ns | quote }}
  labels:
    nullplatform: "true"
spec:
  refreshInterval: 15s
  secretStoreRef:
    name: {{ .vault_secret_store | quote }}
    kind: ClusterSecretStore
  target:
    name: {{ $name | quote }}
    creationPolicy: Owner
  data:
    - secretKey: jwks.json
      remoteRef:
        key: {{ printf "%s/%s/jwks" .vault_kv_cluster $ns | quote }}
        property: jwks
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name | quote }}
  namespace: {{ $ns | quote }}
  labels:
    nullplatform: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{ $name | quote }}
  template:
    metadata:
      labels:
        app: {{ $name | quote }}
        nullplatform: "true"
    spec:
      containers:
        - name: httpd
          image: {{ .jwks_image | quote }}
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            tcpSocket:
              port: 8080
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { cpu: 100m, memory: 128Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: jwks
              mountPath: /var/www/html
              readOnly: true
      volumes:
        - name: jwks
          projected:
            sources:
              - secret:
                  name: {{ $name | quote }}
                  optional: true
                  items:
                    - key: jwks.json
                      path: {{ printf "%s/jwks.json" $ns | quote }}
