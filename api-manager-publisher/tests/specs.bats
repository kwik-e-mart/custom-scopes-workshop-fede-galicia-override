#!/usr/bin/env bats

setup() {
  SPECS="${BATS_TEST_DIRNAME}/../specs"
  SERVICE="$SPECS/service-spec.json.tpl"
  CONNECT="$SPECS/links/connect.json.tpl"
}

@test "todos los specs son JSON valido" {
  for f in "$SERVICE" "$CONNECT"; do
    jq -e . "$f" >/dev/null
  done
}

@test "el service usa las acciones autogeneradas y no declara acciones propias" {
  [ "$(jq -r .use_default_actions "$SERVICE")" = "true" ]
  [ ! -d "$SPECS/actions" ]
}

@test "publicar pide solo el scope: la version es la que tiene desplegada" {
  [ "$(jq -c '.attributes.schema.required' "$SERVICE")" = '["scope"]' ]
  [ "$(jq -c '.attributes.schema.properties | [has("ref"), has("ref_type")]' "$SERVICE")" = '[false,false]' ]
  [ "$(jq -c '[.. | objects | select(has("scope") and (.scope | type == "string")) | .scope | split("/") | last] | map(select(. == "ref" or . == "ref_type"))' "$SERVICE")" = '[]' ]
}

@test "el faq explica que desplegar no republica la API" {
  [[ "$(jq -r '.attributes.schema.uiSchema.elements[0].text' "$SERVICE")" == *"desplegada"*"actualizar"*"no republica"* ]] || false
}

@test "los datos de APIM se ven y no se editan" {
  for field in api_id hostname manifest_path; do
    [ "$(jq -r --arg f "$field" '.attributes.schema.properties[$f].readOnly' "$SERVICE")" = "true" ]
  done
}

@test "el scope es un selector con los scopes de la aplicacion" {
  [ "$(jq -r '.attributes.schema.properties.scope.title' "$SERVICE")" = "Scope" ]
  [ "$(jq -r '.attributes.schema.properties.scope.description' "$SERVICE")" = "Scope que va a recibir el tráfico" ]
  [ "$(jq -r '.attributes.schema.properties.scope.additionalKeywords.enum' "$SERVICE")" = '[.scopes[]?.slug] | if length == 0 then ["No scopes available for selected environment"] else . end' ]
}

@test "el formulario explica el servicio y pide scope y legajo" {
  [ "$(jq -r '.attributes.schema.uiSchema.elements[0].type' "$SERVICE")" = "Label" ]
  [ "$(jq -r '.attributes.schema.uiSchema.elements[0].options.format' "$SERVICE")" = "markdown" ]
  [[ "$(jq -r '.attributes.schema.uiSchema.elements[0].text' "$SERVICE")" == "## API Manager Publisher"*"### FAQ"* ]] || false
  [ "$(jq -c '[.attributes.schema.uiSchema.elements[] | select(.type == "Control") | .scope | split("/") | last] | .[0:2]' "$SERVICE")" = '["scope","legajo"]' ]
}

@test "el rate limit va en una seccion ADVANCED colapsada con una unica tab Rate limit" {
  local advanced
  advanced=$(jq -c '.attributes.schema.uiSchema.elements[] | select(.type == "Categorization")' "$SERVICE")
  [ "$(echo "$advanced" | jq -c .options.collapsable)" = '{"label":"ADVANCED","collapsed":true}' ]
  [ "$(echo "$advanced" | jq -c '[.elements[] | {type, label}]')" = '[{"type":"Category","label":"Rate limit"}]' ]
  [ "$(jq -c '[.attributes.schema.uiSchema.elements[] | select(.type == "Control") | .scope | split("/") | last] | map(select(. == "hits_per_window" or . == "window" or . == "rate_limit_enabled"))' "$SERVICE")" = '[]' ]
}

@test "la tab Rate limit explica el limite global y muestra los inputs solo con el check prendido" {
  local tab
  tab=$(jq -c '.attributes.schema.uiSchema.elements[] | select(.type == "Categorization") | .elements[0]' "$SERVICE")
  [ "$(echo "$tab" | jq -r '.elements[0].type')" = "Label" ]
  [ "$(echo "$tab" | jq -r '.elements[0].options.format')" = "markdown" ]
  [[ "$(echo "$tab" | jq -r '.elements[0].text')" == *"no define un rate limit global"*"suscriptor"*"todos sus suscriptores"* ]] || false
  [ "$(echo "$tab" | jq -c '[.elements[] | select(.type == "Control") | .scope | split("/") | last]')" = '["rate_limit_enabled","hits_per_window","window"]' ]
  [ "$(echo "$tab" | jq -c '.elements[] | select(.type == "Control" and (.scope | endswith("/rate_limit_enabled"))) | has("rule")')" = "false" ]
  for field in hits_per_window window; do
    [ "$(echo "$tab" | jq -c --arg f "$field" '.elements[] | select(.type == "Control" and (.scope | endswith("/" + $f))) | .rule')" = '{"effect":"SHOW","condition":{"scope":"#/properties/rate_limit_enabled","schema":{"const":true}}}' ]
  done
}

@test "el check del rate limit arranca apagado y los inputs no tienen valor por defecto" {
  [ "$(jq -c '.attributes.schema.properties.rate_limit_enabled | {type, default}' "$SERVICE")" = '{"type":"boolean","default":false}' ]
  [ "$(jq -c '.attributes.schema.properties.rate_limit_enabled.editableOn' "$SERVICE")" = '["create","update"]' ]
  for field in hits_per_window window; do
    [ "$(jq -r --arg f "$field" '.attributes.schema.properties[$f] | has("default")' "$SERVICE")" = "false" ]
  done
}

@test "el rate limit se elige con nombres que se entienden" {
  [ "$(jq -r '.attributes.schema.properties.hits_per_window.title' "$SERVICE")" = "Llamadas permitidas" ]
  [ "$(jq -r '.attributes.schema.properties.window.title' "$SERVICE")" = "Período" ]
  [ "$(jq -c '[.attributes.schema.properties.window.oneOf[] | {const, title}]' "$SERVICE")" = '[{"const":"1s","title":"por segundo"},{"const":"10s","title":"cada 10 segundos"},{"const":"1m","title":"por minuto"},{"const":"1h","title":"por hora"}]' ]
}

@test "el link pide el ticket y plan y guarda la suscripcion" {
  [ "$(jq -c '.attributes.schema.required | sort' "$CONNECT")" = '["approval_ref","plan_id"]' ]
  [ "$(jq -c '[.attributes.schema.properties.plan_id.oneOf[].const]' "$CONNECT")" = '["bronze","gold","no-limits"]' ]
  [ "$(jq -c '.attributes.schema.properties.owns_subscription | {type, visibleOn}' "$CONNECT")" = '{"type":"boolean","visibleOn":[]}' ]
  [ "$(jq -c '.attributes.schema.properties.approval_ref | has("pattern")' "$CONNECT")" = "false" ]
}

@test "el link explica el ticket de suscripcion y que tiene que estar aprobado" {
  [ "$(jq -r '.attributes.schema.properties.approval_ref.title' "$CONNECT")" = "Ticket de solicitud de suscripción" ]
  ! grep -q 'RITM' "$CONNECT"
  [[ "$(jq -r '.attributes.schema.properties.approval_ref.description' "$CONNECT")" == *"aprobado"*"falla"* ]] || false
  [ "$(jq -r '.attributes.schema.uiSchema.elements[0].type' "$CONNECT")" = "Label" ]
  [ "$(jq -r '.attributes.schema.uiSchema.elements[0].options.format' "$CONNECT")" = "markdown" ]
  [[ "$(jq -r '.attributes.schema.uiSchema.elements[0].text' "$CONNECT")" == "## Suscripción a la API"*"### FAQ"*"ticket"*"aprobado"* ]] || false
  [ "$(jq -c '[.attributes.schema.uiSchema.elements[] | select(.type == "Control") | .scope | split("/") | last]' "$CONNECT")" = '["approval_ref","plan_id","subscription_id","operation_id","consumer_namespace"]' ]
}

@test "el link y el override identifican al servicio con el mismo provider" {
  [ "$(jq -r '.selectors.provider' "$SERVICE")" = "API Manager" ]
  [ "$(yq -r '.configuration.APIM_PUBLISHER_PROVIDER' "${BATS_TEST_DIRNAME}/../override/values.yaml")" = "API Manager" ]
}

@test "el faq del link explica las env vars de la credencial" {
  [[ "$(jq -r '.attributes.schema.uiSchema.elements[0].text' "$CONNECT")" == *"APIM_APP_ID"*"APIM_APP_KEY"*"deploy"* ]]
}
