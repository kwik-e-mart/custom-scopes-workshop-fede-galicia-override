{
  "name": "API Manager Publisher",
  "slug": null,
  "type": "dependency",
  "selectors": {
    "category": "Networking",
    "imported": false,
    "provider": "Kuadrant",
    "sub_category": "API Exposure"
  },
  "use_default_actions": false,
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": [
        "scope",
        "ref_type",
        "ref"
      ],
      "properties": {
        "scope": {
          "type": "string",
          "title": "Scope que atiende la API",
          "description": "La regla de APIM apunta al dominio de este scope, no a un despliegue.",
          "editableOn": [
            "create",
            "update"
          ]
        },
        "ref_type": {
          "type": "string",
          "title": "Tipo de referencia",
          "enum": [
            "branch",
            "tag",
            "commit"
          ],
          "default": "branch",
          "editableOn": [
            "create",
            "update"
          ]
        },
        "ref": {
          "type": "string",
          "title": "Referencia del repo",
          "description": "Branch, tag o commit del repo de la aplicación con el OpenAPI en la raíz.",
          "default": "main",
          "pattern": "^[A-Za-z0-9._/-]+$",
          "editableOn": [
            "create",
            "update"
          ]
        },
        "legajo": {
          "type": "string",
          "title": "Legajo de quien publica",
          "pattern": "^l[0-9]{7}$",
          "description": "Se informa en el cambio de ITIL.",
          "editableOn": [
            "create",
            "update"
          ]
        },
        "window": {
          "type": "string",
          "title": "Ventana del rate limit",
          "pattern": "^[0-9]+(ms|s|m|h)$",
          "description": "Opcional, junto con hits_per_window. Por ejemplo 10s.",
          "editableOn": [
            "create",
            "update"
          ]
        },
        "hits_per_window": {
          "type": "integer",
          "title": "Hits por ventana",
          "minimum": 1,
          "editableOn": [
            "create",
            "update"
          ]
        },
        "api_id": {
          "type": "string",
          "title": "API en APIM",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": [
            "read"
          ]
        },
        "hostname": {
          "type": "string",
          "title": "Hostname publicado",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": [
            "read"
          ]
        },
        "manifest_path": {
          "type": "string",
          "title": "Ruta de los manifiestos",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": [
            "read"
          ]
        }
      },
      "additionalProperties": false
    },
    "values": {}
  }
}
