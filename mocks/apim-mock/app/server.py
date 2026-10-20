import copy
import hashlib
import hmac
import json
import os
import re
import ssl
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PLANS = [{"id": "bronze", "maxTps": 5}, {"id": "gold", "maxTps": 20}, {"id": "no-limits"}]
PLAN_IDS = [plan["id"] for plan in PLANS]
ENVIRONMENTS = ["dev", "int", "qas", "prd"]
LEGAJO_PATTERN = re.compile(r"l[0-9]{7}")
NAMESPACE_PATTERN = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")
WINDOW_PATTERN = re.compile(r"([0-9]{1,5}(h|m|s|ms)){1,4}")
CALLBACK_PATH = re.compile(r"/(service|link)/[A-Za-z0-9_-]+/action/[A-Za-z0-9_-]+")
CALLBACK_ENTITY = re.compile(r"/(service|link)/([A-Za-z0-9_-]+)/action/[A-Za-z0-9_-]+$")
GATEWAY_API = "/apis/gateway.networking.k8s.io/v1"
KUADRANT_API = "/apis/kuadrant.io/v1"
RITM_CONFLICT = "RITM9990409"
RITM_NOT_APPROVED = "RITM9990422"
RITM_UNAVAILABLE = "RITM9990503"
RITM_ROLLBACK = "RITM9990666"
FINAL_FAILED_STATES = ("RolledBack", "Failed")
PUBLIC_OPERATION_FIELDS = ("id", "kind", "state", "target", "error")
GENERATED_FILES = ["httproute.yaml", "ratelimitpolicy.yaml", "authpolicy.yaml", "apiproduct.yaml"]
MAX_BODY_BYTES = 65536


def log(message):
    print(message, file=sys.stderr, flush=True)


def empty_state():
    return {"subscriptions": {}, "operations": {}, "idempotency": {}, "publications": {}}


def is_text(value):
    return isinstance(value, str) and value != ""


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
        try:
            stored = json.loads((body.get("data") or {}).get(self.KEY) or "{}")
        except ValueError:
            log(f"apim-mock: el ConfigMap {self.name} no tiene JSON válido; arranca con el estado vacío")
            return state
        for key in state:
            if isinstance(stored.get(key), dict):
                state[key] = stored[key]
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


def json_http(method, url, headers, body, context=None, content_type="application/json"):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    for key, value in headers.items():
        request.add_header(key, value)
    if data is not None:
        request.add_header("Content-Type", content_type)
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
        headers = {"Authorization": f"Bearer {token}"}
        if method == "APPLY":
            return json_http("PATCH", f"{self.api_url}{path}?fieldManager=apim-mock&force=true",
                             headers, body, self.context, "application/apply-patch+yaml")
        return json_http(method, f"{self.api_url}{path}", headers, body, self.context)


class Notifier:
    def __init__(self, np_api_url, api_key, http=json_http):
        self.np_api_url = np_api_url
        self.api_key = api_key
        self.http = http

    def allowed(self, callback_url):
        target = urllib.parse.urlparse(callback_url)
        return (target.scheme == "https"
                and target.netloc == urllib.parse.urlparse(self.np_api_url).netloc
                and CALLBACK_PATH.fullmatch(target.path) is not None
                and not (target.query or target.fragment or target.params))

    def token(self):
        code, token = self.http("POST", f"{self.np_api_url}/token", {}, {"api_key": self.api_key})
        if code != 200 or not token or not token.get("access_token"):
            return None
        return token["access_token"]

    def link_service_id(self, link_id):
        if not self.api_key:
            return None
        try:
            token = self.token()
            if not token:
                return None
            code, link = self.http("GET", f"{self.np_api_url}/link/{link_id}", {"Authorization": f"Bearer {token}"}, None)
        except Exception as error:
            log(f"apim-mock: no se pudo leer el link {link_id}: {error}")
            return None
        if code != 200 or not isinstance(link, dict):
            log(f"apim-mock: no se pudo leer el link {link_id} (HTTP {code})")
            return None
        service_id = link.get("service_id") or link.get("serviceId")
        return str(service_id) if service_id else None

    def notify(self, callback_url, message, level="info", status=None):
        if not callback_url or not self.api_key:
            log(f"apim-mock: aviso sin enviar (callbackUrl o NP_API_KEY vacíos): {message}")
            return
        if not self.allowed(callback_url):
            log(f"apim-mock: aviso sin enviar: {callback_url!r} no es una acción de {self.np_api_url}")
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
            log(f"apim-mock: aviso {status or 'avance'} a {callback_url!r} → HTTP {code}")
        except Exception as error:
            log(f"apim-mock: falló el aviso a {callback_url!r}: {error}")


def timer_scheduler(delay, fn):
    timer = threading.Timer(delay, fn)
    timer.daemon = True
    timer.start()


def problem(status, title, detail):
    return status, {"type": "about:blank", "title": title, "status": status, "detail": detail}


def publish_error(message):
    return 400, {"status": "error", "message": message}


def body_hash(body):
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()


def public_operation(operation):
    return {field: operation[field] for field in PUBLIC_OPERATION_FIELDS if field in operation}


def publication_ref(body):
    return body.get("branch") or body.get("tag") or body.get("commit")


def callback_entity(callback_url):
    if not isinstance(callback_url, str):
        return None, None
    match = CALLBACK_ENTITY.search(urllib.parse.urlparse(callback_url).path)
    if not match:
        return None, None
    return match.group(1), match.group(2)


def credential_secret_name(subscription_id):
    return "apim-cred-" + hashlib.sha256(subscription_id.encode()).hexdigest()[:20]


def api_object_paths(namespace, name):
    return [
        f"{GATEWAY_API}/namespaces/{namespace}/httproutes/{name}",
        f"{KUADRANT_API}/namespaces/{namespace}/authpolicies/{name}",
        f"{KUADRANT_API}/namespaces/{namespace}/ratelimitpolicies/{name}",
    ]


def api_manifests(publication):
    namespace, name, api_id = publication["namespace"], publication["apiName"], publication["apiId"]
    labels = {**publication.get("labels", {}), "app.kubernetes.io/managed-by": "apim-mock", "api-id": api_id}
    metadata = {"name": name, "namespace": namespace, "labels": labels}
    target = {"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": name}
    backend = {"group": "", "kind": "Service", "name": name, "namespace": namespace, "port": 8080, "weight": 1}
    backend.update(publication.get("backend") or {})
    manifests = [
        (f"{GATEWAY_API}/namespaces/{namespace}/httproutes/{name}", {
            "apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute", "metadata": metadata,
            "spec": {"parentRefs": publication["parentRefs"], "hostnames": [publication["hostname"]],
                     "rules": [{"matches": [{"path": {"type": "PathPrefix", "value": "/"}}], "backendRefs": [backend]}]},
        }),
        (f"{KUADRANT_API}/namespaces/{namespace}/authpolicies/{name}", {
            "apiVersion": "kuadrant.io/v1", "kind": "AuthPolicy", "metadata": metadata,
            "spec": {"targetRef": target, "rules": {
                "authentication": {"apim-app-key": {
                    "apiKey": {"selector": {"matchLabels": {"api-id": api_id}}, "allNamespaces": True},
                    "credentials": {"customHeader": {"name": "app_key"}}}},
                "authorization": {"apim-app-id": {"patternMatching": {"patterns": [
                    {"predicate": "auth.identity.metadata.labels['app-id'] == request.headers.app_id"}]}}}}},
        }),
    ]
    if publication.get("window") and publication.get("hitsPerWindow"):
        manifests.append((f"{KUADRANT_API}/namespaces/{namespace}/ratelimitpolicies/{name}", {
            "apiVersion": "kuadrant.io/v1", "kind": "RateLimitPolicy", "metadata": metadata,
            "spec": {"targetRef": target, "limits": {"apim-limit": {"rates": [
                {"limit": publication["hitsPerWindow"], "window": publication["window"]}]}}},
        }))
    return manifests


class App:
    def __init__(self, store, k8s, notifier, scheduler, settings, link_service_id=None):
        self.link_service_id = link_service_id or (lambda link_id: None)
        self.store = store
        self.k8s = k8s
        self.notifier = notifier
        self.scheduler = scheduler
        self.settings = settings
        self.lock = threading.RLock()
        self.state = store.load()
        self.reschedule_pending()

    def reschedule_pending(self):
        for operation in list(self.state["operations"].values()):
            if operation.get("state") != "Committed":
                continue
            if operation.get("kind") == "subscription":
                self.schedule(self.complete_subscription, operation["id"])
            if operation.get("kind") == "planChange":
                self.schedule(self.complete_plan_change, operation["id"])
        for publication in list(self.state["publications"].values()):
            if publication.get("status") == "pushed":
                self.schedule(self.complete_publication, publication["apiId"], publication["ref"])

    def schedule(self, fn, *args):
        def run():
            try:
                fn(*args)
            except Exception as error:
                log(f"apim-mock: falló {fn.__name__}{args}: {error}")

        self.scheduler(self.settings["callback_delay"], run)

    def save(self):
        self.prune()
        self.store.save(self.state)

    def prune(self):
        limit = self.settings.get("max_history", 200)
        operations = self.state["operations"]
        finished = [op_id for op_id, operation in operations.items() if operation.get("state") != "Committed"]
        for op_id in finished[:max(0, len(operations) - limit)]:
            del operations[op_id]
        idempotency = self.state["idempotency"]
        for key in list(idempotency)[:max(0, len(idempotency) - limit)]:
            del idempotency[key]

    def authorized(self, headers):
        token = self.settings.get("token")
        if not token:
            return True
        lowered = {key.lower(): value for key, value in headers.items()}
        return hmac.compare_digest(lowered.get("authorization", "").encode(), f"Bearer {token}".encode())

    def handle(self, method, path, headers, raw):
        if path == "/healthz":
            return 200, {"status": "ok"}
        if not self.authorized(headers):
            return problem(401, "Unauthorized", "Falta el Bearer del mock o no coincide con MOCK_TOKEN.")
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            return problem(400, "Bad Request", "El cuerpo no es JSON válido.")
        if not isinstance(body, dict):
            return problem(400, "Bad Request", "El cuerpo tiene que ser un objeto JSON.")
        headers = {key.lower(): value for key, value in headers.items()}
        link_api_id = None
        if method == "POST" and path == "/v1/subscriptions":
            entity, entity_id = callback_entity(body.get("callbackUrl"))
            if entity == "link":
                service_id = self.link_service_id(entity_id)
                if not service_id:
                    return problem(503, "Service Unavailable", f"No se pudo leer el link {entity_id} en nullplatform; reintentá más tarde.")
                link_api_id = f"apim-{service_id}"
        outbox = []
        with self.lock:
            try:
                result = self.route(method, path, headers, body, outbox, link_api_id)
            except Exception as error:
                log(f"apim-mock: error en {method} {path}: {error}")
                outbox = []
                result = problem(500, "Internal Server Error", f"El mock falló: {error}")
        for notification in outbox:
            self.notifier.notify(*notification[:2], **notification[2])
        return result

    def route(self, method, path, headers, body, outbox, link_api_id=None):
        key = headers.get("idempotency-key", "")
        if path == "/v1/plans" and method == "GET":
            return 200, {"items": PLANS}
        if path == "/v1/subscriptions" and method == "POST":
            return self.create_subscription(body, key, outbox, link_api_id)
        match = re.fullmatch(r"/v1/subscriptions/([^/]+)", path)
        if match and method == "GET":
            return self.get_subscription(match.group(1))
        if match and method == "PATCH":
            return self.change_plan(match.group(1), body, key, outbox)
        if match and method == "DELETE":
            return self.revoke_subscription(match.group(1), key)
        match = re.fullmatch(r"/v1/operations/([^/]+)", path)
        if match and method == "GET":
            operation = self.state["operations"].get(match.group(1))
            if not operation:
                return problem(404, "Not Found", f"No existe la operación {match.group(1)}.")
            return 200, public_operation(operation)
        if path == "/v1/kuadrant/manifests/publish" and method == "POST":
            return self.publish(body, outbox)
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

    def replay(self, key, body):
        previous = self.state["idempotency"].get(key) if key else None
        if not previous:
            return None
        operation = self.state["operations"].get(previous["operation_id"])
        if not operation or operation.get("state") in FINAL_FAILED_STATES:
            return None
        if previous["hash"] != body_hash(body):
            return problem(422, "Unprocessable Entity", "La misma Idempotency-Key llegó con otro cuerpo.")
        return previous["status"], public_operation(operation)

    def remember(self, key, body, status, operation):
        if key:
            self.state["idempotency"][key] = {"hash": body_hash(body), "operation_id": operation["id"], "status": status}

    def new_operation(self, kind, target, callback_url):
        operation = {"id": str(uuid.uuid4()), "kind": kind, "state": "Committed", "target": target,
                     "callbackUrl": callback_url if isinstance(callback_url, str) else ""}
        self.state["operations"][operation["id"]] = operation
        return operation

    def namespace_allowed_for_objects(self, namespace):
        if namespace.startswith("kube-") or namespace == "default":
            return False
        allowed = self.settings.get("allowed_namespaces") or []
        if allowed:
            return namespace in allowed
        return bool(self.settings.get("allow_all_namespaces", False))

    def namespace_rejection(self, namespace):
        if namespace.startswith("kube-") or namespace == "default":
            return f"El namespace {namespace} no se puede suscribir desde el mock."
        if not self.settings.get("create_secret", True):
            return None
        allowed = self.settings.get("allowed_namespaces") or []
        if allowed and namespace not in allowed:
            return f"El namespace {namespace} no está en los namespaces permitidos del mock."
        if not allowed and not self.settings.get("allow_all_namespaces", False):
            return "El mock no tiene namespaces permitidos configurados para crear la credencial."
        return None

    def create_subscription(self, body, key, outbox, link_api_id=None):
        if not key:
            return problem(400, "Bad Request", "Falta el header Idempotency-Key.")
        replayed = self.replay(key, body)
        if replayed:
            return replayed
        invalid = [field for field in ("approvalRef", "consumerNamespace", "planId") if not is_text(body.get(field))]
        if invalid:
            return problem(400, "Bad Request", f"Faltan o no son texto: {', '.join(invalid)}.")
        ritm = body["approvalRef"]
        namespace = body["consumerNamespace"]
        if not NAMESPACE_PATTERN.fullmatch(namespace):
            return problem(400, "Bad Request", f"consumerNamespace no es un nombre DNS-1123: {namespace!r}.")
        rejection = self.namespace_rejection(namespace)
        if rejection:
            return problem(422, "Unprocessable Entity", rejection)
        digits = re.sub(r"[^0-9]", "", ritm) or "0"
        api_id = link_api_id or f"api-{digits}"
        subscription_id = f"sub-{api_id}--{namespace}"
        if ritm == RITM_UNAVAILABLE:
            return problem(503, "Service Unavailable", f"ServiceNow no responde (mock: {RITM_UNAVAILABLE}).")
        if ritm == RITM_NOT_APPROVED:
            return problem(422, "Unprocessable Entity",
                           "Tu solicitud no está aprobada en ServiceNow; volvé a enviarla cuando se apruebe.")
        if body["planId"] not in PLAN_IDS:
            return problem(422, "Plan inválido", f"El plan {body['planId']} no está en el catálogo.")
        if ritm == RITM_CONFLICT or subscription_id in self.state["subscriptions"]:
            return problem(409, "Conflict", f"El namespace {namespace} ya está suscripto a {api_id}: {subscription_id}")
        operation = self.new_operation("subscription", subscription_id, body.get("callbackUrl"))
        self.state["subscriptions"][subscription_id] = {
            "id": subscription_id, "apiId": api_id, "consumerNamespace": namespace, "planId": body["planId"],
            "approvalRef": ritm, "tenant": self.settings["tenant"], "state": "Syncing", "operationId": operation["id"],
            "credentialSecret": credential_secret_name(subscription_id),
        }
        self.remember(key, body, 202, operation)
        self.save()
        outbox.append((operation["callbackUrl"],
                       f"Solicitud {ritm} validada. Suscripción escrita en Git; aplicándola en los clusters.", {}))
        self.schedule(self.complete_subscription, operation["id"])
        return 202, public_operation(operation)

    def pending_subscription(self, operation_id):
        operation = self.state["operations"].get(operation_id)
        if not operation or operation.get("state") != "Committed":
            return None, None
        subscription = self.state["subscriptions"].get(operation["target"])
        if not subscription or subscription.get("operationId") != operation_id:
            return operation, None
        return operation, subscription

    def fail_operation(self, operation, state, detail, message, drop_subscription):
        if drop_subscription:
            del self.state["subscriptions"][operation["target"]]
        operation["state"] = state
        operation["error"] = {"detail": detail}
        self.save()
        return operation["callbackUrl"], message, {"level": "error", "status": "failed"}

    def complete_subscription(self, operation_id):
        with self.lock:
            operation, subscription = self.pending_subscription(operation_id)
            if not operation:
                return
            if not subscription:
                notification = self.fail_operation(operation, "RolledBack", "la suscripción se dio de baja antes de completarse",
                                                   "La suscripción se dio de baja antes de quedar activa.", False)
            elif subscription["approvalRef"] == RITM_ROLLBACK:
                notification = self.fail_operation(operation, "RolledBack", f"mock: {RITM_ROLLBACK}",
                                                   f"No se pudo completar (mock: {RITM_ROLLBACK}). Se deshizo; volvé a intentar más tarde.", True)
            else:
                notification = None
                namespace = subscription["consumerNamespace"]
                pending = dict(subscription)
        if notification is None:
            secret_created = self.ensure_credential_secret(namespace) and self.ensure_gateway_credential(pending)
            with self.lock:
                operation, subscription = self.pending_subscription(operation_id)
                if not operation:
                    return
                if not subscription:
                    notification = self.fail_operation(operation, "RolledBack", "la suscripción se dio de baja antes de completarse",
                                                       "La suscripción se dio de baja antes de quedar activa.", False)
                elif not secret_created:
                    notification = self.fail_operation(operation, "Failed", "no se pudo crear el Secret de la credencial",
                                                       "No se pudo aplicar en los clusters (el mock no pudo crear el Secret de la credencial).", True)
                else:
                    subscription["state"] = "Registered"
                    operation["state"] = "Registered"
                    self.save()
                    notification = (operation["callbackUrl"], "Suscripción activa y registrada en el catálogo de APIs.", {"status": "success"})
            if not subscription:
                self.delete_gateway_credential(pending)
        self.notifier.notify(*notification[:2], **notification[2])

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

    def ensure_gateway_credential(self, subscription):
        if not self.settings.get("create_secret", True):
            return True
        namespace = subscription["consumerNamespace"]
        credentials_namespace = self.settings.get("credentials_namespace", "kuadrant-system")
        name = subscription.get("credentialSecret") or credential_secret_name(subscription["id"])
        manifest = {
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {
                "name": name, "namespace": credentials_namespace,
                "labels": {"authorino.kuadrant.io/managed-by": "authorino", "app.kubernetes.io/managed-by": "apim-mock",
                           "api-id": subscription["apiId"], "app-id": f"mock-app-{namespace}", "consumer-ns": namespace},
                "annotations": {"secret.kuadrant.io/plan-id": subscription["planId"],
                                "apim.bancogalicia/approval-ref": subscription["approvalRef"]},
            },
            "stringData": {"api_key": f"mock-key-{namespace}"},
        }
        try:
            status, _ = self.k8s.request("APPLY", f"/api/v1/namespaces/{credentials_namespace}/secrets/{name}", manifest)
        except Exception as error:
            log(f"apim-mock: no se pudo crear la credencial del gateway para {subscription['id']}: {error}")
            return False
        if status not in (200, 201):
            log(f"apim-mock: no se pudo crear la credencial del gateway para {subscription['id']}: HTTP {status}")
            return False
        return True

    def delete_gateway_credential(self, subscription):
        if not self.settings.get("create_secret", True):
            return
        credentials_namespace = self.settings.get("credentials_namespace", "kuadrant-system")
        name = subscription.get("credentialSecret") or credential_secret_name(subscription["id"])
        try:
            self.k8s.request("DELETE", f"/api/v1/namespaces/{credentials_namespace}/secrets/{name}")
        except Exception as error:
            log(f"apim-mock: no se pudo borrar la credencial {name}: {error}")

    def get_subscription(self, subscription_id):
        subscription = self.state["subscriptions"].get(subscription_id)
        if not subscription:
            return problem(404, "Not Found", f"No existe la suscripción {subscription_id}.")
        return 200, {field: value for field, value in subscription.items() if field not in ("operationId", "credentialSecret")}

    def change_plan(self, subscription_id, body, key, outbox):
        if subscription_id not in self.state["subscriptions"]:
            return problem(404, "Not Found", f"No existe la suscripción {subscription_id}.")
        if not key:
            return problem(400, "Bad Request", "Falta el header Idempotency-Key.")
        replayed = self.replay(key, body)
        if replayed:
            return replayed
        plan_id = body.get("planId")
        if not is_text(plan_id):
            return problem(400, "Bad Request", "Falta planId o no es texto.")
        if plan_id not in PLAN_IDS:
            return problem(422, "Plan inválido", f"El plan {plan_id} no está en el catálogo.")
        operation = self.new_operation("planChange", subscription_id, body.get("callbackUrl"))
        operation["planId"] = plan_id
        self.remember(key, body, 202, operation)
        self.save()
        outbox.append((operation["callbackUrl"], f"Cambio de plan a {plan_id} escrito en Git; aplicándolo en los clusters.", {}))
        self.schedule(self.complete_plan_change, operation["id"])
        return 202, public_operation(operation)

    def complete_plan_change(self, operation_id):
        with self.lock:
            operation = self.state["operations"].get(operation_id)
            if not operation or operation.get("state") != "Committed":
                return
            subscription = self.state["subscriptions"].get(operation["target"])
            if not subscription:
                notification = self.fail_operation(operation, "RolledBack", "la suscripción ya no existe",
                                                   "No se pudo cambiar el plan: la suscripción ya no existe.", False)
            else:
                subscription["planId"] = operation["planId"]
                operation["state"] = "Registered"
                self.save()
                notification = (operation["callbackUrl"], f"Plan cambiado a {operation['planId']}.", {"status": "success"})
        self.notifier.notify(*notification[:2], **notification[2])

    def revoke_subscription(self, subscription_id, key):
        replayed = self.replay(key, {"revoke": subscription_id})
        if replayed:
            return replayed
        if subscription_id not in self.state["subscriptions"]:
            return problem(404, "Not Found", f"No existe la suscripción {subscription_id}.")
        self.delete_gateway_credential(self.state["subscriptions"][subscription_id])
        del self.state["subscriptions"][subscription_id]
        operation = self.new_operation("revoke", subscription_id, "")
        operation["state"] = "Succeeded"
        self.remember(key, {"revoke": subscription_id}, 202, operation)
        self.save()
        return 202, public_operation(operation)

    def validate_publication(self, body):
        if not is_text(body.get("tenant")):
            return "El tenant de publicación es obligatorio."
        for field in ("organization", "repository", "environment", "cluster"):
            if not is_text(body.get(field)):
                return f"El campo {field} es obligatorio."
        if body["environment"] not in ENVIRONMENTS:
            return f"El ambiente {body['environment']} no es válido; tiene que ser uno de {', '.join(ENVIRONMENTS)}."
        ref = publication_ref(body)
        if not is_text(ref):
            return "Se requiere al menos uno de branch, tag o commit."
        legajo = body.get("legajo")
        if legajo is not None and not (isinstance(legajo, str) and LEGAJO_PATTERN.fullmatch(legajo)):
            return "El legajo tiene que tener el formato l#######."
        window, hits = body.get("window"), body.get("hitsPerWindow")
        if window is not None or hits is not None:
            valid_hits = isinstance(hits, int) and not isinstance(hits, bool) and hits > 0
            if not (isinstance(window, str) and WINDOW_PATTERN.fullmatch(window) and valid_hits):
                return "El rate limit necesita window (por ejemplo 1m) y hitsPerWindow entero mayor a 0, los dos juntos."
        metadata = body.get("metadata")
        if not isinstance(metadata, dict):
            return "El campo metadata es obligatorio."
        for field in ("name", "namespace"):
            if not is_text(metadata.get(field)):
                return f"El campo metadata.{field} es obligatorio."
        parent_refs = metadata.get("parentRefs")
        if (not isinstance(parent_refs, list) or not parent_refs
                or not all(isinstance(ref, dict) and is_text(ref.get("name")) and is_text(ref.get("namespace")) for ref in parent_refs)):
            return "metadata.parentRefs necesita al menos un Gateway con name y namespace."
        hostnames = metadata.get("hostnames")
        if hostnames is not None and not (isinstance(hostnames, list) and all(is_text(host) for host in hostnames)):
            return "metadata.hostnames tiene que ser una lista de hostnames."
        backend = metadata.get("backend")
        if backend is not None and not (isinstance(backend, dict) and is_text(backend.get("name"))):
            return "metadata.backend tiene que tener al menos name."
        if not NAMESPACE_PATTERN.fullmatch(metadata["namespace"]) or not self.namespace_allowed_for_objects(metadata["namespace"]):
            return f"El mock no puede publicar en el namespace {metadata['namespace']}."
        return None

    def publish(self, body, outbox):
        error = self.validate_publication(body)
        if error:
            return publish_error(error)
        metadata = body["metadata"]
        name, namespace, tenant, environment = metadata["name"], metadata["namespace"], body["tenant"], body["environment"]
        entity, entity_id = callback_entity(body.get("callbackUrl"))
        api_id = f"apim-{entity_id}" if entity == "service" else f"{namespace}-{name}-{tenant}-1"
        ref = publication_ref(body)
        existing = self.state["publications"].get(api_id)
        if existing and existing["ref"] == ref:
            return publish_error(f"La API {api_id} ya está publicada en {ref}.")
        stale_paths = []
        if existing:
            previous = set(existing.get("stalePaths", [])) | set(api_object_paths(existing["namespace"], existing["apiName"]))
            stale_paths = sorted(previous - set(api_object_paths(namespace, name)))
        hostnames = metadata.get("hostnames") or [f"{namespace}-{name}-{tenant}-{environment}.{self.settings['domain']}"]
        callback_url = body.get("callbackUrl")
        publication = {
            "apiId": api_id, "ref": ref, "status": "pushed", "hostname": hostnames[0], "namespace": namespace,
            "apiName": name, "tenant": tenant, "environment": environment,
            "repository": f"{body['organization']}/{body['repository']}",
            "manifestPath": f"clusters/{body['cluster']}/apis/{namespace}/{name}",
            "callbackUrl": callback_url if isinstance(callback_url, str) else "",
            "labels": metadata.get("labels") or {}, "parentRefs": metadata["parentRefs"],
            "backend": metadata.get("backend") or {}, "window": body.get("window"), "hitsPerWindow": body.get("hitsPerWindow"),
            "stalePaths": stale_paths,
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
        outbox.append((publication["callbackUrl"], "Manifiestos pusheados a Git; Argo está sincronizando.", {}))
        self.schedule(self.complete_publication, api_id, ref)
        return 200, response

    def apply_api_objects(self, publication):
        for path, manifest in api_manifests(publication):
            try:
                status, _ = self.k8s.request("APPLY", path, manifest)
            except Exception as error:
                log(f"apim-mock: no se pudo aplicar {path}: {error}")
                return False
            if status not in (200, 201):
                log(f"apim-mock: no se pudo aplicar {path}: HTTP {status}")
                return False
        return True

    def delete_api_objects(self, publication):
        self.delete_paths(api_object_paths(publication["namespace"], publication["apiName"]) + publication.get("stalePaths", []))

    def delete_unused_objects(self, publication):
        applied = {path for path, _ in api_manifests(publication)}
        own = [path for path in api_object_paths(publication["namespace"], publication["apiName"]) if path not in applied]
        self.delete_paths(own + publication.get("stalePaths", []))

    def delete_paths(self, paths):
        for path in paths:
            try:
                self.k8s.request("DELETE", path)
            except Exception as error:
                log(f"apim-mock: no se pudo borrar {path}: {error}")

    def complete_publication(self, api_id, ref):
        with self.lock:
            publication = self.state["publications"].get(api_id)
            if not publication or publication["ref"] != ref or publication["status"] != "pushed":
                return
            pending = dict(publication)
        applied = pending["repository"].split("/", 1)[1].startswith("fail-") is False and self.apply_api_objects(pending)
        with self.lock:
            publication = self.state["publications"].get(api_id)
            current = publication and publication["ref"] == ref and publication["status"] == "pushed"
            if not current:
                notification = None
            elif not applied:
                del self.state["publications"][api_id]
                self.save()
                notification = (publication["callbackUrl"], "Argo no sincronizó (mock: repo fail-* o el cluster rechazó los manifiestos); se eliminaron los manifiestos.",
                                {"level": "error", "status": "failed"})
            else:
                publication["status"] = "registered"
                self.save()
                notification = (publication["callbackUrl"], f"API publicada y registrada en {publication['hostname']}.", {"status": "success"})
        if not publication or (current and not applied):
            self.delete_api_objects(pending)
        elif current:
            self.delete_unused_objects(pending)
        if notification:
            self.notifier.notify(*notification[:2], **notification[2])

    def unpublish(self, api_id):
        if api_id not in self.state["publications"]:
            return 404, {"status": "error", "message": f"No existe la publicación {api_id}."}
        self.delete_api_objects(self.state["publications"][api_id])
        del self.state["publications"][api_id]
        self.save()
        return 200, {"status": "deleted", "apiId": api_id}


def make_handler(app):
    class Handler(BaseHTTPRequestHandler):
        timeout = 10

        def send_json(self, status, body):
            payload = json.dumps(body).encode()
            content_type = "application/problem+json" if status >= 400 and "title" in body else "application/json"
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def respond(self):
            path = self.path.split("?", 1)[0]
            headers = dict(self.headers.items())
            if path != "/healthz" and not app.authorized(headers):
                self.send_json(*problem(401, "Unauthorized", "Falta el Bearer del mock o no coincide con MOCK_TOKEN."))
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if length < 0:
                self.send_json(*problem(400, "Bad Request", "Content-Length inválido."))
                return
            if length > MAX_BODY_BYTES:
                self.send_json(*problem(413, "Payload Too Large", f"El cuerpo supera {MAX_BODY_BYTES} bytes."))
                return
            raw = self.rfile.read(length) if length else b""
            try:
                status, body = app.handle(self.command, path, headers, raw)
            except Exception as error:
                log(f"apim-mock: error en {self.command} {path}: {error}")
                status, body = problem(500, "Internal Server Error", "El mock falló.")
            self.send_json(status, body)

        do_GET = respond
        do_POST = respond
        do_PATCH = respond
        do_DELETE = respond

        def log_message(self, format, *args):
            log(f"apim-mock: {self.command} {self.path!r} → {args[1] if len(args) > 1 else ''}")

    return Handler


def main():
    token = os.environ.get("MOCK_TOKEN", "")
    if not token:
        log("apim-mock: MOCK_TOKEN es obligatorio; sin token cualquiera podría crear Secrets con la ServiceAccount del mock.")
        sys.exit(1)
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
        "token": token,
        "tenant": os.environ.get("MOCK_TENANT", "b2c"),
        "callback_delay": float(os.environ.get("CALLBACK_DELAY_SECONDS", "5")),
        "domain": os.environ.get("PUBLISH_DOMAIN", "bancogalicia.com.ar"),
        "create_secret": os.environ.get("CREATE_CREDENTIAL_SECRET", "true") == "true",
        "own_namespace": namespace,
        "allowed_namespaces": [item for item in os.environ.get("ALLOWED_NAMESPACES", "").split(",") if item],
        "allow_all_namespaces": os.environ.get("ALLOW_ALL_NAMESPACES", "false") == "true",
        "credentials_namespace": os.environ.get("CREDENTIALS_NAMESPACE", "kuadrant-system"),
        "max_history": int(os.environ.get("MAX_HISTORY", "200")),
    }
    app = App(store, k8s, notifier, timer_scheduler, settings, notifier.link_service_id)
    port = int(os.environ.get("PORT", "8080"))
    log(f"apim-mock: escuchando en :{port} (estado en {type(store).__name__})")
    ThreadingHTTPServer(("0.0.0.0", port), make_handler(app)).serve_forever()


if __name__ == "__main__":
    main()
