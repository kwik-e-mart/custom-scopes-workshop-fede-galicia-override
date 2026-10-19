import copy
import hashlib
import json
import os
import re
import ssl
import sys
import threading
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PLANS = [{"id": "bronze", "maxTps": 5}, {"id": "gold", "maxTps": 20}, {"id": "no-limits"}]
ENVIRONMENTS = ["dev", "int", "qas", "prd"]
LEGAJO_PATTERN = re.compile(r"^l[0-9]{7}$")
FINAL_FAILED_STATES = ("RolledBack", "Failed")
GENERATED_FILES = ["httproute.yaml", "ratelimitpolicy.yaml", "authpolicy.yaml", "apiproduct.yaml"]


def log(message):
    print(message, file=sys.stderr, flush=True)


def empty_state():
    return {"subscriptions": {}, "operations": {}, "idempotency": {}, "publications": {}}


class MemoryStore:
    def __init__(self):
        self.state = empty_state()

    def load(self):
        return copy.deepcopy(self.state)

    def save(self, state):
        self.state = copy.deepcopy(state)


class ConfigMapStore:
    KEY = "state.json"

    def __init__(self, k8s, namespace, name):
        self.k8s = k8s
        self.namespace = namespace
        self.name = name
        self.exists = False

    def path(self):
        return f"/api/v1/namespaces/{self.namespace}/configmaps/{self.name}"

    def load(self):
        status, body = self.k8s.request("GET", self.path())
        state = empty_state()
        if status == 404:
            self.exists = False
            return state
        if status != 200:
            raise RuntimeError(f"no se pudo leer el ConfigMap {self.name}: HTTP {status}")
        self.exists = True
        stored = json.loads((body.get("data") or {}).get(self.KEY) or "{}")
        state.update(stored)
        return state

    def save(self, state):
        manifest = {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": self.name, "namespace": self.namespace,
                         "labels": {"app.kubernetes.io/managed-by": "apim-mock"}},
            "data": {self.KEY: json.dumps(state, sort_keys=True)},
        }
        if not self.exists:
            status, _ = self.k8s.request("POST", f"/api/v1/namespaces/{self.namespace}/configmaps", manifest)
            if status in (200, 201):
                self.exists = True
                return
            if status != 409:
                raise RuntimeError(f"no se pudo crear el ConfigMap {self.name}: HTTP {status}")
            self.exists = True
        status, _ = self.k8s.request("PUT", self.path(), manifest)
        if status not in (200, 201):
            raise RuntimeError(f"no se pudo guardar el ConfigMap {self.name}: HTTP {status}")


def json_http(method, url, headers, body, context=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    for key, value in headers.items():
        request.add_header(key, value)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=15, context=context) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw) if raw else None
        except ValueError:
            return error.code, None


class K8sClient:
    def __init__(self, api_url, token_path, ca_path):
        self.api_url = api_url
        self.token_path = token_path
        self.context = ssl.create_default_context(cafile=ca_path) if os.path.exists(ca_path) else None

    def request(self, method, path, body=None):
        with open(self.token_path) as handle:
            token = handle.read().strip()
        return json_http(method, f"{self.api_url}{path}", {"Authorization": f"Bearer {token}"}, body, self.context)


class Notifier:
    def __init__(self, np_api_url, api_key, http=json_http):
        self.np_api_url = np_api_url
        self.api_key = api_key
        self.http = http

    def notify(self, callback_url, message, level="info", status=None):
        if not callback_url or not self.api_key:
            log(f"apim-mock: aviso sin enviar (callbackUrl o NP_API_KEY vacíos): {message}")
            return
        body = {"messages": [{"level": level, "message": message}]}
        if status:
            body = {"status": status, **body}
        try:
            code, token = self.http("POST", f"{self.np_api_url}/token", {}, {"api_key": self.api_key})
            if code != 200 or not token or not token.get("access_token"):
                log(f"apim-mock: no se pudo obtener el token de nullplatform (HTTP {code})")
                return
            code, _ = self.http("PATCH", callback_url, {"Authorization": f"Bearer {token['access_token']}"}, body)
            log(f"apim-mock: aviso {status or 'avance'} a {callback_url} → HTTP {code}")
        except Exception as error:
            log(f"apim-mock: falló el aviso a {callback_url}: {error}")


def timer_scheduler(delay, fn):
    timer = threading.Timer(delay, fn)
    timer.daemon = True
    timer.start()


def problem(status, title, detail):
    return status, {"type": "about:blank", "title": title, "status": status, "detail": detail}


def publish_error(message):
    return 400, {"status": "error", "message": message}


def body_hash(raw):
    try:
        canonical = json.dumps(json.loads(raw or b"{}"), sort_keys=True)
    except ValueError:
        canonical = raw.decode(errors="replace")
    return hashlib.sha256(canonical.encode()).hexdigest()


class App:
    def __init__(self, store, k8s, notifier, scheduler, settings):
        self.store = store
        self.k8s = k8s
        self.notifier = notifier
        self.scheduler = scheduler
        self.settings = settings
        self.lock = threading.RLock()
        self.state = store.load()

    def save(self):
        self.store.save(self.state)

    def handle(self, method, path, headers, raw):
        headers = {key.lower(): value for key, value in headers.items()}
        if path == "/healthz":
            return 200, {"status": "ok"}
        token = self.settings.get("token")
        if token and headers.get("authorization") != f"Bearer {token}":
            return problem(401, "Unauthorized", "Falta el Bearer del mock o no coincide con MOCK_TOKEN.")
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            return problem(400, "Bad Request", "El cuerpo no es JSON válido.")
        with self.lock:
            return self.route(method, path, headers, body, raw)

    def route(self, method, path, headers, body, raw):
        key = headers.get("idempotency-key", "")
        if path == "/v1/plans" and method == "GET":
            return 200, {"items": PLANS}
        if path == "/v1/subscriptions" and method == "POST":
            return self.create_subscription(body, raw, key)
        match = re.fullmatch(r"/v1/subscriptions/([^/]+)", path)
        if match and method == "GET":
            return self.get_subscription(match.group(1))
        if match and method == "PATCH":
            return self.change_plan(match.group(1), body, raw, key)
        if match and method == "DELETE":
            return self.revoke_subscription(match.group(1))
        match = re.fullmatch(r"/v1/operations/([^/]+)", path)
        if match and method == "GET":
            operation = self.state["operations"].get(match.group(1))
            if not operation:
                return problem(404, "Not Found", f"No existe la operación {match.group(1)}.")
            return 200, operation
        if path == "/v1/kuadrant/manifests/publish" and method == "POST":
            return self.publish(body)
        match = re.fullmatch(r"/v1/kuadrant/manifests/([^/]+)", path)
        if match and method == "DELETE":
            return self.unpublish(match.group(1))
        if path == "/mock/state" and method == "GET":
            return 200, self.state
        if path == "/mock/reset" and method == "POST":
            self.state = empty_state()
            self.save()
            return 200, {"status": "reset"}
        return problem(404, "Not Found", f"{method} {path} no existe en el mock.")

    def replay(self, key, raw):
        if not key:
            return None
        previous = self.state["idempotency"].get(key)
        if not previous:
            return None
        operation = self.state["operations"].get(previous["operation_id"], {})
        if operation.get("state") in FINAL_FAILED_STATES:
            return None
        if previous["hash"] != body_hash(raw):
            return problem(422, "Unprocessable Entity", "La misma Idempotency-Key llegó con otro cuerpo.")
        return previous["status"], operation

    def remember(self, key, raw, status, operation):
        if key:
            self.state["idempotency"][key] = {"hash": body_hash(raw), "operation_id": operation["id"], "status": status}

    def new_operation(self, kind, target, callback_url):
        operation = {"id": str(uuid.uuid4()), "kind": kind, "state": "Committed", "target": target,
                     "callbackUrl": callback_url or ""}
        self.state["operations"][operation["id"]] = operation
        return operation

    def create_subscription(self, body, raw, key):
        replayed = self.replay(key, raw)
        if replayed:
            return replayed
        missing = [field for field in ("approvalRef", "consumerNamespace", "planId") if not body.get(field)]
        if missing:
            return problem(400, "Bad Request", f"Faltan campos obligatorios: {', '.join(missing)}.")
        ritm = body["approvalRef"]
        namespace = body["consumerNamespace"]
        digits = re.sub(r"[^0-9]", "", ritm) or "0"
        api_id = f"api-{digits}"
        subscription_id = f"sub-{api_id}--{namespace}"
        if ritm.endswith("503"):
            return problem(503, "Service Unavailable", "ServiceNow no responde (mock: RITM terminado en 503).")
        if ritm.endswith("422"):
            return problem(422, "Unprocessable Entity",
                           "Tu solicitud no está aprobada en ServiceNow; volvé a enviarla cuando se apruebe.")
        if body["planId"] not in [plan["id"] for plan in PLANS]:
            return problem(422, "Plan inválido", f"El plan {body['planId']} no está en el catálogo.")
        if ritm.endswith("409") or subscription_id in self.state["subscriptions"]:
            return problem(409, "Conflict", f"El namespace {namespace} ya está suscripto a {api_id}: {subscription_id}")
        self.state["subscriptions"][subscription_id] = {
            "id": subscription_id, "apiId": api_id, "consumerNamespace": namespace, "planId": body["planId"],
            "approvalRef": ritm, "tenant": self.settings["tenant"], "state": "Syncing",
        }
        operation = self.new_operation("subscription", subscription_id, body.get("callbackUrl"))
        self.remember(key, raw, 202, operation)
        self.save()
        self.notifier.notify(operation["callbackUrl"],
                             f"Solicitud {ritm} validada. Suscripción escrita en Git; aplicándola en los clusters.")
        self.scheduler(self.settings["callback_delay"], lambda: self.complete_subscription(operation["id"]))
        return 202, operation

    def complete_subscription(self, operation_id):
        with self.lock:
            operation = self.state["operations"][operation_id]
            subscription = self.state["subscriptions"].get(operation["target"])
            if not subscription:
                return
            if subscription["approvalRef"].endswith("666"):
                del self.state["subscriptions"][operation["target"]]
                operation["state"] = "RolledBack"
                operation["error"] = {"detail": "mock: RITM terminado en 666"}
                self.save()
                outcome = ("failed", "error", "No se pudo completar (mock: RITM terminado en 666). Se deshizo; volvé a intentar más tarde.")
            elif not self.ensure_credential_secret(subscription["consumerNamespace"]):
                del self.state["subscriptions"][operation["target"]]
                operation["state"] = "Failed"
                operation["error"] = {"detail": "no se pudo crear el Secret de la credencial"}
                self.save()
                outcome = ("failed", "error", "No se pudo aplicar en los clusters (el mock no pudo crear el Secret de la credencial).")
            else:
                subscription["state"] = "Registered"
                operation["state"] = "Registered"
                self.save()
                outcome = ("success", "info", "Suscripción activa y registrada en el catálogo de APIs.")
        status, level, message = outcome
        self.notifier.notify(operation["callbackUrl"], message, level=level, status=status)

    def ensure_credential_secret(self, namespace):
        if not self.settings.get("create_secret", True):
            return True
        tenant = self.settings["tenant"]
        manifest = {
            "apiVersion": "v1",
            "kind": "Secret",
            "type": "Opaque",
            "metadata": {"name": f"secret-apim-{tenant}", "labels": {"app.kubernetes.io/managed-by": "apim-mock"}},
            "stringData": {"app_id": f"mock-app-{namespace}", "app_key": f"mock-key-{namespace}"},
        }
        try:
            status, _ = self.k8s.request("POST", f"/api/v1/namespaces/{namespace}/secrets", manifest)
        except Exception as error:
            log(f"apim-mock: no se pudo crear el Secret en {namespace}: {error}")
            return False
        if status not in (200, 201, 409):
            log(f"apim-mock: no se pudo crear el Secret en {namespace}: HTTP {status}")
            return False
        return True

    def get_subscription(self, subscription_id):
        subscription = self.state["subscriptions"].get(subscription_id)
        if not subscription:
            return problem(404, "Not Found", f"No existe la suscripción {subscription_id}.")
        return 200, subscription

    def change_plan(self, subscription_id, body, raw, key):
        if subscription_id not in self.state["subscriptions"]:
            return problem(404, "Not Found", f"No existe la suscripción {subscription_id}.")
        replayed = self.replay(key, raw)
        if replayed:
            return replayed
        plan_id = body.get("planId")
        if not plan_id:
            return problem(400, "Bad Request", "Falta planId.")
        if plan_id not in [plan["id"] for plan in PLANS]:
            return problem(422, "Plan inválido", f"El plan {plan_id} no está en el catálogo.")
        operation = self.new_operation("planChange", subscription_id, body.get("callbackUrl"))
        operation["planId"] = plan_id
        self.remember(key, raw, 202, operation)
        self.save()
        self.notifier.notify(operation["callbackUrl"], f"Cambio de plan a {plan_id} escrito en Git; aplicándolo en los clusters.")
        self.scheduler(self.settings["callback_delay"], lambda: self.complete_plan_change(operation["id"]))
        return 202, operation

    def complete_plan_change(self, operation_id):
        with self.lock:
            operation = self.state["operations"][operation_id]
            subscription = self.state["subscriptions"].get(operation["target"])
            if not subscription:
                return
            subscription["planId"] = operation["planId"]
            operation["state"] = "Registered"
            self.save()
        self.notifier.notify(operation["callbackUrl"], f"Plan cambiado a {operation['planId']}.", status="success")

    def revoke_subscription(self, subscription_id):
        if subscription_id not in self.state["subscriptions"]:
            return problem(404, "Not Found", f"No existe la suscripción {subscription_id}.")
        del self.state["subscriptions"][subscription_id]
        operation = self.new_operation("revoke", subscription_id, "")
        operation["state"] = "Succeeded"
        self.save()
        return 202, operation

    def validate_publication(self, body):
        if not body.get("tenant"):
            return "El tenant de publicación es obligatorio."
        for field in ("organization", "repository", "environment", "cluster", "metadata"):
            if not body.get(field):
                return f"El campo {field} es obligatorio."
        if body["environment"] not in ENVIRONMENTS:
            return f"El ambiente {body['environment']} no es válido; tiene que ser uno de {', '.join(ENVIRONMENTS)}."
        if not (body.get("branch") or body.get("tag") or body.get("commit")):
            return "Se requiere al menos uno de branch, tag o commit."
        if body.get("legajo") and not LEGAJO_PATTERN.match(body["legajo"]):
            return "El legajo tiene que tener el formato l#######."
        metadata = body["metadata"]
        for field in ("name", "namespace"):
            if not metadata.get(field):
                return f"El campo metadata.{field} es obligatorio."
        parent_refs = metadata.get("parentRefs") or []
        if not parent_refs or not all(ref.get("name") and ref.get("namespace") for ref in parent_refs):
            return "metadata.parentRefs necesita al menos un Gateway con name y namespace."
        return None

    def publish(self, body):
        error = self.validate_publication(body)
        if error:
            return publish_error(error)
        metadata = body["metadata"]
        name, namespace, tenant, environment = metadata["name"], metadata["namespace"], body["tenant"], body["environment"]
        api_id = f"{namespace}-{name}-{tenant}-1"
        ref = body.get("branch") or body.get("tag") or body.get("commit")
        existing = self.state["publications"].get(api_id)
        if existing and existing["ref"] == ref:
            return publish_error(f"La API {api_id} ya está publicada en {ref}.")
        hostnames = metadata.get("hostnames") or [f"{namespace}-{name}-{tenant}-{environment}.{self.settings['domain']}"]
        publication = {
            "apiId": api_id, "ref": ref, "status": "pushed", "hostname": hostnames[0], "namespace": namespace,
            "apiName": name, "tenant": tenant, "environment": environment,
            "repository": f"{body['organization']}/{body['repository']}",
            "manifestPath": f"clusters/{body['cluster']}/apis/{namespace}/{name}",
            "callbackUrl": body.get("callbackUrl") or "",
        }
        self.state["publications"][api_id] = publication
        self.save()
        response = {
            "status": "pushed",
            "message": "La publicación fue pusheada correctamente a Git y Argo sigue sincronizándose.",
            "apiId": api_id, "hostname": publication["hostname"], "namespace": namespace, "apiName": name,
            "tenant": tenant, "environment": environment, "repository": publication["repository"],
            "manifestPath": publication["manifestPath"], "generatedFiles": GENERATED_FILES,
            "argoStatus": {"application": "apim-mock", "sync": "OutOfSync", "health": "Healthy",
                           "operationPhase": "Running", "resources": []},
        }
        self.notifier.notify(publication["callbackUrl"], "Manifiestos pusheados a Git; Argo está sincronizando.")
        self.scheduler(self.settings["callback_delay"], lambda: self.complete_publication(api_id, ref))
        return 200, response

    def complete_publication(self, api_id, ref):
        with self.lock:
            publication = self.state["publications"].get(api_id)
            if not publication or publication["ref"] != ref:
                return
            if publication["repository"].split("/", 1)[1].startswith("fail-"):
                del self.state["publications"][api_id]
                self.save()
                outcome = ("failed", "error", "Argo no sincronizó (mock: repo fail-*); se eliminaron los manifiestos.")
            else:
                publication["status"] = "registered"
                self.save()
                outcome = ("success", "info", f"API publicada y registrada en {publication['hostname']}.")
        status, level, message = outcome
        self.notifier.notify(publication["callbackUrl"], message, level=level, status=status)

    def unpublish(self, api_id):
        if api_id not in self.state["publications"]:
            return 404, {"status": "error", "message": f"No existe la publicación {api_id}."}
        del self.state["publications"][api_id]
        self.save()
        return 200, {"status": "deleted", "apiId": api_id}


def make_handler(app):
    class Handler(BaseHTTPRequestHandler):
        def respond(self):
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            path = self.path.split("?", 1)[0]
            status, body = app.handle(self.command, path, dict(self.headers.items()), raw)
            payload = json.dumps(body).encode()
            content_type = "application/problem+json" if status >= 400 and "title" in body else "application/json"
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = respond
        do_POST = respond
        do_PATCH = respond
        do_DELETE = respond

        def log_message(self, format, *args):
            log(f"apim-mock: {self.command} {self.path} → {args[1] if len(args) > 1 else ''}")

    return Handler


def main():
    namespace = os.environ.get("POD_NAMESPACE", "default")
    k8s = K8sClient(os.environ.get("K8S_API_URL", "https://kubernetes.default.svc"),
                    "/var/run/secrets/kubernetes.io/serviceaccount/token",
                    "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
    if os.environ.get("STATE_BACKEND", "configmap") == "configmap":
        store = ConfigMapStore(k8s, namespace, os.environ.get("STATE_CONFIGMAP", "apim-mock-state"))
    else:
        store = MemoryStore()
    notifier = Notifier(os.environ.get("NP_API_URL", "https://api.nullplatform.com"), os.environ.get("NP_API_KEY", ""))
    settings = {
        "token": os.environ.get("MOCK_TOKEN", ""),
        "tenant": os.environ.get("MOCK_TENANT", "b2c"),
        "callback_delay": float(os.environ.get("CALLBACK_DELAY_SECONDS", "5")),
        "domain": os.environ.get("PUBLISH_DOMAIN", "bancogalicia.com.ar"),
        "create_secret": os.environ.get("CREATE_CREDENTIAL_SECRET", "true") == "true",
    }
    app = App(store, k8s, notifier, timer_scheduler, settings)
    port = int(os.environ.get("PORT", "8080"))
    log(f"apim-mock: escuchando en :{port} (estado en {type(store).__name__})")
    ThreadingHTTPServer(("0.0.0.0", port), make_handler(app)).serve_forever()


if __name__ == "__main__":
    main()
