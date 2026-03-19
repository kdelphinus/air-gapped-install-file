# 🚀 Velero 오프라인 설치 가이드 (ctr 기반)

폐쇄망 환경에서 `ctr`을 사용하여 K8s 클러스터 백업 체계를 구축하는 절차입니다.

## 1단계: CLI 및 이미지 준비

```bash
# 1. CLI 바이너리 설치
tar -xvf velero-v1.14.1-linux-amd64.tar.gz
sudo mv velero /usr/local/bin/

# 2. 이미지 로드 (ctr 사용)
sudo ctr -n k8s.io images import images/velero-velero-v1.14.1.tar
sudo ctr -n k8s.io images import images/velero-velero-plugin-for-aws-v1.10.1.tar
```

## 2단계: Helm 설치 (폴더 방식)

`charts/velero` 폴더를 사용하여 설치합니다.

```bash
# 네임스페이스 생성
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -

# 헬름 설치 (폴더 지정)
helm install velero ./charts/velero \
  -n velero \
  -f values.yaml
```

## 3단계: 백업 테스트

```bash
# 즉시 백업 실행
velero backup create test-backup --include-namespaces default
```
