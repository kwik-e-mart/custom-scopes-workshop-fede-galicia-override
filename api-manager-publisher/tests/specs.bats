#!/usr/bin/env bats

setup() {
  SPECS="${BATS_TEST_DIRNAME}/../specs"
  SERVICE="$SPECS/service-spec.json.tpl"
  CREATE="$SPECS/actions/publish-api.json.tpl"
  UPDATE="$SPECS/actions/republish-api.json.tpl"
  DELETE="$SPECS/actions/unpublish-api.json.tpl"
  CONNECT="$SPECS/links/connect.json.tpl"
}

@test "todos los specs son JSON valido" {
  for f in "$SERVICE" "$CREATE" "$UPDATE" "$DELETE" "$CONNECT"; do
    jq -e . "$f" >/dev/null
  done
}

@test "el service no usa las acciones autogeneradas" {
  [ "$(jq -r .use_default_actions "$SERVICE")" = "false" ]
}

@test "cada accion tiene el type que rutea el handler service" {
  [ "$(jq -r .type "$CREATE")" = "create" ]
  [ "$(jq -r .type "$UPDATE")" = "update" ]
  [ "$(jq -r .type "$DELETE")" = "delete" ]
}

@test "publicar pide el scope y la referencia del repo" {
  [ "$(jq -c '.parameters.schema.required | sort' "$CREATE")" = '["ref","ref_type","scope"]' ]
  [ "$(jq -c '.parameters.schema.properties.ref_type.enum' "$CREATE")" = '["branch","tag","commit"]' ]
  [ "$(jq -r '.parameters.schema.properties.ref.default' "$CREATE")" = "main" ]
}

@test "los resultados de publicar son los datos de APIM que se guardan" {
  [ "$(jq -c '.results.schema.properties | keys' "$CREATE")" = '["api_id","hostname","manifest_path"]' ]
  [ "$(jq -c '.results.schema.properties | keys' "$UPDATE")" = '["api_id","hostname","manifest_path"]' ]
}

@test "los datos de APIM se ven y no se editan" {
  for field in api_id hostname manifest_path; do
    [ "$(jq -r --arg f "$field" '.attributes.schema.properties[$f].readOnly' "$SERVICE")" = "true" ]
  done
}

@test "el link pide RITM y plan y guarda la suscripcion" {
  [ "$(jq -c '.attributes.schema.required | sort' "$CONNECT")" = '["approval_ref","plan_id"]' ]
  [ "$(jq -c '[.attributes.schema.properties.plan_id.oneOf[].const]' "$CONNECT")" = '["bronze","gold","no-limits"]' ]
  [ "$(jq -c '.attributes.schema.properties.owns_subscription | {type, visibleOn}' "$CONNECT")" = '{"type":"boolean","visibleOn":[]}' ]
  [ "$(jq -r '.attributes.schema.properties.approval_ref.pattern' "$CONNECT")" = '^RITM[0-9]+$' ]
}
