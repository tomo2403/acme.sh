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
    _info "MD_CONFIG is not set, so we will use default."
  else
    _savedeployconf "MD_CONFIG" "$MD_CONFIG"
    _debug2 "MD_CONFIG" "$MD_CONFIG"
  fi

  SERVICES_FILE="$DOMAIN_PATH/services.json"
  _validate_services_json "$SERVICES_FILE" || return 1

  SERVICES=$(jq -c ".configs.\"$MD_CONFIG\"[]" "$SERVICES_FILE")

  for SERVICE in $SERVICES; do
    HOOK=$(echo "$SERVICE" | jq -r '.hook')
    VARS=$(echo "$SERVICE" | jq -r '.vars | to_entries | .[] | "\(.key)=\(.value)"')

    for var in $VARS; do
      _secure_debug2 "Exporting $var"
      export "$(_resolve_variables "$var")"
    done

    _info "$(__green "Deploying to service") ($(echo "$SERVICE" | jq -r '.name') via $HOOK)"
    if echo "$DOMAIN_PATH" | grep -q "$ECC_SUFFIX"; then
      _debug "User wants to use ECC."
      deploy "$_cdomain" "$HOOK" "isEcc"
    else
      deploy "$_cdomain" "$HOOK"
    fi

    # Delete exported variables
    for VAR in $VARS; do
      KEY=$(echo "$VAR" | cut -d'=' -f1)
      _debug3 "Deleting KEY" "$KEY"
      _cleardomainconf "SAVED_$KEY"
      unset "$KEY"
    done
  done

  _debug3 "Setting Le_DeployHook"
  _savedomainconf "Le_DeployHook" "multideploy"

  return 0
}

####################  Private functions below ##################################

# var
_resolve_variables() {
  var="$1"
  key=$(echo "$var" | cut -d'=' -f1)
  value=$(echo "$var" | cut -d'=' -f2-)

  while echo "$value" | grep -q '\$'; do
    value=$(eval "echo \"$value\"")
  done

  echo "$key=$value"
}

# filepath
_validate_services_json() {
  services_file="$1"
  required_version="1.0"
  error_count=0

  # Check if the file exists
  if [ ! -f "$services_file" ]; then
    _err "Services file $services_file not found."
    _debug2 "Creating a default template."

    # Create a default template
    echo '{
    "version": "'$required_version'",
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

    _info "$(__green "Default services file created at $services_file.") Edit it to add your services and try again."
    return 1
  fi

  # Check if jq is installed
  if ! command -v jq >/dev/null; then
    _err "jq could not be found. Please install jq to use this script."
    return 1
  fi

  # Check if the file is a valid JSON
  if ! jq empty "$services_file" >/dev/null 2>&1; then
    _err "Invalid JSON format in $services_file."
    return 1
  fi

  # Check the version
  version=$(jq -r '.version' "$services_file")
  if [ "$version" != "$required_version" ]; then
    _err "Version mismatch. Expected $required_version, got $version."
    return 1
  fi

  # Use the selected config (MD_CONFIG)
  selected_config=$(jq -e ".configs[\"$MD_CONFIG\"]" "$services_file")
  if [ $? -ne 0 ]; then
    _err "'$MD_CONFIG' config not found in $services_file."
    return 1
  fi

  # Validate each service in the selected config
  services=$(echo "$selected_config" | jq -c '.[]')
  _secure_debug2 "services" "$services"
  for service in $services; do
    name=$(echo "$service" | jq -r '.name')
    hook=$(echo "$service" | jq -r '.hook')
    vars=$(echo "$service" | jq -c '.vars')

    # Check if name and hook are strings
    if [ -z "$name" ] || [ "$name" = "null" ]; then
      _err "Service name is missing or not a string in $service."
      error_count=$((error_count + 1))
    fi

    if [ -z "$hook" ] || [ "$hook" = "null" ]; then
      _err "Service hook is missing or not a string in $service."
      error_count=$((error_count + 1))
    fi

    if [ -z "$vars" ] || [ "$vars" = "null" ]; then
      _err "Service vars is missing or not an object in $service."
      error_count=$((error_count + 1))
    fi
  done

  if [ $error_count -gt 0 ]; then
    _err "$error_count errors found during validation."
    return 1
  fi

  _info "Services file $services_file validated successfully for config '$MD_CONFIG'."
  return 0
}
