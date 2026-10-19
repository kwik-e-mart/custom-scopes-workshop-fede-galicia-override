{
  "name": "Republish API",
  "type": "update",
  "retryable": false,
  "parameters": {
    "schema": {
      "type": "object",
      "required": [
        "ref_type",
        "ref"
      ],
      "properties": {
        "scope": {
          "type": "string",
          "title": "Scope que atiende la API",
          "description": "La regla de APIM apunta al dominio de este scope, no a un despliegue."
        },
        "ref_type": {
          "type": "string",
          "title": "Tipo de referencia",
          "enum": [
            "branch",
            "tag",
            "commit"
          ],
          "default": "branch"
        },
        "ref": {
          "type": "string",
          "title": "Referencia del repo",
          "description": "Branch, tag o commit del repo de la aplicación con el OpenAPI en la raíz.",
          "default": "main",
          "pattern": "^[A-Za-z0-9._/-]+$"
        },
        "legajo": {
          "type": "string",
          "title": "Legajo de quien publica",
          "pattern": "^l[0-9]{7}$",
          "description": "Se informa en el cambio de ITIL."
        },
        "window": {
          "type": "string",
          "title": "Ventana del rate limit",
          "pattern": "^[0-9]+(ms|s|m|h)$",
          "description": "Opcional, junto con hits_per_window. Por ejemplo 10s."
        },
        "hits_per_window": {
          "type": "integer",
          "title": "Hits por ventana",
          "minimum": 1
        }
      }
    },
    "values": {}
  },
  "results": {
    "schema": {
      "type": "object",
      "properties": {
        "api_id": {
          "type": "string"
        },
        "hostname": {
          "type": "string"
        },
        "manifest_path": {
          "type": "string"
        }
      }
    },
    "values": {}
  }
}
