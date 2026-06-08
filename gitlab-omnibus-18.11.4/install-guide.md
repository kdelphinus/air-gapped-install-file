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

## 2. K8s 자원 배포 및 GitLab 18.11.4 기동

1. **설치 네임스페이스 생성**:
   ```bash
   kubectl create ns gitlab-omnibus
   ```

2. **[필수] 헬름 기동 전 프로브 IP 화이트리스트 사전 수정**:
   * GitLab은 기본 보안 정책으로 모니터링 경로(`/-/readiness`, `/-/liveness`)를 호출하는 IP를 엄격히 필터링합니다.
   * 쿠버네티스의 프로브(kube-probe) 요청 IP 대역이 기본 사설 대역(`127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) 외에 위치하는 경우(예: CNI 마스커레이딩 대역 `1.x.x.x` 등), **반드시 배포 전에 `charts/gitlab-omnibus/templates/configmap.yaml` 파일 내 `monitoring_whitelist` 설정 배열에 해당 대역을 미리 수동 추가**해야 합니다. 
   * 그렇지 않으면 헬스체크 프로브가 `404 Not Found`로 차단당해 파드가 평생 `Ready` 상태로 들어가지 못하는 원인이 됩니다.
     ```ruby
     gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '1.0.0.0/8']
     ```

3. **Values 설정 및 Helm 배포**:
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
