#!/bin/bash
set -eou pipefail

FACTORIO_VERSION=$1
MOD_DIR=$2
USERNAME=$3
TOKEN=$4

MOD_BASE_URL="https://mods.factorio.com"

print_step()
{
  echo "$1"
}

print_success()
{
  echo "$1"
}

print_failure()
{
  echo "$1"
}

# Checks game version vs version in mod.
# Returns 0 if major version differs or mod minor version is less than game version, 1 if ok
check_game_version() {
  local game_version="$1"
  local mod_version="$2"

  local game_major mod_major game_minor mod_minor
  game_major=$(echo "$game_version" | cut -d '.' -f1)
  game_minor=$(echo "$game_version" | cut -d '.' -f2)
  mod_major=$(echo "$mod_version" | cut -d '.' -f1)
  mod_minor=$(echo "$mod_version" | cut -d '.' -f2)

  if [[ "$game_major" -ne "$mod_major" ]]; then
    echo 0
    return
  fi

  if [[ "$mod_minor" -ge "$game_minor" ]]; then
    echo 1
  else
    echo 0
  fi
}

# Checks dependency string with provided version.
# Only checks for operator based string, ignoring everything else
# Returns 1 if check is ok, 0 if not
check_dependency_version()
{
  local dependency="$1"
  local mod_version="$2"

  if [[ "$dependency" =~ ^(\?|!|~|\(~\)) ]]; then
    echo 1
  fi

  local condition
  condition=$(echo "$dependency" | grep -oE '(>=|<=|>|<|=) [0-9]+(\.[0-9]+)*')

  if [[ -z "$condition" ]]; then
    echo 1
  fi

  local operator required_version
  operator=$(echo "$condition" | awk '{print $1}')
  required_version=$(echo "$condition" | awk '{print $2}')

  case "$operator" in
    ">=")
      if [[ "$(printf '%s\n%s\n' "$required_version" "$mod_version" | sort -V | head -n1)" == "$required_version" ]]; then
        echo 1
      else
        echo 0
      fi
      ;;
    ">")
      if [[ "$(printf '%s\n%s\n' "$required_version" "$mod_version" | sort -V | head -n1)" == "$required_version" && "$required_version" != "$FACTORIO_VERSION" ]]; then
        echo 1
      else
        echo 0
      fi
      ;;
    "<=")
      if [[ "$(printf '%s\n%s\n' "$required_version" "$mod_version" | sort -V | tail -n1)" == "$required_version" ]]; then
        echo 1
      else
        echo 0
      fi
      ;;
    "<")
      if [[ "$(printf '%s\n%s\n' "$required_version" "$mod_version" | sort -V | tail -n1)" == "$required_version" && "$required_version" != "$FACTORIO_VERSION" ]]; then
        echo 1
      else
        echo 0
      fi
      ;;
    "=")
      if [[ "$mod_version" == "$required_version" ]]; then
        echo 1
      else
        echo 0
      fi
      ;;
    *)
      echo 0
      ;;
  esac
}

get_mod_info()
{
  local mod_info_json="$1"

  while IFS= read -r mod_release_info; do
    local mod_version mod_factorio_version
    mod_version=$(echo "$mod_release_info" | jq -r ".version")
    mod_factorio_version=$(echo "$mod_release_info" | jq -r ".info_json.factorio_version")

    if [[ $(check_game_version "$mod_factorio_version" "$FACTORIO_VERSION") == 0 ]]; then
      echo "  Skipping mod version $mod_version because of factorio version mismatch"  >&2
      continue
    fi

    # If we found 'dependencies' element, we also check versions there
    if [[ $(echo "$mod_release_info" | jq -e '.info_json | has("dependencies") and (.dependencies | length > 0)') == true ]]; then
      while IFS= read -r dependency; do

        # We only check for 'base' dependency
        if [[ "$dependency" == base* ]] && [[ $(check_dependency_version "$dependency" "$FACTORIO_VERSION") == 0 ]]; then
          echo "  Skipping mod version $mod_version, unsatisfied base dependency: $dependency" >&2
          continue 2
        fi

      done < <(echo "$mod_release_info" | jq -r '.info_json.dependencies[]')
    fi

    echo "$mod_release_info" | jq -j ".file_name, \";\", .download_url, \";\", .sha1"
    break

  done < <(echo "$mod_info_json" | jq -c ".releases|sort_by(.released_at)|reverse|.[]")
}

update_mod()
{
  MOD_NAME="$1"
  MOD_NAME_ENCODED="${1// /%20}"

  print_step "Checking for update of mod $MOD_NAME for factorio $FACTORIO_VERSION ..."

  MOD_INFO_URL="$MOD_BASE_URL/api/mods/$MOD_NAME_ENCODED/full"
  MOD_INFO_JSON=$(curl --silent "$MOD_INFO_URL")

  if ! echo "$MOD_INFO_JSON" | jq -e .name >/dev/null; then
    print_success "  Custom mod not on $MOD_BASE_URL, skipped."
    return 0
  fi

  MOD_INFO=$(get_mod_info "$MOD_INFO_JSON")

  if [[ "$MOD_INFO" == "" ]]; then
    print_failure "  Not compatible with version"
    return 0
  fi

  MOD_FILENAME=$(echo "$MOD_INFO" | cut -f1 -d";")
  MOD_URL=$(echo "$MOD_INFO" | cut -f2 -d";")
  MOD_SHA1=$(echo "$MOD_INFO" | cut -f3 -d";")

  if [[ $MOD_FILENAME == null ]]; then
    print_failure "  Not compatible with version"
    return 0
  fi

  if [[ -f $MOD_DIR/$MOD_FILENAME ]]; then
    print_success "  Already up-to-date."
    return 0
  fi

  print_step "  Downloading $MOD_FILENAME"
  FULL_URL="$MOD_BASE_URL$MOD_URL?username=$USERNAME&token=$TOKEN"
  HTTP_STATUS=$(curl --silent -L -w "%{http_code}" -o "$MOD_DIR/$MOD_FILENAME" "$FULL_URL")

  if [[ $HTTP_STATUS != 200 ]]; then
    print_failure "  Download failed: Code $HTTP_STATUS."
    rm -f "$MOD_DIR/$MOD_FILENAME"
    return 1
  fi

  if [[ ! -f $MOD_DIR/$MOD_FILENAME ]]; then
    print_failure "  Downloaded file missing!"
    return 1
  fi

  if ! [[ $(sha1sum "$MOD_DIR/$MOD_FILENAME") =~ $MOD_SHA1 ]]; then
    print_failure "  SHA1 mismatch!"
    rm -f "$MOD_DIR/$MOD_FILENAME"
    return 1
  fi

  print_success "  Download complete."

  for file in "$MOD_DIR/${MOD_NAME}_"*".zip"; do # wildcard does usually not work in quotes: https://unix.stackexchange.com/a/67761
    if [[ $file != $MOD_DIR/$MOD_FILENAME ]]; then
      print_success "  Deleting old version: $file"
      rm -f "$file"
    fi
  done

  return 0
}

if [[ -f $MOD_DIR/mod-list.json ]]; then
  jq -r ".mods|map(select(.enabled))|.[].name" "$MOD_DIR/mod-list.json" | while read -r mod; do
    if [[ $mod != base ]]; then
      update_mod "$mod" || true
    fi
  done
fi
