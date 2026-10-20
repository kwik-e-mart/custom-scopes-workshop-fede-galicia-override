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
  "use_default_actions": true,
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
          "title": "Scope",
          "description": "Scope que va a recibir el tráfico",
          "additionalKeywords": {
            "enum": "[.scopes[]?.slug] | if length == 0 then [\"No scopes available for selected environment\"] else . end"
          },
          "editableOn": [
            "create",
            "update"
          ]
        },
        "ref_type": {
          "type": "string",
          "title": "Tipo de referencia",
          "description": "Qué tipo de referencia del repo se publica.",
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
          "description": "Nombre del branch o del tag, o el hash del commit, con el OpenAPI en la raíz.",
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
          "description": "Se informa en el cambio de ITIL. Formato l#######.",
          "pattern": "^l[0-9]{7}$",
          "editableOn": [
            "create",
            "update"
          ]
        },
        "hits_per_window": {
          "type": "integer",
          "title": "Llamadas permitidas",
          "description": "Opcional. Máximo de llamadas que acepta la API en el período elegido; va junto con el período.",
          "minimum": 1,
          "editableOn": [
            "create",
            "update"
          ]
        },
        "window": {
          "type": "string",
          "title": "Período",
          "description": "Opcional. Período en el que se cuentan las llamadas permitidas.",
          "oneOf": [
            {
              "const": "1s",
              "title": "por segundo"
            },
            {
              "const": "10s",
              "title": "cada 10 segundos"
            },
            {
              "const": "1m",
              "title": "por minuto"
            },
            {
              "const": "1h",
              "title": "por hora"
            }
          ],
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
      "additionalProperties": false,
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          {
            "type": "Label",
            "text": "## API Manager Publisher\n\n### FAQ\n\n**¿Cuándo tengo que usarlo?** Cuando querés que tu API quede publicada en el API Manager (Kuadrant) para que otras aplicaciones, tuyas o de otros equipos, la consuman con credenciales.\n\n**¿Qué hace el servicio?** Le pide al API Publisher de APIM que publique tu API a partir del OpenAPI (`openapi.yaml`, `openapi.yml` u `openapi.json`) que está en la raíz de tu repo, en la referencia que elijas. Solo quedan expuestos los paths y métodos del OpenAPI; lo que no está declarado sigue siendo inalcanzable. APIM además registra la API en el catálogo.\n\n**¿A dónde llega el tráfico?** Al scope que elijas: la API apunta al despliegue activo de ese scope.\n\n**¿Cuánto tarda?** La acción queda en curso hasta que APIM confirma que la API quedó registrada (unos minutos). Si algo falla, termina con el motivo.\n\n**¿Cómo hace otra app para consumirme?** Se linkea a este servicio con la solicitud aprobada en ServiceNow (RITM) y un plan. Queda suscripta y usa la credencial de su namespace (headers `app_id` y `app_key`).\n\n**¿Puedo cortarle el acceso a alguien?** Sí, borrando su link: se da de baja la suscripción si la creó ese link. La suscripción es del namespace, así que afecta a todas sus aplicaciones.\n\n**¿Cómo actualizo la API?** Con la acción de actualizar, eligiendo la nueva referencia del repo. Cada cambio del OpenAPI tiene que subir al menos la versión patch.\n\n**¿Tengo que cambiar algo en mi código?** No. Solo tener el OpenAPI en la raíz del repo.\n\n## Instrucciones\n\n- Elegí el scope que va a recibir el tráfico, el tipo de referencia (branch, tag o commit) y su nombre.\n\n- El límite de tráfico es opcional: si lo usás, completá las llamadas permitidas y el período.\n\n- Borrar el servicio todavía no despublica la API en APIM: pedí la baja al equipo de APIM.\n\n- Ante cualquier problema comunicarse con el equipo de soporte de plataforma",
            "options": {
              "format": "markdown"
            }
          },
          {
            "type": "Control",
            "scope": "#/properties/scope"
          },
          {
            "type": "Control",
            "scope": "#/properties/ref_type"
          },
          {
            "type": "Control",
            "scope": "#/properties/ref"
          },
          {
            "type": "Control",
            "scope": "#/properties/legajo"
          },
          {
            "type": "Control",
            "scope": "#/properties/hits_per_window"
          },
          {
            "type": "Control",
            "scope": "#/properties/window"
          },
          {
            "type": "Control",
            "scope": "#/properties/api_id",
            "options": {
              "readonly": true
            }
          },
          {
            "type": "Control",
            "scope": "#/properties/hostname",
            "options": {
              "readonly": true
            }
          },
          {
            "type": "Control",
            "scope": "#/properties/manifest_path",
            "options": {
              "readonly": true
            }
          }
        ]
      }
    },
    "values": {}
  }
}
