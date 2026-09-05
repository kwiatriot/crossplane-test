#!/usr/bin/env bash
# Verifies the lab end-to-end: MR health, CloudFront serving, SSM reachability.
set -uo pipefail
cd "$(dirname "$0")/.."
AWS_PROFILE="${AWS_PROFILE:-dev}"
REGION="${REGION:-us-west-2}"
NS=aws-lab
fail=0

echo "=== 1. managed resource health ==="
tot=$(kubectl -n "$NS" get managed --no-headers 2>/dev/null | wc -l)
rdy=$(kubectl -n "$NS" get managed -o json 2>/dev/null | \
  jq '[.items[]|select((.status.conditions//[])[]?|select(.type=="Ready" and .status=="True"))]|length')
echo "    $rdy/$tot READY"
if [ "$tot" -eq 0 ] || [ "$rdy" -ne "$tot" ]; then
  fail=1
  kubectl -n "$NS" get managed -o json 2>/dev/null | jq -r '.items[]|select((.status.conditions//[])[]?|select(.type=="Ready" and .status!="True"))|"    NOT READY: \(.kind)/\(.metadata.name)"'
fi

echo
echo "=== 2. CloudFront distribution ==="
# status.atProvider.domainName is where the MR surfaces the *.cloudfront.net name.
DOMAIN=$(kubectl -n "$NS" get distribution.cloudfront.aws.m.upbound.io lab-distribution \
  -o jsonpath='{.status.atProvider.domainName}' 2>/dev/null)
STATUS=$(kubectl -n "$NS" get distribution.cloudfront.aws.m.upbound.io lab-distribution \
  -o jsonpath='{.status.atProvider.status}' 2>/dev/null)
echo "    domain: ${DOMAIN:-<none>}"
echo "    status: ${STATUS:-<none>}"
if [ -z "$DOMAIN" ]; then
  echo "    SKIP curl - no domain yet"; fail=1
else
  code=$(curl -s -o /tmp/cf-body.$$ -w '%{http_code}' --max-time 30 "https://${DOMAIN}" 2>/dev/null)
  echo "    GET https://${DOMAIN} -> HTTP $code"
  if [ "$code" = "200" ]; then
    echo "    body: $(grep -o '<h1>.*</h1>' /tmp/cf-body.$$ 2>/dev/null | head -1)"
  else
    fail=1
  fi
  rm -f /tmp/cf-body.$$
fi

echo
echo "=== 3. SSM reachability (no inbound SG rules) ==="
IID=$(kubectl -n "$NS" get instance.ec2.aws.m.upbound.io lab-instance \
  -o jsonpath='{.metadata.annotations.crossplane\.io/external-name}' 2>/dev/null)
echo "    instance: ${IID:-<none>}"
if [ -z "$IID" ]; then
  fail=1
else
  PING=$(aws --profile "$AWS_PROFILE" --region "$REGION" ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$IID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
  echo "    SSM PingStatus: ${PING:-<not registered>}"
  [ "$PING" = "Online" ] || { echo "    (agent can take ~2-5 min after boot to register)"; fail=1; }
  # Prove there really are no inbound rules.
  SG=$(kubectl -n "$NS" get securitygroup.ec2.aws.m.upbound.io lab-sg \
    -o jsonpath='{.metadata.annotations.crossplane\.io/external-name}' 2>/dev/null)
  NIN=$(aws --profile "$AWS_PROFILE" --region "$REGION" ec2 describe-security-groups \
    --group-ids "$SG" --query 'length(SecurityGroups[0].IpPermissions)' --output text 2>/dev/null)
  echo "    inbound rules on $SG: ${NIN:-?}  (expect 0)"
  [ "${NIN:-1}" = "0" ] || fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "VERIFY PASSED"; else echo "VERIFY FAILED"; exit 1; fi
