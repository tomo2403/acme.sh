#!/usr/bin/env sh

# MD_CONFIG="default"

########  Public functions #####################

# domain keyfile certfile cafile fullchain
multideploy_deploy() {
  _cdomain="$1"
  _ckey="$2"
  _ccert="$3"
  _cca="$4"
  _cfullchain="$5"

  _debug _cdomain "$_cdomain"
  _debug _ckey "$_ckey"
  _debug _ccert "$_ccert"
  _debug _cca "$_cca"
  _debug _cfullchain "$_cfullchain"

  DOMAIN_DIR=$_cdomain
  if echo "$DOMAIN_PATH" | grep -q "$ECC_SUFFIX"; then
    DOMAIN_DIR="$DOMAIN_DIR"_ecc
  fi
  _debug2 "DOMAIN_DIR" "$DOMAIN_DIR"

  MD_CONFIG="${MD_CONFIG:-$(_getdeployconf MD_CONFIG)}"
  if [ -z "$MD_CONFIG" ]; then
    MD_CONFIG="default"
    _info "MD_CONFIG is not set, so we will use 'default'."
  else
    _savedeployconf "MD_CONFIG" "$MD_CONFIG"
    _debug2 "MD_CONFIG" "$MD_CONFIG"
  fi

  SERVICES_FILE="$DOMAIN_PATH/multideploy.json"
  _check_structure "$SERVICES_FILE" || return 1

  # Iterate through all services
  echo $(jq -r ".configs.$MD_CONFIG" "$SERVICES_FILE") | jq -c '.[]' | while read -r SERVICE; do
    NAME=$(echo "$SERVICE" | jq -r '.name')
    HOOK=$(echo "$SERVICE" | jq -r '.hook')
    VARS=$(echo "$SERVICE" | jq -r '.vars | to_entries | .[] | "\(.key)=\"\(.value)\""')

    _debug2 "NAME" "$NAME"
    _debug2 "HOOK" "$HOOK"
    _secure_debug2 VARS "$VARS"

    IFS=$'\n'
    _debug2 "Exporting all variables"
    for VAR in $VARS; do
      export "$(_resolve_variables "$VAR")"
    done
    IFS=$' \t\n'

    _info "$(__green "Deploying") to '$NAME' using '$HOOK'"
    if echo "$DOMAIN_PATH" | grep -q "$ECC_SUFFIX"; then
      _debug2 "User wants to use ECC."
      deploy "$_cdomain" "$HOOK" "isEcc"
    else
      deploy "$_cdomain" "$HOOK"
    fi

    # Delete exported variables
    _debug2 "Deleting all variables"
    IFS=$'\n'
    for VAR in $VARS; do
      KEY=$(echo "$VAR" | cut -d'=' -f1)
      _debug3 "Deleting KEY" "$KEY"
      _cleardomainconf "SAVED_$KEY"
      unset "$KEY"
    done
    IFS=$' \t\n'
  done


  _debug2 "Setting Le_DeployHook"
  _savedomainconf "Le_DeployHook" "multideploy"

  return 0
}

####################  Private functions below ##################################

# var
_resolve_variables() {
  var="$1"
  key=$(echo "$var" | cut -d'=' -f1)
  value=$(echo "$var" | cut -d'=' -f2-)

  _secure_debug3 "Resolving $key" "$value"
  while echo "$value" | grep -q '\$'; do
    value=\"$(eval "echo $value")\"
  done

  _secure_debug3 "Resolved $key" "$value"
  echo "$key=$value"
}

_check_structure() {
  services_file="$1"
  services_version="1.0"

  # Check if the services_file exists
  if [ ! -f "$services_file" ]; then
    _err "Services file not found."
    _debug3 "Creating a default template."

    # Create a default template
    echo '{
    "version": "'$services_version'",
    "configs": {
        "default": [
            {
                "name": "example",
                "hook": "example",
                "vars": {
                    "EXAMPLE_VAR": "example"
                }
            }
        ]
    }
}' >"$services_file"

    _info "$(__green "Services file created") at $services_file. Edit it to add your services and try again."
    return 1
  fi

  # Check if jq is installed
  if ! command -v jq >/dev/null 2>&1; then
    _err "jq is required but not installed. Please install jq and try again."
    return 1
  fi

  # Check if version is 1.0
  VERSION=$(jq -r '.version' "$services_file")
  if [ "$VERSION" != $services_version ]; then
    _err "Version is not $services_version! Found: $VERSION"
    return 1
  fi
  _debug3 "VERSION" "$VERSION"

  # Check if configs contain the default configuration
  CONFIGS=$(jq -r '.configs | keys' "$services_file")
  if ! echo "$CONFIGS" | grep -q "$MD_CONFIG"; then
    _err "Configuration $MD_CONFIG not found in configs."
    return 1
  fi
  _debug3 "CONFIGS" "$CONFIGS"

  # Extract services of the selected configuration
  SERVICES=$(jq -r ".configs.$MD_CONFIG" "$services_file")
  if [ -z "$SERVICES" ] || [ "$SERVICES" = "[]" ]; then
    _err "No services found in configuration '$MD_CONFIG'."
    return 1
  fi
  _debug "SERVICES" "$SERVICES"

  # Iterate through all services
  echo "$SERVICES" | jq -c '.[]' | while read -r SERVICE; do
    error_count=0
    NAME=$(echo "$SERVICE" | jq -r '.name')
    HOOK=$(echo "$SERVICE" | jq -r '.hook')
    VARS=$(echo "$SERVICE" | jq -r '.vars')

    # Check if name and hook are strings
    _debug3 "NAME" "$NAME"
    if [ -z "$NAME" ] || [ "$NAME" = "null" ] || ! [[ "$NAME" =~ ^[a-zA-Z0-9_\-]+$ ]]; then
      _err "Service: 'name' is missing or not a string."
      error_count=$((error_count + 1))
    fi

    _debug3 "HOOK" "$HOOK"
    if [ -z "$HOOK" ] || [ "$HOOK" = "null" ] || ! [[ "$HOOK" =~ ^[a-zA-Z0-9_\-]+$ ]]; then
      _err "Service $NAME: 'hook' is missing or not a string."
      error_count=$((error_count + 1))
    fi

    if [ -z "$VARS" ] || [ "$VARS" = "null" ]; then
      _err "Service $NAME: 'vars' is missing or does not contain values."
      error_count=$((error_count + 1))
    else
      # Check if vars is an object and all its values are strings
      VAR_KEYS=$(echo "$VARS" | jq -r 'keys[]')
      for KEY in $VAR_KEYS; do
        VALUE=$(echo "$VARS" | jq -r ".\"$KEY\"")
        _secure_debug3 "$KEY" "$VALUE"
        if [ -z "$VALUE" ] && [ "$VALUE" != "" ]; then
          _err "Service $NAME: 'vars.$KEY' is missing or not a string."
          error_count=$((error_count + 1))
        fi
      done
    fi

    if [ $error_count -gt 0 ]; then
      _err "$error_count errors found in service '$NAME'."
      return 1
    fi
  done

  if [ $? -ne 0 ]; then
    return 1
  fi

  _info "$(__green "Configuration validated")"
  return 0
}
