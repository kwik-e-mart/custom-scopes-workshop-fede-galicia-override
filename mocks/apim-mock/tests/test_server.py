import http.client
import json
import os
import subprocess
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

import server


class FakeK8s:
    def __init__(self):
        self.calls = []
        self.objects = {}
        self.fail_apply_for = ""
        self.during_apply = None

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
        if method == "APPLY":
            if self.during_apply:
                hook, self.during_apply = self.during_apply, None
                hook()
            if self.fail_apply_for and self.fail_apply_for in path:
                return 403, {"kind": "Status", "code": 403}
            self.objects[path] = body
            return 200, body
        if method == "DELETE":
            if path in self.objects:
                del self.objects[path]
                return 200, {}
            return 404, {"kind": "Status", "code": 404}
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


def make_app(link_services=None, **config):
    k8s = FakeK8s()
    notifier = FakeNotifier()
    scheduler = ManualScheduler()
    links = link_services or {}
    settings = {"token": "", "tenant": "b2c", "callback_delay": 0, "domain": "bancogalicia.com.ar",
                "create_secret": True, "own_namespace": "apim-mock", "allowed_namespaces": [], "allow_all_namespaces": True,
                "max_history": 200}
    settings.update(config)
    app = server.App(server.MemoryStore(), k8s, notifier, scheduler, settings, links.get)
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
        status, body = subscribe(app, ritm="RITM9990422")
        self.assertEqual(status, 422)
        self.assertIn("ServiceNow", body["detail"])

    def test_ritm_terminado_en_503_responde_503_sin_guardar_nada(self):
        app, _, _, _ = make_app()
        status, _ = subscribe(app, ritm="RITM9990503")
        self.assertEqual(status, 503)
        _, state = call(app, "GET", "/mock/state")
        self.assertEqual(state["subscriptions"], {})

    def test_ritm_terminado_en_409_responde_409_aunque_no_exista(self):
        app, _, _, _ = make_app()
        status, body = subscribe(app, ritm="RITM9990409")
        self.assertEqual(status, 409)
        self.assertIn("sub-api-9990409--sigla-x-qa", body["detail"])

    def test_ritm_terminado_en_666_falla_y_deshace_la_suscripcion(self):
        app, k8s, notifier, scheduler = make_app()
        _, op = subscribe(app, ritm="RITM9990666")
        scheduler.run_all()
        self.assertEqual(notifier.calls[-1]["status"], "failed")
        self.assertEqual(notifier.calls[-1]["level"], "error")
        status, _ = call(app, "GET", "/v1/subscriptions/sub-api-9990666--sigla-x-qa")
        self.assertEqual(status, 404)
        _, operation = call(app, "GET", f"/v1/operations/{op['id']}")
        self.assertEqual(operation["state"], "RolledBack")
        self.assertNotIn("/api/v1/namespaces/sigla-x-qa/secrets/secret-apim-b2c", k8s.objects)

    def test_un_namespace_que_no_es_dns_1123_responde_400_sin_tocar_kubernetes(self):
        app, k8s, _, _ = make_app()
        status, _ = subscribe(app, ns="../kube-system")
        self.assertEqual(status, 400)
        self.assertEqual(k8s.calls, [])

    def test_plan_fuera_del_catalogo_responde_422(self):
        app, _, _, _ = make_app()
        status, body = subscribe(app, plan="platinum")
        self.assertEqual(status, 422)
        self.assertIn("Plan", body["title"] + body["detail"])

    def test_un_ritm_que_termina_como_un_centinela_es_un_alta_normal(self):
        app, _, _, _ = make_app()
        status, _ = subscribe(app, ritm="RITM0012503")
        self.assertEqual(status, 202)

    def test_alta_sin_idempotency_key_responde_400(self):
        app, _, _, _ = make_app()
        status, body = call(app, "POST", "/v1/subscriptions",
                            {"approvalRef": "RITM1", "consumerNamespace": "ns-a", "planId": "gold"})
        self.assertEqual(status, 400)
        self.assertIn("Idempotency-Key", body["detail"])

    def test_la_operacion_que_devuelve_no_expone_el_callback(self):
        app, _, _, _ = make_app()
        _, body = subscribe(app)
        self.assertEqual(sorted(body), ["id", "kind", "state", "target"])

    def test_un_cuerpo_que_no_es_un_objeto_responde_400(self):
        app, _, _, _ = make_app()
        for path in ("/v1/subscriptions", PUBLISH):
            status, _ = call(app, "POST", path, [], {"Idempotency-Key": "k"})
            self.assertEqual(status, 400, path)

    def test_campos_con_tipo_incorrecto_responden_400(self):
        app, _, _, _ = make_app()
        status, _ = call(app, "POST", "/v1/subscriptions",
                         {"approvalRef": 1, "consumerNamespace": "ns-a", "planId": "gold"}, {"Idempotency-Key": "k1"})
        self.assertEqual(status, 400)
        status, _ = call(app, "POST", "/v1/subscriptions",
                         {"approvalRef": "RITM1", "consumerNamespace": ["ns"], "planId": "gold"}, {"Idempotency-Key": "k2"})
        self.assertEqual(status, 400)

    def test_un_namespace_con_salto_de_linea_responde_400(self):
        app, k8s, _, _ = make_app()
        status, _ = subscribe(app, ns="sigla-x-qa\n")
        self.assertEqual(status, 400)
        self.assertEqual(k8s.calls, [])

    def test_un_namespace_del_sistema_no_se_puede_suscribir(self):
        app, _, _, _ = make_app()
        for ns in ("kube-system", "default"):
            status, _ = subscribe(app, ns=ns, key=f"k-{ns}")
            self.assertEqual(status, 422, ns)

    def test_sin_lista_y_sin_permitir_todos_rechaza_el_alta(self):
        app, _, _, _ = make_app(allow_all_namespaces=False)
        status, body = subscribe(app)
        self.assertEqual(status, 422)
        self.assertIn("permitidos", body["detail"])

    def test_el_namespace_del_mock_se_puede_suscribir(self):
        app, _, _, _ = make_app(own_namespace="payments")
        status, _ = subscribe(app, ns="payments")
        self.assertEqual(status, 202)

    def test_con_namespaces_permitidos_rechaza_los_demas(self):
        app, _, _, _ = make_app(allowed_namespaces=["sigla-x-qa"])
        self.assertEqual(subscribe(app, key="k1")[0], 202)
        self.assertEqual(subscribe(app, ns="otra-qa", key="k2")[0], 422)

    def test_si_no_se_puede_guardar_el_estado_responde_500(self):
        app, _, _, _ = make_app()

        def broken(state):
            raise RuntimeError("configmap lleno")

        app.store.save = broken
        status, _ = subscribe(app)
        self.assertEqual(status, 500)

    def test_si_no_se_puede_guardar_al_completar_el_timer_no_se_cae(self):
        app, _, _, scheduler = make_app()
        subscribe(app)

        def broken(state):
            raise RuntimeError("configmap lleno")

        app.store.save = broken
        scheduler.run_all()

    def test_el_historial_de_operaciones_tiene_tope(self):
        app, _, _, scheduler = make_app(max_history=5)
        for number in range(12):
            subscribe(app, ritm=f"RITM{number:07d}", key=f"k{number}")
        scheduler.run_all()
        _, state = call(app, "GET", "/mock/state")
        self.assertLessEqual(len(state["operations"]), 5)
        self.assertLessEqual(len(state["idempotency"]), 5)
        self.assertEqual(len(state["subscriptions"]), 12)

    def test_los_avisos_se_mandan_sin_tener_el_lock(self):
        app, _, _, scheduler = make_app()
        free = []

        class LockProbe:
            def notify(self, *args, **kwargs):
                result = []

                def try_lock():
                    acquired = app.lock.acquire(timeout=0.2)
                    if acquired:
                        app.lock.release()
                    result.append(acquired)

                probe = threading.Thread(target=try_lock)
                probe.start()
                probe.join()
                free.append(result[0])

        app.notifier = LockProbe()
        subscribe(app)
        scheduler.run_all()
        call(app, "POST", PUBLISH, publish_body())
        scheduler.run_all()
        self.assertEqual(len(free), 4)
        self.assertTrue(all(free))

    def test_al_reiniciar_reprograma_las_operaciones_pendientes(self):
        k8s = FakeK8s()
        settings = {"token": "", "tenant": "b2c", "callback_delay": 0, "domain": "bancogalicia.com.ar", "create_secret": True,
                    "allow_all_namespaces": True}
        first = server.App(server.ConfigMapStore(k8s, "apim-mock", "apim-mock-state"), k8s, FakeNotifier(), ManualScheduler(), settings)
        subscribe(first)
        call(first, "POST", PUBLISH, publish_body())
        notifier = FakeNotifier()
        scheduler = ManualScheduler()
        second = server.App(server.ConfigMapStore(k8s, "apim-mock", "apim-mock-state"), k8s, notifier, scheduler, settings)
        scheduler.run_all()
        self.assertEqual([c["status"] for c in notifier.calls], ["success", "success"])
        _, sub = call(second, "GET", "/v1/subscriptions/sub-api-0012345--sigla-x-qa")
        self.assertEqual(sub["state"], "Registered")

    def test_una_baja_durante_un_alta_pendiente_no_completa_la_suscripcion_nueva(self):
        app, _, notifier, scheduler = make_app()
        _, first = subscribe(app, key="k1", callback="https://api.nullplatform.com/service/s/action/a1")
        call(app, "DELETE", "/v1/subscriptions/sub-api-0012345--sigla-x-qa", None, {"Idempotency-Key": "k2"})
        _, second = subscribe(app, key="k3", callback="https://api.nullplatform.com/service/s/action/a3")
        scheduler.run_all()
        finals = [c for c in notifier.calls if c["status"]]
        self.assertEqual([c["url"] for c in finals if c["status"] == "success"], ["https://api.nullplatform.com/service/s/action/a3"])
        _, op1 = call(app, "GET", f"/v1/operations/{first['id']}")
        _, op2 = call(app, "GET", f"/v1/operations/{second['id']}")
        self.assertNotEqual(op1["state"], "Registered")
        self.assertEqual(op2["state"], "Registered")

    def test_baja_repetida_con_la_misma_key_devuelve_la_misma_operacion(self):
        app, _, _, scheduler = make_app()
        subscribe(app)
        scheduler.run_all()
        _, first = call(app, "DELETE", "/v1/subscriptions/sub-api-0012345--sigla-x-qa", None, {"Idempotency-Key": "k9"})
        status, second = call(app, "DELETE", "/v1/subscriptions/sub-api-0012345--sigla-x-qa", None, {"Idempotency-Key": "k9"})
        self.assertEqual(status, 202)
        self.assertEqual(first["id"], second["id"])

    def test_reset_con_operaciones_pendientes_no_rompe_los_timers(self):
        app, _, _, scheduler = make_app()
        subscribe(app)
        call(app, "POST", "/mock/reset")
        scheduler.run_all()

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
        "origen": "nullplatform",
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
        self.assertEqual(body["status"], "commited")
        self.assertEqual(body["apiId"], "apim-svc-1")
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
        self.assertEqual(state["publications"]["apim-svc-1"]["status"], "registered")

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
        status, _ = call(app, "DELETE", "/v1/kuadrant/manifests/apim-svc-1")
        self.assertEqual(status, 200)
        status, _ = call(app, "DELETE", "/v1/kuadrant/manifests/apim-svc-1")
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
        settings = {"token": "", "tenant": "b2c", "callback_delay": 0, "domain": "bancogalicia.com.ar", "allow_all_namespaces": True}
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

    def test_no_manda_el_token_a_un_callback_fuera_de_nullplatform(self):
        calls = []
        server.Notifier("https://api.nullplatform.com", "k", lambda *a: calls.append(a)).notify("https://evil.example/x", "x", status="success")
        self.assertEqual(calls, [])

    def test_no_acepta_un_host_que_solo_empieza_igual(self):
        calls = []
        server.Notifier("https://api.nullplatform.com", "k", lambda *a: calls.append(a)).notify("https://api.nullplatform.com.evil.example/x", "x")
        self.assertEqual(calls, [])

    def test_solo_avisa_a_rutas_de_acciones_de_nullplatform(self):
        calls = []
        notifier = server.Notifier("https://api.nullplatform.com", "k", lambda *a: calls.append(a) or (200, {"access_token": "t"}))
        notifier.notify("https://api.nullplatform.com/user/1", "x")
        notifier.notify("https://api.nullplatform.com/service/s/action/a?x=1", "x")
        self.assertEqual(calls, [])
        notifier.notify("https://api.nullplatform.com/link/l-1/action/a-1", "x")
        self.assertEqual(calls[-1][1], "https://api.nullplatform.com/link/l-1/action/a-1")

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


class HttpTest(unittest.TestCase):
    def setUp(self):
        self.app, _, _, _ = make_app(token="secreto")
        self.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.app))
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.port = self.httpd.server_address[1]

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def send(self, method, path, headers, body=b""):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.putrequest(method, path)
        for key, value in headers.items():
            connection.putheader(key, value)
        connection.endheaders()
        if body:
            connection.send(body)
        response = connection.getresponse()
        status = response.status
        connection.close()
        return status

    def test_sin_bearer_responde_401_sin_leer_el_cuerpo(self):
        status = self.send("POST", "/v1/subscriptions", {"Content-Length": "1000000000"})
        self.assertEqual(status, 401)

    def test_un_cuerpo_demasiado_grande_responde_413(self):
        status = self.send("POST", "/v1/subscriptions", {"Authorization": "Bearer secreto", "Content-Length": "1000000000"})
        self.assertEqual(status, 413)

    def test_un_content_length_invalido_responde_400(self):
        status = self.send("POST", "/v1/subscriptions", {"Authorization": "Bearer secreto", "Content-Length": "-1"})
        self.assertEqual(status, 400)

    def test_un_error_inesperado_responde_500_y_no_corta_la_conexion(self):
        def explode(*args):
            raise ValueError("boom")

        self.app.route = explode
        body = b"{}"
        status = self.send("POST", "/v1/subscriptions", {"Authorization": "Bearer secreto", "Content-Length": str(len(body))}, body)
        self.assertEqual(status, 500)


class MainTest(unittest.TestCase):
    def test_sin_mock_token_arranca_y_avisa_que_no_pide_autenticacion(self):
        env = {key: value for key, value in os.environ.items() if key != "MOCK_TOKEN"}
        env.update({"STATE_BACKEND": "memory", "PORT": "0"})
        process = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(__file__), "..", "app", "server.py")],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                process.wait(timeout=2)
        finally:
            process.kill()
            _, stderr = process.communicate()
        self.assertIn("sin MOCK_TOKEN el mock no pide autenticación", stderr)


ROUTE = "/apis/gateway.networking.k8s.io/v1/namespaces/test-kuadrant/httproutes/test-kuadrant"
AUTH = "/apis/kuadrant.io/v1/namespaces/test-kuadrant/authpolicies/test-kuadrant"
RLP = "/apis/kuadrant.io/v1/namespaces/test-kuadrant/ratelimitpolicies/test-kuadrant"
LINK_CALLBACK = "https://api.nullplatform.com/link/l-1/action/a-1"


class PublishedObjectsTest(unittest.TestCase):
    def test_el_api_id_es_apim_mas_el_id_del_service_del_callback(self):
        app, _, _, _ = make_app()
        _, body = call(app, "POST", PUBLISH, publish_body())
        self.assertEqual(body["apiId"], "apim-svc-1")

    def test_sin_callback_de_service_usa_el_api_id_de_apim(self):
        app, _, _, _ = make_app()
        _, body = call(app, "POST", PUBLISH, publish_body(callbackUrl=""))
        self.assertEqual(body["apiId"], "test-kuadrant-test-kuadrant-b2c-1")

    def test_publicar_crea_la_ruta_la_authpolicy_y_el_rate_limit(self):
        app, k8s, notifier, scheduler = make_app()
        _, response = call(app, "POST", PUBLISH, publish_body(window="1m", hitsPerWindow=100))
        scheduler.run_all()
        self.assertEqual(notifier.calls[-1]["status"], "success")
        route = k8s.objects[ROUTE]
        self.assertEqual(route["kind"], "HTTPRoute")
        self.assertEqual(route["spec"]["parentRefs"], publish_body()["metadata"]["parentRefs"])
        self.assertEqual(route["spec"]["hostnames"], [response["hostname"]])
        self.assertEqual(route["spec"]["rules"][0]["matches"], [{"path": {"type": "PathPrefix", "value": "/"}}])
        self.assertEqual(route["spec"]["rules"][0]["backendRefs"],
                         [{"group": "", "kind": "Service", "name": "test-kuadrant", "namespace": "test-kuadrant", "port": 8080, "weight": 1}])
        auth = k8s.objects[AUTH]
        self.assertEqual(auth["spec"]["targetRef"]["name"], "test-kuadrant")
        key = auth["spec"]["rules"]["authentication"]["apim-app-key"]
        self.assertEqual(key["apiKey"]["selector"]["matchLabels"], {"api-id": "apim-svc-1"})
        self.assertEqual(key["credentials"], {"customHeader": {"name": "app_key"}})
        self.assertIn("request.headers.app_id", json.dumps(auth["spec"]["rules"]["authorization"]))
        self.assertEqual(k8s.objects[RLP]["spec"]["limits"]["apim-limit"]["rates"], [{"limit": 100, "window": "1m"}])

    def test_con_destino_reescribe_el_host_y_manda_al_gateway(self):
        app, k8s, _, scheduler = make_app()
        body = publish_body()
        body["metadata"]["backend"] = {"kind": "Service", "name": "gateway-private", "namespace": "gateways", "port": 8080,
                                       "destinationFqdn": "test-kuadrant-main.ms.ws.bancogalicia.com.ar"}
        call(app, "POST", PUBLISH, body)
        scheduler.run_all()
        rule = k8s.objects[ROUTE]["spec"]["rules"][0]
        self.assertEqual(rule["backendRefs"],
                         [{"group": "", "kind": "Service", "name": "gateway-private", "namespace": "gateways", "port": 8080, "weight": 1}])
        self.assertEqual(rule["filters"],
                         [{"type": "URLRewrite", "urlRewrite": {"hostname": "test-kuadrant-main.ms.ws.bancogalicia.com.ar"}}])

    def test_con_paths_configurados_la_ruta_solo_acepta_esos_paths(self):
        app, k8s, _, scheduler = make_app(route_paths=["/whoami", "/health"])
        call(app, "POST", PUBLISH, publish_body())
        scheduler.run_all()
        self.assertEqual(k8s.objects[ROUTE]["spec"]["rules"][0]["matches"],
                         [{"path": {"type": "Exact", "value": "/whoami"}}, {"path": {"type": "Exact", "value": "/health"}}])

    def test_sin_destino_la_ruta_no_reescribe(self):
        app, k8s, _, scheduler = make_app()
        call(app, "POST", PUBLISH, publish_body())
        scheduler.run_all()
        self.assertNotIn("filters", k8s.objects[ROUTE]["spec"]["rules"][0])

    def test_un_destino_que_no_es_un_hostname_responde_400(self):
        for fqdn in ["https://app.bancogalicia.com.ar", "app.bancogalicia.com.ar/path", "app.bancogalicia.com.ar:443", "a b", "", 8080]:
            app, _, _, _ = make_app()
            body = publish_body()
            body["metadata"]["backend"] = {"kind": "Service", "name": "gateway-private", "namespace": "gateways", "port": 8080, "destinationFqdn": fqdn}
            status, response = call(app, "POST", PUBLISH, body)
            self.assertEqual(status, 400, fqdn)
            self.assertIn("destinationFqdn", response["message"], fqdn)

    def test_sin_origen_responde_400(self):
        app, _, _, _ = make_app()
        body = publish_body()
        del body["origen"]
        status, response = call(app, "POST", PUBLISH, body)
        self.assertEqual(status, 400)
        self.assertIn("origen", response["message"])

    def test_el_backend_del_pedido_reemplaza_al_default(self):
        app, k8s, _, scheduler = make_app()
        body = publish_body()
        body["metadata"]["backend"] = {"kind": "Service", "name": "d-1-2", "namespace": "test-kuadrant", "port": 8080}
        call(app, "POST", PUBLISH, body)
        scheduler.run_all()
        self.assertEqual(k8s.objects[ROUTE]["spec"]["rules"][0]["backendRefs"][0]["name"], "d-1-2")

    def test_rate_limit_invalido_responde_400(self):
        for window, hits in [("1m", None), (None, 10), ("1 minuto", 10), ("1m", "10"), ("1m", 0), ("1m", True)]:
            fields = {key: value for key, value in (("window", window), ("hitsPerWindow", hits)) if value is not None}
            app, _, _, _ = make_app()
            status, body = call(app, "POST", PUBLISH, publish_body(**fields))
            self.assertEqual((status, body["status"]), (400, "error"), fields)
            self.assertIn("window", body["message"], fields)

    def test_sin_rate_limit_no_crea_ratelimitpolicy(self):
        app, k8s, _, scheduler = make_app()
        call(app, "POST", PUBLISH, publish_body())
        scheduler.run_all()
        self.assertNotIn(RLP, k8s.objects)

    def test_si_kubernetes_rechaza_la_ruta_la_publicacion_se_cancela(self):
        app, k8s, notifier, scheduler = make_app()
        k8s.fail_apply_for = "/httproutes/"
        _, response = call(app, "POST", PUBLISH, publish_body())
        scheduler.run_all()
        self.assertEqual(notifier.calls[-1]["status"], "failed")
        _, state = call(app, "GET", "/mock/state")
        self.assertNotIn(response["apiId"], state["publications"])

    def test_publicar_en_un_namespace_no_permitido_responde_400(self):
        app, _, _, _ = make_app(allow_all_namespaces=False, allowed_namespaces=["payments"])
        status, body = call(app, "POST", PUBLISH, publish_body())
        self.assertEqual(status, 400)
        self.assertIn("test-kuadrant", body["message"])

    def test_si_falla_la_authpolicy_no_queda_la_ruta_sin_autenticacion(self):
        app, k8s, notifier, scheduler = make_app()
        k8s.fail_apply_for = "/authpolicies/"
        call(app, "POST", PUBLISH, publish_body(window="1m", hitsPerWindow=100))
        scheduler.run_all()
        self.assertEqual(notifier.calls[-1]["status"], "failed")
        self.assertNotIn(ROUTE, k8s.objects)

    def test_una_baja_durante_la_publicacion_no_deja_objetos(self):
        app, k8s, _, scheduler = make_app()
        _, response = call(app, "POST", PUBLISH, publish_body(window="1m", hitsPerWindow=100))
        k8s.during_apply = lambda: call(app, "DELETE", f"/v1/kuadrant/manifests/{response['apiId']}")
        scheduler.run_all()
        for path in (ROUTE, AUTH, RLP):
            self.assertNotIn(path, k8s.objects)

    def test_republicar_con_otro_nombre_borra_los_objetos_viejos(self):
        app, k8s, _, scheduler = make_app()
        call(app, "POST", PUBLISH, publish_body(window="1m", hitsPerWindow=100))
        scheduler.run_all()
        body = publish_body(branch="develop", window="1m", hitsPerWindow=100)
        body["metadata"]["name"] = "otra-api"
        call(app, "POST", PUBLISH, body)
        scheduler.run_all()
        for path in (ROUTE, AUTH, RLP):
            self.assertNotIn(path, k8s.objects)
        self.assertIn("/apis/gateway.networking.k8s.io/v1/namespaces/test-kuadrant/httproutes/otra-api", k8s.objects)

    def test_republicar_sin_rate_limit_borra_la_ratelimitpolicy(self):
        app, k8s, _, scheduler = make_app()
        call(app, "POST", PUBLISH, publish_body(window="1m", hitsPerWindow=100))
        scheduler.run_all()
        call(app, "POST", PUBLISH, publish_body(branch="develop"))
        scheduler.run_all()
        self.assertNotIn(RLP, k8s.objects)
        self.assertIn(ROUTE, k8s.objects)

    def test_si_falla_la_republicacion_no_quedan_los_objetos_viejos(self):
        app, k8s, notifier, scheduler = make_app()
        call(app, "POST", PUBLISH, publish_body(window="1m", hitsPerWindow=100))
        scheduler.run_all()
        body = publish_body(branch="develop")
        body["metadata"]["name"] = "otra-api"
        k8s.fail_apply_for = "/authpolicies/"
        call(app, "POST", PUBLISH, body)
        scheduler.run_all()
        self.assertEqual(notifier.calls[-1]["status"], "failed")
        self.assertEqual([p for p in k8s.objects if "/apis/" in p], [])

    def test_la_baja_provisoria_borra_los_objetos(self):
        app, k8s, _, scheduler = make_app()
        _, response = call(app, "POST", PUBLISH, publish_body(window="1m", hitsPerWindow=100))
        scheduler.run_all()
        call(app, "DELETE", f"/v1/kuadrant/manifests/{response['apiId']}")
        for path in (ROUTE, AUTH, RLP):
            self.assertNotIn(path, k8s.objects)


class LinkSubscriptionTest(unittest.TestCase):
    def test_la_suscripcion_de_un_link_apunta_a_la_api_del_service_del_link(self):
        app, _, _, _ = make_app(link_services={"l-1": "svc-pub"})
        status, body = subscribe(app, callback=LINK_CALLBACK)
        self.assertEqual(status, 202)
        self.assertEqual(body["target"], "sub-apim-svc-pub--sigla-x-qa")

    def test_la_suscripcion_crea_la_credencial_que_lee_la_authpolicy(self):
        app, k8s, notifier, scheduler = make_app(link_services={"l-1": "svc-pub"})
        subscribe(app, plan="gold", callback=LINK_CALLBACK)
        scheduler.run_all()
        self.assertEqual(notifier.calls[-1]["status"], "success")
        credentials = [o for p, o in k8s.objects.items() if p.startswith("/api/v1/namespaces/kuadrant-system/secrets/")]
        self.assertEqual(len(credentials), 1)
        labels = credentials[0]["metadata"]["labels"]
        self.assertEqual(labels["authorino.kuadrant.io/managed-by"], "authorino")
        self.assertEqual(labels["api-id"], "apim-svc-pub")
        self.assertEqual(labels["app-id"], "mock-app-sigla-x-qa")
        self.assertEqual(labels["consumer-ns"], "sigla-x-qa")
        self.assertEqual(credentials[0]["metadata"]["annotations"]["secret.kuadrant.io/plan-id"], "gold")
        self.assertEqual(credentials[0]["stringData"], {"api_key": "mock-key-sigla-x-qa"})
        consumer = k8s.objects["/api/v1/namespaces/sigla-x-qa/secrets/secret-apim-b2c"]
        self.assertEqual(consumer["stringData"]["app_key"], "mock-key-sigla-x-qa")

    def test_la_baja_borra_la_credencial_del_gateway(self):
        app, k8s, _, scheduler = make_app(link_services={"l-1": "svc-pub"})
        subscribe(app, callback=LINK_CALLBACK)
        scheduler.run_all()
        call(app, "DELETE", "/v1/subscriptions/sub-apim-svc-pub--sigla-x-qa", None, {"Idempotency-Key": "k-del"})
        self.assertEqual([p for p in k8s.objects if p.startswith("/api/v1/namespaces/kuadrant-system/secrets/")], [])

    def test_un_link_que_no_se_puede_resolver_responde_503_y_no_guarda_nada(self):
        app, _, _, _ = make_app()
        status, body = subscribe(app, callback=LINK_CALLBACK)
        self.assertEqual(status, 503)
        self.assertIn("l-1", body["detail"])
        self.assertEqual(app.state["subscriptions"], {})

    def test_una_baja_durante_el_alta_no_deja_la_credencial_y_cierra_la_accion(self):
        app, k8s, notifier, scheduler = make_app(link_services={"l-1": "svc-pub"})
        subscribe(app, callback=LINK_CALLBACK)
        k8s.during_apply = lambda: call(app, "DELETE", "/v1/subscriptions/sub-apim-svc-pub--sigla-x-qa", None, {"Idempotency-Key": "k-del"})
        scheduler.run_all()
        self.assertEqual([p for p in k8s.objects if p.startswith("/api/v1/namespaces/kuadrant-system/secrets/")], [])
        self.assertEqual(notifier.calls[-1]["status"], "failed")


if __name__ == "__main__":
    unittest.main()
