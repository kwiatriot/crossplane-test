# Phase 3 — Deliberate experiments

Reproducible commands for each experiment. These mutate live state; they are not
part of the normal build. Run against `AWS_PROFILE=dev`, region `us-west-2`.

Debug logging (needed for experiment 1) comes from
`bootstrap/debug-runtimeconfig.yaml`, referenced by `provider-aws-ec2` in
`bootstrap/providers.yaml`. Remove both to quiet the provider down.

## 1. Drift correction

```bash
VPC=$(kubectl -n aws-lab get vpc.ec2.aws.m.upbound.io lab-vpc \
  -o jsonpath='{.metadata.annotations.crossplane\.io/external-name}')

aws --profile dev --region us-west-2 ec2 create-tags --resources $VPC \
  --tags Key=Name,Value=HAND-EDITED Key=rogue,Value=should-not-survive

# watch it revert (~35-55s, bounded by --poll-interval=1m)
watch -n5 "aws --profile dev --region us-west-2 ec2 describe-tags \
  --filters Name=resource-id,Values=$VPC --query 'Tags[].[Key,Value]' --output text"

# the reconcile itself
POD=$(kubectl -n crossplane-system get pods -l pkg.crossplane.io/provider=provider-aws-ec2 \
  --field-selector=status.phase=Running -o name | head -1)
kubectl -n crossplane-system logs $POD -f | grep lab-vpc
```

Result: reverted in 53s. Both the overwritten tag AND the added tag were removed.

## 2. Pause

```bash
kubectl -n aws-lab annotate vpc.ec2.aws.m.upbound.io lab-vpc crossplane.io/paused=true
# repeat the tamper from #1 -- it now sticks indefinitely
kubectl -n aws-lab annotate vpc.ec2.aws.m.upbound.io lab-vpc crossplane.io/paused-   # resume
```

Result: edit survived 150s+, provider logged **zero** lines for the resource.
Snapped back 19s after unpause. Conditions while paused:
`Ready=True Available` / `Synced=False ReconcilePaused`.

## 3. Management policies (NOT `ObserveOnly`)

`ObserveOnly` does not exist in v2. The enum is
`[Observe, Create, Update, Delete, LateInitialize, *]`.

```bash
kubectl -n aws-lab patch subnet.ec2.aws.m.upbound.io lab-private-b --type=merge \
  -p '{"spec":{"managementPolicies":["Observe"]}}'

# neither out-of-band drift NOR spec changes are pushed; status still tracks reality
kubectl -n aws-lab get subnet.ec2.aws.m.upbound.io lab-private-b \
  -o jsonpath='{.spec.forProvider.tags}'        # desired  (ignored)
kubectl -n aws-lab get subnet.ec2.aws.m.upbound.io lab-private-b \
  -o jsonpath='{.status.atProvider.tags}'       # observed (real)

kubectl -n aws-lab patch subnet.ec2.aws.m.upbound.io lab-private-b --type=merge \
  -p '{"spec":{"managementPolicies":["*"]}}'    # restore
```

Result: spec and status diverged completely while `Synced=True`.

## 4. Orphan + re-adopt (there is no `deletionPolicy` in v2)

```bash
# orphan = managementPolicies WITHOUT "Delete"
kubectl -n aws-lab patch bucket.s3.aws.m.upbound.io lab-bucket --type=merge \
  -p '{"spec":{"managementPolicies":["Observe","Create","Update","LateInitialize"]}}'

kubectl -n aws-lab delete bucket.s3.aws.m.upbound.io lab-bucket
aws --profile dev s3api head-bucket --bucket crossplane-lab-022334369124-uw2   # survives

# re-adopt: the manifest already carries crossplane.io/external-name
kubectl apply -f ../phase2-raw-mrs/04-s3-cloudfront.yaml
```

Result: MR deleted instantly, bucket + object survived, CloudFront kept serving
HTTP 200. Re-apply adopted the existing bucket — creation date unchanged, exactly
one bucket, no duplicate.

## 5. The missing plan

```bash
# official CLI: no diff, no plan
crossplane --help | grep -iE 'diff|plan'      # nothing

# crossplane-diff (contrib) v0.10.0 -- requires an XRD/Composition
crossplane-diff xr ../phase2-raw-mrs/01-network.yaml
#   Error: ... requires its XR type to find a composition:
#          no XRD found that defines XR type ...Kind=VPC

# the only plan-like tool for raw MRs:
kubectl apply -f ../phase2-raw-mrs/03-instance.yaml --dry-run=server
```
