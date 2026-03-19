# 🚀 Velero 오프라인 설치 가이드 (ctr 기반)

폐쇄망 환경에서 `ctr`을 사용하여 K8s 클러스터 백업 체계를 구축하는 절차입니다.

## 1단계: CLI 및 이미지 준비

```bash
# 1. CLI 바이너리 설치 (velero-v1.14.1-linux-amd64.tar.gz 은 컴포넌트 루트에 위치)
tar -xvf velero-v1.14.1-linux-amd64.tar.gz
sudo mv velero-v1.14.1-linux-amd64/velero /usr/local/bin/
velero version --client-only
```

```bash
# 2. 이미지 로드 (ctr 사용)
# node-agent 는 velero 와 동일 이미지를 사용하므로 별도 tar 없음
sudo ctr -n k8s.io images import images/velero-velero-v1.14.1.tar
sudo ctr -n k8s.io images import images/velero-velero-plugin-for-aws-v1.10.1.tar
```

```bash
# 3. Harbor push — 공통 업로드 스크립트 사용
# harbor-1.14.3/utils/upload_images_to_harbor_v3-lite.sh 내 아래 변수를 수정 후 실행합니다.
#   IMAGE_DIR      : <이 디렉터리>/images
#   HARBOR_REGISTRY: <NODE_IP>:30002
#   HARBOR_PROJECT : library
#   HARBOR_USER    : admin
#   HARBOR_PASSWORD: <Harbor 관리자 비밀번호>
bash ../harbor-1.14.3/utils/upload_images_to_harbor_v3-lite.sh
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
