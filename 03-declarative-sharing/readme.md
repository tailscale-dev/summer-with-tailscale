# Declarative Node Sharing

Tailnets are isolated by design, but often we need to share resources across tailnets. Cross-tailnet sharing isn't new—in fact, you can achieve it today [without Declarative Node Sharing](https://tailscale.com/docs/features/sharing). 

However, sharing a resource manually requires generating an invitation link, sharing it out-of-band, waiting for the recipient to accept, and adjusting policy files. This multi-step, multi-dashboard workflow creates friction and fails to scale for automated pipelines or agentic workflows. 

**Declarative Node Sharing** brings this process into your policy file as code, providing a single source of truth for cross-tailnet connectivity.

---
## Did You Join The Waitlist?

As of this writing, Declarative Node Sharing is an alpha and only accessible via a waitlist (and subject to changes). To join, head to your Tailscale console, navigate to the **Settings** tab, and click the **Join the waitlist** button.

Only one side of the relationship needs to be enrolled: the **sharing tailnet** (the one exposing its own resources) must have been accepted into the alpha. The **receiving tailnet** (the one whose group/tag gets referenced) needs no special access at all.

<img width="1484" height="770" alt="03 DeclarativeSharing_signup_full_snap" src="https://github.com/user-attachments/assets/1e9cb3b9-ee0a-4780-851f-f0ff69f4e474" />


## A Single Policy File to Rule Them All

In Tailscale, a policy file is the source of truth on what can and cannot happen in your tailnet. There are multiple parts in a policy file: ACLs, Grants, Autoapprovers, groups, etc., and each one plays a role that ultimately either permits or denies a traffic. Declarative Node Sharing adds a new section to your policy file and, similar to Grants, it can reference an external entity (`tailnet`) to allow them to communicate to your tailnet.

This demo has two parts:
- The **receiving tailnet (debugfleet)** controls which of its own local groups/tags an external tailnet is allowed to reference.
- The **sharing tailnet (gitworkflows)** writes the `grants` that give those referenced external groups/tags access to one of *its own* local resources.

Nothing connects until both sides have made their respective edit.

### 1. Register the External Tailnet

To establish communication between Tailnets you define the target tailnet inside `externalTailnets` by providing their unique id and what sort of reach (access) they should have to your network (more on this later). After that, you can pack this whole reference in an object and give it a name so it can be used in other parts of the policy file, similar to how you create groups.

The following example is a declarative sharing description, written in **gitworkflows's** own policy file (recall `gitworkflows` is our sharing tailnet, per the roles above):
```jsonc
// gitworkflows's policy file
{
  "externalTailnets": {
    "debugfleet": {
      "externalID": "TyPybmMic721MTEST",
      "allowIncomingConnections": true
    }
  }
}
```
It's worth noting that `allowIncomingConnections: true` says that we, `gitworkflows` (the sharing tailnet), accept incoming traffic from `debugfleet` (the receiving tailnet). That's only half of it though: `debugfleet` still needs to allow us and reference its own group as a `src` (check the receiving-tailnet example below); otherwise this entry has nothing to point at.

After you've created your `externalTailnets` object in the policy file you should use its object name to enforce a behaviour.
For example, in the following we are going to permit the `debugfleet` external tailnet to reach every destination within our own `gitworkflows` tailnet.
```jsonc
// gitworkflows's policy file
"grants": [
    {
        "src": ["group://debugfleet/all"],
        "dst": ["*"],
        "ip": ["*"]
    }
]
```

At this point, you might be wondering, since `dst` and `ip` are a blanket permit in a production environment this could be problematic, or even keeping up with this style would be another problem added to your plate since IPs can change and machines might get replaced. Not to mention, if you've moved Tailscale from your homelab to your business or company, the scale is going to be bigger and in such environments you are usually working with orchestrators like Kubernetes which will recreate pods faster than IPs can be assigned to them.

Great news, you don't have to work with IPs. The beauty of using the same policy file for declarative sharing is that you can use your other defined values (tags, groups, etc..) to police these external connections just like any other resource in your Tailnet.

In the following example, `debugfleet` plays the **receiving tailnet** role: instead of exposing everything, it only allows the external tailnet `gitworkflows` to reference its own `group:foo` — meaning it's *debugfleet's* `group:foo` members who become eligible to reach into `gitworkflows`'s resources, not the other way around.
```jsonc
// debugfleet's policy file
{
    "externalTailnets": {
        "gitworkflows": {
            "externalID": "TySIDEBic721MTEST",
            "allowExternalReferencesTo": ["group:foo"]
        }
    },
    "groups": {
        "group:foo": ["user@example2.com"]
    }
}
```

### 2. The other half of the story

That's only `debugfleet`'s half of the sharing which scoped access down to `group:foo`, `gitworkflows` — still playing the **sharing tailnet** role — should tighten its earlier grant to reference that specific group instead of `/all`:
```jsonc
// gitworkflows's policy file (updated)
{
  "externalTailnets": {
    "debugfleet": {
      "externalID": "TyPybmMic721MTEST",
      "allowIncomingConnections": true
    }
  },
  "grants": [
    {
      "src": ["group://debugfleet/foo"],
      "dst": ["<some resource local to gitworkflows>"],
      "ip": ["*"]
    }
  ]
}
```
Only once both edits exist — `debugfleet`'s `allowExternalReferencesTo` and `gitworkflows`'s `allowIncomingConnections` + grant — can `debugfleet`'s `group:foo` members actually reach into `gitworkflows`.

> **Bidirectional sharing:** In this example only `debugfleet`'s group gets access into `gitworkflows`. When both tailnets need to reach each other both sides needs to have `allowIncomingConnections: true` *and* `allowExternalReferencesTo` together, and each tailnet also writes its own `grants` referencing the other's tag as `src`.

## What's next?

Now that you know the basics of automation with Tailscale, deploying an application using these features via scripts should be straightforward. 

In the next module, we will pull together everything you've learned so far and create two isolated tailnets, attaching an application to each, and establishing cross-app communication—completely automated with scripts. 


## References

- [Declarative node sharing](https://tailscale.com/docs/features/declarative-node-sharing)
