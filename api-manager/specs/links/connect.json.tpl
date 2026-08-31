{
  "name": "Connect",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": [],
      "properties": {
        "api_key": {
          "type": "string",
          "title": "API key",
          "readOnly": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "export": {
            "type": "environment_variable",
            "target": "API_MANAGER_API_KEY",
            "secret": true
          }
        }
      },
      "additionalProperties": false
    },
    "values": {}
  }
}
