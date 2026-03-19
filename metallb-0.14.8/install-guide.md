# 🚀 MetalLB v0.14.8 오프라인 설치 가이드

폐쇄망 환경에서 MetalLB를 설치하고 L2 로드밸런싱을 구성하는 절차입니다.

## 1단계: 이미지 로드 및 푸시 (Harbor)

오프라인 이미지 파일(`.tar`)을 노드에 로드하고 로컬 Harbor(`30002`)로 푸시합니다.

```bash
# 1. 이미지 로드
docker load -i images/metallb-controller-v0.14.8.tar
docker load -i images/metallb-speaker-v0.14.8.tar

# 2. 태그 변경 및 푸시 (Harbor IP 입력 필요)
HARBOR_IP="192.168.1.100"
docker tag quay.io/metallb/controller:v0.14.8 ${HARBOR_IP}:30002/library/metallb-controller:v0.14.8
docker push ${HARBOR_IP}:30002/library/metallb-controller:v0.14.8
```

## 2단계: Helm 설치

`values.yaml` 내의 레지스트리 주소를 확인한 후 헬름 설치를 진행합니다.

```bash
# 네임스페이스 생성
kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f -

# 헬름 설치
helm install metallb ./charts/metallb-0.14.8.tgz \
  -n metallb-system \
  -f values.yaml
```

## 3단계: IP 대역(L2) 설정

`manifests/l2-config.yaml` 파일을 열어 자신의 네트워크 환경에 맞는 IP 대역을 설정한 후 적용합니다.

```bash
# 예: 192.168.1.200-210 등 유휴 IP 입력
vi manifests/l2-config.yaml

# 적용
kubectl apply -f manifests/l2-config.yaml
```

## 4단계: 설치 확인

```bash
# 파드 상태 확인
kubectl get pods -n metallb-system

# 서비스 테스트
kubectl get svc -A | grep LoadBalancer
```
