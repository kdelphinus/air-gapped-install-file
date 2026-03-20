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

## 3단계: 접속 및 확인

```bash
# Grafana 접속 (Port-forward 예시)
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring

# 초기 정보
# ID: admin / PW: admin (values.yaml 설정값)
```
