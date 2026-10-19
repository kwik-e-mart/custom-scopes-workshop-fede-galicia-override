{
  "name": "Connect",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": [
        "approval_ref",
        "plan_id"
      ],
      "properties": {
        "approval_ref": {
          "type": "string",
          "title": "Solicitud aprobada (RITM)",
          "pattern": "^RITM[0-9]+$",
          "editableOn": [
            "create"
          ],
          "description": "La solicitud tiene que estar aprobada en ServiceNow por el dueño de la API. Si todavía no lo está, el pedido va a fallar y lo vas a tener que enviar de nuevo cuando se apruebe."
        },
        "plan_id": {
          "type": "string",
          "title": "Plan",
          "editableOn": [
            "create"
          ],
          "description": "TPS máximo para tu namespace sobre esta API.",
          "oneOf": [
            {
              "const": "bronze",
              "title": "bronze (5 TPS)"
            },
            {
              "const": "gold",
              "title": "gold (20 TPS)"
            },
            {
              "const": "no-limits",
              "title": "no-limits (sin límite)"
            }
          ]
        },
        "subscription_id": {
          "type": "string",
          "title": "Suscripción",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": [
            "read"
          ]
        },
        "operation_id": {
          "type": "string",
          "title": "Última operación en APIM",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": [
            "read"
          ]
        },
        "consumer_namespace": {
          "type": "string",
          "title": "Namespace suscripto",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": [
            "read"
          ]
        },
        "owns_subscription": {
          "type": "boolean",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": []
        }
      },
      "additionalProperties": false
    },
    "values": {}
  }
}
