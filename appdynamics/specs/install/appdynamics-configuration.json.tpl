{
  "name": "App Dynamics",
  "slug": "app-dynamics",
  "description": "Configures AppDynamics APM agent environment variables, shared across runtimes plus optional per-language overrides",
  "category": "metrics",
  "icon": "logos:appdynamics-icon",
  "visible_to": [
    "{{ env.Getenv "NRN" }}"
  ],
  "allow_dimensions": true,
  "schema": {
    "type": "object",
    "title": "AppDynamics configuration",
    "groups": ["global", "python", "node", "java", "dotnet"],
    "required": ["global"],
    "additionalProperties": false,
    "description": "Environment variables for the AppDynamics agent. Variables in Global apply to every runtime; each language group adds variables that apply only to services of that runtime.",
    "properties": {
      "global": {
        "type": "object",
        "order": 1,
        "title": "Global",
        "required": ["variables"],
        "additionalProperties": false,
        "description": "Environment variables applied to services of any runtime.",
        "properties": {
          "variables": {
            "type": "array",
            "order": 1,
            "title": "Environment variables",
            "minItems": 1,
            "description": "AppDynamics agent environment variables.",
            "items": {
              "type": "object",
              "required": ["name", "type", "value"],
              "additionalProperties": false,
              "properties": {
                "name": {
                  "type": "string",
                  "order": 1,
                  "title": "Name",
                  "examples": ["APPDYNAMICS_AGENT_TIER_NAME"],
                  "description": "Environment variable name."
                },
                "type": {
                  "type": "string",
                  "order": 2,
                  "title": "Type",
                  "default": "Text",
                  "enum": ["Text", "Reference", "Secret", "Configmap"],
                  "description": "How the value is resolved: a literal string, a Downward API field reference, a Kubernetes Secret, or a ConfigMap."
                },
                "value": {
                  "type": "string",
                  "order": 3,
                  "title": "Value",
                  "description": "Literal value when type is Text; otherwise the field path (Reference) or the Secret/ConfigMap name to resolve."
                }
              }
            }
          }
        }
      },
      "python": {
        "type": "object",
        "order": 2,
        "title": "Python",
        "additionalProperties": false,
        "description": "Environment variables applied only to Python services.",
        "properties": {
          "variables": {
            "type": "array",
            "order": 1,
            "title": "Environment variables",
            "description": "AppDynamics agent environment variables.",
            "items": {
              "type": "object",
              "required": ["name", "type", "value"],
              "additionalProperties": false,
              "properties": {
                "name": {
                  "type": "string",
                  "order": 1,
                  "title": "Name",
                  "examples": ["APPD_NODE_NAME"],
                  "description": "Environment variable name."
                },
                "type": {
                  "type": "string",
                  "order": 2,
                  "title": "Type",
                  "default": "Text",
                  "enum": ["Text", "Reference", "Secret", "Configmap"],
                  "description": "How the value is resolved: a literal string, a Downward API field reference, a Kubernetes Secret, or a ConfigMap."
                },
                "value": {
                  "type": "string",
                  "order": 3,
                  "title": "Value",
                  "description": "Literal value when type is Text; otherwise the field path (Reference) or the Secret/ConfigMap name to resolve."
                }
              }
            }
          }
        }
      },
      "node": {
        "type": "object",
        "order": 3,
        "title": "Node.js",
        "additionalProperties": false,
        "description": "Environment variables applied only to Node.js services.",
        "properties": {
          "variables": {
            "type": "array",
            "order": 1,
            "title": "Environment variables",
            "description": "AppDynamics agent environment variables.",
            "items": {
              "type": "object",
              "required": ["name", "type", "value"],
              "additionalProperties": false,
              "properties": {
                "name": {
                  "type": "string",
                  "order": 1,
                  "title": "Name",
                  "examples": ["APPDYNAMICS_AGENT_NODE_NAME"],
                  "description": "Environment variable name."
                },
                "type": {
                  "type": "string",
                  "order": 2,
                  "title": "Type",
                  "default": "Text",
                  "enum": ["Text", "Reference", "Secret", "Configmap"],
                  "description": "How the value is resolved: a literal string, a Downward API field reference, a Kubernetes Secret, or a ConfigMap."
                },
                "value": {
                  "type": "string",
                  "order": 3,
                  "title": "Value",
                  "description": "Literal value when type is Text; otherwise the field path (Reference) or the Secret/ConfigMap name to resolve."
                }
              }
            }
          }
        }
      },
      "java": {
        "type": "object",
        "order": 4,
        "title": "Java",
        "additionalProperties": false,
        "description": "Environment variables applied only to Java services.",
        "properties": {
          "variables": {
            "type": "array",
            "order": 1,
            "title": "Environment variables",
            "description": "AppDynamics agent environment variables.",
            "items": {
              "type": "object",
              "required": ["name", "type", "value"],
              "additionalProperties": false,
              "properties": {
                "name": {
                  "type": "string",
                  "order": 1,
                  "title": "Name",
                  "examples": ["APPDYNAMICS_AGENT_NODE_NAME"],
                  "description": "Environment variable name."
                },
                "type": {
                  "type": "string",
                  "order": 2,
                  "title": "Type",
                  "default": "Text",
                  "enum": ["Text", "Reference", "Secret", "Configmap"],
                  "description": "How the value is resolved: a literal string, a Downward API field reference, a Kubernetes Secret, or a ConfigMap."
                },
                "value": {
                  "type": "string",
                  "order": 3,
                  "title": "Value",
                  "description": "Literal value when type is Text; otherwise the field path (Reference) or the Secret/ConfigMap name to resolve."
                }
              }
            }
          }
        }
      },
      "dotnet": {
        "type": "object",
        "order": 5,
        "title": ".NET",
        "additionalProperties": false,
        "description": "Environment variables applied only to .NET services.",
        "properties": {
          "variables": {
            "type": "array",
            "order": 1,
            "title": "Environment variables",
            "description": "AppDynamics agent environment variables.",
            "items": {
              "type": "object",
              "required": ["name", "type", "value"],
              "additionalProperties": false,
              "properties": {
                "name": {
                  "type": "string",
                  "order": 1,
                  "title": "Name",
                  "examples": ["APPDYNAMICS_AGENT_NODE_NAME"],
                  "description": "Environment variable name."
                },
                "type": {
                  "type": "string",
                  "order": 2,
                  "title": "Type",
                  "default": "Text",
                  "enum": ["Text", "Reference", "Secret", "Configmap"],
                  "description": "How the value is resolved: a literal string, a Downward API field reference, a Kubernetes Secret, or a ConfigMap."
                },
                "value": {
                  "type": "string",
                  "order": 3,
                  "title": "Value",
                  "description": "Literal value when type is Text; otherwise the field path (Reference) or the Secret/ConfigMap name to resolve."
                }
              }
            }
          }
        }
      }
    }
  }
}
