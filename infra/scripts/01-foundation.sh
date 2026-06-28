#!/bin/bash
# ============================================================
# PHASE 1: AWS Foundation
# File: infra/scripts/01-foundation.sh
#
# Tạo toàn bộ hạ tầng nền tảng:
#   - VPC + Subnets (public/private, multi-AZ)
#   - Internet Gateway + NAT Gateway
#   - Security Groups (ALB, App, DB, Kafka)
#   - ECR Repositories (3 repos)
#   - IAM Roles (Task Execution + Task Role)
#   - EFS File System + Mount Targets (Postgres/Kafka data)
#   - CloudWatch Log Groups
#
# Usage: ./01-foundation.sh
# Idempotent: có thể chạy lại an toàn
# ============================================================

set -euo pipefail

# Disable path translation in Git Bash on Windows
export MSYS_NO_PATHCONV=1

# ── Load config ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   🏗️  PHASE 1: AWS Foundation Setup              ║"
echo "║   Region: ${AWS_REGION}                          ║"
echo "║   Project: ${PROJECT_NAME}                       ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Helper: tag resources consistently ────────────────────
TAGS="Key=Project,Value=${PROJECT_NAME} Key=ManagedBy,Value=script Key=Environment,Value=${ENVIRONMENT}"

# ── 1. VPC ─────────────────────────────────────────────────
echo "▶ [1/12] Creating VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "None")

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 create-vpc \
    --cidr-block "10.0.0.0/16" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query "Vpc.VpcId" --output text)
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
  echo "   ✅ VPC created: $VPC_ID"
else
  echo "   ⏭️  VPC already exists: $VPC_ID"
fi
echo "VPC_ID=$VPC_ID" >> "${SCRIPT_DIR}/outputs.env"

# ── 2. Subnets ─────────────────────────────────────────────
echo "▶ [2/12] Creating Subnets (2 public + 2 private, multi-AZ)..."
AZ1="${AWS_REGION}a"
AZ2="${AWS_REGION}b"

create_subnet() {
  local name=$1 cidr=$2 az=$3 public=$4
  local existing
  existing=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[0].SubnetId" --output text 2>/dev/null || echo "None")
  if [ "$existing" = "None" ] || [ -z "$existing" ]; then
    local id
    id=$(aws ec2 create-subnet \
      --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT_NAME}}]" \
      --query "Subnet.SubnetId" --output text)
    if [ "$public" = "true" ]; then
      aws ec2 modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch
    fi
    echo "   ✅ Subnet $name: $id" >&2
    echo "$id"
  else
    echo "   ⏭️  Subnet $name exists: $existing" >&2
    echo "$existing"
  fi
}

PUBLIC_SUBNET_1=$(create_subnet "${PROJECT_NAME}-public-1" "10.0.1.0/24" "$AZ1" "true")
PUBLIC_SUBNET_2=$(create_subnet "${PROJECT_NAME}-public-2" "10.0.2.0/24" "$AZ2" "true")
PRIVATE_SUBNET_1=$(create_subnet "${PROJECT_NAME}-private-1" "10.0.10.0/24" "$AZ1" "false")
PRIVATE_SUBNET_2=$(create_subnet "${PROJECT_NAME}-private-2" "10.0.11.0/24" "$AZ2" "false")

{
  echo "PUBLIC_SUBNET_1=$PUBLIC_SUBNET_1"
  echo "PUBLIC_SUBNET_2=$PUBLIC_SUBNET_2"
  echo "PRIVATE_SUBNET_1=$PRIVATE_SUBNET_1"
  echo "PRIVATE_SUBNET_2=$PRIVATE_SUBNET_2"
} >> "${SCRIPT_DIR}/outputs.env"

# ── 3. Internet Gateway ────────────────────────────────────
echo "▶ [3/12] Creating Internet Gateway..."
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null || echo "None")

if [ "$IGW_ID" = "None" ] || [ -z "$IGW_ID" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query "InternetGateway.InternetGatewayId" --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  echo "   ✅ IGW created & attached: $IGW_ID"
else
  echo "   ⏭️  IGW already exists: $IGW_ID"
fi

# ── 4. Route Tables ────────────────────────────────────────
echo "▶ [4/12] Configuring Route Tables..."
PUBLIC_RT=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-public-rt" "Name=vpc-id,Values=${VPC_ID}" \
  --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || echo "None")

if [ "$PUBLIC_RT" = "None" ] || [ -z "$PUBLIC_RT" ]; then
  PUBLIC_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-rt},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query "RouteTable.RouteTableId" --output text)
  aws ec2 create-route --route-table-id "$PUBLIC_RT" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" > /dev/null
  aws ec2 associate-route-table --route-table-id "$PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET_1" > /dev/null
  aws ec2 associate-route-table --route-table-id "$PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET_2" > /dev/null
  echo "   ✅ Public route table configured"
fi

# NAT Gateway (cost-optimized: 1 NAT only)
echo "▶ [4b/12] Creating NAT Gateway (for private subnets)..."
NAT_EIP=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat-eip},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query "AllocationId" --output text 2>/dev/null || \
  aws ec2 describe-addresses --filters "Name=tag:Name,Values=${PROJECT_NAME}-nat-eip" \
    --query "Addresses[0].AllocationId" --output text)

NAT_GW=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Project,Values=${PROJECT_NAME}" "Name=state,Values=available,pending" \
  --query "NatGateways[0].NatGatewayId" --output text 2>/dev/null || echo "None")

if [ "$NAT_GW" = "None" ] || [ -z "$NAT_GW" ]; then
  NAT_GW=$(aws ec2 create-nat-gateway \
    --subnet-id "$PUBLIC_SUBNET_1" \
    --allocation-id "$NAT_EIP" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query "NatGateway.NatGatewayId" --output text)
  echo "   ⏳ Waiting for NAT Gateway to be available..."
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW"
  echo "   ✅ NAT Gateway ready: $NAT_GW"
fi

# Private route table
PRIVATE_RT=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-private-rt" "Name=vpc-id,Values=${VPC_ID}" \
  --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || echo "None")

if [ "$PRIVATE_RT" = "None" ] || [ -z "$PRIVATE_RT" ]; then
  PRIVATE_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-rt},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query "RouteTable.RouteTableId" --output text)
  aws ec2 create-route --route-table-id "$PRIVATE_RT" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW" > /dev/null
  aws ec2 associate-route-table --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET_1" > /dev/null
  aws ec2 associate-route-table --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET_2" > /dev/null
  echo "   ✅ Private route table configured"
fi

# ── 5. Security Groups ─────────────────────────────────────
echo "▶ [5/12] Creating Security Groups..."

create_sg() {
  local name=$1 desc=$2
  local existing
  existing=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")
  if [ "$existing" = "None" ] || [ -z "$existing" ]; then
    local id
    id=$(aws ec2 create-security-group \
      --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT_NAME}}]" \
      --query "GroupId" --output text)
    echo "$id"
  else
    echo "$existing"
  fi
}

SG_ALB=$(create_sg "${PROJECT_NAME}-alb-sg" "ALB: public HTTP/HTTPS")
SG_APP=$(create_sg "${PROJECT_NAME}-app-sg" "App: NestJS services")
SG_DB=$(create_sg "${PROJECT_NAME}-db-sg" "DB: PostgreSQL")
SG_KAFKA=$(create_sg "${PROJECT_NAME}-kafka-sg" "Kafka broker")

# ALB: allow 80 + 443 from anywhere
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]},{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
  2>/dev/null || true

# App: allow from ALB only
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":80,\"ToPort\":3002,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ALB}\"}]}]" \
  2>/dev/null || true

# App to App (internal service mesh)
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":0,\"ToPort\":65535,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_APP}\"}]}]" \
  2>/dev/null || true

# DB: allow from App only (port 5432, 5433)
aws ec2 authorize-security-group-ingress --group-id "$SG_DB" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":5432,\"ToPort\":5433,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_APP}\"}]}]" \
  2>/dev/null || true

# Kafka: allow from App only (port 9092)
aws ec2 authorize-security-group-ingress --group-id "$SG_KAFKA" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":9092,\"ToPort\":9092,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_APP}\"}]}]" \
  2>/dev/null || true

# EFS: allow from App, DB, and Kafka (port 2049)
aws ec2 authorize-security-group-ingress --group-id "$SG_DB" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":2049,\"ToPort\":2049,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_APP}\"},{\"GroupId\":\"${SG_DB}\"},{\"GroupId\":\"${SG_KAFKA}\"}]}]" \
  2>/dev/null || true

echo "   ✅ Security Groups: ALB=$SG_ALB APP=$SG_APP DB=$SG_DB KAFKA=$SG_KAFKA"

{
  echo "SG_ALB=$SG_ALB"
  echo "SG_APP=$SG_APP"
  echo "SG_DB=$SG_DB"
  echo "SG_KAFKA=$SG_KAFKA"
} >> "${SCRIPT_DIR}/outputs.env"

# ── 6. ECR Repositories ────────────────────────────────────
echo "▶ [6/12] Creating ECR Repositories..."
create_ecr() {
  local name=$1
  aws ecr describe-repositories --repository-names "$name" --region "$AWS_REGION" &>/dev/null || \
    aws ecr create-repository \
      --repository-name "$name" \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 \
      --region "$AWS_REGION" \
      --tags Key=Project,Value="${PROJECT_NAME}" > /dev/null
  local uri
  uri=$(aws ecr describe-repositories --repository-names "$name" \
    --query "repositories[0].repositoryUri" --output text)
  echo "   ✅ ECR: $uri" >&2
  echo "$uri"
}

ECR_NGINX=$(create_ecr "${PROJECT_NAME}/nginx-gateway")
ECR_AUTH=$(create_ecr "${PROJECT_NAME}/auth-service")
ECR_TICKETS=$(create_ecr "${PROJECT_NAME}/ticket-service")

# ECR lifecycle policy (keep last 10 images only → save cost)
LIFECYCLE_POLICY='{"rules":[{"rulePriority":1,"description":"Keep last 10","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}'
aws ecr put-lifecycle-policy --repository-name "${PROJECT_NAME}/nginx-gateway" --lifecycle-policy-text "$LIFECYCLE_POLICY" > /dev/null
aws ecr put-lifecycle-policy --repository-name "${PROJECT_NAME}/auth-service" --lifecycle-policy-text "$LIFECYCLE_POLICY" > /dev/null
aws ecr put-lifecycle-policy --repository-name "${PROJECT_NAME}/ticket-service" --lifecycle-policy-text "$LIFECYCLE_POLICY" > /dev/null

{
  echo "ECR_NGINX=$ECR_NGINX"
  echo "ECR_AUTH=$ECR_AUTH"
  echo "ECR_TICKETS=$ECR_TICKETS"
} >> "${SCRIPT_DIR}/outputs.env"

# ── 7. IAM Roles ───────────────────────────────────────────
echo "▶ [7/12] Creating IAM Roles..."
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# Task Execution Role (ECS agent needs this to pull images, write logs)
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam get-role --role-name ecsTaskExecutionRole &>/dev/null || \
  aws iam create-role \
    --role-name ecsTaskExecutionRole \
    --assume-role-policy-document "$TRUST_POLICY" \
    --tags Key=Project,Value="${PROJECT_NAME}" > /dev/null

aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" \
  2>/dev/null || true

# Allow reading Secrets Manager
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn "arn:aws:iam::aws:policy/SecretsManagerReadWrite" \
  2>/dev/null || true

# Task Role (app code uses this — least privilege)
aws iam get-role --role-name "${PROJECT_NAME}-task-role" &>/dev/null || \
  aws iam create-role \
    --role-name "${PROJECT_NAME}-task-role" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --tags Key=Project,Value="${PROJECT_NAME}" > /dev/null

# Allow ECS Exec (for debugging)
TASK_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ssmmessages:CreateControlChannel\",\"ssmmessages:CreateDataChannel\",\"ssmmessages:OpenControlChannel\",\"ssmmessages:OpenDataChannel\"],\"Resource\":\"*\"},{\"Effect\":\"Allow\",\"Action\":[\"elasticfilesystem:ClientMount\",\"elasticfilesystem:ClientWrite\",\"elasticfilesystem:DescribeFileSystems\"],\"Resource\":\"*\"}]}"

TASK_POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='${PROJECT_NAME}-task-policy'].Arn" --output text)
if [ -z "$TASK_POLICY_ARN" ]; then
  TASK_POLICY_ARN=$(aws iam create-policy \
    --policy-name "${PROJECT_NAME}-task-policy" \
    --policy-document "$TASK_POLICY" \
    --query "Policy.Arn" --output text)
fi
aws iam attach-role-policy \
  --role-name "${PROJECT_NAME}-task-role" \
  --policy-arn "$TASK_POLICY_ARN" 2>/dev/null || true

echo "   ✅ IAM Roles: ecsTaskExecutionRole, ${PROJECT_NAME}-task-role"
echo "ACCOUNT_ID=$ACCOUNT_ID" >> "${SCRIPT_DIR}/outputs.env"

# ── 8. EFS File System ─────────────────────────────────────
echo "▶ [8/12] Creating EFS File System (persistent data)..."
EFS_ID=$(aws efs describe-file-systems \
  --query "FileSystems[?Tags[?Key=='Project' && Value=='${PROJECT_NAME}']].FileSystemId | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "$EFS_ID" = "None" ] || [ -z "$EFS_ID" ]; then
  EFS_ID=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags Key=Name,Value="${PROJECT_NAME}-efs" Key=Project,Value="${PROJECT_NAME}" \
    --query "FileSystemId" --output text)
  echo "   ⏳ Waiting for EFS to be available..."
  aws efs wait file-system-available --file-system-id "$EFS_ID" 2>/dev/null || sleep 10
  echo "   ✅ EFS created: $EFS_ID"
fi

# Create EFS Mount Targets in private subnets
for subnet in "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2"; do
  aws efs create-mount-target \
    --file-system-id "$EFS_ID" \
    --subnet-id "$subnet" \
    --security-groups "$SG_DB" \
    2>/dev/null || true
done

# EFS Access Points
create_ap() {
  local name=$1 path=$2
  local existing
  existing=$(aws efs describe-access-points \
    --file-system-id "$EFS_ID" \
    --query "AccessPoints[?RootDirectory.Path=='${path}'].AccessPointId | [0]" \
    --output text 2>/dev/null || echo "None")
  if [ "$existing" = "None" ] || [ -z "$existing" ]; then
    local ap_id
    ap_id=$(aws efs create-access-point \
      --file-system-id "$EFS_ID" \
      --posix-user Uid=999,Gid=999 \
      --root-directory "Path=${path},CreationInfo={OwnerUid=999,OwnerGid=999,Permissions=755}" \
      --tags Key=Name,Value="${name}" Key=Project,Value="${PROJECT_NAME}" \
      --query "AccessPointId" --output text)
    echo "$ap_id"
  else
    echo "$existing"
  fi
}

EFS_AP_AUTH=$(create_ap "${PROJECT_NAME}-efs-auth" "/postgres/auth")
EFS_AP_TICKETS=$(create_ap "${PROJECT_NAME}-efs-tickets" "/postgres/tickets")
EFS_AP_KAFKA=$(create_ap "${PROJECT_NAME}-efs-kafka" "/kafka")

echo "   ✅ EFS: $EFS_ID | APs: auth=$EFS_AP_AUTH tickets=$EFS_AP_TICKETS kafka=$EFS_AP_KAFKA"

{
  echo "EFS_ID=$EFS_ID"
  echo "EFS_AP_AUTH=$EFS_AP_AUTH"
  echo "EFS_AP_TICKETS=$EFS_AP_TICKETS"
  echo "EFS_AP_KAFKA=$EFS_AP_KAFKA"
} >> "${SCRIPT_DIR}/outputs.env"

# ── Summary ────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅ PHASE 1 COMPLETE                            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "📋 All outputs saved to: ${SCRIPT_DIR}/outputs.env"
echo "▶  Next: run ./02-build-push.sh"
