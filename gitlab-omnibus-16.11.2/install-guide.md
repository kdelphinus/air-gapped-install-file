# 🚀 GitLab Omnibus 16.11.2 초기 설치 및 백업 복원 가이드

본 문서는 마이그레이션 연습(Dry-run)을 위해 테스트 환경에 GitLab **`16.11.2`** 초기 환경을 배포하고, 기존 운영 데이터를 백업 복원하는 절차를 설명합니다.

---

## 1. 사전 준비 사항

1. **마이그레이션 데이터 반입**:
   * 운영 환경에서 백업한 애플리케이션 데이터 파일(`*_gitlab_backup.tar`)
   * 운영 환경의 설정 백업본 (`gitlab-secrets.json` 및 `gitlab.rb`)
2. **네임스페이스 및 퍼시스턴트 볼륨(PV/PVC)**:
   * 복원될 용량에 맞춰 충분한 크기의 스토리지 공간을 갖춘 PV를 사전에 프로비저닝해야 합니다. (기본 `values.yaml` 기준: data 50Gi, config 1Gi)

---

## 2. 1단계: K8s 자원 배포 및 GitLab 16.11.2 기동

1. **설치 네임스페이스 생성**:
   ```bash
   kubectl create ns gitlab-omnibus
   ```
2. **PV 매니페스트 배포**:
   * `manifests/gitlab-omnibus-pv.yaml` 내의 스토리지 저장 경로를 검증용 HostPath 혹은 NFS 디렉토리로 수정한 후 적용합니다:
     ```bash
     kubectl apply -f manifests/gitlab-omnibus-pv.yaml
     ```
3. **Values 설정 및 Helm 배포**:
   * **[필수] 헬름 기동 전 프로브 IP 화이트리스트 사전 수정**:
     GitLab은 기본 보안 정책으로 모니터링 경로(`/-/readiness`)를 호출하는 IP를 철저히 제한합니다. 쿠버네티스의 프로브(kube-probe) 요청 IP 대역이 기본 대역(`127.0.0.0/8`, `10.0.0.0/8` 등) 외에 위치하는 경우(예: CNI 마스커레이딩 대역 `1.x.x.x` 등), **반드시 배포 전에 `charts/gitlab-omnibus/templates/configmap.yaml` 파일 내 `monitoring_whitelist` 설정 배열에 해당 대역을 미리 추가**해야 합니다. 그렇지 않으면 헬스체크 프로브가 `404 Not Found`로 거부되어 파드가 정상(`Ready`) 상태로 들어가지 못합니다.
     ```ruby
     gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '1.0.0.0/8']
     ```
   * `values.yaml` 내의 `externalUrl` 주소를 테스트 도메인 또는 테스트 NodePort 주소(예: `http://<TEST_NODE_IP>:32135`)로 수정합니다.
   * 아래 명령을 실행하여 16.11.2 파드를 띄웁니다:
     ```bash
     helm upgrade --install gitlab-omnibus ./charts/gitlab-omnibus \
       -n gitlab-omnibus \
       -f values.yaml
     ```


---

## 3. 2단계: 운영 백업 데이터 이전 및 복원 실행

### 3.1. 백업 자산 컨테이너 내부로 업로드
1. **설정 및 암호화 파일 이전**:
   * 복원 시 데이터베이스를 올바르게 복호화하려면 운영 환경의 `gitlab-secrets.json` 파일이 필요합니다.
   * 아래 명령어로 파일을 컨테이너 내부의 설정 경로로 업로드합니다:
     ```bash
     # secrets.json 업로드
     kubectl cp gitlab-secrets.json gitlab-omnibus-nfs-config:/etc/gitlab/gitlab-secrets.json -n gitlab-omnibus
     # gitlab.rb 업로드
     kubectl cp gitlab-rb-backup /etc/gitlab/gitlab.rb
     ```
     *(실제 영구 볼륨 스토리지의 config PV 경로인 `/data/gitlab_omnibus/config` 등에 파일들을 직접 복사해 두는 방안이 훨씬 더 간단하고 안정적입니다.)*

2. **애플리케이션 백업 tar 파일 복사**:
   * 운영 백업 tar 파일을 GitLab 데이터 영구 스토리지 볼륨 내부의 백업 디렉토리(기본값: `/var/opt/gitlab/backups/`)로 복사합니다:
     ```bash
     # 컨테이너 내 백업 볼륨 경로로 복사
     kubectl cp <BACKUP_FILE>.tar gitlab-omnibus-pod-name:/var/opt/gitlab/backups/ -n gitlab-omnibus
     ```
   * **소유권 변경**: 복사 완료 후 파일의 소유자가 `git:git`인지 확인하고 변경해 주어야 GitLab 복원 도구가 정상 접근할 수 있습니다.
     ```bash
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- chown git:git /var/opt/gitlab/backups/<BACKUP_FILE>.tar
     ```

### 3.2. 복원 실행
1. **웹서비스 및 백그라운드 큐 처리 프로세스 정지**:
   * 복원 중 DB 정합성이 흔들리지 않도록 Puma 웹서버와 Sidekiq을 정지시킵니다.
     ```bash
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-ctl stop puma
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-ctl stop sidekiq
     ```
2. **복원 명령어 트리거**:
   * 백업 파일명 중 타임스탬프 부분(예: `1716123456_2026_06_08_16.11.2_gitlab_backup.tar` 이라면 `1716123456_2026_06_08_16.11.2`)을 TIMESTAMP 인자로 설정해 복원을 돌립니다.
     ```bash
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-backup restore BACKUP=<TIMESTAMP>
     ```
     *(복원 프로세스 중 Authorized keys 파일과 데이터베이스 테이블 덮어쓰기 여부를 물으면 `yes`를 입력하여 승인합니다.)*

3. **환경 재설정 및 기동**:
   * 복원이 정상 완료되면 중지한 프로세스들을 켜주고 GitLab 설정을 리프레시합니다.
     ```bash
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-ctl reconfigure
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-ctl restart
     ```

---

## 4. 복원 상태 자가 검증

기동 완료 후 아래 명령을 통해 복원 데이터 정합성을 자가 체크합니다:
```bash
kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-rake gitlab:check SANITIZE=true
```
체크 결과 모든 검사 결과가 `green/yes`로 나타나면 테스트 환경에 성공적으로 운영 데이터가 복구된 것입니다. 이 시점부터 목표 버전인 `18.11.4`를 향한 **순차 마이그레이션 실습**을 시작할 수 있습니다. (상세 단계는 `gitlab-omnibus-18.11.4/install-guide.md` 참조)

---

## 5. 트러블슈팅: K8s 프로브(Readiness) 404 에러

* **현상**: 파드가 `Running` 상태이나 `Ready`로 전환되지 않으며, `GET /-/readiness HTTP/1.1" 404` 로그가 반복될 때.
* **원인**: GitLab은 외부 접근 및 서비스 거부(DoS) 방지를 위해 모니터링 엔드포인트(`/-/readiness`)의 IP 화이트리스트(`monitoring_whitelist`)를 운영합니다. K8s의 프로브 소스 IP(예: CNI 마스커레이딩 대역 등)가 기본 사설 대역을 벗어나면 GitLab Rails가 요청을 차단하여 404 Not Found를 응답합니다.
* **해결 방법**:
  `charts/gitlab-omnibus/templates/configmap.yaml` 파일 내의 `monitoring_whitelist` 리스트에 프로브가 시도되는 네트워크 대역(예: `'1.0.0.0/8'`) 혹은 사내 에어갭 보안 정책에 맞춰 모든 대역(`'0.0.0.0/0'`)을 추가한 뒤 Helm 업그레이드를 재수행하십시오:
  ```ruby
  gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '1.0.0.0/8']
  ```

