# 🚀 NFS Provisioner 에어갭 설치 가이드

본 문서는 오프라인(폐쇄망) 환경에서 NetApp NFS를 백엔드로 연동하는 NFS Subdir External Provisioner의 배포 절차를 기술합니다.

---

## 📌 버전 정의 명세

사용자 혼선을 예방하기 위해 본 패키지의 Chart 및 App/Image 버전을 다음과 같이 정의합니다.

* **Helm Chart Version**: `4.0.18` (nfs-subdir-external-provisioner)
* **App / Provisioner Image Version**: `v4.0.2`

---

## 0. 오프라인 설치 에셋 수집 (외부망 - 인터넷 환경)

폐쇄망 내부로 반입할 Helm 차트와 컨테이너 이미지(`.tar`) 자산을 수집하기 위해, **인터넷이 연결된 외부 리눅스 PC**에서 아래 단계를 수행합니다.

```bash
# 컴포넌트 루트 디렉토리에서 실행 권한 부여 및 에셋 수집 스크립트 실행
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

* **수집되는 자산:**
  * `./charts/nfs-subdir-external-provisioner/` (helm pull --untar 결과)
  * `./images/registry.k8s.io-sig-storage-nfs-subdir-external-provisioner-v4.0.2.tar`

에셋 수집이 완료되면 전체 디렉토리를 압축하여 폐쇄망 내부로 안전하게 반입합니다.

---

## 1. 이미지 로드 및 마이그레이션 (폐쇄망 환경)

반입 완료 후 환경에 따라 다음 모드 중 하나를 선택해 기동합니다.

```bash
# 이미지 마이그레이션 스크립트 권한 부여 및 실행
chmod +x ./images/upload_images_to_harbor_v3-lite.sh
sudo ./images/upload_images_to_harbor_v3-lite.sh
```

* **방식 1 (로컬 이미지 로드):** 실행 모드에서 `1`을 선택하여 containerd(`k8s.io` 네임스페이스)에 직접 로드합니다.
* **방식 2 (Harbor 레지스트리 업로드):** 실행 모드에서 `2`를 선택하여 Harbor 주소 및 프로젝트 경로를 대화형으로 입력 후 이미지 업로드를 완료합니다.

---

## 2. 대화형 멱등 설치 (install.sh)

설치 스크립트는 컴포넌트 루트에서 기동하며, 실행 시 자동으로 오프라인 에셋 존재 여부(`charts/`, `images/`)를 사전 검증하여 안전하게 종료 흐름을 제어합니다.

```bash
chmod +x ./scripts/install.sh
./scripts/install.sh
```

### 주요 입력 사항 및 수명주기 동작

1. **이미지 소스:**
   * `1` (Harbor 레지스트리 주소 및 프로젝트 경로 입력)
   * `2` (로컬 tar 직접 import)
2. **NFS 서버 정보:**
   * NFS 서버 IP 및 실제 공유 경로 입력 (예: `/data/nfs-share`)
3. **설정 영구화 및 멱등 배포:**
   * 입력된 설정 정보는 `install.conf` 및 `values-infra.yaml`에 보존되어, 향후 재기동 시 입력 프롬프트를 생략하고 업그레이드를 수행합니다.
4. **수명주기 메뉴:**
   * 기존 설치나 `install.conf` 감지 시 표준 메뉴(`1) Upgrade`, `2) Reinstall`, `3) Reset`, `4) Cancel`) 분기가 작동합니다.

---

## 3. 설치 검증

```bash
# 1. StorageClass 상태 확인
kubectl get sc

# 2. 프로비저너 포드 상태 확인
kubectl get pods -n kube-system -l app=nfs-client-provisioner

# 3. 테스트 PVC 생성 및 바인딩 확인
kubectl apply -f - <<EOF
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: nfs-test-pvc
spec:
  storageClassName: nfs-app
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
EOF

# PVC 상태 확인 (Bound 인지 대조)
kubectl get pvc nfs-test-pvc
```

---

## 4. 서비스 삭제 및 초기화

### 일반 삭제 (인프라 설정 유지)

NFS Provisioner 릴리즈 및 추가 StorageClass(`additional-sc.yaml`)만 안전하게 제거하며, 로컬 설정 백업 자산인 `install.conf` 와 `values-infra.yaml` 은 **보존**합니다.

```bash
chmod +x ./scripts/uninstall.sh
./scripts/uninstall.sh
```

### 완전 초기화 (설정 완전 삭제)

헬름 릴리즈 삭제 후, 2차 정밀 y/N 프롬프트를 거쳐 로컬 설정 파일(`install.conf`, `values-infra.yaml`)까지 완벽하게 소거합니다.

```bash
./scripts/uninstall.sh --reset
```
