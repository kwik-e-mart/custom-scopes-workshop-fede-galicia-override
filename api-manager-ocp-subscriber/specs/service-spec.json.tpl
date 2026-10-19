{
  "name": "API Manager OCP Subscriber",
  "slug": null,
  "type": "dependency",
  "selectors": {
    "category": "Networking",
    "imported": false,
    "provider": "Kuadrant",
    "sub_category": "API Subscription"
  },
  "use_default_actions": false,
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": ["api_name", "approval_ref", "plan_id"],
      "properties": {
        "api_name": {
          "type": "string",
          "title": "API",
          "description": "Nombre con el que tu equipo reconoce la API. Es informativo: la API real sale de la solicitud de ServiceNow.",
          "editableOn": ["create"]
        },
        "approval_ref": {
          "type": "string",
          "title": "Solicitud aprobada (RITM)",
          "pattern": "^RITM[0-9]+$",
          "editableOn": ["create"]
        },
        "plan_id": {
          "type": "string",
          "title": "Plan",
          "editableOn": ["create", "update"]
        },
        "subscription_id": {
          "type": "string",
          "title": "Suscripción",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": ["read"]
        },
        "operation_id": {
          "type": "string",
          "title": "Última operación en APIM",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": ["read"]
        },
        "consumer_namespace": {
          "type": "string",
          "title": "Namespace suscripto",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": ["read"]
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
