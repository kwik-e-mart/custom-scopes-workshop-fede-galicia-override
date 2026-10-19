{
  "name": "Change plan",
  "type": "update",
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
      "required": ["plan_id"],
      "properties": {
        "plan_id": {
          "type": "string",
          "title": "Plan",
          "description": "El plan es de la suscripción del namespace, no de esta aplicación: cambiarlo cambia el TPS para todas las aplicaciones del namespace que consumen esta API, aunque esta instancia no haya creado la suscripción. No pasa por ServiceNow.",
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
      "properties": { "operation_id": { "type": "string" } }
    },
    "values": {}
  }
}
