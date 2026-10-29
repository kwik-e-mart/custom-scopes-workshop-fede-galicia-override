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
          "title": "Ticket de solicitud de suscripción",
          "editableOn": [
            "create",
            "update"
          ],
          "description": "Número del ticket de ServiceNow con el que pediste acceso a esta API o el cambio de plan. Tiene que estar aprobado por el dueño de la API: si no está aprobado, la acción falla."
        },
        "plan_id": {
          "type": "string",
          "title": "Plan",
          "editableOn": [
            "create",
            "update"
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
            "text": "## Suscripción a la API\n\n### FAQ\n\n**¿Para qué sirve?** Suscribe el namespace de tu aplicación a esta API en el API Manager, así tu aplicación la puede llamar.\n\n**¿Qué necesito antes?** Un ticket de solicitud de suscripción en ServiceNow, aprobado por el dueño de la API. Si el ticket no está aprobado, el link falla.\n\n**¿Cómo llamo a la API?** Cuando el link termina bien, tu namespace tiene la credencial de APIM y tus deployments la reciben en las variables de entorno `APIM_APP_ID` y `APIM_APP_KEY`. Mandá sus valores en los headers `app_id` y `app_key`.\n\n**¿Tengo que volver a desplegar?** Sí: las variables se agregan en cada deploy, así que los deployments que ya estaban corriendo las reciben recién en el próximo.\n\n**¿Qué es el plan?** El límite de llamadas por segundo (TPS) que tiene tu namespace sobre esta API. Se elige al crear el link y se puede cambiar editándolo, con un ticket aprobado para el cambio.\n\n**¿Y si mi namespace ya estaba suscripto?** El link usa esa suscripción y su plan; no crea otra.\n\n**¿Qué pasa si borro el link?** Se da de baja la suscripción solo si la creó este link. La suscripción es del namespace, así que afecta a todas las aplicaciones que viven en él.\n\n**¿Cuánto tarda?** El link queda en curso hasta que APIM confirma la suscripción. Si algo falla, termina con el motivo.\n\n## Instrucciones\n\n- Cargá el número del ticket aprobado y elegí el plan.\n\n- Ante cualquier problema comunicarse con el equipo de soporte de plataforma",
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
