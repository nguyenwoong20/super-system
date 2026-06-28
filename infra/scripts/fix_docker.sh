#!/bin/bash
set -e
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.ap-southeast-1.amazonaws.com"
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin $ECR_URI
aws ecr create-repository --repository-name "super-system/postgres" --region ap-southeast-1 || true
docker pull postgres:16-alpine
docker tag postgres:16-alpine ${ECR_URI}/super-system/postgres:16-alpine
docker push ${ECR_URI}/super-system/postgres:16-alpine
