#!/usr/bin/env bash
#
# end-to-end.sh — chains modules 01-03 together, driven entirely by the
# Tailscale API. This script doesn't introduce new concepts; it's the four
# modules run back to back. If a step below is unclear, the referenced
# readme walks through that exact API call by hand:
#
#   1. Provision two isolated tailnets            -> ../01-tailnet-sandboxes/readme.md
#   2. Bring up a tsnet app inside each one        -> ../02-tailnet-membership/readme.md
#   3. Declaratively share the two tailnets        -> ../03-declarative-sharing/readme.md
#   4. (this file) wire it together via the API    -> ./readme.md
#
# Usage:
#   export CLIENT_ID=<org-level OAuth client id>       # or put them in ../.env
#   export CLIENT_SECRET=<org-level OAuth client secret>
#   ./end-to-end.sh up       # provision, deploy, and share (needs CLIENT_ID/CLIENT_SECRET)
#   ./end-to-end.sh up --direction one   # one-directional: only sandbox-b's
#                             # tag can reach into sandbox-a (default is
#                             # bidirectional: --direction bi)
#   ./end-to-end.sh status   # show what's running
#   ./end-to-end.sh policy   # dump each sandbox tailnet's current policy file
#                             # (uses the per-tailnet credentials saved under
#                             # .state/, not CLIENT_ID/CLIENT_SECRET)
#   ./end-to-end.sh down     # tear everything back down (uses the per-tailnet
#                             # credentials saved under .state/, not CLIENT_ID/CLIENT_SECRET)
#
# Requires: curl, jq, docker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$SCRIPT_DIR/.state"
APP_IMAGE="ts-demo-app"
DOMAIN="https://api.tailscale.com"

# Two isolated tailnets get created and torn down by this script.
LABELS=(a b)

# bi: both sandboxes can reach each other. one: only sandbox-b can reach
# sandbox-a (sandbox-a shares its app; sandbox-b never shares anything back).
DIRECTION="bi"

log()  { printf '\033[1;34m[e2e]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[e2e]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[e2e]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

parse_up_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --direction)   DIRECTION="${2:-}"; shift 2 ;;
      --direction=*) DIRECTION="${1#*=}"; shift ;;
      *) die "unknown argument to 'up': $1" ;;
    esac
  done
  case "$DIRECTION" in
    bi|one) ;;
    *) die "--direction must be 'bi' or 'one' (got '$DIRECTION')" ;;
  esac
}

# For 'one', sandbox-a is always the sharer (exposes its own app) and
# sandbox-b is always the receiver (its tag gets referenced, no grant back).
sharing_role_for() {
  local label="$1"
  if [[ "$DIRECTION" == "bi" ]]; then
    echo "both"
  elif [[ "$label" == "a" ]]; then
    echo "share"
  else
    echo "receive"
  fi
}

load_env() {
# Show an error when .env is not found
  if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a; source "$ROOT_DIR/.env"; set +a
  fi
}

require_env() {
  load_env
  [[ -n "${CLIENT_ID:-}" && -n "${CLIENT_SECRET:-}" ]] \
    || die "CLIENT_ID/CLIENT_SECRET not set (export them, or fill in $ROOT_DIR/.env — see .env.example)"
}

# --- Step 0: org-level access token -----------------------------------
# Same exchange as ../01-tailnet-sandboxes/readme.md. This token is only
# used to create/delete the two sandbox tailnets below; every other call
# uses the scoped token handed back for that specific tailnet.
org_access_token() {
  curl -sS -X POST "$DOMAIN/api/v2/oauth/token" \
    -d "client_id=$CLIENT_ID" \
    -d "client_secret=$CLIENT_SECRET" \
    | jq -r '.access_token'
}

# --- Step 1: provision two isolated tailnets ---------------------------
# See ../01-tailnet-sandboxes/readme.md for the same call explained line
# by line, including why the response must be saved immediately.
create_tailnet() {
  local label="$1" token="$2"
  curl -sS "$DOMAIN/api/v2/organizations/-/tailnets" \
    --request POST \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" \
    --data "{\"displayName\": \"e2e-sandbox-$label\"}"
}

tailnet_access_token() {
  local client_id="$1" client_secret="$2"
  curl -sS -X POST "$DOMAIN/api/v2/oauth/token" \
    -d "client_id=$client_id" \
    -d "client_secret=$client_secret" \
    | jq -r '.access_token'
}

# --- Step 1.5: turn on HTTPS certs for the new tailnet ------------------
# A fresh tailnet has HTTPS certificates off by default, and ../02-tailnet-
# membership/main.go calls srv.ListenTLS — without this, that call fails
# at runtime with "you must enable HTTPS in the admin panel to proceed".
# There's no dedicated toggle endpoint in the public API docs, but the
# tailnet settings resource accepts a PATCH for it.
enable_https() {
  local token="$1"
  curl -sS "$DOMAIN/api/v2/tailnet/-/settings" \
    --request PATCH \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" \
    --data '{"httpsEnabled": true}' --fail-with-body -o /dev/null
}

# --- Step 2: tag the policy file + declaratively share -----------------
# Split into two calls on purpose: tagOwners is plain ACL housekeeping
# needed before we can issue a tagged auth key below, and must succeed.
# externalTailnets/grants is the declarative sharing pattern from
# ../03-declarative-sharing/readme.md, which is still waitlist-gated — if
# your account isn't enrolled, the Tailscale API rejects that whole POST
# (as one atomic policy update) with "external tailnet not allowed in
# local policy grants". Keeping it in a separate call means that failure
# can't also take the tag declaration down with it.
get_policy() {
  local token="$1"
  # The ACL endpoint returns HuJSON (JSON with comments) by default, which
  # jq can't parse — ask for plain JSON instead.
  curl -sS "$DOMAIN/api/v2/tailnet/-/acl" \
    --header "Authorization: Bearer $token" \
    --header 'Accept: application/json'
}

put_policy() {
  local token="$1" policy="$2"
  curl -sS "$DOMAIN/api/v2/tailnet/-/acl" \
    --request POST \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" \
    --data "$policy" --fail-with-body -o /dev/null
}

patch_policy_tag() {
  local token="$1" new
  new=$(jq '.tagOwners["tag:tsnet-app"] = (.tagOwners["tag:tsnet-app"] // ["autogroup:admin"])' \
    <<<"$(get_policy "$token")")
  put_policy "$token" "$new"
}

patch_policy_sharing() {
  local token="$1" other_id="$2" other_label="$3" role="$4"
  local new
  # role "share":   accept incoming connections + write the grant that
  #                 exposes our own tag to the referenced external group.
  # role "receive": only let the external tailnet reference our tag —
  #                 no grant, we're not exposing anything of our own.
  # role "both":    do both (bidirectional sharing). Declarative sharing is
  #                 like routing, it needs to be mutually agreed upon.
  new=$(jq \
    --arg tag "tag:tsnet-app" \
    --arg name "sandbox-$other_label" \
    --arg id "$other_id" \
    --arg role "$role" \
    '.externalTailnets[$name] =
        ( {"externalID": $id}
          + (if ($role == "share" or $role == "both") then {"allowIncomingConnections": true} else {} end)
          + (if ($role == "receive" or $role == "both") then {"allowExternalReferencesTo": [$tag]} else {} end)
        )
     | (if ($role == "share" or $role == "both") then
         .grants = ((.grants // []) + [{"src": ["tag://\($name)/tsnet-app"], "dst": [$tag], "ip": ["*"]}])
       else . end)' \
    <<<"$(get_policy "$token")")

  put_policy "$token" "$new" \
    && log "policy updated for sandbox-$other_label sharing (role: $role)" \
    || warn "policy update failed (likely not on the Declarative Sharing waitlist) — continuing without cross-tailnet sharing"
}

# --- Step 3: issue a scoped auth key ------------------------------------
# See ../04-api-is-the-way/readme.md, "Issuing auth keys instead of
# copy-pasting them" for what each field below does.
issue_auth_key() {
  local token="$1"
  curl -sS "$DOMAIN/api/v2/tailnet/-/keys" \
    --request POST \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" \
    --data '{
      "capabilities": {
        "devices": {
          "create": {
            "reusable": false,
            "ephemeral": true,
            "preauthorized": true,
            "tags": ["tag:tsnet-app"]
          }
        }
      },
      "expirySeconds": 3600
    }' | jq -r '.key'
}

# --- Step 4: deploy the tsnet app ---------------------------------------
# This is exactly ../02-tailnet-membership/main.go, built from its
# dockerfile, given an auth key instead of a dashboard-issued one. It
# serves "Hello from tsnet" directly over HTTPS on the tailnet — no
# backend to stand up.
device_ids_by_hostname() {
  local token="$1" hostname="$2"
  curl -sS "$DOMAIN/api/v2/tailnet/-/devices" \
      --header "Authorization: Bearer $token" \
    | jq -r --arg h "$hostname" '.devices[] | select(.hostname == $h) | .id'
}
# This part solves the problem where a device is deleted but its still listed in the Tailnet.
delete_device() {
  local token="$1" id="$2"
  curl -sS "$DOMAIN/api/v2/device/$id" --request DELETE --header "Authorization: Bearer $token" -o /dev/null
}

deploy_app() {
  local label="$1" authkey="$2" token="$3"
  local hostname="sandbox-$label-app" device_ids reply

  device_ids=$(device_ids_by_hostname "$token" "$hostname")

  # Only ask when there's actually something from a previous run to tear
  # down -- a clean first deploy shouldn't need confirmation.
  if docker inspect "ts-demo-app-$label" >/dev/null 2>&1 || [[ -n "$device_ids" ]]; then
    warn "$hostname already exists from a previous run (docker container and/or tailnet device)."
    if [[ -t 0 ]]; then
      read -r -p "$(printf '\033[1;34m[e2e]\033[0m remove it and redeploy? [y/N] ')" reply
      [[ "$reply" =~ ^[Yy] ]] || die "aborted: leaving $hostname in place, not redeployed"
    else
      die "$hostname already exists and stdin isn't a terminal to confirm removal -- run '$0 up' interactively, or remove it yourself first"
    fi
    docker rm -f "ts-demo-app-$label" >/dev/null 2>&1 || true
  fi



  # Free the hostname on the Tailscale side
  local id
  for id in $device_ids; do
    delete_device "$token" "$id"
  done

  docker run -d --name "ts-demo-app-$label" \
    -e "TS_HOSTNAME=sandbox-$label-app" \
    -e "TS_AUTHKEY=$authkey" \
    "$APP_IMAGE" >/dev/null
}

# --- Step 5: verify the sharing grant is actually reachable -------------
# This part runs two probe to check the actual flow of traffic.
PROBE_IMAGE="tailscale/tailscale"

tailnet_token_from_state() {
  local label="$1" cid csecret
  cid=$(jq -r '.oauthClient.id' "$STATE_DIR/tailnet-$label.json")
  csecret=$(jq -r '.oauthClient.secret' "$STATE_DIR/tailnet-$label.json")
  tailnet_access_token "$cid" "$csecret"
}

verify_connectivity() {
  local from_label="$1" from_token="$2" to_host="$3" probe_key

  probe_key=$(curl -sS "$DOMAIN/api/v2/tailnet/-/keys" \
    --request POST \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $from_token" \
    --data '{
      "capabilities": {
        "devices": {
          "create": {
            "reusable": false,
            "ephemeral": true,
            "preauthorized": true,
            "tags": ["tag:tsnet-app"]
          }
        }
      },
      "expirySeconds": 300
    }' | jq -r '.key')
  [[ -n "$probe_key" && "$probe_key" != "null" ]] \
    || { warn "could not issue probe key for sandbox-$from_label — skipping connectivity check"; return 1; }

  log "probing sandbox-$from_label -> $to_host (joins a short-lived probe device, ~10-30s)"
  # A simple pass/fail here isn't enough to tell what is the issue,
  # a real ACL denial apart from "tailscale up" never completing, DNS not
  # resolving the cross-tailnet MagicDNS name, or the shared peer just not
  # having propagated into this probe's netmap yet. The nc retry loop
  # covers that last case (netmap propagation lagging a few seconds behind
  # "tailscale up" returning); everything else prints straight to stderr.
  if docker run --rm \
      -e TS_AUTHKEY="$probe_key" \
      -e TO_HOST="$to_host" \
      "$PROBE_IMAGE" \
      sh -c '
        tailscaled --tun=userspace-networking --state=mem: --socket=/tmp/ts.sock >/tmp/tailscaled.log 2>&1 &
        up=1
        for i in $(seq 1 30); do
          tailscale --socket=/tmp/ts.sock up --authkey="$TS_AUTHKEY" --hostname="probe-$$" 2>/tmp/up.log && { up=0; break; }
          sleep 1
        done
        if [ "$up" -ne 0 ]; then
          echo "[probe] tailscale up never succeeded:" >&2
          cat /tmp/up.log >&2
          echo "[probe] tailscaled log:" >&2
          cat /tmp/tailscaled.log >&2
          exit 1
        fi
        echo "[probe] joined tailnet, connecting to $TO_HOST:443" >&2
        ok=1
        for i in $(seq 1 10); do
          if tailscale --socket=/tmp/ts.sock nc "$TO_HOST" 443 </dev/null 2>/tmp/nc.log; then
            ok=0; break
          fi
          sleep 2
        done
        if [ "$ok" -ne 0 ]; then
          echo "[probe] tailscale nc failed after retries:" >&2
          cat /tmp/nc.log >&2
          echo "[probe] tailscale status:" >&2
          tailscale --socket=/tmp/ts.sock status >&2
          exit 1
        fi
      '
  then
    log "connectivity OK: sandbox-$from_label can reach $to_host"
  else
    warn "connectivity check FAILED: sandbox-$from_label could not reach $to_host over the tailnet (see [probe] output above)"
  fi
}

cmd_up() {
  require_env
  require_cmd curl; require_cmd jq; require_cmd docker
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  log "requesting org access token"
  local org_token; org_token=$(org_access_token)
  [[ "$org_token" != "null" && -n "$org_token" ]] || die "failed to get org access token — check CLIENT_ID/CLIENT_SECRET"

  log "building tsnet app image from ../02-tailnet-membership"
  docker build -q -f "$ROOT_DIR/02-tailnet-membership/dockerfile" -t "$APP_IMAGE" "$ROOT_DIR/02-tailnet-membership" >/dev/null

  for label in "${LABELS[@]}"; do
    local f="$STATE_DIR/tailnet-$label.json"

    # There is a secret let's reuse it
    if [[ -f "$f" ]] && jq -e '.oauthClient.secret' "$f" >/dev/null 2>&1; then
      log "reusing existing tailnet state for e2e-sandbox-$label"
      continue
    fi

    # Don't write down keys if its an error
    log "creating tailnet e2e-sandbox-$label"
    create_tailnet "$label" "$org_token" > "$f.tmp"
    if jq -e '.oauthClient.secret' "$f.tmp" >/dev/null 2>&1; then
      mv "$f.tmp" "$f"
      chmod 600 "$f"
    else
      local msg; msg=$(jq -r '.message // .' "$f.tmp" 2>/dev/null) || msg=$(cat "$f.tmp")
      rm -f "$f.tmp"
      die "tailnet creation failed for e2e-sandbox-$label: $msg"
    fi
  done

  for label in "${LABELS[@]}"; do
    local other; other=$([[ "$label" == "a" ]] && echo b || echo a)
    local cid csecret token authkey

    cid=$(jq -r '.oauthClient.id' "$STATE_DIR/tailnet-$label.json")
    csecret=$(jq -r '.oauthClient.secret' "$STATE_DIR/tailnet-$label.json")
    token=$(tailnet_access_token "$cid" "$csecret")

    log "enabling HTTPS certs for sandbox-$label"
    enable_https "$token" || die "failed to enable HTTPS certs for sandbox-$label"

    log "declaring tag:tsnet-app for sandbox-$label"
    patch_policy_tag "$token" || die "failed to update policy tags for sandbox-$label"

    other_id=$(jq -r '.id' "$STATE_DIR/tailnet-$other.json")
    local role; role=$(sharing_role_for "$label")
    log "updating policy for sandbox-$label -> sandbox-$other sharing (role: $role, direction: $DIRECTION)"
    patch_policy_sharing "$token" "$other_id" "$other" "$role"

    log "issuing tsnet auth key for sandbox-$label"
    authkey=$(issue_auth_key "$token")
    [[ -n "$authkey" && "$authkey" != "null" ]] || die "failed to issue auth key for sandbox-$label"

    log "deploying app for sandbox-$label"
    deploy_app "$label" "$authkey" "$token"
  done

  log "verifying cross-tailnet connectivity (direction: $DIRECTION)"
  local dns_a dns_b token_a token_b
  dns_a=$(jq -r '.dnsName' "$STATE_DIR/tailnet-a.json")
  dns_b=$(jq -r '.dnsName' "$STATE_DIR/tailnet-b.json")
  token_a=$(tailnet_token_from_state a)
  token_b=$(tailnet_token_from_state b)
  if [[ "$DIRECTION" == "bi" ]]; then
    verify_connectivity a "$token_a" "sandbox-b-app.$dns_b"
  else
    log "one-directional sharing: sandbox-a shares but doesn't receive access, skipping sandbox-a -> sandbox-b probe"
  fi
  verify_connectivity b "$token_b" "sandbox-a-app.$dns_a"

  log "done. run '$0 status' to see the two apps."
}

cmd_status() {
  [[ -d "$STATE_DIR" ]] || die "nothing is up (no $STATE_DIR) — run '$0 up' first"
  for label in "${LABELS[@]}"; do
    local f="$STATE_DIR/tailnet-$label.json"
    [[ -f "$f" ]] || continue
    local dns; dns=$(jq -r '.dnsName' "$f")
    echo "sandbox-$label:  https://sandbox-$label-app.$dns"
  done
  echo
  docker ps --filter "name=ts-demo-" --format 'table {{.Names}}\t{{.Status}}'
}

cmd_policy() {
  require_cmd curl; require_cmd jq
  [[ -d "$STATE_DIR" ]] || die "nothing is up (no $STATE_DIR) — run '$0 up' first"
  local dumped=false
  for label in "${LABELS[@]}"; do
    local f="$STATE_DIR/tailnet-$label.json"
    [[ -f "$f" ]] || continue

    local token; token=$(tailnet_token_from_state "$label")
    if [[ "$token" == "null" || -z "$token" ]]; then
      warn "could not get an access token for sandbox-$label — skipping"
      continue
    fi

    log "policy for sandbox-$label:"
    get_policy "$token" | jq .
    echo
    dumped=true
  done
  [[ "$dumped" == true ]] || die "no sandbox tailnet state found under $STATE_DIR"
}

cmd_down() {
  require_cmd curl; require_cmd jq; require_cmd docker

  # Docker resources never need a Tailscale credential to remove, so this
  # always runs even if CLIENT_ID/CLIENT_SECRET are missing or rotated.
  for label in "${LABELS[@]}"; do
    docker rm -f "ts-demo-app-$label" >/dev/null 2>&1 || true
  done
  docker rmi "$APP_IMAGE" >/dev/null 2>&1 || true
  log "docker resources removed"

  if [[ -d "$STATE_DIR" ]]; then
    # Deletion requires a token scoped to the specific tailnet being
    # deleted — the org-level CLIENT_ID/CLIENT_SECRET can't do it, only
    # the oauthClient credentials returned when that tailnet was created
    # can. See ../01-tailnet-sandboxes/readme.md, "Delete a Tailnet".
    # That means `down` doesn't need CLIENT_ID/CLIENT_SECRET at all —
    # everything it needs is already sitting in $STATE_DIR.
    local all_deleted=true
    for label in "${LABELS[@]}"; do
      local f="$STATE_DIR/tailnet-$label.json"
      [[ -f "$f" ]] || continue

      local id cid csecret token
      id=$(jq -r '.id' "$f")
      cid=$(jq -r '.oauthClient.id' "$f")
      csecret=$(jq -r '.oauthClient.secret' "$f")
      token=$(tailnet_access_token "$cid" "$csecret")
      if [[ "$token" == "null" || -z "$token" ]]; then
        warn "could not get an access token for tailnet $id (sandbox-$label) — leaving it in $STATE_DIR"
        all_deleted=false
        continue
      fi

      log "deleting tailnet $id (sandbox-$label)"
      curl -sS "$DOMAIN/api/v2/tailnet/$id" \
        --request DELETE \
        --header "Authorization: Bearer $token" -o /dev/null \
        || { warn "could not delete tailnet $id — check the console"; all_deleted=false; }
    done
    # Only wipe the state (and the credentials it holds) once every
    # tailnet it references is confirmed gone.
    [[ "$all_deleted" == true ]] && rm -rf "$STATE_DIR"
  fi
  log "done."
}

case "${1:-}" in
  up)
    shift
    parse_up_args "$@"
    cmd_up
    ;;
  status) cmd_status ;;
  policy) cmd_policy ;;
  down)   cmd_down ;;
  *) die "usage: $0 {up [--direction bi|one]|status|policy|down}" ;;
esac
