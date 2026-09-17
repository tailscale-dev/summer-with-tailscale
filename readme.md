Building with, and on, Tailscale
===
##  Tailscale summer 2026 update code and script examples

This repository provides scripts and code patterns to programmatically provision isolated Tailscale networks (tailnets), embed Zero-Trust connectivity directly into application binaries using tsnet, and automate cross-tailnet resource sharing via policy files.

What's Included
Programmatic Tailnet Management: Scripts to create, list, and delete isolated tailnet sandboxes using the Tailscale Console API without manual dashboard interaction.

Embedded App Networking (tsnet): Examples demonstrating how to bundle Tailscale directly inside Go applications to run isolated microservices and automatically handle HTTPS TLS certificates.

Declarative Sharing: Policy configuration patterns to establish secure cross-tailnet communication channels entirely via code.

# Prerequisites

* A Tailscale account with API access
* Docker or GO (for tsnet applications)
* curl and jq installed locally

# Run it end to end

Read through the modules below at your own pace, or skip straight to `04-api-is-the-way/end-to-end.sh`, which chains all of them together: it provisions two isolated tailnets, deploys the `tsnet` app from module 02 into each one, and declaratively shares them so the two apps can reach each other — all driven by the Tailscale API, no console clicks required.

```bash
cp .env.example .env   # fill in CLIENT_ID/CLIENT_SECRET
cd 04-api-is-the-way
./end-to-end.sh up       # provision, deploy, and share
./end-to-end.sh status   # see the two apps that came up
./end-to-end.sh down     # tear everything back down
```

The script itself is intentionally thin — just the API calls from the modules below, chained together with a bit of docker glue. If a step it takes isn't obvious, the corresponding module walks through that exact call by hand:

* [01-tailnet-sandboxes](01-tailnet-sandboxes/readme.md) — how the script's two tailnets get created
* [02-tailnet-membership](02-tailnet-membership/readme.md) — the `tsnet` app the script deploys into each one
* [03-declarative-sharing](03-declarative-sharing/readme.md) — how the script connects the two tailnets together
* [04-api-is-the-way](04-api-is-the-way/readme.md) — the API calls the script itself is built from

