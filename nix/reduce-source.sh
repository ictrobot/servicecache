#!/usr/bin/env bash
set -euo pipefail
cd "${1:?source directory}"
exclusions="${2:?exclusions file}"
shopt -s dotglob nullglob

check_path() {
  local path="$1" parent="$1"
  case "/$path/" in
    *'//'* | *'/./'* | *'/../'*)
      echo "source exclusion needs a relative path without dot components: $path" >&2
      exit 1
      ;;
  esac
  while [[ "$parent" == */* ]]; do
    parent="${parent%/*}"
    [[ ! -L "$parent" ]] || {
      echo "source exclusion traverses a symlink: $path" >&2
      exit 1
    }
  done
  [[ -e "$path" || -L "$path" ]] || {
    echo "source exclusion or keep names a missing path: $path" >&2
    exit 1
  }
}

remove_path() {
  local path="$1" keep child descend=false
  for keep in "${kept[@]}"; do
    if [[ "$path" == "$keep" || "$path" == "$keep/"* ]]; then
      return 0
    fi
    if [[ "$keep" == "$path/"* ]]; then
      descend=true
    fi
  done
  if "$descend"; then
    for child in "$path"/*; do
      remove_path "$child"
    done
  else
    rm -rf -- "$path"
  fi
}

while IFS= read -r rule; do
  mapfile -t paths < <(jq -r '.paths[] | rtrimstr("/")' <<<"$rule")
  mapfile -t kept < <(jq -r '.keep[] | rtrimstr("/")' <<<"$rule")
  for path in "${paths[@]}" "${kept[@]}"; do
    check_path "$path"
  done
  for keep in "${kept[@]}"; do
    contained=false
    for path in "${paths[@]}"; do
      if [[ "$keep" == "$path" || "$keep" == "$path/"* ]]; then
        contained=true
        break
      fi
    done
    "$contained" || {
      echo "source keep is outside this rule's excluded paths: $keep" >&2
      exit 1
    }
  done
  for path in "${paths[@]}"; do
    remove_path "$path"
  done
done < <(jq -c '.[]' "$exclusions")
