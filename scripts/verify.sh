#!/usr/bin/env bash
# Verifies the lab end-to-end: MR health, CloudFront serving, SSM reachability.
#
# Reads everything from the XR's status where possible -- that is the whole point
# of the Phase 4 abstraction: you should not need to know the names of the 23
# composed managed resources to check the stack is working.
#
# Falls back to the Phase 2 raw-MR names if no XR is present.
set -uo pipefail
cd "$(dirname "$0")/.."
AWS_PROFILE="${AWS_PROFILE:-dev}"
REGION="${REGION:-us-west-2}"
NS=aws-lab
XR=lab-site
fail=0

echo "=== 1. managed resource health ==="
tot=$(kubectl -n "$NS" get managed --no-headers 2>/dev/null | grep -c .)
rdy=$(kubectl -n "$NS" get managed -o json 2>/dev/null | \
  jq '[.items[]|select((.status.conditions//[])[]?|select(.type=="Ready" and .status=="True"))]|length')
echo "    $rdy/$tot READY"
if [ "$tot" -eq 0 ] || [ "$rdy" -ne "$tot" ]; then
  fail=1
  kubectl -n "$NS" get managed -o json 2>/dev/null | jq -r '.items[]|select((.status.conditions//[])[]?|select(.type=="Ready" and .status!="True"))|"    NOT READY: \(.kind)/\(.metadata.name)"'
fi

if kubectl -n "$NS" get xstaticsite "$XR" >/dev/null 2>&1; then
  echo
  echo "=== 1b. composite resource ==="
  kubectl -n "$NS" get xstaticsite "$XR" -o json 2>/dev/null | \
    jq -r '"    XR \(.metadata.name): synced=\([(.status.conditions[]?|select(.type=="Synced"))]|.[0].status) ready=\([(.status.conditions[]?|select(.type=="Ready"))]|.[0].status)"'
  DOMAIN=$(kubectl -n "$NS" get xstaticsite "$XR" -o jsonpath='{.status.cloudfrontDomain}' 2>/dev/null)
  IID=$(kubectl -n "$NS" get xstaticsite "$XR" -o jsonpath='{.status.instanceId}' 2>/dev/null)
  SGNAME="${XR}-sg"
else
  DOMAIN=$(kubectl -n "$NS" get distribution.cloudfront.aws.m.upbound.io lab-distribution \
    -o jsonpath='{.status.atProvider.domainName}' 2>/dev/null)
  IID=$(kubectl -n "$NS" get instance.ec2.aws.m.upbound.io lab-instance \
    -o jsonpath='{.metadata.annotations.crossplane\.io/external-name}' 2>/dev/null)
  SGNAME="crossplane-lab-sg"
fi

echo
echo "=== 2. CloudFront ==="
echo "    domain: ${DOMAIN:-<none>}"
if [ -z "$DOMAIN" ]; then
  echo "    SKIP curl - no domain yet (distribution still deploying?)"; fail=1
else
  code=$(curl -s -o /tmp/cf-body.$$ -w '%{http_code}' --max-time 30 "https://${DOMAIN}" 2>/dev/null)
  echo "    GET https://${DOMAIN} -> HTTP $code"
  [ "$code" = "200" ] && echo "    body: $(grep -o '<h1>.*</h1>' /tmp/cf-body.$$ 2>/dev/null | head -1)" || fail=1
  rm -f /tmp/cf-body.$$
fi

echo
echo "=== 3. SSM reachability (no inbound SG rules) ==="
echo "    instance: ${IID:-<none>}"
if [ -z "$IID" ]; then
  fail=1
else
  PING=$(aws --profile "$AWS_PROFILE" --region "$REGION" ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$IID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
  echo "    SSM PingStatus: ${PING:-<not registered>}"
  [ "$PING" = "Online" ] || { echo "    (agent takes ~2-5 min after boot to register)"; fail=1; }
  NIN=$(aws --profile "$AWS_PROFILE" --region "$REGION" ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SGNAME" \
    --query 'length(SecurityGroups[0].IpPermissions)' --output text 2>/dev/null)
  echo "    inbound rules on $SGNAME: ${NIN:-?}  (expect 0)"
  [ "${NIN:-1}" = "0" ] || fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "VERIFY PASSED"; else echo "VERIFY FAILED"; exit 1; fi
