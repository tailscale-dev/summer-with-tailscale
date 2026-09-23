# API (This is the way)

Across this series you've provisioned isolated tailnets from the console, embedded Tailscale into an application with `tsnet`, and rewritten cross-tailnet sharing as policy-as-code. Each of those workflows has a manual escape hatch—click through the admin console, copy an auth key from the dashboard, edit the policy file in the browser editor. The Tailscale API is what removes the escape hatch. Every action that you did manually in modules 01–03 has a corresponding API call, which means the entire lifecycle of a tailnet—creation, device onboarding, and policy management—can be driven from a single script or pipeline.

## Authentication, one more time

Every API call in this module reuses the same OAuth exchange from [module 01](../01-tailnet-sandboxes/readme.md): trade a client ID and secret for a short-lived access token, then attach it as a bearer token to every request.

```bash
export CLIENT_ID=<your OAuth client id>
export CLIENT_SECRET=<your OAuth client secret>

ACCESS_TOKEN=$(curl -sS -X POST "https://api.tailscale.com/api/v2/oauth/token" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  | jq -r '.access_token')
```

Scope the OAuth client narrowly for whatever step you're automating (`devices:core`, `policy_file`, `auth_keys`, etc.)—a token with blanket admin access defeats the purpose of scripting this instead of clicking through the console.

## Turning on HTTPS certs (so `ListenTLS` actually works)

A freshly created tailnet has HTTPS certificates turned off by default. [Module 02](../02-tailnet-membership/readme.md)'s `srv.ListenTLS(...)` call depends on this being on—without it, `tsnet` fails at runtime with `you must enable HTTPS in the admin panel to proceed`. This isn't in the console under an obvious toggle you'd think to script around, and it isn't a dedicated API endpoint either—but the tailnet settings resource accepts a `PATCH` for it:

```bash
curl -sS "https://api.tailscale.com/api/v2/tailnet/-/settings" \
  --request PATCH \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --data '{"httpsEnabled": true}'
```

Do this once per tailnet, right after creating it and before anything tries to listen on `:443`.

## Issuing auth keys instead of copy-pasting them

In [module 02](../02-tailnet-membership/readme.md), `tsnet` picked up credentials from an auth key or OAuth client baked into the environment. Rather than generating that key by hand in the console, request one from the API and hand it straight to the deployment:

```bash
curl -sS "https://api.tailscale.com/api/v2/tailnet/-/keys" \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
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
```

Feed the resulting key straight into `TS_AUTHKEY` for the container or process running `tsnet`—no dashboard visit required, and the key is scoped, tagged, and short-lived by construction.

## Editing the policy file as data, not a text box

[Module 03](../03-declarative-sharing/readme.md) walked through declarative sharing as JSON inside the policy file. The console's policy editor is just a thin wrapper over `GET`/`POST` against the same file, so you can read and write it directly:

```bash
# Pull the current policy file
curl -sS "https://api.tailscale.com/api/v2/tailnet/-/acl" \
  --header "Authorization: Bearer $ACCESS_TOKEN" | jq . > policy.json

# ...edit policy.json (add externalTailnets, grants, tags, whatever the change is)...

# Push it back
curl -sS "https://api.tailscale.com/api/v2/tailnet/-/acl" \
  --request POST \
  --header 'Content-Type: application/hujson' \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --data @policy.json
```

Because the policy file is just JSON/HuJSON, it's diffable and reviewable like any other config—generate it from a template, run it through CI, and only ever push a change that's been validated.

## Putting it together

Chaining the calls above turns the whole series into one script:

1. Provision a tailnet (module 01).
2. Turn on HTTPS certs for it.
3. Tag the policy file, and add the new tailnet to `externalTailnets`/`grants` (module 03).
4. Request a scoped, tagged auth key and use it to bring up a `tsnet` app (module 02).

None of these steps touch the console UI. That's the point of this module: the API isn't a shortcut for the things you already did manually—it's the one interface that every other workflow in Tailscale, including the console itself, is built on top of.

`end-to-end.sh` in this directory is a runnable version of the steps above: it provisions two tailnets, turns on HTTPS for each, deploys the `tsnet` app from module 02 into each one, and declaratively shares them, all through the API.

```bash
./end-to-end.sh up       # provision, deploy, and share
./end-to-end.sh status   # see the two apps that came up
./end-to-end.sh policy   # dump each sandbox tailnet's current policy file
./end-to-end.sh down     # tear everything back down
```

The script is deliberately thin—each step is a direct translation of a curl call from this readme (or from [module 01](../01-tailnet-sandboxes/readme.md), [module 02](../02-tailnet-membership/readme.md), and [module 03](../03-declarative-sharing/readme.md)) plus a little `docker` glue to actually run the app. Read the script's comments alongside those modules if you want to see exactly which call maps to which line.

`up` also takes `--direction bi|one` (bidirectional sharing is the default; `one` limits it to sandbox-b reaching into sandbox-a) and `--only <steps>` to run a subset of the pipeline instead of the whole thing (e.g. `--only sharing,verify`). And any step can be pointed at an existing tailnet instead of one this script provisions: set `SANDBOX_A_CLIENT_ID`/`SANDBOX_A_CLIENT_SECRET` (and, depending on the step, `SANDBOX_A_TAILNET_ID`/`SANDBOX_A_DNS_NAME`) — or the `SANDBOX_B_*` equivalents — and that label is left alone by `sandboxes`/`down`, with `app`/`sharing` printing the exact change to make by hand and pausing until it's confirmed live, instead of writing to a tailnet the script doesn't own. See the script's header comment and `../.env.example` for the full list of overrides.

## What's next?

This wraps up the core series. From here, the natural next step is turning these curl calls into a real automation—wire them into CI/CD, a Terraform provider, or an internal service that provisions sandboxes on demand for agents or short-lived workloads.

## References

- [Tailscale API reference](https://tailscale.com/api)
- [How to enable HTTPS](https://tailscale.com/docs/how-to/set-up-https-certificates)
- [Auth keys](https://tailscale.com/kb/1085/auth-keys/)
- [Policy file (ACL) reference](https://tailscale.com/kb/1018/acl-tags)
- [OAuth clients](https://tailscale.com/kb/1215/oauth-clients)
