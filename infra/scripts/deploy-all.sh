#!/bin/bash
# ============================================================
# MASTER DEPLOYMENT SCRIPT
# File: infra/scripts/deploy-all.sh
#
# Chạy toàn bộ 5 phases tuần tự.
# Có thể resume từ bất kỳ phase nào:
#   ./deploy-all.sh          → chạy từ phase 1
#   ./deploy-all.sh --from 3 → chạy từ phase 3
#   ./deploy-all.sh --only 2 → chỉ chạy phase 2
# ============================================================

set -euo pipefail

# Disable path translation in Git Bash on Windows
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

START_PHASE=1
ONLY_PHASE=""

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --from) START_PHASE="$2"; shift 2 ;;
    --only) ONLY_PHASE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  🚀 SUPER-SYSTEM — AWS Deployment                       ║"
echo "║  Region: ${AWS_REGION}   Project: ${PROJECT_NAME}       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Validate AWS credentials
echo "🔑 Validating AWS credentials..."
ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text)
USER_ARN=$(aws sts get-caller-identity --query "Arn" --output text)
echo "   Account: ${ACCOUNT}"
echo "   User:    ${USER_ARN}"
echo ""

# Initialize outputs file
touch "${SCRIPT_DIR}/outputs.env"

run_phase() {
  local phase=$1 script=$2 name=$3
  if [ -n "$ONLY_PHASE" ] && [ "$phase" != "$ONLY_PHASE" ]; then
    return
  fi
  if [ "$phase" -lt "$START_PHASE" ]; then
    echo "   ⏭️  Skipping Phase ${phase}: ${name}"
    return
  fi
  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "  📋 Phase ${phase}: ${name}"
  echo "══════════════════════════════════════════════════════════"
  bash "${SCRIPT_DIR}/${script}"
}

run_phase 1 "01-foundation.sh"    "VPC + ECR + IAM + EFS"
run_phase 2 "02-build-push.sh"   "Build & Push Docker Images"
run_phase 3 "03-ecs-setup.sh"    "ECS Cluster + Secrets + Task Definitions"
run_phase 4 "04-alb-services.sh" "ALB + ECS Services"
run_phase 5 "05-autoscaling.sh"  "Auto Scaling + CloudWatch Alarms"

# ── Source outputs for final summary ──────────────────────
source "${SCRIPT_DIR}/outputs.env"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  🎉 DEPLOYMENT COMPLETE!                                ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  🌐 Your API URL:                                        ║"
echo "║     http://${ALB_DNS}                                    ║"
echo "║                                                          ║"
echo "║  📋 Test it now:                                         ║"
echo "║     curl http://${ALB_DNS}/health                        ║"
echo "║     curl http://${ALB_DNS}/api/auth/health               ║"
echo "║     curl http://${ALB_DNS}/api/tickets/health            ║"
echo "║                                                          ║"
echo "║  🗑️  To destroy everything: ./teardown.sh                ║"
echo "╚══════════════════════════════════════════════════════════╝"
