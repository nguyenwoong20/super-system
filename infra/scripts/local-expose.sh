#!/bin/bash
# ============================================================
# CLOUDFLARE QUICK TUNNEL HELPER
# File: infra/scripts/local-expose.sh
#
# Tiết lộ dự án local ra ngoài internet mà không cần tài khoản:
#   - Expose Nginx Gateway (mặc định port 8080)
#   - Tự động sinh domain ngẫu nhiên *.trycloudflare.com (HTTPS)
#   - Sử dụng cloudflared local hoặc tự chạy qua Docker container.
#
# Usage: ./local-expose.sh [port]
# ============================================================

set -euo pipefail

PORT="${1:-8080}"
TARGET_URL="http://localhost:${PORT}"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   🌐 Cloudflare Quick Tunnel (Local Expose)      ║"
echo "║   Target: ${TARGET_URL}                         ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Kiểm tra xem cloudflared đã cài trên máy chủ chưa
if command -v cloudflared &> /dev/null; then
  echo "🚀 Phát hiện 'cloudflared' đã cài đặt cục bộ."
  echo "   Đang khởi động Quick Tunnel kết nối đến ${TARGET_URL}..."
  echo "   (Nhấn Ctrl + C để dừng chia sẻ tên miền)"
  echo ""
  cloudflared tunnel --url "$TARGET_URL"
else
  # Fallback: Chạy cloudflared thông qua Docker container
  echo "⚠️  Không tìm thấy lệnh 'cloudflared' cài trên máy."
  echo "🐳 Đang khởi động Quick Tunnel thông qua Docker..."
  echo "   (Nhấn Ctrl + C để tắt container và ngắt chia sẻ)"
  echo ""

  # Nếu chạy trên Windows qua Git Bash, localhost cần trỏ về docker host
  # Chuyển localhost thành host.docker.internal nếu chạy trong Docker container
  DOCKER_TARGET="http://host.docker.internal:${PORT}"

  docker run --rm -it \
    --name cloudflare-quick-tunnel-temp \
    --add-host=host.docker.internal:host-gateway \
    cloudflare/cloudflared:latest \
    tunnel --no-autoupdate --url "$DOCKER_TARGET"
fi
