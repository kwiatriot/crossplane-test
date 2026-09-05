# crossplane-aws-lab

A hands-on comparison of Crossplane's continuous-reconciliation model against
OpenTofu's plan/apply model, provisioning a small AWS stack in `us-west-2`.

This is a learning lab, not production. Everything is re-creatable from this repo.

## What it builds

- VPC `10.42.0.0/16`, public + private subnets across `us-west-2a`/`b`, IGW,
  public route table. **No NAT gateway** (cost).
- `t3.micro` AL2023 instance in a public subnet, reachable **only** via SSM
  Session Manager — security group has zero inbound rules.
- Private S3 bucket behind CloudFront via Origin Access Control, default
  `*.cloudfront.net` domain, no ACM/Route53.

## Versions (verified 2026-09-05)

| Component | Version |
| --- | --- |
| Kubernetes | 1.34.10 |
| Crossplane core + chart | 2.4.0 |
| Crossplane CLI | 2.5.0 (versions independently of core) |
| Upbound AWS providers | 2.7.1 (family releases in lockstep) |

## Bootstrap

```bash
# 1. control plane
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --version 2.4.0 -f bootstrap/helm-values.yaml --wait

# 2. providers (wait for HEALTHY)
kubectl apply -f bootstrap/providers.yaml
kubectl wait provider.pkg.crossplane.io --all --for=condition=Healthy --timeout=10m

# 3. namespace + credentials + providerconfig
kubectl apply -f bootstrap/namespace.yaml
cp bootstrap/aws-credentials.ini.template bootstrap/aws-credentials.ini
$EDITOR bootstrap/aws-credentials.ini      # paste the IAM user access key
bash scripts/load-creds.sh
kubectl apply -f bootstrap/providerconfig.yaml

# 4. resources -- ALWAYS server-side apply (see "Applying does not converge" below)
kubectl apply -f phase2-raw-mrs/ --server-side --force-conflicts

# 5. check
bash scripts/verify.sh
bash scripts/drift-check.sh
```

Teardown: `bash scripts/teardown.sh`

## Things that are genuinely different from OpenTofu

### The v2 namespaced/cluster split is the biggest footgun

Crossplane 2 publishes **every** MR kind twice: namespaced under `*.aws.m.upbound.io`
and cluster-scoped under the legacy `*.aws.upbound.io`. There are four
ProviderConfig-ish kinds:

| Group | Kind | Scope |
| --- | --- | --- |
| `aws.m.upbound.io` | `ClusterProviderConfig` | Cluster |
| `aws.m.upbound.io` | `ProviderConfig` | **Namespaced** |
| `aws.upbound.io` | `ProviderConfig` | Cluster (legacy) |
| `aws.upbound.io` | `ProviderConfigUsage` | Cluster (legacy) |

`spec.providerConfigRef` on a namespaced MR **requires `kind`** and defaults to
`ClusterProviderConfig`. Omit it and you silently reference a cluster-scoped
object that does not exist. Set it explicitly, every time.

Also: `secretRef` requires an explicit `namespace` even on the *namespaced*
ProviderConfig, so it can read a Secret from any namespace. Namespacing does not
contain credential blast radius on its own — RBAC does.

### `deletionPolicy` is gone; `ObserveOnly` was never a value

On v2 namespaced MRs the spec is exactly five fields: `forProvider`,
`initProvider`, `managementPolicies`, `providerConfigRef`,
`writeConnectionSecretToRef`.

- **No `deletionPolicy`.** Orphaning is `managementPolicies` without `Delete`.
  (The legacy cluster-scoped CRDs still have `deletionPolicy: Orphan|Delete`.)
- **No `ObserveOnly`.** The enum is
  `[Observe, Create, Update, Delete, LateInitialize, *]`, default `["*"]`.
  Observe-only is `managementPolicies: ["Observe"]`.

Much of the Crossplane material online still shows the old fields.

### Selective activation is a real win, but it is off by default

Installing four providers unfiltered would create **337 CRDs**. With
`--enable-custom-to-managed-resource-conversion` (beta) plus an explicit
activation list, we get **24** — the 19 kinds we use plus 5 ProviderConfig kinds,
which install unconditionally because they aren't managed resources.

Crossplane still creates all 332 MRDs as cheap metadata; flipping one to `Active`
later creates its CRD on demand, so adding a resource type is a one-line MRAP
edit rather than a provider reinstall.

The chart default is `provider.defaultActivations: ["*"]`, which activates
everything and quietly defeats the flag.

### Ordering is a runtime property, not a plan-time one

`*Ref`/`*Selector` fields express dependencies declaratively, and you can apply
the whole directory at once. But unresolved references surface as
`ReconcileError: cannot resolve references ... (referenced resource may not yet
be ready)` on the MR, and Crossplane simply retries until they resolve.

Applying the network group produced three of those errors before converging in
~92 seconds. **In OpenTofu that class of error is a hard failure that aborts the
apply. Here it is normal operation.** That is a real mental adjustment: a red
condition may just mean "not yet."

### Applying does not converge the cluster to the repo

The sharpest operational surprise in this build, found by accident.

During the Phase 3 experiments I added a tag to an MR's `spec` with
`kubectl patch --type=merge`. That is an RFC 7386 merge patch: it merges keys and
does **not** remove ones you omit. So my "restore" patch left the tag behind, and
when full `managementPolicies` were restored, Crossplane faithfully pushed that
test tag onto the real AWS subnet.

Re-applying the manifest — which never contained the tag — did not fix it:

| Attempt | Result |
| --- | --- |
| `kubectl apply -f` (client-side) | `unchanged`, key remains |
| `kubectl apply --server-side --force-conflicts` | `serverside-applied`, key remains |
| ...`--field-manager=kubectl-patch` | `serverside-applied`, key remains |
| `kubectl patch` setting the key to `null` | removed; AWS converged in ~1s |

The mechanic: server-side apply keys ownership on **(manager, operation)**. The
object ends up with *two* `kubectl-patch` entries — one `op=Apply` and one
`op=Update` — and an `Apply` never prunes fields the same manager owns via an
`Update`:

```
manager=kubectl        op=Apply   tags: f:Name, f:crossplane-lab
manager=kubectl-patch  op=Apply   tags: f:Name, f:crossplane-lab
manager=kubectl-patch  op=Update  tags: f:ssa-test-tag      <-- never pruned
manager=provider       op=Update  tags: f:crossplane-kind, ...
```

**So: no form of `kubectl apply` removes a spec field introduced imperatively.**

SSA is still worth using, and this repo now does — it prunes fields *it* owns
correctly (verified: a tag added to the manifest, applied, then removed from the
manifest, is deleted on the next apply), it makes ownership inspectable via
`managedFields`, and it coexists cleanly with the provider's late-initialization
writes into `spec`. But it is not a defence against imperative drift.

The real lesson is about the model, not about kubectl:

> **Crossplane reconciles the cluster against AWS. Nothing reconciles the cluster
> against Git.**

OpenTofu does not have this failure mode, because the config file *is* the desired
state on every run — there is no long-lived intermediate object to accumulate
stray fields. In Crossplane the MR is that intermediate object, and it is
writable by anyone with RBAC. Drift now has two independent surfaces:
AWS-vs-cluster (Crossplane fixes this automatically) and cluster-vs-repo
(**nothing fixes this** — it is what Argo CD/Flux are for).

`scripts/drift-check.sh` is the stopgap: it walks every manifest, compares each
declared leaf against the live spec, and flags extra tag keys, changed values,
non-default `managementPolicies`, and leftover `crossplane.io/paused`
annotations. It deliberately only checks manifest-declared keys, so provider
late-initialization is not reported as drift.

### `region` is per-resource, IAM has none

Every EC2/S3/CloudFront MR requires `spec.forProvider.region`. There is no
provider-level default region — the ProviderConfig carries credentials only. IAM
MRs have no `region` field at all. This repetition is a large part of why the
Phase 4 Composition earns its keep.

### `kubectl explain` name collisions

`kubectl explain role` resolves to Kubernetes RBAC `Role`, not the IAM one. Use
fully-qualified names: `kubectl explain roles.iam.aws.m.upbound.io.spec.forProvider`.

### Never trust the CRD description over the schema

`BucketOwnershipControls.spec.forProvider.rule` is described as
"Configuration block(s)" and is a repeatable block in Terraform — but the CRD
models it as a **single object**. Writing it as a list fails strict decoding.
Check the schema, not the prose.

### Composition gotchas found the hard way

**Composed resources get generated names unless you set `metadata.name`.**
Cross-resource refs inside a Composition (`vpcIdRef: {name: ...}`) therefore
resolve to nothing until every composed resource carries an explicit name. This
is silent — you get unresolvable refs, not an error naming the cause.

**`crossplane composition render` reads your LOCAL file; the cluster runs the
last-applied CompositionRevision.** After editing a Composition, render can
succeed while the cluster keeps failing on the old revision, and the error gives
no hint that you are looking at a stale revision. Re-apply before concluding
anything from a cluster-side error.

**Go templating whitespace will bite you.** Two failures in one file:
`{{- /* comment */ -}}` before a `---` forward-trims the newline and glues the
document separator onto the previous line, merging two YAML docs; and a comment
must end exactly at the delimiter (`*/}}`, never `*/ }}`). Neither is caught by
anything except attempting a render.

**XR status lags composed-resource readiness.** `status.instanceId` stayed empty
for minutes after the Instance was `Ready`, then populated immediately when the XR
was nudged. The XR re-renders on its own cadence; a composed resource becoming
ready does not trigger it. The beta flag `--enable-realtime-compositions` exists
precisely for this ("reconciling compositions immediately when any of the composed
resources is updated"). Without it, treat XR status as eventually-consistent.

**Crossplane adds `SYNCED`/`READY` printer columns to XRs automatically** —
declaring them in the XRD duplicates them.

### Drift behaviour under a Composition

Four tests against the Phase 4 XR. The first three are reassuring; the fourth is
the one that matters.

**Out-of-band AWS drift is still corrected.** Retagged the composed VPC directly
in AWS; reverted in 72s (vs 53s at the raw layer -- the extra hop through the XR
costs a little). Same behaviour, no surprises.

**A deleted composed MR is recreated in ~16s** -- but with a NEW external ID
(`sgr-08c2...` -> `sgr-0448...`). The AWS resource was genuinely destroyed and
rebuilt, not re-adopted. Harmless for a security group rule; destructive for an
instance, a database, or anything holding state. Deleting a composed MR to "force
a refresh" is not safe.

**The Composition only owns the fields it declares.** Patching a composed MR
directly in Kubernetes:

| Field | In the Composition? | Result |
| --- | --- | --- |
| `tags.Name` | yes | reverted in 18s |
| `tags.k8s-rogue` | **no** | **survived, and was pushed to AWS** |

The XR continued to report `SYNCED=True READY=True` the whole time. So a
Composition is not a closed abstraction -- it is an overlay of declared fields.
Anyone with RBAC on the composed MR can inject fields that reach AWS and never
get reverted, while every status signal stays green. This is the same
field-ownership model as server-side apply (see "Applying does not converge"),
and it means the XR boundary is not a security or correctness boundary.

**`crossplane-diff` works now, but it is a spec diff, not a plan.**
With an XRD present it produces a real, readable diff and correctly propagates an
XR-level change down to composed resources:

```
~~~ Instance/lab-site-instance
-     instanceType: t3.micro
+     instanceType: t3.small
Summary: 3 modified
```

Two serious caveats:

1. **It does not know what AWS will do.** Changing `vpcCidr` from `10.42.0.0/16`
   to `10.99.0.0/16` -- which forces replacement of the VPC and cascades to every
   subnet, the instance and the security group -- is reported as:

   ```
   Summary: 7 modified
   ```

   "Modified", not "replaced". `tofu plan` prints `# forces replacement` and
   shows the destroy/create cascade. This is the single most important gap: the
   output is materially misleading for exactly the changes where you most need a
   warning.

2. **It never reports a clean no-op.** Run against the *unchanged* XR it still
   reports `Summary: 1 modified`, because the Distribution's late-initialized
   `originAccessControlId` is absent from the desired state. So "0 modified" is
   not achievable and cannot be used as a gate.

Verdict: `crossplane composition render` + `crossplane-diff` together get you a
preview of *desired Kubernetes state*. Neither tells you what AWS will do in
response. That is still not `tofu plan`.

## Gotchas handled explicitly

### No data sources

There is no `data "aws_ami"`. The AL2023 AMI is a hardcoded literal in
`phase2-raw-mrs/03-instance.yaml`, resolved out-of-band:

```bash
aws ssm get-parameters --region us-west-2 \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
```

It **goes stale** (Amazon republishes ~monthly), Crossplane will not warn you,
and changing it replaces the instance.

### Missing reference fields

Most links are declarative (`vpcIdRef`, `subnetIdRef`, `routeTableIdRef`,
`gatewayIdRef`, `vpcSecurityGroupIdRefs`, `roleRef`, `bucketRef`,
`originAccessControlIdRef`). Two are not:

1. **`Instance.iamInstanceProfile`** — plain string, no ref. Worked around by
   pinning the profile name with `crossplane.io/external-name` and repeating the
   literal. The edge is invisible to Crossplane: it will try, fail against AWS,
   and retry until the profile exists. A typo yields a retry loop, not a
   reference error naming the missing object.
2. **`Distribution.origin[].domainName`** — no ref to the bucket's regional
   domain. Assembled by hand from the pinned bucket name.

### CloudFront ↔ S3 circular dependency

The standard OAC bucket policy scopes on `AWS:SourceArn` = the distribution ARN,
which does not exist until the distribution is created. Crossplane **cannot**
reference a status field into the middle of an opaque JSON policy string — there
is no interpolation at the raw-MR layer.

Broken by conditioning on **`AWS:SourceAccount`** instead. Tradeoff, stated
plainly: `SourceAccount` is weaker. `SourceArn` scopes reads to one
distribution; `SourceAccount` lets *any* CloudFront distribution in the account
read the bucket. Fine in a single-account lab; a real (if narrow) widening in a
shared account.

### CloudFront is slow

A distribution sits `Synced=True, Ready=False, reason=Creating` for several
minutes while it reaches `Deployed`. That is not a failure — do not treat a
non-ready status as an error too early.

### Where connection details land

`writeConnectionSecretToRef` on an MR writes provider-generated values into a
Kubernetes Secret in the MR's namespace. Nothing in this build produces
interesting ones (no RDS passwords, no IAM access keys), so it is unused here —
but that is the mechanism, and it means **secrets are namespace-scoped objects
subject to normal RBAC**, unlike OpenTofu state where every secret lands in one
blob everyone with state access can read.

### Teardown verification must match BOTH naming schemes

A bug I shipped and only caught by verifying independently. Phase 2 names IAM and
CloudFront resources `crossplane-lab-*`; the Phase 4 Composition derives names
from the XR (`lab-site-ssm-role`, `lab-site-instance-profile`, `lab-site-oac`).
The original `teardown.sh` only checked the `crossplane-lab-` prefix, so **three
of its eight checks would have reported "clean" while leaving orphaned IAM roles,
instance profiles and OACs behind.**

Two compounding factors made this silent:

- Each check ends in `|| echo 0`, so a query that *errors* is indistinguishable
  from a query that finds nothing.
- CloudFront returns `null` rather than `[]` when empty, and JMESPath `length()`
  errors on null — so the two CloudFront checks were failing into `0` from the
  very first run.

Lessons that generalise beyond this repo: a cleanup verifier whose failure mode is
"reports clean" is worse than no verifier. Assert the query form returns a
non-zero count against a pattern you know matches, so you know it executes at all.
And when an abstraction changes how things are *named*, every out-of-band check
keyed on those names silently stops working.

## Layout

```
bootstrap/          helm values, provider install, providerconfig, creds template
phase2-raw-mrs/     one file per resource group -- the unabstracted layer
phase4-composition/ xrd.yaml, composition.yaml, xr.yaml
scripts/
  load-creds.sh     creates the aws-creds Secret from bootstrap/aws-credentials.ini
  verify.sh         reads the XR status; falls back to Phase 2 raw-MR names
  drift-check.sh    compares phase2-raw-mrs/ against the live cluster spec;
                    skips cleanly once the Phase 4 XR has taken over
  teardown.sh       deletes everything, then verifies against AWS directly
```

## Scorecard

Judged only against what this build actually exercised.

### Where Crossplane beat OpenTofu

**Drift correction is real and unattended.** Retagged a VPC out-of-band; it was
reverted in 53s with no command issued — and it removed the tag I *added*, not
just restored the one I changed. There is no `tofu apply` in a cron job to
maintain, no drift-detection pipeline to build. This is the headline feature and
it delivers.

**Import is dramatically better.** Orphaning a bucket (`managementPolicies`
without `Delete`) and re-adopting it was a plain `kubectl apply` — the manifest
already carried `crossplane.io/external-name`, so adoption took ~10s with the
bucket's creation date unchanged. No `tofu import`, no state surgery, no
generated-config reconciliation. If you have a large estate of
click-ops-created AWS resources, this is the strongest argument in Crossplane's
favour.

**Pause is an escape hatch OpenTofu lacks.** `crossplane.io/paused: "true"` lets
you hand-edit a resource mid-incident and have the edit *stay*, without deleting
state or commenting out code. The controller drops it from the work queue
entirely (verified: zero log lines). Unpausing re-asserted in 19s.

**Selective activation.** 337 CRDs reduced to 24, and adding a resource type
later is a one-line MRAP edit rather than a provider reinstall.

**Compositions can compute, where patch-and-transform could not.** Subnet CIDRs
are derived from `vpcCidr`; `enableInstance: false` drops four resources from the
output entirely (19 composed instead of 23). The resource *list* is computed, not
just field values mapped onto a fixed set.

### Where it did not

**No plan. This is the big one.** At the raw-MR layer there is nothing:
`crossplane-diff` v0.10.0 refuses to run without an XRD, and the official CLI has
no `diff` or `plan` subcommand at all. The only tool is
`kubectl apply --dry-run=server`, which validates schema and admission and
nothing else. Pointed at an AMI change that destroys and recreates an EC2
instance, its complete output was:

```
instance.ec2.aws.m.upbound.io/lab-instance configured (server dry run)
```

No replacement warning, no mention that the public IP changes or that SSM must
re-register. `tofu plan` prints `-/+ forces replacement`. You do get the diff —
`Diff detected` with old/new values in the provider logs — but only *after* the
change has been applied. For any team whose change process depends on reviewing
a plan before apply, the raw-MR layer alone is a blocker.

At the Composition layer this improves, but less than hoped. `crossplane
composition render` runs the real render engine locally and shows every resource
that would be created, and `crossplane-diff` does produce a genuine diff against
the live cluster. But a change that destroys and recreates a VPC and everything
inside it is reported as `Summary: 7 modified` -- and the tool never reports a
clean no-op, so it cannot gate a pipeline. See "Drift behaviour under a
Composition" for the detail.

**Nothing reconciles the cluster against Git.** Crossplane reconciles the cluster
against AWS; the MR in between is a long-lived, writable object. A field added to
a spec imperatively is never removed by any form of `kubectl apply` (see
"Applying does not converge" above) and gets pushed to AWS forever. OpenTofu has
no equivalent failure mode because the config file *is* the desired state on
every run. This needs Argo CD/Flux, or `scripts/drift-check.sh`, to close.

**References are one-shot, not live links.** They resolve once and bake the value
into your spec (`resolve: IfNotPresent` by default). I deleted a Bucket MR and
its four dependents stayed `Synced=True`, still pointing at the resolved name.
The dependency "graph" is bootstrap ordering, not a maintained relationship —
unlike OpenTofu, which re-evaluates the graph on every plan.

**The XR is not a closed abstraction.** Fields injected directly into a composed
MR that the Composition does not declare are never reverted, propagate to AWS,
and leave every status green. The Composition owns only what it declares.

**`Synced=True` does not mean "matches your spec".** Under
`managementPolicies: ["Observe"]` the spec and reality diverged completely while
the resource reported `Synced=True ReconcileSuccess`. It means "the reconcile
loop ran without error." Anything alerting on `Synced` needs to know this.

**Missing reference fields force string coupling.** `Instance.iamInstanceProfile`
and `Distribution.origin[].domainName` have no `Ref`/`Selector`, so both had to be
hand-assembled from names pinned via `crossplane.io/external-name`. A typo yields
a retry loop against AWS rather than a reference-resolution error naming the
missing object. The Composition improves this — both sides are generated from one
variable — but the underlying edge is still invisible to Crossplane.

**Go templating is fragile at this size.** Three separate YAML/template failures
while writing one Composition, all whitespace- or delimiter-related: a `{{- ... -}}`
forward trim gluing a `---` document separator onto the previous line, and a
comment `*/ }}` with a space (Go requires `*/}}`). None were caught by anything
except a render attempt. `function-kcl` would have caught these structurally —
the tradeoff noted in `phase4-composition/functions.yaml` is real, and at ~20
resources I would now lean KCL.

**The providers are Terraform underneath.** The debug logs show
`*terraform.InstanceDiff`. You are not escaping Terraform's resource model, you
are changing what drives it — inheriting its field semantics and its quirks (like
`BucketOwnershipControls.rule` being modelled as a block).

### Verdict for my use case

Crossplane wins decisively on *maintaining* infrastructure — drift correction and
adoption are things OpenTofu genuinely cannot do. It loses decisively on
*changing* infrastructure safely, because there is no plan and no repo
convergence. Those are complementary, not competing, which is the actual
conclusion: the realistic migration is not "replace OpenTofu with Crossplane" but
"Crossplane for things that must stay correct continuously, behind a GitOps tool
that supplies the diff and the pruning Crossplane does not."
