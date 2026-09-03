# Tailnet Sandboxes

A tailnet is a foundational component of Tailscale. By default, every user is assigned a tailnet upon account creation. Tailnets are secure, private virtual networks that interconnect your devices, services, and resources across any physical location or infrastructure.

While a single tailnet works well for everyday networking, you often need isolated environments for testing, multi-tenant deployments, or sandboxed AI workloads.

Tailscale allows you to programmatically provision additional, completely isolated tailnets using the Tailscale API.

## Manual walkthrough (no scripts, just curl)

This part is a walkthrough over the raw API calls, no scripts involved. We'll create an additional tailnet to isolate the `probe` and `tool-server` deployments on a sandboxed secure network.

Before we get started, create an OAuth client in the console and export its credentials as environment variables. Scope the client narrowly to what this walkthrough needs: under **Custom scopes**, grant **Tailnets: Read + Write** and leave everything else unchecked—an OAuth client with blanket admin access is more than this requires.

![Editing an OAuth client's scopes in the Tailscale console, with the Tailnets scope set to Read and Write](screenshot-oauth-client.png)

```bash
export CLIENT_ID=<your OAuth client id>
export CLIENT_SECRET=<your OAuth client secret>
```

Next, exchange the ID and Secret with an access token, this part is done via a POST request to the tailscale API endpoint.
```bash
# 1. Exchange CLIENT_ID/CLIENT_SECRET for a short-lived access token
ACCESS_TOKEN=$(curl -sS -X POST "https://api.tailscale.com/api/v2/oauth/token" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  | jq -r '.access_token')
```

Now that we have the access token stored in the terminal, we can access other endpoints that are part of the Tailscale API.

Use the following command to create an additional Tailnet in your account:
```bash
curl -sS https://api.tailscale.com/api/v2/organizations/-/tailnets \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --data '{"displayName": "agent-sandbox"}'
```

> **Important**: Save the JSON output returned by this command. It contains the scoped admin credentials for the newly created tailnet—your org-level `$ACCESS_TOKEN` can't delete it later; only these credentials can.

example API response
```json
{"id":"T4nzP1SHT921CNTRL","displayName":"agent-sandbox","orgId":"oAUSxgKxZQ11CNTRL","dnsName":"taild4bc6b.ts.net","createdAt":"2026-08-13T04:17:14Z","oauthClient":{"id":"kHN12PmWUw11CNTRL","secret":"tskey-client-kHN12PmWUw11CNTRL-e4VB9oXiRq2j1RZSZ4yjp2xN5T3jdteQ"}}
```

## List and Delete your additional Tailnets

### List Tailnets

At any point you can use your token to query all the Tailnets that are associated with your account.

Use the following command to list all your tailnets:
```bash
curl -sS https://api.tailscale.com/api/v2/organizations/-/tailnets \
  --header "Authorization: Bearer $ACCESS_TOKEN" | jq
```
### Delete a Tailnet

To delete a tailnet, issue a DELETE request referencing the tailnet ID. The org-level `$ACCESS_TOKEN` from earlier won't work here—deletion requires a token scoped to that specific tailnet, so exchange the `oauthClient` credentials from its creation response (the same exchange as the very first step, just with that tailnet's own `id`/`secret`) for their own access token first:
```bash
TAILNET_ACCESS_TOKEN=$(curl -sS -X POST "https://api.tailscale.com/api/v2/oauth/token" \
  -d "client_id=kHN12PmWUw11CNTRL" \
  -d "client_secret=tskey-client-kHN12PmWUw11CNTRL-e4VB9oXiRq2j1RZSZ4yjp2xN5T3jdteQ" \
  | jq -r '.access_token')

curl https://api.tailscale.com/api/v2/tailnet/T4nzP1SHT921CNTRL \
  --request DELETE \
  --header "Authorization: Bearer $TAILNET_ACCESS_TOKEN"
```

**Security Note:** If an OAuth client ID or secret is ever compromised, revoke it immediately. Do not simply modify its permissions, as active access tokens may remain valid until expiration.

### Access Token Recovery

If you lose your API-only tailnet's OAuth credentials, you can regain access using an OAuth client from the parent tailnet. As long as that client has the all scope, it can request a new OAuth access token for the API-only tailnet by passing its tailnet ID in the /token request.

<img width="670" height="273" alt="screenshot-oauth-allscope" src="https://github.com/user-attachments/assets/5804793d-334c-4fd0-b5fd-de665a6185f8" />


```bash
TAILNET_ACCESS_TOKEN=$(curl -sS -X POST "https://api.tailscale.com/api/v2/oauth/token" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "tailnet=T4nzP1SHT921CNTRL" \
  | jq -r '.access_token')
```

## What's next?

Now that you can programmatically provision isolated tailnets, the next module explores how to connect workloads, containers, and microservices directly to your tailnet without installing the standard system-level Tailscale daemon—comparing embedded tsnet vs. daemon installation.


## References

- [What is a tailnet?](https://tailscale.com/docs/concepts/tailnet)
- [Additional tailnets](https://tailscale.com/api#tag/organizations)
- [Trust-credentials](https://tailscale.com/kb/1623/trust-credentials)
