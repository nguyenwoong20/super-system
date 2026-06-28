# 🛠️ Hướng Dẫn Deploy lên AWS

## Yêu cầu trước khi chạy

### 1. Cài đặt công cụ

**Windows — chạy lệnh này trong PowerShell (Admin):**
```powershell
# Cài AWS CLI
winget install Amazon.AWSCLI

# Cài Git Bash (để chạy shell scripts)
winget install Git.Git

# Cài Docker Desktop
winget install Docker.DockerDesktop
```

**Kiểm tra đã cài đúng:**
```bash
aws --version      # aws-cli/2.x.x
docker --version   # Docker version 24.x.x
git --version      # git version 2.x.x
```

---

### 2. Cấu hình AWS CLI

```bash
aws configure
# AWS Access Key ID:     <nhập Access Key của bạn>
# AWS Secret Access Key: <nhập Secret Key của bạn>
# Default region name:   ap-southeast-1
# Default output format: json
```

**Kiểm tra credentials:**
```bash
aws sts get-caller-identity
# Sẽ trả về Account ID và ARN của bạn
```

---

### 3. Chỉnh sửa config

Mở file `infra/scripts/config.env` và kiểm tra:
```bash
AWS_REGION="ap-southeast-1"   # Giữ nguyên hoặc đổi region
PROJECT_NAME="super-system"    # Tên project (sẽ làm prefix cho tất cả resources)
ALERT_EMAIL=""                 # Email nhận cảnh báo (để trống nếu không cần)
```

---

## Chạy Deploy

### Option A: Chạy toàn bộ (khuyến nghị)

**Mở Git Bash**, `cd` vào thư mục project rồi chạy:

```bash
cd /e/super-system/infra/scripts

# Cấp quyền executable
chmod +x *.sh

# Chạy toàn bộ deployment
./deploy-all.sh
```

Thời gian ước tính: **~15–20 phút**

---

### Option B: Chạy từng phase (nếu muốn kiểm soát)

```bash
cd /e/super-system/infra/scripts
chmod +x *.sh

# Phase 1: VPC, ECR, IAM, EFS (~5 phút, bao gồm NAT Gateway)
./01-foundation.sh

# Phase 2: Build Docker images và push lên ECR (~5 phút)
./02-build-push.sh

# Phase 3: ECS Cluster, Secrets, Task Definitions (~2 phút)
./03-ecs-setup.sh

# Phase 4: ALB, ECS Services, chờ healthy (~5 phút)
./04-alb-services.sh

# Phase 5: Auto Scaling + CloudWatch Alarms (~1 phút)
./05-autoscaling.sh
```

### Resume từ phase cụ thể (nếu bị lỗi giữa chừng)

```bash
# Resume từ phase 3 (đã xong phase 1 và 2)
./deploy-all.sh --from 3

# Chỉ chạy phase 2 (build lại images)
./deploy-all.sh --only 2
```

---

## Sau khi deploy xong

### Test hệ thống

```bash
# Chạy automated tests
./06-test-deployment.sh

# Hoặc test thủ công:
ALB_DNS=$(grep ALB_DNS outputs.env | cut -d= -f2)

# Health check
curl http://$ALB_DNS/health
curl http://$ALB_DNS/api/auth/health
curl http://$ALB_DNS/api/tickets/health

# Đăng ký user
curl -X POST http://$ALB_DNS/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"name":"Test User","email":"test@example.com","password":"Password123!"}'

# Đăng nhập
curl -X POST http://$ALB_DNS/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"Password123!"}'
```

---

## ⚡ Chia sẻ Local/Dev nhanh (Cloudflare Quick Tunnel)

Bạn có thể chia sẻ ứng dụng đang chạy ở máy local của mình lên internet bằng Cloudflare Quick Tunnel (tự động tạo subdomain HTTPS miễn phí dạng `*.trycloudflare.com` mà không cần cấu hình tài khoản):

### Cách 1: Sử dụng Script có sẵn
Chúng tôi đã cung cấp sẵn script tự động kiểm tra và chạy Quick Tunnel (tự động fallback sang Docker nếu máy chưa cài CLI):
```bash
cd /e/super-system/infra/scripts
chmod +x local-expose.sh

# Chia sẻ Nginx Gateway (mặc định port 8080)
./local-expose.sh 8080
```
Nhìn vào màn hình console, bạn sẽ thấy đường link HTTPS ngẫu nhiên xuất hiện. Bạn chỉ cần copy link đó gửi cho đối tác hoặc dùng điện thoại truy cập trực tiếp.

### Cách 2: Sử dụng Docker Compose
Trong file `docker-compose.yml`, chúng tôi đã cấu hình sẵn service `cloudflare-tunnel` (mặc định đang comment). Hãy bỏ comment service này và chạy:
```bash
docker-compose up -d
docker-compose logs -f cloudflare-tunnel
```
Log sẽ in ra tên miền `.trycloudflare.com` ngẫu nhiên dẫn thẳng đến API Gateway cục bộ của bạn.

---

## Xem logs trên AWS Console

- **ECS Services:** https://ap-southeast-1.console.aws.amazon.com/ecs/v2/clusters/super-system-cluster/services
- **CloudWatch Logs:** https://ap-southeast-1.console.aws.amazon.com/cloudwatch/home#logsV2:log-groups
- **ALB Health:** https://ap-southeast-1.console.aws.amazon.com/ec2/v2/home#LoadBalancers

---

## Cập nhật code (sau khi thay đổi code)

```bash
# Chỉ build lại images và update services
./deploy-all.sh --from 2 --only 2    # Build images
./deploy-all.sh --only 3             # Update task definitions (nếu cần)

# Force ECS redeploy (dùng image mới nhất)
aws ecs update-service \
  --cluster super-system-cluster \
  --service super-system-auth-service \
  --force-new-deployment \
  --region ap-southeast-1
```

---

## Xóa toàn bộ hạ tầng

```bash
# ⚠️ Cẩn thận! Script này xóa hết mọi thứ
./teardown.sh
```

---

## Ước tính chi phí (~$90–115/tháng)

| Resource | Chi phí |
|----------|---------|
| ECS Fargate (6 tasks × 0.5vCPU) | ~$30–50 |
| ALB | ~$18 |
| NAT Gateway | ~$35 |
| EFS (10GB) | ~$3 |
| ECR (storage) | ~$1 |
| CloudWatch Logs | ~$5 |
| Secrets Manager | ~$2 |

> **Tiết kiệm chi phí:** Khi không dùng (ví dụ ban đêm), chạy `teardown.sh` rồi sáng hôm sau deploy lại — chỉ mất ~20 phút và tiết kiệm được nhiều tiền.
