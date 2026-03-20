# 🚀 Monitoring (kube-prometheus-stack) 오프라인 설치 가이드 (ctr 기반)

폐쇄망 환경에서 `ctr`을 사용하여 통합 모니터링(Prometheus/Grafana)을 구축하는 절차입니다.

## 1단계: 오프라인 이미지 로드 및 푸시

모니터링 스택은 여러 이미지를 사용합니다. `images/` 폴더 내의 모든 `.tar` 파일(총 11개)을 로드합니다.

> Prometheus, Alertmanager, Prometheus Operator, Config Reloader, Webhook Certgen,
> Grafana, Grafana Sidecar (k8s-sidecar), busybox (initChownData),
> Node Exporter, kube-state-metrics, Prometheus Adapter

```bash
# 1. 이미지 로드 (ctr 사용)
for f in images/*.tar; do sudo ctr -n k8s.io images import "$f"; done
```

```bash
# 2. Harbor push — images/ 내 업로드 스크립트 사용
cd images
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : . (현재 디렉터리의 .tar 파일을 직접 사용)
# HARBOR_REGISTRY: <NODE_IP>:30002
# HARBOR_PROJECT : library
# HARBOR_USER    : admin
# HARBOR_PASSWORD: <Harbor 관리자 비밀번호>
chmod +x upload_images_to_harbor_v3-lite.sh
./upload_images_to_harbor_v3-lite.sh
cd ..
```

## 2단계: Helm 설치 (폴더 방식)

압축 해제된 차트 폴더(`charts/kube-prometheus-stack`)를 사용하여 설치를 진행합니다.

```bash
# 네임스페이스 생성
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# 헬름 설치 (폴더 지정)
helm install prometheus ./charts/kube-prometheus-stack \
  -n monitoring \
  -f values.yaml
```

## 3단계: 재설치 시 PVC 처리

Helm은 `uninstall` 시 PVC를 삭제하지 않습니다. StorageClass의 `reclaimPolicy: Retain` 설정 시 PVC를 삭제해도 PV와 실제 데이터는 보존됩니다.

### 재설치 절차

```bash
# 1. Helm 릴리즈 제거 (PVC는 남음)
helm uninstall prometheus -n monitoring

# 2. PVC 확인
kubectl get pvc -n monitoring

# 3-A. 데이터 초기화 후 재설치: PVC와 PV 모두 삭제
kubectl delete pvc --all -n monitoring
kubectl delete pv <PV_NAME>   # PVC 삭제 후 남은 PV 수동 삭제 (Retain 정책)

# 3-B. 데이터 유지하며 재설치: PVC 그대로 두고 재설치
# → Helm이 기존 PVC를 재사용하므로 데이터 보존됨

# 4. 재설치
helm install prometheus ./charts/kube-prometheus-stack \
  -n monitoring \
  -f values.yaml
```

> StorageClass `reclaimPolicy: Delete`인 경우 PVC 삭제 시 PV와 데이터도 함께 삭제됩니다.

## 4단계: 접속 및 확인

```bash
# Grafana 접속 (Port-forward 예시)
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring

# 초기 정보
# ID: admin / PW: admin (values.yaml 설정값)
```
