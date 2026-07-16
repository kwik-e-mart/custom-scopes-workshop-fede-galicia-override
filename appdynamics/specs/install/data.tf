data "external" "appdynamics_spec" {
  program = ["sh", "-c", <<-EOT
    set -eu
    printf '%s' '${base64encode(file("${path.module}/appdynamics-configuration.json.tpl"))}' \
      | base64 -d \
      | gomplate \
      | jq -c '{json: tojson}'
  EOT
  ]
}
