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

@test "publicar pide el scope y la referencia del repo" {
  [ "$(jq -c '.attributes.schema.required | sort' "$SERVICE")" = '["ref","ref_type","scope"]' ]
  [ "$(jq -c '.attributes.schema.properties.ref_type.enum' "$SERVICE")" = '["branch","tag","commit"]' ]
  [ "$(jq -r '.attributes.schema.properties.ref.default' "$SERVICE")" = "main" ]
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

@test "el formulario explica el servicio y ordena tipo de referencia antes que la referencia" {
  [ "$(jq -r '.attributes.schema.uiSchema.elements[0].type' "$SERVICE")" = "Label" ]
  [ "$(jq -r '.attributes.schema.uiSchema.elements[0].options.format' "$SERVICE")" = "markdown" ]
  [[ "$(jq -r '.attributes.schema.uiSchema.elements[0].text' "$SERVICE")" == "## API Manager Publisher"*"### FAQ"* ]] || false
  [ "$(jq -c '[.attributes.schema.uiSchema.elements[] | select(.type == "Control") | .scope | split("/") | last] | .[0:6]' "$SERVICE")" = '["scope","ref_type","ref","legajo","hits_per_window","window"]' ]
}

@test "el rate limit se elige con nombres que se entienden" {
  [ "$(jq -r '.attributes.schema.properties.hits_per_window.title' "$SERVICE")" = "Llamadas permitidas" ]
  [ "$(jq -r '.attributes.schema.properties.window.title' "$SERVICE")" = "Período" ]
  [ "$(jq -c '[.attributes.schema.properties.window.oneOf[] | {const, title}]' "$SERVICE")" = '[{"const":"1s","title":"por segundo"},{"const":"10s","title":"cada 10 segundos"},{"const":"1m","title":"por minuto"},{"const":"1h","title":"por hora"}]' ]
}

@test "el link pide RITM y plan y guarda la suscripcion" {
  [ "$(jq -c '.attributes.schema.required | sort' "$CONNECT")" = '["approval_ref","plan_id"]' ]
  [ "$(jq -c '[.attributes.schema.properties.plan_id.oneOf[].const]' "$CONNECT")" = '["bronze","gold","no-limits"]' ]
  [ "$(jq -c '.attributes.schema.properties.owns_subscription | {type, visibleOn}' "$CONNECT")" = '{"type":"boolean","visibleOn":[]}' ]
  [ "$(jq -r '.attributes.schema.properties.approval_ref.pattern' "$CONNECT")" = '^RITM[0-9]+$' ]
}

@test "el link explica el ticket de suscripcion y que tiene que estar aprobado" {
  [ "$(jq -r '.attributes.schema.properties.approval_ref.title' "$CONNECT")" = "Ticket de solicitud de suscripción (RITM)" ]
  [[ "$(jq -r '.attributes.schema.properties.approval_ref.description' "$CONNECT")" == *"aprobado"*"falla"* ]] || false
  [ "$(jq -r '.attributes.schema.uiSchema.elements[0].type' "$CONNECT")" = "Label" ]
  [ "$(jq -r '.attributes.schema.uiSchema.elements[0].options.format' "$CONNECT")" = "markdown" ]
  [[ "$(jq -r '.attributes.schema.uiSchema.elements[0].text' "$CONNECT")" == "## Suscripción a la API"*"### FAQ"*"RITM"* ]] || false
  [ "$(jq -c '[.attributes.schema.uiSchema.elements[] | select(.type == "Control") | .scope | split("/") | last]' "$CONNECT")" = '["approval_ref","plan_id","subscription_id","operation_id","consumer_namespace"]' ]
}

@test "el link y el override identifican al servicio con el mismo provider" {
  [ "$(jq -r '.selectors.provider' "$SERVICE")" = "API Manager" ]
  [ "$(yq -r '.configuration.APIM_PUBLISHER_PROVIDER' "${BATS_TEST_DIRNAME}/../override/values.yaml")" = "API Manager" ]
}

@test "el faq del link explica las env vars de la credencial" {
  [[ "$(jq -r '.attributes.schema.uiSchema.elements[0].text' "$CONNECT")" == *"APIM_APP_ID"*"APIM_APP_KEY"*"deploy"* ]]
}
