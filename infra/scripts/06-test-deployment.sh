#!/bin/bash
# ============================================================
# QUICK DEPLOY HELPER — Dành cho Windows (Git Bash / WSL)
# File: infra/scripts/06-test-deployment.sh
#
# Sau khi deploy xong, chạy script này để verify toàn bộ
# hệ thống hoạt động đúng
# ============================================================

# set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/outputs.env"

BASE_URL="http://${ALB_DNS}"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   🧪 Testing Deployed System                     ║"
echo "║   URL: ${BASE_URL}                               ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

pass=0
fail=0

check() {
  local name=$1 url=$2 expected=$3
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  if [ "$response" = "$expected" ]; then
    echo "   ✅ PASS: $name ($response)"
    ((pass++))
  else
    echo "   ❌ FAIL: $name (expected $expected, got $response)"
    ((fail++))
  fi
}

# Health checks
check "Nginx Gateway Health"  "${BASE_URL}/health"             "200"
check "Auth Service Health"   "${BASE_URL}/api/auth/health"   "200"
check "Ticket Service Health" "${BASE_URL}/api/tickets/health" "200"

# Auth endpoints
TEST_EMAIL="test_$(date +%s)@example.com"
REGISTER_RESPONSE=$(curl -s -X POST "${BASE_URL}/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"Test User\",\"email\":\"${TEST_EMAIL}\",\"password\":\"Password123!\"}" \
  -w "\n%{http_code}")

STATUS=$(echo "$REGISTER_RESPONSE" | tail -1)
BODY=$(echo "$REGISTER_RESPONSE" | head -1)

if [ "$STATUS" = "201" ] || [ "$STATUS" = "200" ]; then
  echo "   ✅ PASS: Register user ($STATUS)"
  ((pass++))

  # Extract token
  ACCESS_TOKEN=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null || echo "")

  if [ -n "$ACCESS_TOKEN" ]; then
    echo "   ✅ PASS: JWT token received"
    ((pass++))

    # Test protected endpoint
    ME_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "${BASE_URL}/api/auth/me")
    check "Protected /me endpoint" "${BASE_URL}/api/auth/me" "200" || true
  fi
else
  echo "   ❌ FAIL: Register user (got $STATUS)"
  ((fail++))
fi

# Ticket endpoints
check "List Events" "${BASE_URL}/api/tickets/events" "200"

echo ""
echo "══════════════════════════════════════════════════"
echo "   Results: ${pass} passed, ${fail} failed"
echo "══════════════════════════════════════════════════"

if [ "$fail" -eq 0 ]; then
  echo "   🎉 All tests passed! System is healthy."
else
  echo "   ⚠️  Some tests failed. Check CloudWatch logs:"
  echo "   https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home#logsV2:log-groups"
fi
echo ""
echo "   🌐 Live URL: ${BASE_URL}"
