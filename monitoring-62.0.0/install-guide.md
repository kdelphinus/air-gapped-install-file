# 🚀 Monitoring 오프라인 설치 가이드 (ctr 기반)

폐쇄망 환경에서 `ctr`을 사용하여 통합 모니터링(Prometheus/Grafana)을 구축하는 절차입니다.

## 1단계: 이미지 Harbor 업로드

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# 1. 이미지 로드 (ctr 사용)
for f in images/*.tar; do sudo ctr -n k8s.io images import "$f"; done

# 2. upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images (현재 디렉터리의 이미지 폴더 지정)
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

## 2단계: 설치 실행

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# 헬름 설치 (루트의 values.yaml 자동 반영)
chmod +x scripts/install.sh
./scripts/install.sh
```

## 3단계: 재설치 시 PVC 처리 (선택)

Helm은 `uninstall` 시 PVC를 삭제하지 않습니다. 데이터를 초기화하려면 수동으로 삭제해야 합니다.

```bash
# 1. Helm 릴리즈 제거
helm uninstall prometheus -n monitoring

# 2. 데이터 초기화 필요 시 PVC/PV 삭제
kubectl delete pvc --all -n monitoring
# (ReclaimPolicy가 Retain인 경우 PV도 수동 삭제 필요)
```

## 4단계: 설치 확인 및 접속

```bash
# Grafana 접속 (Port-forward 테스트)
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring

# 초기 정보 (values.yaml 설정값 확인)
# ID: admin / PW: admin
```
