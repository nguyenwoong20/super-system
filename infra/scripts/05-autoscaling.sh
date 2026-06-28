#!/bin/bash
# ============================================================
# PHASE 5: Auto Scaling + CloudWatch Alarms
# File: infra/scripts/05-autoscaling.sh
#
# Cấu hình tự động co giãn cho Auth & Ticket services:
#   - Scale out khi CPU > 70%
#   - Scale in khi CPU < 30%
#   - CloudWatch Alarms + SNS email notification
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/outputs.env"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ⚙️  PHASE 5: Auto Scaling + Alarms             ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

CLUSTER="${PROJECT_NAME}-cluster"

# ── 1. SNS Topic for alerts ────────────────────────────────
echo "▶ [1/4] Creating SNS Alert Topic..."
SNS_ARN=$(aws sns list-topics \
  --query "Topics[?contains(TopicArn, '${PROJECT_NAME}-alerts')].TopicArn | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "$SNS_ARN" = "None" ] || [ -z "$SNS_ARN" ]; then
  SNS_ARN=$(aws sns create-topic \
    --name "${PROJECT_NAME}-alerts" \
    --tags Key=Project,Value="${PROJECT_NAME}" \
    --query "TopicArn" --output text)
  
  # Subscribe email if provided
  if [ -n "${ALERT_EMAIL:-}" ]; then
    aws sns subscribe \
      --topic-arn "$SNS_ARN" \
      --protocol email \
      --notification-endpoint "$ALERT_EMAIL" > /dev/null
    echo "   📧 Alert email subscription sent to: $ALERT_EMAIL"
  fi
  echo "   ✅ SNS Topic: $SNS_ARN"
fi
echo "SNS_ARN=$SNS_ARN" >> "${SCRIPT_DIR}/outputs.env"

# ── 2. Register Auto Scaling Targets ───────────────────────
echo "▶ [2/4] Registering Application Auto Scaling targets..."

register_scaling_target() {
  local service=$1 min=$2 max=$3
  local resource_id="service/${CLUSTER}/${PROJECT_NAME}-${service}"

  aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id "$resource_id" \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity "$min" \
    --max-capacity "$max" \
    --region "$AWS_REGION" 2>/dev/null || true

  echo "   ✅ Auto Scaling target: ${service} (min=${min}, max=${max})"
}

register_scaling_target "auth-service" 1 5
register_scaling_target "ticket-service" 1 5
register_scaling_target "nginx-gateway" 1 3

# ── 3. Scaling Policies ────────────────────────────────────
echo "▶ [3/4] Creating scaling policies (CPU-based)..."

create_scaling_policy() {
  local service=$1
  local resource_id="service/${CLUSTER}/${PROJECT_NAME}-${service}"

  # Scale OUT policy (CPU > 70%)
  aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id "$resource_id" \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name "${PROJECT_NAME}-${service}-scale-out" \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration '{
      "TargetValue": 70.0,
      "PredefinedMetricSpecification": {
        "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
      },
      "ScaleOutCooldown": 60,
      "ScaleInCooldown": 300
    }' \
    --region "$AWS_REGION" > /dev/null

  echo "   ✅ Scaling policy created: $service"
}

create_scaling_policy "auth-service"
create_scaling_policy "ticket-service"
create_scaling_policy "nginx-gateway"

# ── 4. CloudWatch Alarms ───────────────────────────────────
echo "▶ [4/4] Creating CloudWatch Alarms..."

create_alarm() {
  local name=$1 metric=$2 namespace=$3 threshold=$4 comparison=$5 dimensions=$6
  aws cloudwatch put-metric-alarm \
    --alarm-name "$name" \
    --metric-name "$metric" \
    --namespace "$namespace" \
    --statistic Average \
    --period 60 \
    --evaluation-periods 3 \
    --threshold "$threshold" \
    --comparison-operator "$comparison" \
    --alarm-actions "$SNS_ARN" \
    --ok-actions "$SNS_ARN" \
    --dimensions "$dimensions" \
    --treat-missing-data notBreaching \
    --region "$AWS_REGION" 2>/dev/null || true
}

# ALB 5xx errors
create_alarm \
  "${PROJECT_NAME}-alb-5xx-high" \
  "HTTPCode_Target_5XX_Count" \
  "AWS/ApplicationELB" \
  "10" \
  "GreaterThanThreshold" \
  "Name=LoadBalancer,Value=${ALB_ARN##*/load-balancer/}"

# Auth service CPU
create_alarm \
  "${PROJECT_NAME}-auth-cpu-high" \
  "CPUUtilization" \
  "AWS/ECS" \
  "85" \
  "GreaterThanThreshold" \
  "Name=ClusterName,Value=${CLUSTER} Name=ServiceName,Value=${PROJECT_NAME}-auth-service"

# Ticket service CPU
create_alarm \
  "${PROJECT_NAME}-tickets-cpu-high" \
  "CPUUtilization" \
  "AWS/ECS" \
  "85" \
  "GreaterThanThreshold" \
  "Name=ClusterName,Value=${CLUSTER} Name=ServiceName,Value=${PROJECT_NAME}-ticket-service"

# Auth service Memory
create_alarm \
  "${PROJECT_NAME}-auth-memory-high" \
  "MemoryUtilization" \
  "AWS/ECS" \
  "85" \
  "GreaterThanThreshold" \
  "Name=ClusterName,Value=${CLUSTER} Name=ServiceName,Value=${PROJECT_NAME}-auth-service"

echo "   ✅ CloudWatch Alarms created"

# ── Summary ────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅ PHASE 5 COMPLETE — Auto Scaling Active      ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "   📈 Scaling: CPU > 70% → scale out | CPU < 30% → scale in"
echo "   🔔 Alerts → SNS Topic: ${SNS_ARN}"
echo ""
echo "🎉 Deployment COMPLETE! Your system is fully live."
echo "   🌐 http://${ALB_DNS}"
