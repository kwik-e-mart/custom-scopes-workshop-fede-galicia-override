{
  "name": "Create subscription",
  "type": "create",
  "retryable": false,
  "parameters": {
    "schema": {
      "type": "object",
      "required": [
        "api_name",
        "approval_ref",
        "plan_id"
      ],
      "properties": {
        "api_name": {
          "type": "string",
          "title": "API",
          "description": "Nombre con el que tu equipo reconoce la API. Es informativo: la API real sale de la solicitud de ServiceNow."
        },
        "approval_ref": {
          "type": "string",
          "title": "Solicitud aprobada (RITM)",
          "pattern": "^RITM[0-9]+$",
          "description": "La solicitud tiene que estar aprobada en ServiceNow por el dueño de la API. Si todavía no lo está, el pedido va a fallar y lo vas a tener que enviar de nuevo cuando se apruebe."
        },
        "plan_id": {
          "type": "string",
          "title": "Plan",
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
        }
      }
    },
    "values": {}
  },
  "results": {
    "schema": {
      "type": "object",
      "properties": {
        "subscription_id": {
          "type": "string"
        },
        "operation_id": {
          "type": "string"
        },
        "consumer_namespace": {
          "type": "string"
        },
        "owns_subscription": {
          "type": "boolean"
        }
      }
    },
    "values": {}
  }
}
