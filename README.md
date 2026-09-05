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

# 4. resources
kubectl apply -f phase2-raw-mrs/

# 5. check
bash scripts/verify.sh
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

## Layout

```
bootstrap/          helm values, provider install, providerconfig, creds template
phase2-raw-mrs/     one file per resource group -- the unabstracted layer
phase4-composition/ xrd.yaml, composition.yaml, xr.yaml
scripts/            load-creds.sh, verify.sh, teardown.sh
```

## Scorecard

_Filled in after Phases 3 and 4._
