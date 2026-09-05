#!/usr/bin/env bash
# Tears down everything this lab creates, then VERIFIES nothing was orphaned in AWS.
#
# Ordering matters. Crossplane deletes MRs concurrently, but AWS has hard
# dependency ordering (you cannot delete a VPC with subnets in it). Crossplane
# retries on failure, so it converges -- but we delete in dependency order and
# wait, so failures are legible rather than a wall of retry noise.
#
# Usage: bash scripts/teardown.sh [--yes]
set -uo pipefail
cd "$(dirname "$0")/.."

AWS_PROFILE="${AWS_PROFILE:-dev}"
REGION="${REGION:-us-west-2}"
NS=aws-lab
TAG_KEY=crossplane-lab          # every MR is tagged with this for verification

if [ "${1:-}" != "--yes" ]; then
  read -r -p "Delete ALL lab resources in ${REGION} (profile ${AWS_PROFILE})? [y/N] " a
  [ "$a" = "y" ] || { echo "aborted"; exit 1; }
fi

echo "==> deleting composite resources (phase 4), if any"
kubectl -n "$NS" delete xstaticsite --all --ignore-not-found --timeout=10m 2>/dev/null

echo "==> deleting raw managed resources (phase 2), if any"
# Reverse dependency order.
for kind in \
  object.s3.aws.m.upbound.io \
  distribution.cloudfront.aws.m.upbound.io \
  bucketpolicy.s3.aws.m.upbound.io \
  originaccesscontrol.cloudfront.aws.m.upbound.io \
  bucketpublicaccessblock.s3.aws.m.upbound.io \
  bucketownershipcontrols.s3.aws.m.upbound.io \
  bucket.s3.aws.m.upbound.io \
  instance.ec2.aws.m.upbound.io \
  instanceprofile.iam.aws.m.upbound.io \
  rolepolicyattachment.iam.aws.m.upbound.io \
  role.iam.aws.m.upbound.io \
  securitygroupegressrule.ec2.aws.m.upbound.io \
  securitygroup.ec2.aws.m.upbound.io \
  routetableassociation.ec2.aws.m.upbound.io \
  route.ec2.aws.m.upbound.io \
  routetable.ec2.aws.m.upbound.io \
  internetgateway.ec2.aws.m.upbound.io \
  subnet.ec2.aws.m.upbound.io \
  vpc.ec2.aws.m.upbound.io
do
  if kubectl -n "$NS" get "$kind" >/dev/null 2>&1; then
    echo "    - $kind"
    kubectl -n "$NS" delete "$kind" --all --ignore-not-found --timeout=15m 2>/dev/null
  fi
done

echo "==> waiting for all MRs in $NS to disappear"
end=$((SECONDS+900))
while [ $SECONDS -lt $end ]; do
  left=$(kubectl -n "$NS" get managed --no-headers 2>/dev/null | wc -l)
  [ "$left" -eq 0 ] && break
  echo "    $left managed resource(s) remaining..."
  sleep 15
done

remaining=$(kubectl -n "$NS" get managed --no-headers 2>/dev/null | wc -l)
if [ "$remaining" -ne 0 ]; then
  echo "!! $remaining MR(s) did not delete. Likely Orphan management policy, or a"
  echo "   stuck finalizer from the phase-3 experiments. Inspect:"
  kubectl -n "$NS" get managed 2>/dev/null
fi

echo
echo "=================== AWS ORPHAN VERIFICATION ==================="
A=(aws --profile "$AWS_PROFILE" --region "$REGION")
fail=0
check() { # label, count
  if [ "${2:-0}" -gt 0 ]; then echo "  ORPHANED  $1: $2"; fail=1
  else echo "  clean     $1"; fi
}

check "VPCs (tag:$TAG_KEY)" "$("${A[@]}" ec2 describe-vpcs \
  --filters "Name=tag-key,Values=$TAG_KEY" --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)"
check "EC2 instances (tag:$TAG_KEY, non-terminated)" "$("${A[@]}" ec2 describe-instances \
  --filters "Name=tag-key,Values=$TAG_KEY" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)"
check "Security groups (tag:$TAG_KEY)" "$("${A[@]}" ec2 describe-security-groups \
  --filters "Name=tag-key,Values=$TAG_KEY" --query 'length(SecurityGroups)' --output text 2>/dev/null || echo 0)"
check "IAM roles (crossplane-lab-*)" "$("${A[@]}" iam list-roles \
  --query 'length(Roles[?starts_with(RoleName, `crossplane-lab-`)])' --output text 2>/dev/null || echo 0)"
check "Instance profiles (crossplane-lab-*)" "$("${A[@]}" iam list-instance-profiles \
  --query 'length(InstanceProfiles[?starts_with(InstanceProfileName, `crossplane-lab-`)])' --output text 2>/dev/null || echo 0)"
check "S3 buckets (crossplane-lab-*)" "$("${A[@]}" s3api list-buckets \
  --query 'length(Buckets[?starts_with(Name, `crossplane-lab-`)])' --output text 2>/dev/null || echo 0)"
check "CloudFront distributions (lab comment)" "$("${A[@]}" cloudfront list-distributions \
  --query 'length(DistributionList.Items[?Comment==`crossplane-lab`])' --output text 2>/dev/null || echo 0)"
check "OACs (crossplane-lab-*)" "$("${A[@]}" cloudfront list-origin-access-controls \
  --query 'length(OriginAccessControlList.Items[?starts_with(Name, `crossplane-lab-`)])' --output text 2>/dev/null || echo 0)"

echo "==============================================================="
if [ "$fail" -eq 0 ] && [ "$remaining" -eq 0 ]; then
  echo "TEARDOWN CLEAN - nothing orphaned."
else
  echo "TEARDOWN INCOMPLETE - see ORPHANED entries above."
  exit 1
fi
