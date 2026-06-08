# 🚀 GitLab Omnibus 18.11.4 신규 설치 및 구성 가이드

본 문서는 사내 GitLab Omnibus 단일 파드(Kubernetes 환경)를 최신 LTS 안정 버전인 **`18.11.4`**로 깨끗하게 신규 설치하고 구성하기 위한 엔터프라이즈 가이드라인입니다.

---

## 1. 사전 준비 사항

1. **네임스페이스 및 퍼시스턴트 볼륨(PV/PVC)**:
   * GitLab 애플리케이션 및 설정 파일 영구 저장을 위해 충분한 크기의 스토리지 공간을 갖춘 PV를 사전에 프로비저닝해야 합니다. (기본 `values.yaml` 기준: data 50Gi, config 1Gi)
   * `manifests/gitlab-omnibus-pv.yaml` 내의 스토리지 저장 경로를 설치 환경(NFS 또는 호스트 패스 등)에 맞게 수정한 후 K8s 클러스터에 배포합니다:
     ```bash
     kubectl apply -f manifests/gitlab-omnibus-pv.yaml
     ```

2. **도메인 및 외부 통신**:
   * GitLab 웹 호스트에 접근할 외부 NodePort 또는 LoadBalancer IP를 확보하고, DNS 혹은 `/etc/hosts` 파일에 매핑할 테스트 도메인(예: `gitlab.local`)을 사전에 계획합니다.

---

## 2. 배포 절차 (설치 방법 선택)

설치 환경 및 운영 편의에 맞춰 **[방법 A] 자동화 스크립트 배포** 혹은 **[방법 B] 수동 명령어 배포** 중 하나를 선택하여 진행하십시오.

### [방법 A] 자동화 스크립트 이용 배포 (권장)
* **특징**: 입력 설정을 `install.conf`에 영구 보존하며, 기존 배포 상태를 감지하여 업그레이드/재설치/초기화 분기 처리를 자동 제공합니다.
* **설치 명령**:
  컴포넌트 루트 디렉토리에서 다음 스크립트를 실행하고 대화형 프롬프트에 따라 값을 입력하십시오:
  ```bash
  ./scripts/install.sh
  ```
* **동작 세부**:
  1. **대화형 환경 입력**: 이미지 소스(Harbor / Local load / Online), 스토리지 경로(NFS / HostPath / Dynamic), 외부 도메인 등을 수집합니다.
  2. **Values 자동 동기화**: 수집된 환경 변수는 `sed` 명령어를 통해 `values.yaml` 및 `configmap.yaml` 화이트리스트에 자동으로 동기화 매핑되어 반영됩니다.

---

### [방법 B] 수동 명령어 이용 배포 (Manual Fallback)
* **특징**: 자동화 스크립트 없이 매니페스트 설정을 직접 튜닝하여 단계별 수동 명령으로 배포를 통제합니다.
* **수동 배포 단계**:
  1. **설치 네임스페이스 생성**:
     ```bash
     kubectl create ns gitlab-omnibus
     ```
  2. **[필수] 프로브 IP 화이트리스트 사전 수정**:
     K8s 프로브(kube-probe) 요청 IP 대역이 기본 사설 대역 외에 위치하는 경우(예: CNI 마스커레이딩 대역 `1.x.x.x` 등), **배포 전에 `charts/gitlab-omnibus/templates/configmap.yaml` 파일 내 `monitoring_whitelist` 설정 배열에 해당 대역을 미리 수동 추가**해야 합니다 (미조치 시 404 에러로 파드가 정상 동작하지 않습니다).
     ```ruby
     gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '1.0.0.0/8']
     ```
  3. **PV 매니페스트 배포**:
     `manifests/gitlab-omnibus-pv.yaml` 내의 스토리지 저장 경로를 수정한 후 적용합니다:
     ```bash
     kubectl apply -f manifests/gitlab-omnibus-pv.yaml
     ```
  4. **Values 설정 및 Helm 배포**:
     * `values.yaml` 내의 `externalUrl` 주소를 계획한 외부 NodePort 주소(예: `http://gitlab.local:32135` 혹은 `http://<NODE_IP>:32135`)로 수정합니다.
     * 아래 명령을 실행하여 18.11.4 파드를 최초 설치합니다:
       ```bash
       helm upgrade --install gitlab-omnibus ./charts/gitlab-omnibus \
         -n gitlab-omnibus \
         -f values.yaml
       ```

---

## 3. 최초 설치 완료 후 사후 작업 및 검증

Helm 배포가 완료된 후, 파드가 정상 작동하는지 확인하고 초기 관리자 계정을 확보하는 단계입니다.

### 3.1. 초기 관리자(root) 비밀번호 확인
GitLab Omnibus는 최초 설치 시 24시간 동안 유효한 임시 root 비밀번호를 자동으로 생성하여 컨테이너 내부 설정 경로에 저장합니다.
```bash
# 컨테이너 내부에 저장된 초기 비밀번호 파일 조회
kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- cat /etc/gitlab/initial_root_password
```
* **로그인**: 웹브라우저로 `externalUrl`에 접속한 후, 아이디 `root`와 위 명령어로 확인한 임시 비밀번호로 최초 로그인합니다.
* **비밀번호 변경**: 로그인 직후 우측 상단 프로필 -> Settings -> Password 메뉴를 통해 비밀번호를 반드시 즉시 변경하십시오. (보안을 위해 임시 비밀번호 파일은 24시간 후 자동 삭제됩니다.)

### 3.2. 애플리케이션 무결성 점검
GitLab 설치 상태 및 내부 서브데몬(Gitaly, Postgres, Redis 등)들이 문제없이 작동하는지 정합성을 자가 체크합니다:
```bash
kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-rake gitlab:check SANITIZE=true
```
* Rake check 실행 결과 모든 항목이 `green` 및 `yes`로 출력되면 성공적으로 배포가 완료된 것입니다.

---

## 4. 트러블슈팅: K8s 프로브(Readiness) 404 에러

* **현상**: 파드가 `Running` 상태이나 `Ready`로 전환되지 않으며, `GET /-/readiness HTTP/1.1" 404` 로그가 반복될 때.
* **원인**: 2장의 **프로브 IP 화이트리스트 사전 수정** 단계를 누락하여 K8s의 프로브 IP가 차단되었을 때 발생합니다.
* **해결 방법**:
  `charts/gitlab-omnibus/templates/configmap.yaml` 파일 내의 `monitoring_whitelist` 리스트에 프로브가 시도되는 네트워크 대역(예: `'1.0.0.0/8'`) 혹은 사내 에어갭 보안 정책에 맞춰 모든 대역(`'0.0.0.0/0'`)을 추가한 뒤 Helm 업그레이드를 재수행하십시오:
  ```ruby
  gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '1.0.0.0/8']
  ```
