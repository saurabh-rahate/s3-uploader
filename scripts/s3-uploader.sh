#!/usr/bin/env bash
#
# Lints, diffs and uploads JSON files to S3. The Makefile calls it as:
#
#   scripts/s3-uploader.sh lint
#   scripts/s3-uploader.sh diff   <environment> <dir>
#   scripts/s3-uploader.sh upload <environment> <dir>
#
# Each upload lives in src/files/<dir>/<environment>/: a config.json saying where
# the file goes, and the JSON file it names. See README.md for the rules.
#
# Sticks to bash 3.2 features so it also runs on macOS's built-in bash.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly FILES_ROOT=src/files
readonly DEFAULT_REGION=ap-south-1
# environment and dir must be plain folder names.
readonly NAME_PATTERN='^[A-Za-z0-9_-][A-Za-z0-9._-]*$'

# Keep the AWS CLI from opening a pager.
export AWS_PAGER=""

# Filled in by check_config.
PROBLEMS=""
PROBLEM_COUNT=0
BUCKET=""
KEY=""
REGION=""
SOURCE=""

# Temporary copy of the file currently in S3, used by diff.
CURRENT_COPY=""

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 lint | diff <environment> <dir> | upload <environment> <dir>" >&2
  exit 2
}

require_jq() {
  command -v jq >/dev/null 2>&1 || fail "jq is not installed."
}

require_aws() {
  command -v aws >/dev/null 2>&1 || fail "the AWS CLI is not installed."
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] || fail "AWS_ACCESS_KEY_ID is not set."
  [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || fail "AWS_SECRET_ACCESS_KEY is not set."
}

add_problem() {
  PROBLEMS="$PROBLEMS$1"$'\n'
  PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
}

# Prints why a file isn't exactly one valid JSON document, or nothing if it is.
# jq on its own accepts empty files, several documents in one file and NaN, so those are checked too.
json_problem() {
  local output
  if output=$(jq -r -s '
      if length == 0 then "file is empty"
      elif length > 1 then "file holds more than one JSON document"
      elif any(.[0] | .. | numbers; isnan) then "NaN is not valid JSON"
      else empty end' "$1" 2>&1); then
    printf '%s' "$output"
  else
    output=${output#jq: }
    printf '%s' "${output:-not valid JSON}"
  fi
}

# Checks a config.json and the file it names, without contacting AWS.
# Sets BUCKET, KEY, REGION and SOURCE, and adds anything wrong to PROBLEMS.
check_config() {
  local config=$1 folder problem file raw_path path
  folder=$(dirname "$config")
  PROBLEMS=""
  PROBLEM_COUNT=0
  BUCKET=""
  KEY=""
  REGION=""
  SOURCE=""

  problem=$(json_problem "$config")
  if [ -n "$problem" ]; then
    add_problem "$config: $problem"
    return 0
  fi
  if [ "$(jq -r type "$config")" != object ]; then
    add_problem "$config: must be a JSON object"
    return 0
  fi

  while IFS= read -r problem; do
    add_problem "$config: $problem"
  done < <(jq -r '
    (("bucket", "path", "file") as $field
      | if .[$field] == null then "\"\($field)\" is missing"
        elif (.[$field] | type) != "string" then "\"\($field)\" must be a string"
        elif .[$field] == "" then "\"\($field)\" is empty"
        else empty end),
    (if has("region") and (.region | type) != "string" then "\"region\" must be a string"
     elif .region == "" then "\"region\" is empty"
     else empty end)' "$config")

  BUCKET=$(jq -r '.bucket | strings' "$config")
  REGION=$(jq -r --arg default "$DEFAULT_REGION" '(.region | strings) // $default' "$config")
  file=$(jq -r '.file | strings' "$config")

  # Drop slashes at either end, so "/a/b/" and "a/b" mean the same folder.
  raw_path=$(jq -r '.path | strings' "$config")
  path=$(printf '%s' "$raw_path" | sed -e 's#^/*##' -e 's#/*$##')
  if [ -n "$raw_path" ] && [ -z "$path" ]; then
    add_problem "$config: \"path\" must name a folder, not just \"$raw_path\""
  fi
  KEY="$path/$file"

  case $file in
    "") ;; # Already reported above.
    */*) add_problem "$config: \"file\" must be a file name, not a path" ;;
    . | .. | config.json) add_problem "$config: \"file\" can't be \"$file\"" ;;
    *)
      if [ ! -f "$folder/$file" ]; then
        add_problem "$config: \"file\" is \"$file\", but $folder/$file does not exist"
      else
        SOURCE="$folder/$file"
        problem=$(json_problem "$SOURCE")
        if [ -n "$problem" ]; then
          add_problem "$SOURCE: $problem"
        fi
      fi
      ;;
  esac
}

# Finds and checks the config for one upload, and prints where the file goes.
load_upload() {
  local command=$1 environment=$2 dir=$3 config

  if [ -z "$environment" ] || [ -z "$dir" ]; then
    fail "environment and dir are required, e.g. make $command environment=dev dir=MY_FOLDER"
  fi
  [[ $environment =~ $NAME_PATTERN ]] || fail "environment must be a folder name, got \"$environment\"."
  [[ $dir =~ $NAME_PATTERN ]] || fail "dir must be a folder name, got \"$dir\"."

  config="$FILES_ROOT/$dir/$environment/config.json"
  [ -f "$config" ] || fail "$config not found."

  check_config "$config"
  if [ "$PROBLEM_COUNT" -gt 0 ]; then
    echo "Error: fix these problems first:" >&2
    printf '%s' "$PROBLEMS" | sed 's/^/  /' >&2
    exit 1
  fi

  echo "Source:      $SOURCE"
  echo "Destination: s3://$BUCKET/$KEY"
  echo "Region:      $REGION"
  echo
}

run_lint() {
  local config file problem checked=$'\n' checked_count=0 problem_total=0

  [ -d "$FILES_ROOT" ] || fail "$FILES_ROOT not found."

  # Each config.json gets the same checks as diff and upload, including the file it names.
  while IFS= read -r config; do
    check_config "$config"
    checked_count=$((checked_count + 1))
    if [ -n "$SOURCE" ]; then
      checked="$checked$SOURCE"$'\n'
      checked_count=$((checked_count + 1))
    fi
    if [ "$PROBLEM_COUNT" -eq 0 ]; then
      echo "ok    $config"
      echo "ok    $SOURCE"
    else
      printf '%s' "$PROBLEMS" | sed 's/^/FAIL  /'
      problem_total=$((problem_total + PROBLEM_COUNT))
    fi
  done < <(find "$FILES_ROOT" -type f -name config.json | sort)

  # Any other JSON file must be valid too, even if no config names it.
  while IFS= read -r file; do
    if [[ $checked == *$'\n'"$file"$'\n'* ]]; then
      continue
    fi
    checked_count=$((checked_count + 1))
    problem=$(json_problem "$file")
    if [ -z "$problem" ]; then
      echo "ok    $file"
    else
      echo "FAIL  $file: $problem"
      problem_total=$((problem_total + 1))
    fi
  done < <(find "$FILES_ROOT" -type f -name '*.json' ! -name config.json | sort)

  echo
  if [ "$problem_total" -gt 0 ]; then
    echo "Lint failed: $problem_total problem(s) found." >&2
    exit 1
  fi
  echo "Lint passed: $checked_count file(s) checked."
}

run_diff() {
  local error before before_label status=0

  load_upload diff "$1" "$2"
  require_aws
  command -v diff >/dev/null 2>&1 || fail "diff is not installed."

  CURRENT_COPY=$(mktemp)
  trap 'rm -f "$CURRENT_COPY"' EXIT

  if error=$(aws s3api get-object --bucket "$BUCKET" --key "$KEY" --region "$REGION" "$CURRENT_COPY" 2>&1 >/dev/null); then
    before=$CURRENT_COPY
    before_label="s3://$BUCKET/$KEY (current)"
  elif [[ $error == *NoSuchKey* ]]; then
    echo "Nothing exists at the destination yet, so the whole file is new."
    echo
    before=/dev/null
    before_label="s3://$BUCKET/$KEY (does not exist yet)"
  elif [[ $error == *AccessDenied* ]]; then
    fail "access denied reading s3://$BUCKET/$KEY.
The credentials need s3:GetObject on the file, and s3:ListBucket on the bucket so that a missing file isn't reported as access denied.
${error#$'\n'}"
  else
    fail "could not read s3://$BUCKET/$KEY.
${error#$'\n'}"
  fi

  diff -u --label "$before_label" --label "$SOURCE (new)" "$before" "$SOURCE" || status=$?
  case $status in
    0) echo "No changes: the file in S3 already matches $SOURCE." ;;
    1) ;;
    *) fail "diff could not compare the files." ;;
  esac
}

run_upload() {
  load_upload upload "$1" "$2"
  require_aws
  aws s3 cp "$SOURCE" "s3://$BUCKET/$KEY" --region "$REGION" --content-type application/json --no-progress
}

case ${1:-} in
  lint)
    require_jq
    run_lint
    ;;
  diff)
    require_jq
    run_diff "${2:-}" "${3:-}"
    ;;
  upload)
    require_jq
    run_upload "${2:-}" "${3:-}"
    ;;
  *)
    usage
    ;;
esac
