#!/bin/bash
# ============================================================
# PHASE 3: ECS Cluster + Secrets Manager + Task Definitions
# File: infra/scripts/03-ecs-setup.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/outputs.env"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ⚙️  PHASE 3: ECS + Secrets + Task Definitions  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole"
TASK_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT_NAME}-task-role"

# ── 1. ECS Cluster ─────────────────────────────────────────
echo "▶ [1/5] Creating ECS Cluster..."
CLUSTER_EXISTS=$(aws ecs describe-clusters \
  --clusters "${PROJECT_NAME}-cluster" \
  --query "clusters[?status=='ACTIVE'].clusterName" \
  --output text 2>/dev/null || echo "")

if [ -z "$CLUSTER_EXISTS" ]; then
  aws ecs create-cluster \
    --cluster-name "${PROJECT_NAME}-cluster" \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy \
      capacityProvider=FARGATE,weight=1,base=1 \
    --settings name=containerInsights,value=enabled \
    --tags key=Project,value="${PROJECT_NAME}" \
    --region "$AWS_REGION" > /dev/null
  echo "   ✅ ECS Cluster: ${PROJECT_NAME}-cluster"
else
  echo "   ⏭️  Cluster already exists"
fi

# ── 2. Secrets Manager ─────────────────────────────────────
echo "▶ [2/5] Storing secrets in AWS Secrets Manager..."

# Generate random passwords
DB_AUTH_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)
DB_TICKETS_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)
JWT_SECRET=$(openssl rand -base64 48 | tr -d '/+=')

store_secret() {
  local name=$1 value=$2
  if aws secretsmanager describe-secret --secret-id "$name" &>/dev/null; then
    echo "   ⏭️  Secret exists: $name"
  else
    aws secretsmanager create-secret \
      --name "$name" \
      --secret-string "$value" \
      --tags Key=Project,Value="${PROJECT_NAME}" \
      --region "$AWS_REGION" > /dev/null
    echo "   ✅ Secret stored: $name"
  fi
}

store_secret "${PROJECT_NAME}/auth/db-password" "$DB_AUTH_PASS"
store_secret "${PROJECT_NAME}/tickets/db-password" "$DB_TICKETS_PASS"
store_secret "${PROJECT_NAME}/jwt-secret" "$JWT_SECRET"
store_secret "${PROJECT_NAME}/auth/db-url" \
  "postgresql://auth_user:${DB_AUTH_PASS}@postgres-auth.${PROJECT_NAME}.local:5432/auth_db"
store_secret "${PROJECT_NAME}/tickets/db-url" \
  "postgresql://tickets_user:${DB_TICKETS_PASS}@postgres-tickets.${PROJECT_NAME}.local:5433/tickets_db"

# Get ARNs for task definitions
SECRET_ARN_DB_AUTH_URL=$(aws secretsmanager describe-secret \
  --secret-id "${PROJECT_NAME}/auth/db-url" \
  --query "ARN" --output text)
SECRET_ARN_DB_TICKETS_URL=$(aws secretsmanager describe-secret \
  --secret-id "${PROJECT_NAME}/tickets/db-url" \
  --query "ARN" --output text)
SECRET_ARN_JWT=$(aws secretsmanager describe-secret \
  --secret-id "${PROJECT_NAME}/jwt-secret" \
  --query "ARN" --output text)
SECRET_ARN_DB_AUTH_PASS=$(aws secretsmanager describe-secret \
  --secret-id "${PROJECT_NAME}/auth/db-password" \
  --query "ARN" --output text)
SECRET_ARN_DB_TICKETS_PASS=$(aws secretsmanager describe-secret \
  --secret-id "${PROJECT_NAME}/tickets/db-password" \
  --query "ARN" --output text)

{
  echo "DB_AUTH_PASS=${DB_AUTH_PASS}"
  echo "DB_TICKETS_PASS=${DB_TICKETS_PASS}"
  echo "SECRET_ARN_DB_AUTH_URL=${SECRET_ARN_DB_AUTH_URL}"
  echo "SECRET_ARN_DB_TICKETS_URL=${SECRET_ARN_DB_TICKETS_URL}"
  echo "SECRET_ARN_JWT=${SECRET_ARN_JWT}"
  echo "SECRET_ARN_DB_AUTH_PASS=${SECRET_ARN_DB_AUTH_PASS}"
  echo "SECRET_ARN_DB_TICKETS_PASS=${SECRET_ARN_DB_TICKETS_PASS}"
} >> "${SCRIPT_DIR}/outputs.env"

# ── 3. CloudWatch Log Groups ───────────────────────────────
echo "▶ [3/5] Creating CloudWatch Log Groups..."
for svc in nginx-gateway auth-service ticket-service kafka postgres; do
  aws logs create-log-group \
    --log-group-name "/ecs/${PROJECT_NAME}/${svc}" \
    --region "$AWS_REGION" 2>/dev/null || true
  aws logs put-retention-policy \
    --log-group-name "/ecs/${PROJECT_NAME}/${svc}" \
    --retention-in-days 30 \
    --region "$AWS_REGION" 2>/dev/null || true
done
echo "   ✅ Log groups created (30-day retention)"

# ── 4. Service Discovery (Cloud Map) ──────────────────────
echo "▶ [4/5] Setting up Cloud Map Service Discovery..."
NS_ID=$(aws servicediscovery list-namespaces \
  --query "Namespaces[?Name=='${PROJECT_NAME}.local'].Id | [0]" \
  --output text 2>/dev/null || echo "None")

if [ "$NS_ID" = "None" ] || [ -z "$NS_ID" ]; then
  NS_ID=$(aws servicediscovery create-private-dns-namespace \
    --name "${PROJECT_NAME}.local" \
    --vpc "$VPC_ID" \
    --tags Key=Project,Value="${PROJECT_NAME}" \
    --query "OperationId" --output text)
  echo "   ⏳ Waiting for namespace to be created..."
  sleep 15
  NS_ID=$(aws servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${PROJECT_NAME}.local'].Id | [0]" \
    --output text)
  echo "   ✅ Cloud Map namespace: ${PROJECT_NAME}.local ($NS_ID)"
fi
echo "NS_ID=$NS_ID" >> "${SCRIPT_DIR}/outputs.env"

# Create service discovery entries
create_sd_service() {
  local name=$1 port=$2
  local existing
  existing=$(aws servicediscovery list-services \
    --filters Name=NAMESPACE_ID,Values="$NS_ID" \
    --query "Services[?Name=='${name}'].Id | [0]" \
    --output text 2>/dev/null || echo "None")
  if [ "$existing" = "None" ] || [ -z "$existing" ]; then
    local sd_id
    sd_id=$(aws servicediscovery create-service \
      --name "$name" \
      --namespace-id "$NS_ID" \
      --dns-config "NamespaceId=${NS_ID},DnsRecords=[{Type=A,TTL=10}]" \
      --health-check-custom-config FailureThreshold=1 \
      --query "Service.Id" --output text)
    echo "   ✅ SD service: ${name}.${PROJECT_NAME}.local ($sd_id)" >&2
    echo "$sd_id"
  else
    echo "   ⏭️  SD service exists: $name" >&2
    echo "$existing"
  fi
}

SD_AUTH=$(create_sd_service "auth-service" "3001")
SD_TICKETS=$(create_sd_service "ticket-service" "3002")
SD_KAFKA=$(create_sd_service "kafka" "9092")
SD_PG_AUTH=$(create_sd_service "postgres-auth" "5432")
SD_PG_TICKETS=$(create_sd_service "postgres-tickets" "5433")

{
  echo "SD_AUTH=$SD_AUTH"
  echo "SD_TICKETS=$SD_TICKETS"
  echo "SD_KAFKA=$SD_KAFKA"
  echo "SD_PG_AUTH=$SD_PG_AUTH"
  echo "SD_PG_TICKETS=$SD_PG_TICKETS"
} >> "${SCRIPT_DIR}/outputs.env"

# ── 5. Register Task Definitions ───────────────────────────
echo "▶ [5/5] Registering ECS Task Definitions..."

# ── Task Def: Postgres Auth ───────────────────
cat > td-postgres-auth.json << EOF
{
  "family": "${PROJECT_NAME}-postgres-auth",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "volumes": [{
    "name": "postgres-auth-data",
    "efsVolumeConfiguration": {
      "fileSystemId": "${EFS_ID}",
      "transitEncryption": "ENABLED",
      "authorizationConfig": { "accessPointId": "${EFS_AP_AUTH}", "iam": "ENABLED" }
    }
  }],
  "containerDefinitions": [{
    "name": "postgres-auth",
    "image": "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/super-system/postgres:16-alpine",
    "user": "999",
    "essential": true,
    "portMappings": [{"containerPort": 5432, "protocol": "tcp"}],
    "environment": [
      {"name": "POSTGRES_DB", "value": "auth_db"},
      {"name": "POSTGRES_USER", "value": "auth_user"},
      {"name": "PGDATA", "value": "/var/lib/postgresql/data/pgdata"}
    ],
    "secrets": [{"name": "POSTGRES_PASSWORD", "valueFrom": "${SECRET_ARN_DB_AUTH_PASS}"}],
    "mountPoints": [{"sourceVolume": "postgres-auth-data", "containerPath": "/var/lib/postgresql/data"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${PROJECT_NAME}/postgres",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "auth-db"
      }
    },
    "healthCheck": {
      "command": ["CMD-SHELL", "pg_isready -U auth_user -d auth_db"],
      "interval": 30, "timeout": 5, "retries": 5, "startPeriod": 30
    }
  }]
}
EOF

# ── Task Def: Postgres Tickets ───────────────
cat > td-postgres-tickets.json << EOF
{
  "family": "${PROJECT_NAME}-postgres-tickets",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "volumes": [{
    "name": "postgres-tickets-data",
    "efsVolumeConfiguration": {
      "fileSystemId": "${EFS_ID}",
      "transitEncryption": "ENABLED",
      "authorizationConfig": { "accessPointId": "${EFS_AP_TICKETS}", "iam": "ENABLED" }
    }
  }],
  "containerDefinitions": [{
    "name": "postgres-tickets",
    "image": "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/super-system/postgres:16-alpine",
    "user": "999",
    "essential": true,
    "portMappings": [{"containerPort": 5433, "protocol": "tcp"}],
    "environment": [
      {"name": "POSTGRES_DB", "value": "tickets_db"},
      {"name": "POSTGRES_USER", "value": "tickets_user"},
      {"name": "PGPORT", "value": "5433"},
      {"name": "PGDATA", "value": "/var/lib/postgresql/data/pgdata"}
    ],
    "secrets": [{"name": "POSTGRES_PASSWORD", "valueFrom": "${SECRET_ARN_DB_TICKETS_PASS}"}],
    "mountPoints": [{"sourceVolume": "postgres-tickets-data", "containerPath": "/var/lib/postgresql/data"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${PROJECT_NAME}/postgres",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "tickets-db"
      }
    },
    "healthCheck": {
      "command": ["CMD-SHELL", "pg_isready -U tickets_user -d tickets_db"],
      "interval": 30, "timeout": 5, "retries": 5, "startPeriod": 30
    }
  }]
}
EOF

# ── Task Def: Kafka ───────────────────────────
cat > td-kafka.json << EOF
{
  "family": "${PROJECT_NAME}-kafka",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "volumes": [{
    "name": "kafka-data",
    "efsVolumeConfiguration": {
      "fileSystemId": "${EFS_ID}",
      "transitEncryption": "ENABLED",
      "authorizationConfig": { "accessPointId": "${EFS_AP_KAFKA}", "iam": "ENABLED" }
    }
  }],
  "containerDefinitions": [
    {
      "name": "zookeeper",
      "image": "confluentinc/cp-zookeeper:7.5.0",
      "essential": true,
      "portMappings": [{"containerPort": 2181}],
      "environment": [
        {"name": "ZOOKEEPER_CLIENT_PORT", "value": "2181"},
        {"name": "ZOOKEEPER_TICK_TIME", "value": "2000"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/${PROJECT_NAME}/kafka",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "zookeeper"
        }
      }
    },
    {
      "name": "kafka",
      "image": "confluentinc/cp-kafka:7.5.0",
      "essential": true,
      "dependsOn": [{"containerName": "zookeeper", "condition": "START"}],
      "portMappings": [{"containerPort": 9092}],
      "environment": [
        {"name": "KAFKA_BROKER_ID", "value": "1"},
        {"name": "KAFKA_ZOOKEEPER_CONNECT", "value": "localhost:2181"},
        {"name": "KAFKA_ADVERTISED_LISTENERS", "value": "PLAINTEXT://kafka.${PROJECT_NAME}.local:9092"},
        {"name": "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR", "value": "1"},
        {"name": "KAFKA_AUTO_CREATE_TOPICS_ENABLE", "value": "true"},
        {"name": "KAFKA_LOG_RETENTION_HOURS", "value": "168"}
      ],
      "mountPoints": [{"sourceVolume": "kafka-data", "containerPath": "/var/lib/kafka/data"}],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/${PROJECT_NAME}/kafka",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "kafka"
        }
      }
    }
  ]
}
EOF

# ── Task Def: Auth Service ─────────────────────
cat > td-auth.json << EOF
{
  "family": "${PROJECT_NAME}-auth-service",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "auth-service",
    "image": "${ECR_AUTH_IMAGE}",
    "essential": true,
    "portMappings": [{"containerPort": 3001, "protocol": "tcp"}],
    "environment": [
      {"name": "NODE_ENV", "value": "production"},
      {"name": "PORT", "value": "3001"},
      {"name": "KAFKA_BROKERS", "value": "kafka.${PROJECT_NAME}.local:9092"}
    ],
    "secrets": [
      {"name": "DATABASE_URL", "valueFrom": "${SECRET_ARN_DB_AUTH_URL}"},
      {"name": "JWT_SECRET", "valueFrom": "${SECRET_ARN_JWT}"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${PROJECT_NAME}/auth-service",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "healthCheck": {
      "command": ["CMD-SHELL", "curl -f http://localhost:3001/auth/health || exit 1"],
      "interval": 30, "timeout": 5, "retries": 3, "startPeriod": 60
    }
  }]
}
EOF

# ── Task Def: Ticket Service ───────────────────
cat > td-tickets.json << EOF
{
  "family": "${PROJECT_NAME}-ticket-service",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "ticket-service",
    "image": "${ECR_TICKETS_IMAGE}",
    "essential": true,
    "portMappings": [{"containerPort": 3002, "protocol": "tcp"}],
    "environment": [
      {"name": "NODE_ENV", "value": "production"},
      {"name": "PORT", "value": "3002"},
      {"name": "KAFKA_BROKERS", "value": "kafka.${PROJECT_NAME}.local:9092"}
    ],
    "secrets": [
      {"name": "DATABASE_URL", "valueFrom": "${SECRET_ARN_DB_TICKETS_URL}"},
      {"name": "JWT_SECRET", "valueFrom": "${SECRET_ARN_JWT}"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${PROJECT_NAME}/ticket-service",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "healthCheck": {
      "command": ["CMD-SHELL", "curl -f http://localhost:3002/tickets/health || exit 1"],
      "interval": 30, "timeout": 5, "retries": 3, "startPeriod": 60
    }
  }]
}
EOF

# ── Task Def: Nginx Gateway ────────────────────
cat > td-nginx.json << EOF
{
  "family": "${PROJECT_NAME}-nginx-gateway",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "nginx-gateway",
    "image": "${ECR_NGINX_IMAGE}",
    "essential": true,
    "portMappings": [{"containerPort": 80, "protocol": "tcp"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${PROJECT_NAME}/nginx-gateway",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "healthCheck": {
      "command": ["CMD-SHELL", "curl -f http://localhost:80/health || exit 1"],
      "interval": 15, "timeout": 5, "retries": 3, "startPeriod": 30
    }
  }]
}
EOF

# Register all task definitions
register_td() {
  local file=$1 name=$2
  aws ecs register-task-definition \
    --cli-input-json "file://${file}" \
    --region "$AWS_REGION" \
    --query "taskDefinition.taskDefinitionArn" --output text
  echo "   ✅ Task definition registered: $name" >&2
}

TD_PG_AUTH=$(register_td td-postgres-auth.json "postgres-auth")
TD_PG_TICKETS=$(register_td td-postgres-tickets.json "postgres-tickets")
TD_KAFKA=$(register_td td-kafka.json "kafka")
TD_AUTH=$(register_td td-auth.json "auth-service")
TD_TICKETS=$(register_td td-tickets.json "ticket-service")
TD_NGINX=$(register_td td-nginx.json "nginx-gateway")

{
  echo "TD_PG_AUTH=$TD_PG_AUTH"
  echo "TD_PG_TICKETS=$TD_PG_TICKETS"
  echo "TD_KAFKA=$TD_KAFKA"
  echo "TD_AUTH=$TD_AUTH"
  echo "TD_TICKETS=$TD_TICKETS"
  echo "TD_NGINX=$TD_NGINX"
} >> "${SCRIPT_DIR}/outputs.env"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅ PHASE 3 COMPLETE                            ║"
echo "╚══════════════════════════════════════════════════╝"
echo "▶  Next: run ./04-alb-services.sh"
