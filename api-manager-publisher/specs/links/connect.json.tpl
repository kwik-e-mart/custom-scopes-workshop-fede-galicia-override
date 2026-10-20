{
  "name": "Connect",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": [
        "approval_ref",
        "plan_id"
      ],
      "properties": {
        "approval_ref": {
          "type": "string",
          "title": "Ticket de solicitud de suscripción (RITM)",
          "pattern": "^RITM[0-9]+$",
          "editableOn": [
            "create"
          ],
          "description": "Número del ticket de ServiceNow con el que pediste acceso a esta API, por ejemplo RITM0012345. Tiene que estar aprobado por el dueño de la API: si no está aprobado, el link falla y lo vas a tener que crear de nuevo cuando se apruebe."
        },
        "plan_id": {
          "type": "string",
          "title": "Plan",
          "editableOn": [
            "create"
          ],
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
        },
        "subscription_id": {
          "type": "string",
          "title": "Suscripción",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": [
            "read"
          ]
        },
        "operation_id": {
          "type": "string",
          "title": "Última operación en APIM",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": [
            "read"
          ]
        },
        "consumer_namespace": {
          "type": "string",
          "title": "Namespace suscripto",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": [
            "read"
          ]
        },
        "owns_subscription": {
          "type": "boolean",
          "readOnly": true,
          "editableOn": [],
          "visibleOn": []
        }
      },
      "additionalProperties": false,
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          {
            "type": "Label",
            "text": "## Suscripción a la API\n\n### FAQ\n\n**¿Para qué sirve?** Suscribe el namespace de tu aplicación a esta API en el API Manager, así tu aplicación la puede llamar.\n\n**¿Qué necesito antes?** Un ticket de solicitud de suscripción (RITM) en ServiceNow, aprobado por el dueño de la API. Si el ticket no está aprobado, el link falla.\n\n**¿Cómo llamo a la API?** Cuando el link termina bien, tu namespace tiene la credencial de APIM: mandá sus valores en los headers `app_id` y `app_key`.\n\n**¿Qué es el plan?** El límite de llamadas por segundo (TPS) que tiene tu namespace sobre esta API. Se elige al crear el link.\n\n**¿Y si mi namespace ya estaba suscripto?** El link usa esa suscripción y su plan; no crea otra.\n\n**¿Qué pasa si borro el link?** Se da de baja la suscripción solo si la creó este link. La suscripción es del namespace, así que afecta a todas las aplicaciones que viven en él.\n\n**¿Cuánto tarda?** El link queda en curso hasta que APIM confirma la suscripción. Si algo falla, termina con el motivo.\n\n## Instrucciones\n\n- Cargá el número del RITM aprobado y elegí el plan.\n\n- Ante cualquier problema comunicarse con el equipo de soporte de plataforma",
            "options": {
              "format": "markdown"
            }
          },
          {
            "type": "Control",
            "scope": "#/properties/approval_ref"
          },
          {
            "type": "Control",
            "scope": "#/properties/plan_id"
          },
          {
            "type": "Control",
            "scope": "#/properties/subscription_id",
            "options": {
              "readonly": true
            }
          },
          {
            "type": "Control",
            "scope": "#/properties/operation_id",
            "options": {
              "readonly": true
            }
          },
          {
            "type": "Control",
            "scope": "#/properties/consumer_namespace",
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
