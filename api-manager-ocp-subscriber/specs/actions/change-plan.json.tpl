{
  "name": "Change plan",
  "type": "update",
  "retryable": false,
  "parameters": {
    "schema": {
      "type": "object",
      "required": [
        "plan_id"
      ],
      "properties": {
        "plan_id": {
          "type": "string",
          "title": "Plan",
          "description": "El plan es de la suscripción del namespace, no de esta aplicación: cambiarlo cambia el TPS para todas las aplicaciones del namespace que consumen esta API, aunque esta instancia no haya creado la suscripción. No pasa por ServiceNow.",
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
        "operation_id": {
          "type": "string"
        }
      }
    },
    "values": {}
  }
}
