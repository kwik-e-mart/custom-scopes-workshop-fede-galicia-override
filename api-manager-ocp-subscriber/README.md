# API Manager OCP Subscriber (service nullplatform)

Suscribe el namespace de una aplicación a una API de APIM (Kuadrant) que **no** está en nuestro
catálogo, usando el API Subscriber de APIM. El diseño completo está en
[`docs/DISENO.md`](./docs/DISENO.md).

## Cómo se usa

- **Crear una instancia = pedir la suscripción.** El formulario pide el nombre de la API (informativo),
  el RITM aprobado en ServiceNow y el plan. La API real sale del RITM. La acción queda en curso hasta
  que APIM avisa el resultado (entre 15 s y unos 6 minutos).
- **Linkear una app = indicar que la usa.** El link no toca APIM: la suscripción es del namespace y
  todas las apps del namespace quedan habilitadas.
- **Cambiar el plan** desde la acción `update` (ver la advertencia de abajo).
- **Borrar la instancia = dar de baja la suscripción**, solo si esta instancia la creó. Si el namespace
  ya estaba suscripto cuando se creó (`409`), borrarla no toca APIM.

> [!WARNING]
> **El plan es del namespace, no de la aplicación ni de esta instancia.**
>
> En APIM una suscripción es **namespace × API**: hay una sola por par, la comparten todas las
> aplicaciones del namespace y el plan (el TPS máximo) se aplica a esa suscripción entera. Cambiar el
> plan desde cualquier instancia que apunte a ella cambia el límite para **todas** las aplicaciones del
> namespace que consumen esa API, estén o no linkeadas a esta instancia.
>
> Esto vale también cuando la instancia no creó la suscripción. Bajar el plan (por ejemplo de `gold`
> a `bronze`) puede hacer que otra aplicación del namespace empiece a recibir `429` sin haber tocado
> nada. El cambio no pasa por ServiceNow.

## Configuración del agente

El agente que atiende este service (el que elige `tags_selectors`) tiene que tener:

| Variable | Uso |
|---|---|
| `API_SUBSCRIBER_URL` | Base del API Subscriber, sin `/v1` |
| `API_SUBSCRIBER_TOKEN` | Credencial de nullplatform para el API Subscriber |

Sin alguna de las dos, la acción falla nombrando la que falta.

## Instalación

`specs/install/` registra el service y crea el notification channel de sus acciones.

```bash
cd specs/install
cp terraform.tfvars.example terraform.tfvars   # completar np_api_key, nrn y tags_selectors
tofu init && tofu apply
```

Por ahora los planes del formulario (`bronze`, `gold`, `no-limits`) están fijos en
`specs/actions/*.json.tpl`. Cuando haya acceso a `GET /v1/plans`, se vuelven a leer en vivo con external
context: el handler `entrypoint/external` ya está escrito y probado; falta declarar `external` en las
acciones y crear su channel, con el release de `tofu-modules` que pasa `external` a las action specifications.

## Tests

```bash
PATH=/opt/homebrew/bin:$PATH bats tests/
```

Requiere **bash >= 4**, **jq** y **yq**.

## Pendiente

- Override del scope que monta en la aplicación el Secret `secret-apim-<tenant>` que deja External Secrets.
- Que el link de `api-manager-publisher` use `scripts/subscriber_lib` para suscribirse a APIs del catálogo.
