# 🚀 Velero 오프라인 설치 가이드 (ctr 기반)

폐쇄망 환경에서 `ctr`을 사용하여 K8s 클러스터 백업 체계를 구축하는 절차입니다.

## 1단계: CLI 설치 및 이미지 업로드

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# 1. CLI 바이너리 설치 (컴포넌트 루트에 위치)
tar -xvf velero-v1.14.1-linux-amd64.tar.gz
sudo mv velero-v1.14.1-linux-amd64/velero /usr/local/bin/
velero version --client-only

# 2. 이미지 로드 (ctr 사용)
sudo ctr -n k8s.io images import images/velero-velero-v1.14.1.tar
sudo ctr -n k8s.io images import images/velero-velero-plugin-for-aws-v1.10.1.tar

# 3. upload_images_to_harbor_v3-lite.sh 상단 Config 수정
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

## 3단계: 백업 테스트

설치 완료 후 백업이 정상적으로 수행되는지 테스트합니다.

```bash
# 즉시 백업 실행
velero backup create test-backup --include-namespaces default

# 백업 상태 확인
velero backup get
```
