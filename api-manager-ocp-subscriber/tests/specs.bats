#!/usr/bin/env bats

setup() {
  SPECS="${BATS_TEST_DIRNAME}/../specs"
  SERVICE="$SPECS/service-spec.json.tpl"
  CREATE="$SPECS/actions/create-subscription.json.tpl"
  CHANGE="$SPECS/actions/change-plan.json.tpl"
  DELETE="$SPECS/actions/delete-subscription.json.tpl"
  CONNECT="$SPECS/links/connect.json.tpl"
  PLANS='{"external":{"plans":[{"id":"bronze","maxTps":5},{"id":"gold","maxTps":20},{"id":"no-limits"}]}}'
}

@test "todos los specs son JSON valido" {
  for f in "$SERVICE" "$CREATE" "$CHANGE" "$DELETE" "$CONNECT"; do
    jq -e . "$f" >/dev/null
  done
}

@test "el service no usa las acciones autogeneradas" {
  run jq -r '.use_default_actions' "$SERVICE"
  [ "$output" = "false" ]
}

@test "cada accion tiene el type que rutea el handler service" {
  [ "$(jq -r .type "$CREATE")" = "create" ]
  [ "$(jq -r .type "$CHANGE")" = "update" ]
  [ "$(jq -r .type "$DELETE")" = "delete" ]
}

@test "alta y cambio de plan resuelven los planes por external context" {
  for f in "$CREATE" "$CHANGE"; do
    [ "$(jq -r '.external.action' "$f")" = "list-apim-plans" ]
    [ "$(jq -r '.external.output_schema.required[0]' "$f")" = "plans" ]
  done
}

@test "el desplegable muestra el TPS y manda el id" {
  expr=$(jq -r '.parameters.schema.properties.plan_id.additionalKeywords.oneOf' "$CREATE")
  run jq -c "$expr" <<<"$PLANS"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"const":"bronze","title":"bronze (5 TPS)"},{"const":"gold","title":"gold (20 TPS)"},{"const":"no-limits","title":"no-limits (sin límite)"}]' ]
}

@test "cambio de plan usa la misma expresion de planes que el alta" {
  [ -n "$(jq -r '.parameters.schema.properties.plan_id.additionalKeywords.oneOf // empty' "$CHANGE")" ]
  [ "$(jq -r '.parameters.schema.properties.plan_id.additionalKeywords.oneOf' "$CREATE")" = "$(jq -r '.parameters.schema.properties.plan_id.additionalKeywords.oneOf' "$CHANGE")" ]
}

@test "el alta pide api_name, approval_ref y plan_id" {
  run jq -c '.parameters.schema.required | sort' "$CREATE"
  [ "$output" = '["api_name","approval_ref","plan_id"]' ]
}

@test "approval_ref acepta solo numeros de RITM" {
  pattern=$(jq -r '.parameters.schema.properties.approval_ref.pattern' "$CREATE")
  [[ "RITM0012345" =~ $pattern ]] || false
  ! [[ "INC0012345" =~ $pattern ]]
}

@test "el cambio de plan advierte que el plan es del namespace" {
  run jq -r '.parameters.schema.properties.plan_id.description' "$CHANGE"
  [[ "$output" == *"todas las aplicaciones del namespace"* ]]
}

@test "owns_subscription existe y no se muestra" {
  run jq -c '.attributes.schema.properties.owns_subscription | {type, visibleOn}' "$SERVICE"
  [ "$output" = '{"type":"boolean","visibleOn":[]}' ]
}

@test "los resultados del alta coinciden con los atributos de solo lectura del service" {
  run jq -c '.results.schema.properties | keys' "$CREATE"
  [ "$output" = '["consumer_namespace","operation_id","owns_subscription","subscription_id"]' ]
}

@test "el link no declara atributos" {
  run jq -c '.attributes.schema.properties' "$CONNECT"
  [ "$output" = '{}' ]
}
