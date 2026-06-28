#!/bin/bash
# ============================================================
# PHASE 4: ALB + ECS Services
# File: infra/scripts/04-alb-services.sh
#
# Tạo Application Load Balancer và khởi động toàn bộ ECS Services:
#   - ALB (public-facing, vì không dùng Cloudflare Tunnel)
#   - Target Groups cho Nginx Gateway
#   - ALB Listener (HTTP:80, HTTPS:443 nếu có cert)
#   - ECS Services: Postgres × 2, Kafka, Auth, Tickets, Nginx
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/outputs.env"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ⚖️  PHASE 4: ALB + ECS Services               ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

CLUSTER="${PROJECT_NAME}-cluster"

# ── 1. Application Load Balancer (public) ──────────────────
echo "▶ [1/8] Creating Application Load Balancer..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?LoadBalancerName=='${PROJECT_NAME}-alb'].LoadBalancerArn | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${PROJECT_NAME}-alb" \
    --subnets "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" \
    --security-groups "$SG_ALB" \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4 \
    --tags Key=Project,Value="${PROJECT_NAME}" \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)
  echo "   ⏳ Waiting for ALB to be active..."
  aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
  echo "   ✅ ALB created: $ALB_ARN"
else
  echo "   ⏭️  ALB already exists"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" --output text)

{
  echo "ALB_ARN=$ALB_ARN"
  echo "ALB_DNS=$ALB_DNS"
} >> "${SCRIPT_DIR}/outputs.env"

echo "   🌐 ALB DNS: http://${ALB_DNS}"

# ── 2. Target Group (Nginx Gateway) ────────────────────────
echo "▶ [2/8] Creating Target Group..."
TG_ARN=$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?TargetGroupName=='${PROJECT_NAME}-nginx-tg'].TargetGroupArn | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "$TG_ARN" = "None" ] || [ -z "$TG_ARN" ]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${PROJECT_NAME}-nginx-tg" \
    --protocol HTTP \
    --port 80 \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-protocol HTTP \
    --health-check-path "/health" \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --tags Key=Project,Value="${PROJECT_NAME}" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
  echo "   ✅ Target Group: $TG_ARN"
fi
echo "TG_NGINX_ARN=$TG_ARN" >> "${SCRIPT_DIR}/outputs.env"

# ── 3. ALB Listener ────────────────────────────────────────
echo "▶ [3/8] Creating ALB Listener (HTTP:80)..."
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`80\`].ListenerArn | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "$LISTENER_ARN" = "None" ] || [ -z "$LISTENER_ARN" ]; then
  LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions \
      Type=forward,TargetGroupArn="$TG_ARN" \
    --tags Key=Project,Value="${PROJECT_NAME}" \
    --query "Listeners[0].ListenerArn" --output text)
  echo "   ✅ HTTP Listener created"
fi
echo "LISTENER_ARN=$LISTENER_ARN" >> "${SCRIPT_DIR}/outputs.env"

# ── Helper: create or update ECS service ──────────────────
create_ecs_service() {
  local name=$1
  local task_def=$2
  local desired=$3
  local subnets=$4
  local sgs=$5
  local sd_id=$6
  local extra_flags=${7:-""}

  local existing
  existing=$(aws ecs describe-services \
    --cluster "$CLUSTER" --services "$name" \
    --query "services[?status=='ACTIVE'].serviceName | [0]" \
    --output text 2>/dev/null || echo "None")

  if [ "$existing" = "None" ] || [ -z "$existing" ]; then
    local sd_config=""
    if [ -n "$sd_id" ]; then
      sd_config="--service-registries registryArn=arn:aws:servicediscovery:${AWS_REGION}:${ACCOUNT_ID}:service/${sd_id}"
    fi

    # shellcheck disable=SC2086
    aws ecs create-service \
      --cluster "$CLUSTER" \
      --service-name "$name" \
      --task-definition "$task_def" \
      --desired-count "$desired" \
      --launch-type FARGATE \
      --platform-version LATEST \
      --network-configuration \
        "awsvpcConfiguration={subnets=[${subnets}],securityGroups=[${sgs}],assignPublicIp=DISABLED}" \
      --enable-execute-command \
      $sd_config \
      $extra_flags \
      --tags key=Project,value="${PROJECT_NAME}" \
      --region "$AWS_REGION" > /dev/null
    echo "   ✅ ECS Service created: $name"
  else
    echo "   ⏭️  ECS Service exists: $name"
  fi
}

PRIVATE_SUBNETS="${PRIVATE_SUBNET_1},${PRIVATE_SUBNET_2}"

# ── 4. ECS Service: Postgres Auth ─────────────────────────
echo "▶ [4/8] Starting Postgres Auth service..."
create_ecs_service \
  "${PROJECT_NAME}-postgres-auth" \
  "${PROJECT_NAME}-postgres-auth" \
  1 \
  "$PRIVATE_SUBNETS" \
  "$SG_DB" \
  "$SD_PG_AUTH"

# ── 5. ECS Service: Postgres Tickets ──────────────────────
echo "▶ [5/8] Starting Postgres Tickets service..."
create_ecs_service \
  "${PROJECT_NAME}-postgres-tickets" \
  "${PROJECT_NAME}-postgres-tickets" \
  1 \
  "$PRIVATE_SUBNETS" \
  "$SG_DB" \
  "$SD_PG_TICKETS"

echo "   ⏳ Waiting 30s for databases to start..."
sleep 30

# ── 6. ECS Service: Kafka ──────────────────────────────────
echo "▶ [6/8] Starting Kafka service..."
create_ecs_service \
  "${PROJECT_NAME}-kafka" \
  "${PROJECT_NAME}-kafka" \
  1 \
  "$PRIVATE_SUBNETS" \
  "$SG_KAFKA" \
  "$SD_KAFKA"

echo "   ⏳ Waiting 45s for Kafka to start..."
sleep 45

# ── 7. ECS Services: Auth + Ticket ─────────────────────────
echo "▶ [7/8] Starting Auth & Ticket services..."
create_ecs_service \
  "${PROJECT_NAME}-auth-service" \
  "${PROJECT_NAME}-auth-service" \
  1 \
  "$PRIVATE_SUBNETS" \
  "$SG_APP" \
  "$SD_AUTH"

create_ecs_service \
  "${PROJECT_NAME}-ticket-service" \
  "${PROJECT_NAME}-ticket-service" \
  1 \
  "$PRIVATE_SUBNETS" \
  "$SG_APP" \
  "$SD_TICKETS"

echo "   ⏳ Waiting 60s for app services to start..."
sleep 60

# ── 8. ECS Service: Nginx Gateway (with ALB) ───────────────
echo "▶ [8/8] Starting Nginx Gateway (connected to ALB)..."

EXISTING_NGINX=$(aws ecs describe-services \
  --cluster "$CLUSTER" --services "${PROJECT_NAME}-nginx-gateway" \
  --query "services[?status=='ACTIVE'].serviceName | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "$EXISTING_NGINX" = "None" ] || [ -z "$EXISTING_NGINX" ]; then
  aws ecs create-service \
    --cluster "$CLUSTER" \
    --service-name "${PROJECT_NAME}-nginx-gateway" \
    --task-definition "${PROJECT_NAME}-nginx-gateway" \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration \
      "awsvpcConfiguration={subnets=[${PRIVATE_SUBNETS}],securityGroups=[${SG_APP}],assignPublicIp=DISABLED}" \
    --load-balancers \
      "targetGroupArn=${TG_ARN},containerName=nginx-gateway,containerPort=80" \
    --health-check-grace-period-seconds 60 \
    --enable-execute-command \
    --tags key=Project,value="${PROJECT_NAME}" \
    --region "$AWS_REGION" > /dev/null
  echo "   ✅ Nginx Gateway service created & linked to ALB"
fi

# ── Wait for services to stabilize ─────────────────────────
echo ""
echo "   ⏳ Waiting for Nginx Gateway to register with ALB..."
aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services "${PROJECT_NAME}-nginx-gateway" \
  --region "$AWS_REGION" 2>/dev/null || echo "   ⚠️  Services still starting (check console)"

# ── Final Summary ──────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅ PHASE 4 COMPLETE — System is LIVE!          ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "   🌐 Your API is accessible at:"
echo "      http://${ALB_DNS}"
echo ""
echo "   📋 Test endpoints:"
echo "      GET  http://${ALB_DNS}/health"
echo "      GET  http://${ALB_DNS}/api/auth/health"
echo "      GET  http://${ALB_DNS}/api/tickets/health"
echo "      POST http://${ALB_DNS}/api/auth/register"
echo ""
echo "   📊 AWS Console links:"
echo "      ECS: https://${AWS_REGION}.console.aws.amazon.com/ecs/v2/clusters/${CLUSTER}/services"
echo "      ALB: https://${AWS_REGION}.console.aws.amazon.com/ec2/v2/home#LoadBalancers"
echo "      CWL: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home#logsV2:log-groups"
echo ""
echo "▶  Next (optional): run ./05-autoscaling.sh"
