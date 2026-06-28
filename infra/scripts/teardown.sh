#!/bin/bash
# ============================================================
# TEARDOWN SCRIPT — Xóa toàn bộ infrastructure
# File: infra/scripts/teardown.sh
#
# ⚠️  CẢNH BÁO: Script này xóa TOÀN BỘ resources trên AWS
# Dùng khi không cần hệ thống nữa để tránh bị charge tiền
#
# Usage: ./teardown.sh
# ============================================================

set -euo pipefail

# Disable path translation in Git Bash on Windows
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/outputs.env" 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ⚠️  TEARDOWN — Xóa toàn bộ hạ tầng AWS         ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Project: ${PROJECT_NAME}"
echo "  Region:  ${AWS_REGION}"
echo ""
read -rp "  ❓ Bạn có chắc muốn XÓA TOÀN BỘ không? [yes/no]: " confirm
if [ "$confirm" != "yes" ]; then
  echo "  ✋ Huỷ bỏ."
  exit 0
fi

CLUSTER="${PROJECT_NAME}-cluster"

echo ""
echo "▶ [1/10] Stopping all ECS services..."
for svc in nginx-gateway auth-service ticket-service kafka postgres-auth postgres-tickets; do
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "${PROJECT_NAME}-${svc}" \
    --desired-count 0 \
    --region "$AWS_REGION" &>/dev/null || true
done

echo "▶ [2/10] Deleting ECS services..."
for svc in nginx-gateway auth-service ticket-service kafka postgres-auth postgres-tickets; do
  aws ecs delete-service \
    --cluster "$CLUSTER" \
    --service "${PROJECT_NAME}-${svc}" \
    --force \
    --region "$AWS_REGION" &>/dev/null || true
done

echo "▶ [3/10] Deleting ECS cluster..."
aws ecs delete-cluster --cluster "$CLUSTER" --region "$AWS_REGION" &>/dev/null || true

echo "▶ [4/10] Deleting ALB and Target Groups..."
[ -n "${ALB_ARN:-}" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" &>/dev/null || true
sleep 10
[ -n "${TG_NGINX_ARN:-}" ] && aws elbv2 delete-target-group --target-group-arn "$TG_NGINX_ARN" &>/dev/null || true

echo "▶ [5/10] Deleting ECR images..."
for repo in "${PROJECT_NAME}/nginx-gateway" "${PROJECT_NAME}/auth-service" "${PROJECT_NAME}/ticket-service"; do
  aws ecr batch-delete-image \
    --repository-name "$repo" \
    --image-ids "$(aws ecr list-images --repository-name "$repo" --query 'imageIds[*]' --output json 2>/dev/null || echo '[]')" \
    --region "$AWS_REGION" &>/dev/null || true
  aws ecr delete-repository --repository-name "$repo" --force --region "$AWS_REGION" &>/dev/null || true
done

echo "▶ [6/10] Deleting Secrets Manager secrets..."
for secret in \
  "${PROJECT_NAME}/auth/db-url" \
  "${PROJECT_NAME}/tickets/db-url" \
  "${PROJECT_NAME}/auth/db-password" \
  "${PROJECT_NAME}/tickets/db-password" \
  "${PROJECT_NAME}/jwt-secret"; do
  aws secretsmanager delete-secret \
    --secret-id "$secret" \
    --force-delete-without-recovery \
    --region "$AWS_REGION" &>/dev/null || true
done

echo "▶ [7/10] Deleting EFS Access Points and File System..."
if [ -n "${EFS_ID:-}" ]; then
  for ap in "${EFS_AP_AUTH:-}" "${EFS_AP_TICKETS:-}" "${EFS_AP_KAFKA:-}"; do
    [ -n "$ap" ] && aws efs delete-access-point --access-point-id "$ap" &>/dev/null || true
  done
  sleep 5
  # Delete mount targets
  MT_IDS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
    --query "MountTargets[*].MountTargetId" --output text 2>/dev/null || echo "")
  for mt in $MT_IDS; do
    aws efs delete-mount-target --mount-target-id "$mt" &>/dev/null || true
  done
  sleep 10
  aws efs delete-file-system --file-system-id "$EFS_ID" &>/dev/null || true
fi

echo "▶ [8/10] Deleting Cloud Map services & namespace..."
for sd in "${SD_AUTH:-}" "${SD_TICKETS:-}" "${SD_KAFKA:-}" "${SD_PG_AUTH:-}" "${SD_PG_TICKETS:-}"; do
  [ -n "$sd" ] && aws servicediscovery delete-service --id "$sd" &>/dev/null || true
done
[ -n "${NS_ID:-}" ] && aws servicediscovery delete-namespace --id "$NS_ID" &>/dev/null || true

echo "▶ [9/10] Deleting NAT Gateway, EIP..."
if [ -n "${NAT_GW:-}" ]; then
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW" &>/dev/null || true
  echo "   ⏳ Waiting 60s for NAT Gateway to delete..."
  sleep 60
fi

echo "▶ [10/10] Deleting VPC and all networking resources..."
if [ -n "${VPC_ID:-}" ]; then
  # Detach and delete IGW
  IGW=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null || echo "")
  if [ -n "$IGW" ] && [ "$IGW" != "None" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" &>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" &>/dev/null || true
  fi

  # Delete subnets
  SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[*].SubnetId" --output text 2>/dev/null || echo "")
  for s in $SUBNETS; do aws ec2 delete-subnet --subnet-id "$s" &>/dev/null || true; done

  # Delete route tables
  RTS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null || echo "")
  for rt in $RTS; do aws ec2 delete-route-table --route-table-id "$rt" &>/dev/null || true; done

  # Delete security groups
  SGS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Project,Values=${PROJECT_NAME}" \
    --query "SecurityGroups[*].GroupId" --output text 2>/dev/null || echo "")
  for sg in $SGS; do aws ec2 delete-security-group --group-id "$sg" &>/dev/null || true; done

  # Delete VPC
  aws ec2 delete-vpc --vpc-id "$VPC_ID" &>/dev/null || true
fi

# Release EIPs
aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query "Addresses[*].AllocationId" --output text 2>/dev/null | \
  xargs -r -n1 aws ec2 release-address --allocation-id &>/dev/null || true

# Delete CloudWatch Log Groups
for svc in nginx-gateway auth-service ticket-service kafka postgres; do
  aws logs delete-log-group \
    --log-group-name "/ecs/${PROJECT_NAME}/${svc}" \
    --region "$AWS_REGION" &>/dev/null || true
done

# Clean outputs file
echo "" > "${SCRIPT_DIR}/outputs.env"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅ TEARDOWN COMPLETE — All resources deleted   ║"
echo "║   💰 AWS billing for these resources has stopped ║"
echo "╚══════════════════════════════════════════════════╝"
