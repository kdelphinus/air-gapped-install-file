# Helm 차트 준비 방법

이 디렉토리에 `nginx-ingress/` Helm 차트를 배치합니다.

## 인터넷 연결 환경에서 준비

```bash
git clone https://github.com/nginx/kubernetes-ingress.git
cd kubernetes-ingress
git checkout v5.3.1

# Helm 차트 추출 (deployments/helm-chart/ → charts/nginx-ingress-5.3.1/)
cp -r deployments/helm-chart/ /transfer/nginx-nic-5.3.1/charts/nginx-ingress-5.3.1
```

## 이관 후 디렉토리 구조

```text
charts/
└── nginx-ingress-5.3.1/
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
```

## 설치 시 참조 경로

`scripts/install.sh`에서 `HELM_CHART_PATH="./charts/nginx-ingress-5.3.1"`로 지정합니다.
