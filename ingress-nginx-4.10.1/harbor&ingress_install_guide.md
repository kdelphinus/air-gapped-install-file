# Harbor & Ingress Controller 설치 가이드 (폐쇄망 환경)

## 📌 목적
이 문서는 **폐쇄망 환경에서 Harbor를 Kubernetes 위에 설치**하기 위한 가이드입니다.  
사전에 준비된 스크립트들을 실행하기 전에 반드시 필요한 변수들을 설정하고, 실행 순서를 정확히 지켜야 합니다.

---

## ⚙️ 실행 순서
1. **Ingress 이미지 업로드 (`helm-ingress-controller-설치/ingress-controller-images-upload/upload_images.sh`)**  
   - Ingress 설치에 필요한 Docker 이미지를 설치 될 노드에 미리 업로드합니다.

2. **Ingress Controller 설치 (`helm-ingress-controller-설치/ingress_controller_install_offline.sh`)**  
   - Harbor에 접근하기 위해 Ingress Controller를 설치합니다.

3. **Harbor 이미지 업로드 (`helm-harbor설치/harbor-images-upload/upload_images.sh`)**  
   - Harbor 설치에 필요한 Docker 이미지를 설치 될 노드에 미리 업로드합니다.

4. **Harbor 설치 (`helm-harbor설치/harbor_install_offline.sh`)**  
   - Helm Chart를 이용하여 Harbor를 설치합니다.


5. **(TLS를 사용하지 않은 harbor registry의 경우에만) containerd에 insecure_registry 등록 (`insecurity_registry_add.sh`)**  
   - TLS를 사용하지 않은 harbor registry의 경우 containerd에 insecure_registry를 등록합니다. (각 전체 노드에서 실행)

---

## ⚙️ 설치 전 필수 가이드 라인
- harbor 설치 시 인증서를 사용하지 않고 ip로만 접속 한다면 TLS 활성화 하지 않도록 사용 할 수 있습니다, harbor 설치 스크립트의 EXTERNAL_HOSTNAME은 harbor 레지스트리 push시 사용 되는 ip와 동일 해야 합니다.(인증서를 사용하지 않는다면 자체 NodePort를 생성해서 ip:port로 접속이 가능합니다.)
- harbor 설치 시 인증서를 사용해서 도메인으로 접속한다면 설치 시 TLS로 설정해야 합니다. secret명을 요구하므로 사전에 인증서로 kubernetes의 secret이 생성되어 있어야 합니다. (TLS 설정시 ingress controller의 ip 포트로 접속이 가능합니다.)
harbor 설치 스크립트의 EXTERNAL_HOSTNAME은 실제 도메인 명으로 수정 해야 합니다(harbor 레지스트리 push시 사용 되는 ip와 동일 해야 합니다. TLS 사용시에는 도메인 명).
- harbor 설치 스크립트의 SAVE_PATH(실제 데이터가 저장되는 경로)는 NODE_NAME(PV가 생성될 노드)을 가진 노드에서 디렉터리가 생성 되어 있어야 합니다 (chmod 777 권한 부여 권장)

---

## 🛠 사전 준비 사항
- Kubernetes 클러스터 (master + worker 구성 가능)
- Helm 설치 완료
- `kubectl` CLI 사용 가능
- 네 가지 스크립트 준비:
  - `ingress-controller-images-upload/upload_images.sh`
  - `harbor-images-upload/upload_images.sh`
  - `ingress_controller_install_offline.sh`
  - `harbor_install_offline.sh`
- Harbor 설치용 이미지 `.tar` 파일 준비
- harbor 설치 스크립트에서 TLS 사용 시 TLS 시크릿 명 입력 필요

---

## 📂 스크립트별 설명

### 1️⃣ upload_images.sh
- **목적**: 폐쇄망 환경에서 필요한 모든 Docker 이미지를 노드에 로드합니다.
- **실행 예시**
  ```bash
  ./upload_images.sh
  ```
- **주의 사항**
  - 모든 worker 노드에서 upload_images.sh 스크립트가 실행 되어야 합니다
  - 모든 Harbor/Ingress Controller 관련 이미지(*.tar)는 반드시 upload_images.sh와 같은 폴더에 있어야 합니다.
  - 실행 후 `ctr -n k8s.io images import <이미지_파일.tar>` 로 이미지가 정상 업로드 되었는지 확인합니다.

---

### 2️⃣ ingress_controller_install_offline.sh
- **목적**: Harbor 접속을 위한 Ingress Controller 설치
- **변수**
  - `NAMESPACE`: ingress controller가 설치 될 namespace (기본: `ingress-nginx`)
  - `RELEASE_NAME`: helm release name (기본: `ingress-nginx`)
  - `HELM_CHART_PATH`: helm 차트 파일 경로 (기본: `./ingress-nginx-4.10.1.tgz`)
- **실행 예시**
  ```bash
  ./ingress_controller_install_offline.sh
  ```
- **주의 사항**
  - 특정 노드를 지정하여 설치합니다. 외부에서 해당 노드의 ip로 접근 가능 하면 ingress-controller를 통한 쿠버네티스 ingress, pod을 접근 할 수 있습니다.

---

### 3️⃣ harbor_install_offline.sh
- **목적**: Helm Chart를 이용한 Harbor 설치
- **변수**
  - `HARBOR_NAMESPACE`: harbor가 설치 될 namespace (기본: `harbor`)
  - `HARBOR_RELEASE_NAME`: helm release name (기본: `harbor`)
  - `HELM_CHART_PATH`: helm 차트 파일 경로 (기본: `./harbor-1.14.3.tgz`)
  - `EXTERNAL_HOSTNAME`: Harbor 접근용 도메인 (TLS 인증서 도메인 명과 일치 해야함)
  - `SAVE_PATH`: PV로 사용할 로컬 경로 (데이터 저장 용, 설치 되는 노드의 특정 경로)
  - `NODE_NAME`: harbor의 데이터가 저장될 PV가 위치할 노드 (kubectl get node로 확인)
  - `STORAGE_SIZE`: PVC 요청 크기 (예: `5Gi`)
- **실행 예시**
  ```bash
  ./harbor_install_offline.sh
  ```
- **주의 사항**
  - harbor 설치 스크립트의 SAVE_PATH(실제 데이터가 저장되는 경로)는 NODE_NAME(PV가 생성될 노드)을 가진 노드에서 디렉터리가 생성 되어 있어야 합니다 (chmod 777 권한 부여 권장)
  - `EXTERNAL_HOSTNAME`은 TLS 인증서 도메인 명과 일치 해야함
  - TLS 설치 시 설치 스크립트에서는 시크릿 명을 받으므로 시크릿이 생성 되어 있어야 함
  - 기존 설치가 남아있으면 스크립트가 자동으로 삭제 여부를 물어봅니다 (PV/PVC/Service 포함)

---

### 4️⃣ insecurity_registry_add.sh
- **목적**: TLS를 사용하지 않은 harbor registry에 image를 push하기 위한 containerd 설정
- **변수**
  - `CONFIG_FILE`: containerd 설정파일 위치 (기본: `/etc/containerd/config.toml`)
  - `BACKUP_FILE`: containerd 백업 생성 위치 (기본: `/etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)`)
- **실행 예시**
  ```bash
  ./insecurity_registry_add.sh
  ```
- **주의 사항**
  - harbor에 이미지를 푸쉬하기 위한 실제 주소를 입력해야 합니다.

---

### 5 create_self_signed_tls.sh
- **목적**: self_signed 인증서 생성 스크립트
- **실행 예시**
  ```bash
  ./create_self_signed_tls.sh
  ```

---


## 🌐 접속 방법
- 설치 완료 후 Harbor 접속:
  ```
  TLS 사용: harbor 설치 시 입력 한 domain으로 접속
  NodePort 사용: 화면에 출력
  ```
- 기본 계정:
  - ID: `admin`
  - PW: `HARBOR_ADMIN_PASSWORD`

---

## 📎 추가 참고
- TLS 사용시 `externalURL` 은 Push/Pull 시점에 사용되는 주소 → DNS 등록, TLS 인증서 내 도메인과 같은 값 필요
- 문제 발생 시 별개 쉘을 띄워 `kubectl logs` 로 Ingress 및 Harbor Pod 로그 확인 (설치를 취소하면 롤백 됨)

