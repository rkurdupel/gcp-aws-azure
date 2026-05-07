#!/usr/bin/env bash
set -euo pipefail

ALB_URL="http://coinops-network-812317851.eu-central-1.elb.amazonaws.com"
REGION="eu-central-1"
TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:eu-central-1:109622022091:targetgroup/coinops-network-tg/9dd33c47a53bf474"

echo "=== Failover verification ==="
echo ""

# Step 1 - baseline check
echo "--- Step 1: Baseline check (both VMs healthy) ---"
curl -sf "$ALB_URL/health" && echo "app responding"
echo ""

# Step 2 - find and stop one app VM
echo "--- Step 2: Stopping one app VM ---"
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=app" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text \
  --region "$REGION")

echo "Stopping instance: $INSTANCE_ID"
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
echo "Waiting 60s for ALB to detect unhealthy instance..."
sleep 60

# Step 3 - check app still works with one VM down
echo ""
echo "--- Step 3: Check app still works with 1 VM down ---"
PASS=0
for i in 1 2 3; do
  if curl -sf "$ALB_URL/health" > /dev/null; then
    echo "Request $i: healthy"
    PASS=$((PASS + 1))
  else
    echo "Request $i: failed"
  fi
done

echo ""
if [ "$PASS" -ge 2 ]; then
  echo "PASS: Failover works — app still running with 1 VM down"
else
  echo "FAIL: App is down — failover not working"
fi

# Step 4 - restart the stopped VM
echo ""
echo "--- Step 4: Restarting stopped VM ---"
aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
echo "Instance $INSTANCE_ID restarting..."
echo ""
echo "=== Done ==="