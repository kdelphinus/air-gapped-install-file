# 🚀 Monitoring (kube-prometheus-stack) 오프라인 설치 가이드

폐쇄망 환경에서 통합 모니터링(Prometheus/Grafana)을 구축하는 절차입니다.

## 1단계: 오프라인 이미지 준비

모니터링 스택은 약 10개 이상의 이미지를 사용합니다. `images/` 폴더 내의 모든 `.tar` 파일을 로드합니다.

```bash
# 1. 이미지 로드 (예시)
docker load -i images/prometheus-v2.54.tar
docker load -i images/grafana-v11.x.tar
# (나머지 이미지들도 로드)

# 2. Harbor로 푸시
HARBOR_IP="192.168.1.100"
docker tag ... ${HARBOR_IP}:30002/library/prometheus:v2.54
docker push ...
```

## 2단계: 스토리지 방식 선택 (values.yaml 수정)

데이터 보존을 위한 스토리지 방식을 결정합니다.

### Case A: NFS 사용 (권장)
`values.yaml`에서 `storageClassName`을 `nfs-provisioner`로 설정합니다.

### Case B: HostPath 사용
별도의 스토리지 클래스가 없거나 단일 노드 테스트 환경인 경우 `hostpath` 옵션을 사용합니다.

## 3단계: Helm 설치

```bash
# 네임스페이스 생성
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# 헬름 설치
helm install prometheus ./charts/kube-prometheus-stack-62.0.0.tgz \
  -n monitoring \
  -f values.yaml
```

## 4단계: 접속 확인

```bash
# Grafana 접속 (Port-forward 예시)
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring

# 초기 관리자 정보
# ID: admin
# PW: values.yaml 내 grafana.adminPassword 참조
```
