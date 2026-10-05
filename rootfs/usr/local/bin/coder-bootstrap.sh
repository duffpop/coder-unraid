#!/bin/bash
# Runs as the coder user in the background after the server starts.
# Creates the first admin user and installs the license from environment
# variables. Everything is idempotent and failures never stop the server.
set -uo pipefail

log() { echo "[coder-bootstrap] $*"; }

EMAIL="${CODER_FIRST_USER_EMAIL:-}"
USERNAME="${CODER_FIRST_USER_USERNAME:-}"
PASSWORD="${CODER_FIRST_USER_PASSWORD:-}"
FULL_NAME="${CODER_FIRST_USER_FULL_NAME:-}"
LICENSE="${CODER_LICENSE:-}"

have_creds=0
if [[ -n "$EMAIL" && -n "$USERNAME" && -n "$PASSWORD" ]]; then
  have_creds=1
fi

if [[ $have_creds -eq 0 && -z "$LICENSE" ]]; then
  exit 0
fi
if [[ $have_creds -eq 0 && -n "$LICENSE" ]]; then
  log "WARNING: CODER_LICENSE is set but the bootstrap admin email, username and password are not."
  log "WARNING: The license cannot be applied automatically. Add it under Admin settings > Deployment > Licenses."
  exit 0
fi

# Local URL to talk to this server. With TLS on and redirect-to-access-URL on,
# Coder 307s plain HTTP requests, so go through the TLS listener instead.
CURL_OPTS=()
if [[ "${CODER_TLS_ENABLE:-}" == "true" && ( "${CODER_REDIRECT_TO_ACCESS_URL:-}" == "true" || -z "${CODER_HTTP_ADDRESS:-}" ) ]]; then
  addr="${CODER_TLS_ADDRESS:-127.0.0.1:3443}"
  BASE="https://127.0.0.1:${addr##*:}"
  CURL_OPTS=(-k)
else
  addr="${CODER_HTTP_ADDRESS:-127.0.0.1:3000}"
  BASE="http://127.0.0.1:${addr##*:}"
fi

# Present the access URL host so CODER_REDIRECT_TO_ACCESS_URL does not bounce us.
host_header=()
if [[ -n "${CODER_ACCESS_URL:-}" ]]; then
  h="${CODER_ACCESS_URL#*://}"; h="${h%%/*}"
  host_header=(-H "Host: ${h}")
fi

TOKEN=""
STATUS=""
BODY=""
api() { # method path [json-body] -> sets $STATUS and $BODY (never call in a subshell)
  local method=$1 path=$2 body=${3:-}
  local -a extra=()
  [[ -n "$TOKEN" ]] && extra+=(-H "Coder-Session-Token: $TOKEN")
  [[ -n "$body" ]] && extra+=(--data-binary "$body")
  local out
  out=$(curl -sS -o - -w '\n%{http_code}' "${CURL_OPTS[@]}" -X "$method" "${host_header[@]}" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    "${extra[@]}" "${BASE}${path}" 2>/dev/null)
  STATUS="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}
jqmsg() { printf '%s' "$BODY" | jq -r "$1" 2>/dev/null | tr '\n' ' '; }

log "waiting for Coder at ${BASE} ..."
deadline=$(( $(date +%s) + 900 ))
until [[ "$(curl -s -o /dev/null -w '%{http_code}' "${CURL_OPTS[@]}" "${host_header[@]}" "${BASE}/healthz")" == "200" ]]; do
  if (( $(date +%s) > deadline )); then
    log "WARNING: server did not become healthy within 15 minutes, skipping bootstrap"
    exit 0
  fi
  sleep 3
done
# /healthz comes up before the API is fully ready; make sure buildinfo answers too.
until [[ "$(curl -s -o /dev/null -w '%{http_code}' "${CURL_OPTS[@]}" "${host_header[@]}" "${BASE}/api/v2/buildinfo")" == "200" ]]; do
  sleep 2
done

# First user
api GET /api/v2/users/first
if [[ "$STATUS" == "404" ]]; then
  log "creating first user '${USERNAME}'"
  payload=$(jq -nc --arg e "$EMAIL" --arg u "$USERNAME" --arg n "$FULL_NAME" --arg p "$PASSWORD" \
    '{email:$e, username:$u, password:$p, trial:false} + (if $n != "" then {name:$n} else {} end)')
  api POST /api/v2/users/first "$payload"
  if [[ "$STATUS" == "201" || "$STATUS" == "409" ]]; then
    log "first user ready (HTTP $STATUS)"
  else
    log "ERROR: creating first user failed (HTTP $STATUS): $(jqmsg '.message // empty, .detail // empty, (.validations[]? | "\(.field): \(.detail)")')"
    exit 0
  fi
elif [[ "$STATUS" != "200" ]]; then
  log "WARNING: unexpected response checking first user (HTTP $STATUS), skipping bootstrap"
  exit 0
fi

[[ -z "$LICENSE" ]] && exit 0

# Login
api POST /api/v2/users/login "$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')"
if [[ "$STATUS" != "201" ]]; then
  log "WARNING: login as ${EMAIL} failed (HTTP $STATUS). If the admin password was changed in the UI, update CODER_FIRST_USER_PASSWORD or add the license manually."
  exit 0
fi
TOKEN=$(printf '%s' "$BODY" | jq -r '.session_token')

# License
b64() { # base64url decode
  local s=${1//-/+}; s=${s//_//}
  while (( ${#s} % 4 )); do s+="="; done
  printf '%s' "$s" | base64 -d 2>/dev/null
}
seg=$(printf '%s' "$LICENSE" | tr -d '[:space:]' | cut -d. -f2)
jti=$(b64 "$seg" | jq -r '.jti // empty' 2>/dev/null)
if [[ -z "$jti" ]]; then
  log "WARNING: CODER_LICENSE does not look like a Coder license JWT, skipping"
  exit 0
fi

api GET /api/v2/licenses
if [[ "$STATUS" != "200" ]]; then
  log "WARNING: could not list licenses (HTTP $STATUS)"
  exit 0
fi
if printf '%s' "$BODY" | jq -e --arg id "$jti" 'map(.uuid) | index($id) != null' >/dev/null; then
  log "license ${jti} is already installed"
  exit 0
fi

api POST /api/v2/licenses "$(jq -nc --arg l "$(printf '%s' "$LICENSE" | tr -d '[:space:]')" '{license:$l}')"
if [[ "$STATUS" == "201" ]]; then
  exp=$(jqmsg '.claims.license_expires // empty')
  [[ -n "$exp" ]] && exp=" (expires $(date -u -d "@$exp" +%F 2>/dev/null || echo "$exp"))"
  log "license ${jti} installed${exp}"
else
  log "ERROR: installing license failed (HTTP $STATUS): $(jqmsg '.message // empty, .detail // empty')"
fi
