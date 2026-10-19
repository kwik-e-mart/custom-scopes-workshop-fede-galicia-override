import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

import server


class FakeK8s:
    def __init__(self):
        self.calls = []
        self.objects = {}

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET":
            if path in self.objects:
                return 200, self.objects[path]
            return 404, {"kind": "Status", "code": 404}
        if method == "POST":
            name = body["metadata"]["name"]
            key = f"{path}/{name}"
            if key in self.objects:
                return 409, {"kind": "Status", "code": 409}
            self.objects[key] = body
            return 201, body
        if method == "PUT":
            self.objects[path] = body
            return 200, body
        return 405, None


class FakeNotifier:
    def __init__(self):
        self.calls = []

    def notify(self, callback_url, message, level="info", status=None):
        self.calls.append({"url": callback_url, "message": message, "level": level, "status": status})


class ManualScheduler:
    def __init__(self):
        self.pending = []

    def __call__(self, delay, fn):
        self.pending.append(fn)

    def run_all(self):
        while self.pending:
            self.pending.pop(0)()


CALLBACK = "https://api.nullplatform.com/service/svc-1/action/act-1"


def make_app(**config):
    k8s = FakeK8s()
    notifier = FakeNotifier()
    scheduler = ManualScheduler()
    settings = {"token": "", "tenant": "b2c", "callback_delay": 0, "domain": "bancogalicia.com.ar", "create_secret": True}
    settings.update(config)
    app = server.App(server.MemoryStore(), k8s, notifier, scheduler, settings)
    return app, k8s, notifier, scheduler


def call(app, method, path, body=None, headers=None):
    raw = json.dumps(body).encode() if body is not None else b""
    return app.handle(method, path, headers or {}, raw)


def subscribe(app, ritm="RITM0012345", ns="sigla-x-qa", plan="gold", key="act-1", callback=CALLBACK):
    return call(app, "POST", "/v1/subscriptions",
                {"approvalRef": ritm, "consumerNamespace": ns, "planId": plan, "callbackUrl": callback},
                {"Idempotency-Key": key})


class SubscriberTest(unittest.TestCase):
    def test_alta_responde_202_con_la_operacion_committed(self):
        app, _, _, _ = make_app()
        status, body = subscribe(app)
        self.assertEqual(status, 202)
        self.assertEqual(body["state"], "Committed")
        self.assertEqual(body["kind"], "subscription")
        self.assertEqual(body["target"], "sub-api-0012345--sigla-x-qa")

    def test_alta_avisa_el_avance_y_despues_el_exito(self):
        app, _, notifier, scheduler = make_app()
        subscribe(app)
        self.assertEqual([c["status"] for c in notifier.calls], [None])
        scheduler.run_all()
        self.assertEqual([c["status"] for c in notifier.calls], [None, "success"])
        self.assertTrue(all(c["url"] == CALLBACK for c in notifier.calls))

    def test_alta_exitosa_deja_el_secreto_del_namespace(self):
        app, k8s, _, scheduler = make_app()
        subscribe(app)
        scheduler.run_all()
        secret = k8s.objects["/api/v1/namespaces/sigla-x-qa/secrets/secret-apim-b2c"]
        self.assertEqual(secret["stringData"], {"app_id": "mock-app-sigla-x-qa", "app_key": "mock-key-sigla-x-qa"})

    def test_alta_exitosa_deja_la_suscripcion_registrada(self):
        app, _, _, scheduler = make_app()
        _, op = subscribe(app)
        scheduler.run_all()
        status, sub = call(app, "GET", "/v1/subscriptions/sub-api-0012345--sigla-x-qa")
        self.assertEqual(status, 200)
        self.assertEqual(sub["state"], "Registered")
        self.assertEqual(sub["consumerNamespace"], "sigla-x-qa")
        self.assertEqual(sub["planId"], "gold")
        _, operation = call(app, "GET", f"/v1/operations/{op['id']}")
        self.assertEqual(operation["state"], "Registered")

    def test_sin_crear_secretos_el_alta_igual_termina_registrada(self):
        app, k8s, notifier, scheduler = make_app(create_secret=False)
        subscribe(app)
        scheduler.run_all()
        self.assertEqual(notifier.calls[-1]["status"], "success")
        self.assertEqual([c for c in k8s.calls if "/secrets" in c[1]], [])

    def test_un_secreto_existente_no_rompe_el_alta(self):
        app, k8s, notifier, scheduler = make_app()
        k8s.objects["/api/v1/namespaces/sigla-x-qa/secrets/secret-apim-b2c"] = {"metadata": {"name": "secret-apim-b2c"}}
        subscribe(app)
        scheduler.run_all()
        self.assertEqual(notifier.calls[-1]["status"], "success")

    def test_repetir_namespace_y_api_responde_409_con_el_id(self):
        app, _, _, scheduler = make_app()
        subscribe(app, key="act-1")
        scheduler.run_all()
        status, body = subscribe(app, key="act-2")
        self.assertEqual(status, 409)
        self.assertIn("sub-api-0012345--sigla-x-qa", body["detail"])

    def test_otro_namespace_con_el_mismo_ritm_es_otra_suscripcion(self):
        app, _, _, _ = make_app()
        subscribe(app, key="act-1")
        status, body = subscribe(app, ns="otra-sigla-qa", key="act-2")
        self.assertEqual(status, 202)
        self.assertEqual(body["target"], "sub-api-0012345--otra-sigla-qa")

    def test_misma_idempotency_key_devuelve_la_misma_operacion(self):
        app, _, _, _ = make_app()
        _, first = subscribe(app, key="act-1")
        status, second = subscribe(app, key="act-1")
        self.assertEqual(status, 202)
        self.assertEqual(first["id"], second["id"])

    def test_misma_idempotency_key_con_otro_cuerpo_responde_422(self):
        app, _, _, _ = make_app()
        subscribe(app, key="act-1")
        status, _ = subscribe(app, plan="bronze", key="act-1")
        self.assertEqual(status, 422)

    def test_ritm_terminado_en_422_responde_422(self):
        app, _, _, _ = make_app()
        status, body = subscribe(app, ritm="RITM0000422")
        self.assertEqual(status, 422)
        self.assertIn("ServiceNow", body["detail"])

    def test_ritm_terminado_en_503_responde_503_sin_guardar_nada(self):
        app, _, _, _ = make_app()
        status, _ = subscribe(app, ritm="RITM0000503")
        self.assertEqual(status, 503)
        _, state = call(app, "GET", "/mock/state")
        self.assertEqual(state["subscriptions"], {})

    def test_ritm_terminado_en_409_responde_409_aunque_no_exista(self):
        app, _, _, _ = make_app()
        status, body = subscribe(app, ritm="RITM0000409")
        self.assertEqual(status, 409)
        self.assertIn("sub-api-0000409--sigla-x-qa", body["detail"])

    def test_ritm_terminado_en_666_falla_y_deshace_la_suscripcion(self):
        app, k8s, notifier, scheduler = make_app()
        _, op = subscribe(app, ritm="RITM0000666")
        scheduler.run_all()
        self.assertEqual(notifier.calls[-1]["status"], "failed")
        self.assertEqual(notifier.calls[-1]["level"], "error")
        status, _ = call(app, "GET", "/v1/subscriptions/sub-api-0000666--sigla-x-qa")
        self.assertEqual(status, 404)
        _, operation = call(app, "GET", f"/v1/operations/{op['id']}")
        self.assertEqual(operation["state"], "RolledBack")
        self.assertNotIn("/api/v1/namespaces/sigla-x-qa/secrets/secret-apim-b2c", k8s.objects)

    def test_plan_fuera_del_catalogo_responde_422(self):
        app, _, _, _ = make_app()
        status, body = subscribe(app, plan="platinum")
        self.assertEqual(status, 422)
        self.assertIn("Plan", body["title"] + body["detail"])

    def test_pedido_sin_campos_obligatorios_responde_400(self):
        app, _, _, _ = make_app()
        status, _ = call(app, "POST", "/v1/subscriptions", {"approvalRef": "RITM1"}, {"Idempotency-Key": "k"})
        self.assertEqual(status, 400)

    def test_cambio_de_plan_responde_202_y_aplica_el_plan_al_completar(self):
        app, _, notifier, scheduler = make_app()
        subscribe(app)
        scheduler.run_all()
        status, op = call(app, "PATCH", "/v1/subscriptions/sub-api-0012345--sigla-x-qa",
                          {"planId": "bronze", "callbackUrl": CALLBACK}, {"Idempotency-Key": "act-2"})
        self.assertEqual(status, 202)
        self.assertEqual(op["kind"], "planChange")
        scheduler.run_all()
        _, sub = call(app, "GET", "/v1/subscriptions/sub-api-0012345--sigla-x-qa")
        self.assertEqual(sub["planId"], "bronze")
        self.assertEqual(notifier.calls[-1]["status"], "success")

    def test_cambio_de_plan_de_una_suscripcion_inexistente_responde_404(self):
        app, _, _, _ = make_app()
        status, _ = call(app, "PATCH", "/v1/subscriptions/sub-api-1--x", {"planId": "gold"}, {})
        self.assertEqual(status, 404)

    def test_baja_responde_202_y_borra_la_suscripcion_pero_no_el_secreto(self):
        app, k8s, _, scheduler = make_app()
        subscribe(app)
        scheduler.run_all()
        status, op = call(app, "DELETE", "/v1/subscriptions/sub-api-0012345--sigla-x-qa", None, {"Idempotency-Key": "act-3"})
        self.assertEqual(status, 202)
        self.assertEqual(op["kind"], "revoke")
        status, _ = call(app, "GET", "/v1/subscriptions/sub-api-0012345--sigla-x-qa")
        self.assertEqual(status, 404)
        self.assertIn("/api/v1/namespaces/sigla-x-qa/secrets/secret-apim-b2c", k8s.objects)

    def test_baja_de_una_suscripcion_inexistente_responde_404(self):
        app, _, _, _ = make_app()
        status, _ = call(app, "DELETE", "/v1/subscriptions/sub-api-1--x", None, {})
        self.assertEqual(status, 404)

    def test_despues_de_la_baja_se_puede_volver_a_suscribir(self):
        app, _, _, scheduler = make_app()
        subscribe(app, key="act-1")
        scheduler.run_all()
        call(app, "DELETE", "/v1/subscriptions/sub-api-0012345--sigla-x-qa", None, {"Idempotency-Key": "act-2"})
        status, _ = subscribe(app, key="act-3")
        self.assertEqual(status, 202)

    def test_planes(self):
        app, _, _, _ = make_app()
        status, body = call(app, "GET", "/v1/plans")
        self.assertEqual(status, 200)
        self.assertEqual(body["items"], [{"id": "bronze", "maxTps": 5}, {"id": "gold", "maxTps": 20}, {"id": "no-limits"}])

    def test_operacion_inexistente_responde_404(self):
        app, _, _, _ = make_app()
        status, _ = call(app, "GET", "/v1/operations/nope")
        self.assertEqual(status, 404)


class AuthTest(unittest.TestCase):
    def test_con_token_configurado_rechaza_pedidos_sin_bearer(self):
        app, _, _, _ = make_app(token="secreto")
        status, _ = call(app, "GET", "/v1/plans")
        self.assertEqual(status, 401)

    def test_con_token_configurado_acepta_el_bearer_correcto(self):
        app, _, _, _ = make_app(token="secreto")
        status, _ = call(app, "GET", "/v1/plans", None, {"Authorization": "Bearer secreto"})
        self.assertEqual(status, 200)

    def test_healthz_no_pide_token(self):
        app, _, _, _ = make_app(token="secreto")
        status, _ = call(app, "GET", "/healthz")
        self.assertEqual(status, 200)


def publish_body(**overrides):
    body = {
        "organization": "zosc-zosconnect",
        "repository": "test-kuadrant",
        "branch": "master",
        "environment": "qas",
        "tenant": "b2c",
        "cluster": "cluster1",
        "legajo": "l0510541",
        "callbackUrl": CALLBACK,
        "metadata": {
            "name": "test-kuadrant",
            "namespace": "test-kuadrant",
            "labels": {"app": "test-kuadrant"},
            "parentRefs": [{"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": "gw-echoserver",
                            "namespace": "tenant-01-qas", "sectionName": "api"}],
        },
    }
    body.update(overrides)
    return body


PUBLISH = "/v1/kuadrant/manifests/publish"


class PublisherTest(unittest.TestCase):
    def test_publicar_responde_200_pushed_con_apiid_y_hostname(self):
        app, _, _, _ = make_app()
        status, body = call(app, "POST", PUBLISH, publish_body())
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "pushed")
        self.assertEqual(body["apiId"], "test-kuadrant-test-kuadrant-b2c-1")
        self.assertEqual(body["hostname"], "test-kuadrant-test-kuadrant-b2c-qas.bancogalicia.com.ar")
        self.assertEqual(body["manifestPath"], "clusters/cluster1/apis/test-kuadrant/test-kuadrant")
        self.assertEqual(body["repository"], "zosc-zosconnect/test-kuadrant")

    def test_publicar_usa_el_hostname_pedido(self):
        app, _, _, _ = make_app()
        body = publish_body()
        body["metadata"]["hostnames"] = ["api.custom.example"]
        _, response = call(app, "POST", PUBLISH, body)
        self.assertEqual(response["hostname"], "api.custom.example")

    def test_publicar_avisa_y_registra(self):
        app, _, notifier, scheduler = make_app()
        call(app, "POST", PUBLISH, publish_body())
        scheduler.run_all()
        self.assertEqual([c["status"] for c in notifier.calls], [None, "success"])
        _, state = call(app, "GET", "/mock/state")
        self.assertEqual(state["publications"]["test-kuadrant-test-kuadrant-b2c-1"]["status"], "registered")

    def test_republicar_el_mismo_ref_responde_400(self):
        app, _, _, scheduler = make_app()
        call(app, "POST", PUBLISH, publish_body())
        scheduler.run_all()
        status, body = call(app, "POST", PUBLISH, publish_body())
        self.assertEqual(status, 400)
        self.assertEqual(body["status"], "error")
        self.assertIn("ya está publicada", body["message"])

    def test_republicar_otro_ref_actualiza_la_publicacion(self):
        app, _, _, scheduler = make_app()
        call(app, "POST", PUBLISH, publish_body())
        scheduler.run_all()
        body = publish_body()
        body.pop("branch")
        body["commit"] = "a1b2c3d"
        status, response = call(app, "POST", PUBLISH, body)
        self.assertEqual(status, 200)
        _, state = call(app, "GET", "/mock/state")
        self.assertEqual(state["publications"][response["apiId"]]["ref"], "a1b2c3d")

    def test_repo_que_empieza_con_fail_avisa_falla_y_borra_la_publicacion(self):
        app, _, notifier, scheduler = make_app()
        body = publish_body(repository="fail-api")
        _, response = call(app, "POST", PUBLISH, body)
        scheduler.run_all()
        self.assertEqual(notifier.calls[-1]["status"], "failed")
        _, state = call(app, "GET", "/mock/state")
        self.assertNotIn(response["apiId"], state["publications"])

    def test_sin_branch_tag_ni_commit_responde_400(self):
        app, _, _, _ = make_app()
        body = publish_body()
        body.pop("branch")
        status, response = call(app, "POST", PUBLISH, body)
        self.assertEqual(status, 400)
        self.assertEqual(response["status"], "error")

    def test_legajo_con_formato_invalido_responde_400(self):
        app, _, _, _ = make_app()
        status, _ = call(app, "POST", PUBLISH, publish_body(legajo="510541"))
        self.assertEqual(status, 400)

    def test_ambiente_invalido_responde_400(self):
        app, _, _, _ = make_app()
        status, _ = call(app, "POST", PUBLISH, publish_body(environment="staging"))
        self.assertEqual(status, 400)

    def test_sin_tenant_responde_400_con_el_mensaje_del_contrato(self):
        app, _, _, _ = make_app()
        body = publish_body()
        body.pop("tenant")
        status, response = call(app, "POST", PUBLISH, body)
        self.assertEqual(status, 400)
        self.assertEqual(response["message"], "El tenant de publicación es obligatorio.")

    def test_sin_parentrefs_responde_400(self):
        app, _, _, _ = make_app()
        body = publish_body()
        body["metadata"]["parentRefs"] = []
        status, _ = call(app, "POST", PUBLISH, body)
        self.assertEqual(status, 400)

    def test_baja_provisoria_borra_la_publicacion(self):
        app, _, _, scheduler = make_app()
        call(app, "POST", PUBLISH, publish_body())
        scheduler.run_all()
        status, _ = call(app, "DELETE", "/v1/kuadrant/manifests/test-kuadrant-test-kuadrant-b2c-1")
        self.assertEqual(status, 200)
        status, _ = call(app, "DELETE", "/v1/kuadrant/manifests/test-kuadrant-test-kuadrant-b2c-1")
        self.assertEqual(status, 404)


class StateTest(unittest.TestCase):
    def test_reset_limpia_suscripciones_y_publicaciones(self):
        app, _, _, scheduler = make_app()
        subscribe(app)
        call(app, "POST", PUBLISH, publish_body())
        scheduler.run_all()
        status, _ = call(app, "POST", "/mock/reset")
        self.assertEqual(status, 200)
        _, state = call(app, "GET", "/mock/state")
        self.assertEqual(state["subscriptions"], {})
        self.assertEqual(state["publications"], {})

    def test_configmap_store_persiste_y_recupera_el_estado(self):
        k8s = FakeK8s()
        store = server.ConfigMapStore(k8s, "apim-mock", "apim-mock-state")
        self.assertEqual(store.load()["subscriptions"], {})
        state = store.load()
        state["subscriptions"]["sub-a--b"] = {"id": "sub-a--b"}
        store.save(state)
        reloaded = server.ConfigMapStore(k8s, "apim-mock", "apim-mock-state").load()
        self.assertEqual(reloaded["subscriptions"], {"sub-a--b": {"id": "sub-a--b"}})

    def test_configmap_store_crea_el_configmap_la_primera_vez_y_despues_lo_reemplaza(self):
        k8s = FakeK8s()
        store = server.ConfigMapStore(k8s, "apim-mock", "apim-mock-state")
        store.save(store.load())
        store.save(store.load())
        methods = [m for m, p, _ in k8s.calls if m in ("POST", "PUT")]
        self.assertEqual(methods, ["POST", "PUT"])

    def test_el_estado_sobrevive_a_un_reinicio_del_mock(self):
        k8s = FakeK8s()
        scheduler = ManualScheduler()
        settings = {"token": "", "tenant": "b2c", "callback_delay": 0, "domain": "bancogalicia.com.ar"}
        first = server.App(server.ConfigMapStore(k8s, "apim-mock", "apim-mock-state"), k8s, FakeNotifier(), scheduler, settings)
        subscribe(first)
        scheduler.run_all()
        second = server.App(server.ConfigMapStore(k8s, "apim-mock", "apim-mock-state"), k8s, FakeNotifier(), ManualScheduler(), settings)
        status, _ = subscribe(second, key="act-9")
        self.assertEqual(status, 409)


class NotifierTest(unittest.TestCase):
    def test_canjea_la_api_key_y_hace_patch_al_callback(self):
        calls = []

        def http(method, url, headers, body):
            calls.append((method, url, headers, body))
            if url.endswith("/token"):
                return 200, {"access_token": "tok-np"}
            return 200, {}

        notifier = server.Notifier("https://api.nullplatform.com", "np-key", http)
        notifier.notify(CALLBACK, "listo", status="success")
        self.assertEqual(calls[0][0], "POST")
        self.assertEqual(calls[0][3], {"api_key": "np-key"})
        method, url, headers, body = calls[1]
        self.assertEqual((method, url), ("PATCH", CALLBACK))
        self.assertEqual(headers["Authorization"], "Bearer tok-np")
        self.assertEqual(body, {"status": "success", "messages": [{"level": "info", "message": "listo"}]})

    def test_un_aviso_de_avance_no_manda_status(self):
        calls = []

        def http(method, url, headers, body):
            calls.append(body)
            return 200, {"access_token": "t"}

        server.Notifier("https://api.nullplatform.com", "k", http).notify(CALLBACK, "en curso")
        self.assertEqual(calls[-1], {"messages": [{"level": "info", "message": "en curso"}]})

    def test_sin_api_key_no_llama_a_nadie(self):
        calls = []
        server.Notifier("https://api.nullplatform.com", "", lambda *a: calls.append(a)).notify(CALLBACK, "x", status="success")
        self.assertEqual(calls, [])

    def test_sin_callback_url_no_llama_a_nadie(self):
        calls = []
        server.Notifier("https://api.nullplatform.com", "k", lambda *a: calls.append(a)).notify("", "x", status="success")
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
