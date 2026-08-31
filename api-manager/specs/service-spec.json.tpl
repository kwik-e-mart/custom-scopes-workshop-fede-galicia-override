{
  "name": "Api Manager",
  "type": "dependency",
  "visible_to": ["{{ env.Getenv `NRN` }}"],
  "dimensions": {},
  "scopes": {},
  "assignable_to": "any",
  "use_default_actions": true,
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": ["hosts", "routes"],
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          {
            "type": "Label",
            "options": { "format": "markdown" },
            "text": "## Api Manager\n\n### FAQ\n\n**¿Cuándo tengo que usarlo?** Cuando otra aplicación, que corre en otro namespace, necesita consumir la tuya. Por defecto las aplicaciones de distintos namespaces no se ven entre sí.\n\n**¿Qué hace el servicio?** Publica los paths que declarás acá bajo los dominios que elijas, y los deja alcanzables desde otros namespaces. Lo que no declarás sigue siendo inalcanzable.\n\n**¿Cómo hace otra app para consumirme?** Se linkea a este servicio. En ese momento recibe su propia credencial como variable de entorno, sin que nadie copie ni pegue nada.\n\n**¿Puedo cortarle el acceso a alguien?** Sí, borrando el link. Es inmediato y sólo afecta a esa aplicación.\n\n**¿Tengo que cambiar algo en mi código?** No. Tu aplicación sigue escuchando donde escucha hoy."
          },
          {
            "type": "Control",
            "label": "Dominios",
            "scope": "#/properties/hosts"
          },
          {
            "type": "Control",
            "scope": "#/properties/routes",
            "options": {
              "elementLabelProp": "summary",
              "showSortButtons": true,
              "detail": {
                "type": "VerticalLayout",
                "elements": [
                  { "type": "Control", "label": "Verbos", "scope": "#/properties/methods" },
                  {
                    "type": "HorizontalLayout",
                    "elements": [
                      { "type": "Control", "label": "Path", "scope": "#/properties/path" },
                      { "type": "Control", "label": "Scope", "scope": "#/properties/scope" }
                    ]
                  }
                ]
              }
            }
          }
        ]
      },
      "properties": {
        "hosts": {
          "type": "array",
          "title": "Dominios",
          "description": "Dominios por los que se expone la aplicación. Otras apps la van a consumir por acá.",
          "minItems": 1,
          "uniqueItems": true,
          "items": {
            "type": "string",
            "pattern": "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"
          }
        },
        "routes": {
          "type": "array",
          "title": "Rutas expuestas",
          "minItems": 1,
          "items": {
            "type": "object",
            "required": ["methods", "path", "scope"],
            "properties": {
              "path": {
                "type": "string",
                "title": "Path",
                "pattern": "^/([a-zA-Z0-9_\\-\\.:{}/]*\\*?)?$",
                "description": "Tiene que empezar con /. El '*' sólo puede ir al final, para exponer un subárbol. Ejemplos: /, /api, /api/v1/users, /items/{id}, /files/*"
              },
              "scope": {
                "type": "string",
                "title": "Scope",
                "description": "Scope de la aplicación que atiende esta ruta.",
                "additionalKeywords": {
                  "enum": "[.scopes[]?.slug] | if length == 0 then [\"No hay scopes disponibles\"] else . end"
                }
              },
              "methods": {
                "type": "array",
                "title": "Verbos",
                "minItems": 1,
                "uniqueItems": true,
                "items": {
                  "type": "string",
                  "enum": ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
                }
              },
              "summary": {
                "type": "string",
                "title": "Resumen",
                "editableOn": ["create", "update"],
                "visibleOn": []
              }
            }
          }
        }
      }
    },
    "values": {}
  },
  "selectors": {
    "category": "Networking",
    "imported": false,
    "provider": "Kuadrant",
    "sub_category": "API Exposure"
  }
}
