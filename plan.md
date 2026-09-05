# Crossplane on Homelab → AWS: Build Plan

> Personal exploration project. Paste this whole file into a Claude Code session as the task prompt.

## Context

I'm a platform engineer evaluating Crossplane as a possible replacement for OpenTofu for AWS
resource management. This is a personal learning project, not production. I have:

- A homelab Kubernetes cluster (Crossplane will run here as the control plane)
- A personal AWS multi-account setup; **for this build everything lives in a single account**
- A brand-new IAM user + access key created specifically for Crossplane (I'll supply the creds)

The goal is to feel the difference between Crossplane's continuous-reconciliation model and
OpenTofu's plan/apply model — not to ship a website. Optimize for me learning the tool.

## Target state

Three things provisioned in AWS **entirely through Crossplane**, in `us-east-1`:

1. A VPC (`10.42.0.0/16`) with public and private subnets across two AZs, an internet gateway,
   and route tables. **No NAT gateway** — cost matters here.
2. A `t3.micro` (or `t4g.micro`) EC2 instance running Amazon Linux 2023, in a **public** subnet
   with a public IP, an instance profile granting `AmazonSSMManagedInstanceCore`, and a security
   group with **no inbound rules**. Access is via SSM Session Manager only. Public subnet is a
   deliberate cost choice: SSM in a private subnet would require three interface VPC endpoints.
3. A private S3 bucket serving as a CloudFront origin via Origin Access Control, plus a CloudFront
   distribution. **No custom domain, no ACM cert, no Route 53** — I'll use the default
   `*.cloudfront.net` domain and the default CloudFront certificate. Upload a trivial
   `index.html` so I can curl the distribution and see it work.

## Work in phases — do not skip ahead

### Phase 0 — Verify before you write YAML

My knowledge of Crossplane v2 specifics is a few months stale. **Check current docs first** and
tell me what you find before generating manifests:

- Current Crossplane 2.x release and its Helm chart version
- Current Upbound `provider-aws-*` family package versions
- In v2, the correct API groups for namespaced managed resources (I believe `.m` suffixed, e.g.
  `ec2.aws.m.upbound.io/v1beta1`) and — importantly — **the correct ProviderConfig kind and scope
  for namespaced MRs**. I think v2 splits this into a cluster-scoped and a namespaced variant, but
  verify rather than guessing; this is the single most likely thing to be wrong.

### Phase 1 — Control plane

- Install Crossplane via Helm into `crossplane-system`.
- Install **only** these providers: `provider-aws-ec2`, `provider-aws-s3`, `provider-aws-cloudfront`,
  `provider-aws-iam`. Do not install the monolithic AWS provider.
- If v2's ManagedResourceDefinitions / selective activation is available, use it to activate only
  the MR kinds this build needs. Explain what it saved in CRD count.
- Create the credentials Secret from a `[default]`-profile credentials file and the ProviderConfig
  pointing at it. Leave a clear `<PASTE CREDS HERE>` marker — do not invent key material.
- Wait for all providers to report `HEALTHY` and `INSTALLED` before continuing. Show me the output.

### Phase 2 — Raw managed resources

Write one MR per AWS resource, in a namespace called `aws-lab`. No Compositions yet — I want to see
the unabstracted layer first.

Use Crossplane's **cross-resource references** (`vpcIdSelector`, `subnetIdRef`, etc.) rather than
hardcoding IDs, so the dependency ordering is expressed declaratively. Call out anywhere a
reference field doesn't exist and you had to work around it.

Apply in a sensible order, and after each group show me `kubectl get managed` output.

### Phase 3 — Deliberate experiments

This is the actual point of the project. Walk me through each, one at a time, and explain what
happened:

1. **Drift correction.** Change something out-of-band with the AWS CLI (retag the VPC, modify the
   security group). Watch Crossplane revert it. Show me the reconcile in the provider logs.
2. **Pause.** Add `crossplane.io/paused: "true"` to that MR, repeat the out-of-band change, show
   that it now sticks.
3. **Management policies.** Flip one resource to `ObserveOnly` and explain what Crossplane will and
   won't do with it now.
4. **Deletion semantics.** Set `deletionPolicy: Orphan` on the S3 bucket, delete the MR, confirm
   the bucket survives, then re-adopt it with the `crossplane.io/external-name` annotation. This is
   the import story and I want to see how rough it is.
5. **The missing plan.** Show me what `crossplane render` gives me, and whether `crossplane-diff`
   (crossplane-contrib) is usable here. Be honest about the gap versus `tofu plan`.

### Phase 4 — Refactor into an XRD + Composition

Only after Phase 3. Collapse the whole thing into a single namespaced XR — something like
`XStaticSite` — whose user-facing spec is small and opinionated:

```yaml
spec:
  region: us-east-1
  vpcCidr: 10.42.0.0/16
  instanceType: t3.micro
  enableInstance: true
```

Use a Composition **function pipeline**, not deprecated inline patch-and-transform. Pick one
templating function (`function-go-templating` or `function-kcl`) and justify the choice in a
sentence or two. Surface the CloudFront domain name as a connection detail or status field so I can
curl it without digging through MRs.

Then delete the raw MRs and recreate everything from the XR, to prove the abstraction is complete.

## Known gotchas — handle these explicitly

- **No data sources.** Crossplane has no `data "aws_ami"` equivalent. The AL2023 AMI ID must be
  hardcoded. Look up the current one for `us-east-1`, put it in a clearly-marked variable, and add
  a comment that it goes stale.
- **CloudFront ↔ S3 circular dependency.** The bucket policy for OAC normally scopes to the
  distribution ARN, which doesn't exist until the distribution is created — and Crossplane can't
  reference into a JSON policy string. Use an `AWS:SourceAccount` condition instead of
  `AWS:SourceArn` to break the cycle. Note the tradeoff in a comment.
- **CloudFront is slow.** Distributions take several minutes to reach `Deployed`. Don't treat a
  non-ready status as a failure too early.
- **Secrets.** Point out where connection details land as Kubernetes Secrets, even if nothing here
  produces interesting ones.

## Repo layout

```
crossplane-aws-lab/
├── README.md              # what this is, how to bootstrap, how to tear down
├── bootstrap/             # helm values, provider install, providerconfig, creds template
├── phase2-raw-mrs/        # one file per resource group
├── phase4-composition/    # xrd.yaml, composition.yaml, xr.yaml
└── scripts/
    ├── teardown.sh        # deletes everything, verifies nothing orphaned in AWS
    └── verify.sh          # curls the distribution, checks SSM connectivity
```

## Ground rules

- Explain the *why* as you go — I know AWS and Kubernetes deeply, I do not know Crossplane. Skip
  explanations of what a VPC is; do explain why a Composition pipeline is shaped the way it is.
- Never invent API fields. If you're unsure a field exists on a v2 MR, check the CRD with
  `kubectl explain` and tell me.
- Everything must be re-creatable from the repo. No `kubectl edit` fixes that don't get written back
  to a file.
- Include a working teardown from the start. I do not want to hunt for orphaned resources later.

## Done when

- `kubectl get managed -A` shows everything `READY=True SYNCED=True`
- `curl https://<distribution-domain>` returns the index page
- `aws ssm start-session` reaches the EC2 instance with no inbound SG rules
- `bash scripts/teardown.sh` leaves the account clean
- The README explains, in my own operational terms, where Crossplane beat OpenTofu here and where
  it didn't