# 🚀 Nexus Repository 오프라인 설치 가이드 (ctr 기반)

폐쇄망 환경에서 `ctr`을 사용하여 Nexus3를 설치하고 라이브러리 저장소를 구성하는 절차입니다.

## 1단계: 이미지 로드 및 푸시

```bash
# 1. 이미지 로드 (ctr 사용)
sudo ctr -n k8s.io images import images/sonatype-nexus3-3.70.1.tar
```

```bash
# 2. Harbor push — 공통 업로드 스크립트 사용
# harbor-1.14.3/utils/upload_images_to_harbor_v3-lite.sh 내 아래 변수를 수정 후 실행합니다.
#   IMAGE_DIR      : <이 디렉터리>/images
#   HARBOR_REGISTRY: <NODE_IP>:30002
#   HARBOR_PROJECT : library
#   HARBOR_USER    : admin
#   HARBOR_PASSWORD: <Harbor 관리자 비밀번호>
bash ../harbor-1.14.3/utils/upload_images_to_harbor_v3-lite.sh
```

## 2단계: Helm 설치 (폴더 방식)

`charts/nexus-repository-manager` 폴더를 사용하여 설치합니다.

```bash
# 네임스페이스 생성
kubectl create namespace nexus --dry-run=client -o yaml | kubectl apply -f -

# 헬름 설치 (폴더 지정)
helm install nexus ./charts/nexus-repository-manager \
  -n nexus \
  -f values.yaml
```

## 3단계: 초기 비밀번호 확인

```bash
kubectl exec -it nexus-0 -n nexus -- cat /nexus-data/admin.password
```
