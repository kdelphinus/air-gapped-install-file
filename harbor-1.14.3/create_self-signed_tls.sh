#!/bin/bash

# 사용자 입력 받기
read -p "Enter your domain (예: harbor.example.com): " DOMAIN
read -p "Enter secret name (예: harbor-tls): " SECRET_NAME
read -p "Enter namespace (기본값: harbor): " NAMESPACE
NAMESPACE=${NAMESPACE:-harbor}

# 임시 파일명
CRT_FILE="tls.crt"
KEY_FILE="tls.key"

echo "[INFO] 기존 시크릿 확인 및 삭제..."
kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null
if [ $? -eq 0 ]; then
  kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE"
  echo "[INFO] 기존 시크릿 $SECRET_NAME 삭제 완료"
fi

echo "[INFO] 자체 서명 TLS 인증서 생성 중..."
openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
  -keyout "$KEY_FILE" -out "$CRT_FILE" \
  -subj "/C=KR/ST=Seoul/L=Seoul/O=MyOrg/OU=IT/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN"

if [ $? -ne 0 ]; then
  echo "[ERROR] 인증서 생성 실패!"
  exit 1
fi

echo "[INFO] Kubernetes Secret 생성 중..."
kubectl create secret tls "$SECRET_NAME" \
  --cert="$CRT_FILE" \
  --key="$KEY_FILE" \
  -n "$NAMESPACE"

if [ $? -eq 0 ]; then
  echo "[INFO] 시크릿 $SECRET_NAME 생성 완료 (namespace: $NAMESPACE)"
else
  echo "[ERROR] 시크릿 생성 실패!"
  exit 1
fi

echo "[INFO] 로컬 인증서 파일 정리 (선택 사항)"
# rm -f "$CRT_FILE" "$KEY_FILE"