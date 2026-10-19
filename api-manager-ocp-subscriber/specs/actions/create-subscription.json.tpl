{
  "name": "Create subscription",
  "type": "create",
  "retryable": false,
  "external": {
    "action": "list-apim-plans",
    "output_schema": {
      "type": "object",
      "required": ["plans"],
      "properties": {
        "plans": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["id"],
            "properties": { "id": { "type": "string" }, "maxTps": { "type": "number" } }
          }
        }
      }
    }
  },
  "parameters": {
    "schema": {
      "type": "object",
      "required": ["api_name", "approval_ref", "plan_id"],
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
          "additionalKeywords": {
            "oneOf": ".external.plans | map({const: .id, title: (.id + \" (\" + (if .maxTps then (.maxTps | tostring) + \" TPS\" else \"sin límite\" end) + \")\")})"
          }
        }
      }
    },
    "values": {}
  },
  "results": {
    "schema": {
      "type": "object",
      "properties": {
        "subscription_id": { "type": "string" },
        "operation_id": { "type": "string" },
        "consumer_namespace": { "type": "string" },
        "owns_subscription": { "type": "boolean" }
      }
    },
    "values": {}
  }
}
