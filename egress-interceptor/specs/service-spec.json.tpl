{
  "name": "Egress Interceptor",
  "slug": "egress-interceptor",
  "type": "dependency",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "available_links": [],
  "selectors": {
    "category": "Networking",
    "imported": false,
    "provider": "K8S",
    "sub_category": "Service Mesh"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": ["interceptions"],
      "properties": {
        "interceptions": {
          "type": "array",
          "title": "Servicios a migrar / migrados de OpenShift a EKS",
          "order": 2,
          "editableOn": ["create", "update"],
          "items": {
            "type": "object",
            "required": ["service_name", "scope", "percent"],
            "properties": {
              "service_name": { "type": "string", "title": "Origen: nombre del servicio en OpenShift", "description": "⚠️ Introducir el nombre, no el FQDN", "order": 1 },
              "scope": {
                "type": "string",
                "title": "Destino: scope de nullplatform",
                "description": "Debe pertenecer a esta misma aplicación, abrir para ver los scopes disponibles.",
                "order": 2,
                "additionalKeywords": {
                  "enum": "[.scopes[]?.slug] | if length == 0 then [\"No scopes available for selected environment\"] else . end"
                }
              },
              "percent": { "type": "integer", "minimum": 0, "maximum": 100, "default": 0, "title": "% de tráfico a migrar a EKS", "description": "0 = todo a OpenShift ; 100 = todo a EKS.", "order": 3 }
            }
          }
        },
        "resolved": {
          "type": "array",
          "title": "Ruteo resuelto",
          "order": 3,
          "editableOn": [],
          "visibleOn": ["read"],
          "items": {
            "type": "object",
            "properties": {
              "service_name": { "type": "string", "title": "Service" },
              "scope": { "type": "string", "title": "Scope" },
              "scope_fqdn": { "type": "string", "title": "FQDN del scope" },
              "percent": { "type": "integer", "title": "% migrado" }
            }
          }
        }
      },
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          {
            "type": "Label",
            "text": "## Migración de tráfico service-to-service de OpenShift a EKS\n\n### FAQ\n\n**¿Cuando tengo que usarlo?** Cuando se migra un servicio de on-premise (OCP) a AWS (EKS, nullplatform).\n\n**¿Qué hace el servicio?** Se ocupa que el tráfico que llega al servicio de OpenShift viaje hacia su versión en AWS, haciendo la migración transparente para los clientes del servicio.\n\n**¿Cambia algo para los clientes de mi servicio?.** No, las aplicaciones que lo consumen lo siguen invocando por el mismo nombre de siempre: el cambio es transparente, no es necesario cambiar la URL de consumo en el código.\n\n**El porcentaje indica qué % del tráfico viaja hacia EKS.** En `0` todo el tráfico va hacia OpenShift, en `100` todo a EKS. Al migrar una aplicación a EKS, permite mover el tráfico de forma paulatina y validar el funcionamiento sobre el camino real.\n\n**Una vez migrado del todo... ¿la regla se mantiene?** Cuando un servicio queda completamente migrado a EKS y se lo borra de OpenShift, la regla es lo único que sostiene su URL de consumo original. Si se elimina, esa URL deja de existir y las aplicaciones que todavía la usan dejan de funcionar.\n\n## Instrucciones\n\n- Cada regla del listado declara qué servicio se migra a AWS y en qué porcentaje de las llamadas (esto es porque admite migración gradual).\n\n- Una vez completados los datos se actualiza el servicio y se espera la ejecución\n\n- Ante cualquier problema comunicarse con el equipo de soporte de plataforma",
            "options": { "format": "markdown" }
          },
          {
            "type": "Control",
            "scope": "#/properties/interceptions",
            "options": {
              "detail": {
                "type": "VerticalLayout",
                "elements": [
                  { "type": "Control", "scope": "#/properties/service_name" },
                  { "type": "Control", "scope": "#/properties/scope" },
                  { "type": "Control", "scope": "#/properties/percent" }
                ]
              }
            }
          },
          { "type": "Control", "scope": "#/properties/resolved", "options": { "readonly": true } }
        ]
      }
    },
    "values": {}
  }
}
