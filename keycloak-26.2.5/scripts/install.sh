#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

NAMESPACE="keycloak"
RELEASE_NAME="keycloak"
CHART_PATH="./charts/keycloak"
VALUES_FILE="./values.yaml"
CONF_FILE="./install.conf"
SECRET_NAME="keycloak-credentials"

load_conf() { if [[ -f ./install.conf ]]; then source ./install.conf; fi; }
save_conf() { cat > ./install.conf <<EOF
# Keycloak 26.2.5 설치 설정 - 비밀번호는 Kubernetes Secret에만 저장됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-}"
HARBOR_PROJECT="${HARBOR_PROJECT:-}"
KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME}"
STORAGE_CLASS="${STORAGE_CLASS}"
STORAGE_SIZE="${STORAGE_SIZE}"
INSTALLED_VERSION="v26.2.5"
EOF
}

check_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "[오류] '$1' 명령어가 필요합니다."; exit 1; }
}

cleanup_resources() {
  local mode="$1"
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null || true
  kubectl delete -f ./manifests/httproute.yaml --ignore-not-found=true 2>/dev/null || true
  read -r -p "Keycloak DB PVC와 인증 Secret도 삭제합니까? (데이터 영구 삭제, y/N): " delete_data
  if [[ "$delete_data" =~ ^[Yy]$ ]]; then
    kubectl delete pvc -n "$NAMESPACE" --all --ignore-not-found=true
    kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found=true
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
  else
    echo "[안내] PVC와 Secret을 보존했습니다."
  fi
  [[ "$mode" == "reset" ]] && rm -f "$CONF_FILE" || true
}

load_conf
check_command kubectl
check_command helm

upgrade=false
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || [[ -f "$CONF_FILE" ]]; then
  echo "기존 설치 또는 설정이 감지되었습니다."
  echo "  1) 업그레이드 (현재 Secret과 설정 유지)"
  echo "  2) 재설치"
  echo "  3) 초기화"
  echo "  4) 취소"
  read -r -p "선택 [1/2/3/4]: " action
  case "$action" in
    1) upgrade=true ;;
    2) cleanup_resources reinstall ;;
    3) cleanup_resources reset; exit 0 ;;
    *) exit 0 ;;
  esac
fi

if [[ "$upgrade" != true ]]; then
  echo "이미지 소스를 선택하세요: 1) Harbor  2) 로컬 tar import"
  read -r -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
  IMAGE_SOURCE="${IMAGE_SOURCE:-1}"
  if [[ "$IMAGE_SOURCE" == "1" ]]; then
    read -r -p "Harbor 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
    read -r -p "Harbor 프로젝트 (예: oss): " HARBOR_PROJECT
    [[ -n "$HARBOR_REGISTRY" && -n "$HARBOR_PROJECT" ]] || { echo "[오류] Harbor 주소와 프로젝트가 필요합니다."; exit 1; }
  elif [[ "$IMAGE_SOURCE" == "2" ]]; then
    for archive in ./images/*.tar; do
      [[ -e "$archive" ]] || { echo "[오류] ./images/에 tar 파일이 없습니다."; exit 1; }
      sudo ctr -n k8s.io images import --all-platforms "$archive"
    done
    HARBOR_REGISTRY=""
    HARBOR_PROJECT=""
  else
    echo "[오류] 1 또는 2를 선택하세요."; exit 1
  fi
  read -r -p "Keycloak FQDN (기본값: keycloak.devops.internal): " KEYCLOAK_HOSTNAME
  KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME:-keycloak.devops.internal}"
  read -r -p "PostgreSQL StorageClass (기본값: nfs-provisioner): " STORAGE_CLASS
  STORAGE_CLASS="${STORAGE_CLASS:-nfs-provisioner}"
  read -r -p "PostgreSQL PVC 크기 (기본값: 20Gi): " STORAGE_SIZE
  STORAGE_SIZE="${STORAGE_SIZE:-20Gi}"
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [[ "$upgrade" != true ]] || ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  read -r -p "Keycloak 관리자 계정 (기본값: admin): " admin_user
  admin_user="${admin_user:-admin}"
  read -r -s -p "Keycloak 관리자 비밀번호: " admin_password; echo
  read -r -s -p "PostgreSQL 비밀번호: " postgres_password; echo
  [[ -n "$admin_password" && -n "$postgres_password" ]] || { echo "[오류] 비밀번호는 비워둘 수 없습니다."; exit 1; }
  kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
    --from-literal=keycloak-admin-password="$admin_password" \
    --from-literal=postgres-password="$postgres_password" \
    --dry-run=client -o yaml | kubectl apply -f -
  sed -i "s|username: admin|username: ${admin_user}|" "$VALUES_FILE"
fi

if [[ "$IMAGE_SOURCE" == "1" ]]; then
  sed -i "s|repository: quay.io/keycloak/keycloak|repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/keycloak|" "$VALUES_FILE"
  sed -i "s|repository: docker.io/library/postgres|repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/postgres|" "$VALUES_FILE"
else
  sed -i "s|repository: .*keycloak.*|repository: quay.io/keycloak/keycloak|" "$VALUES_FILE"
  sed -i "s|repository: .*postgres.*|repository: docker.io/library/postgres|" "$VALUES_FILE"
fi
sed -i "s|hostname: .*|hostname: ${KEYCLOAK_HOSTNAME}|" "$VALUES_FILE"
sed -i "s|storageClass: .*|storageClass: ${STORAGE_CLASS}|" "$VALUES_FILE"
sed -i "s|size: .*|size: ${STORAGE_SIZE}|" "$VALUES_FILE"
sed -i "s|keycloak.devops.internal|${KEYCLOAK_HOSTNAME}|g" ./manifests/httproute.yaml
save_conf

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" --namespace "$NAMESPACE" -f "$VALUES_FILE" --wait
kubectl apply -f ./manifests/httproute.yaml

echo "[완료] https://${KEYCLOAK_HOSTNAME}/admin/ 에서 관리 콘솔에 접속하십시오."
echo "OIDC issuer: https://${KEYCLOAK_HOSTNAME}/realms/oss"
