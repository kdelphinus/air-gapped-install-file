# 🚀 GitLab 크로스 클러스터 이관 및 순차 업그레이드 종합 가이드 (v16.11.2 ──> v18.11.4)

본 문서는 구형 클러스터의 GitLab Omnibus (v16.11.2) 환경에서 실행 중인 운영 데이터를 안전하게 보존하면서, 신형 클러스터의 최신 LTS 안정 버전(v18.11.4) 환경으로 **크로스 클러스터 이관(Migration)** 및 **순차 업그레이드**를 수행하기 위한 엔터프라이즈 가이드라인입니다.

---

## 1. 크로스 클러스터 이관(Migration) 전략 설계

구형 클러스터의 데이터를 신형 클러스터로 이전할 때, 기존 PV(NFS 스토리지 등)를 신형에 직접 그대로 마운트하여 업그레이드하는 방식은 데이터가 깨졌을 때 복구(롤백)가 불가능하므로 **결코 권장되지 않습니다.** 아래의 두 가지 전략 중 상황에 맞는 아키텍처를 선택하여 수행하십시오.

### 1안. [권장] 백업 & 복원(Restore) 기반 격리 이관 방식 (안전성 100%)
구형 클러스터와 원본 스토리지는 그대로 보존한 채, 신형 클러스터에 완전히 독립된 새로운 PV/PVC를 생성하여 데이터를 마이그레이션하는 표준 방식입니다.

* **이관 프로세스**:
  1. 구형 클러스터(v16.11.2)에서 서비스 영향도가 낮은 시간대에 **공식 애플리케이션 백업 파일(`tar`)과 암호키 정보**를 추출합니다. (상세 절차는 2장 참조)
  2. 신형 클러스터에 **완전히 독립된 새 영구 볼륨(PV/PVC)**을 갖는 GitLab 16.11.2 파드를 기동합니다.
  3. 구형 클러스터의 백업 자산을 신형 클러스터의 16.11.2 파드에 복원(Restore)합니다. (상세 절차는 3장 참조)
  4. 신형 클러스터에 복구된 GitLab v16.11.2의 정상 기동과 데이터 정합성을 확인합니다.
  5. 검증 완료 후, **신형 클러스터 내에서만 18.11.4까지 순차 업그레이드를 진행**합니다.
* **장점**: 업그레이드 실패 시 신형 클러스터 자원만 리셋하면 되므로, 구형 클러스터의 라이브 서비스에는 전혀 지장이 없고 **DNS 롤백만으로 1초 만에 서비스 원복**이 가능합니다.

### 2안. NFS 파일 스토리지 물리 복제(rsync/Snapshot) 방식
동일한 원본 데이터를 기반으로 인플레이스(In-place) 마이그레이션을 모방하여 진행하고 싶을 때 사용하는 하드웨어/스토리지 수준 복제 방식입니다.

* **이관 프로세스**:
  1. **[필수]** 구형 클러스터의 GitLab v16 파드를 완전히 정지(`scale=0`)하여 NFS 스토리지에 대한 모든 쓰기 동작을 중단시킵니다.
  2. NFS 스토리지 서버 레벨에서 원본 디렉토리를 **신형 클러스터용 새 NFS 디렉토리로 통째로 물리 복제**합니다. (예: `rsync -a` 또는 스토리지 볼륨 스냅샷 복제)
  3. 신형 클러스터에 GitLab 16.11.2 파드를 띄우고, **복제된 새 NFS 스토리지 경로와 바인딩된 PV/PVC**를 매핑합니다.
  4. 정상 기동하는 것을 검증한 뒤 18.11.4까지 순차 업그레이드를 진행합니다.
* **주의점**: 기존 구형 GitLab 파드가 켜져 있는 상태에서 동일한 NFS 디렉토리를 신형 파드가 동시에 읽고 쓰면 데이터베이스 테이블 및 Git 리포지토리가 영구적으로 손상(오염)됩니다.

---

## 2. 사전 원본 데이터 백업 절차 (롤백 대비)

작업 도중 발생하는 장애나 데이터 정합성 실패에 대응하기 위해 구형 클러스터의 데이터 자산을 다음과 같이 격리 보관해야 합니다.

### A. GitLab 공식 애플리케이션 백업 (DB 및 리포지토리)
GitLab 내부의 데이터베이스, 업로드된 파일, Git 리포지토리 등의 정합성을 맞춰 하나의 아카이브로 패키징합니다.
```bash
# 구형 클러스터의 GitLab 파드 내 백업 명령 실행
kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-backup create
```
* **결과물**: `/var/opt/gitlab/backups/` 내에 `[타임스탬프]_YYYY_MM_DD_16.11.2_gitlab_backup.tar` 파일이 생성됩니다.
* 이 파일을 `kubectl cp` 또는 NFS 직접 접근을 통해 외부의 안전한 로컬/백업 서버로 다운로드하여 복사해 둡니다.

### B. 시스템 설정 및 복호화 암호 키 백업 (★필수★)
**GitLab 공식 백업 명령(`gitlab-backup create`)은 암호키와 환경 설정 파일을 포함하지 않습니다.** 데이터베이스 내 암호화된 계정 비밀번호, 러너 토큰, 통합 서비스 정보 등을 복구하려면 반드시 아래 두 파일을 **수동으로 별도 보관**해야 합니다. 이 파일이 유실되면 데이터를 복원하더라도 GitLab 로그인이 불가능하고 DB가 무용지물이 됩니다.
* `/etc/gitlab/gitlab-secrets.json` (복호화 비밀키)
* `/etc/gitlab/gitlab.rb` (사용자 정의 설정 파일)

### C. 물리 NFS 스토리지 통째 아카이브 (NFS 서버 단)
스토리지 서버 수준에서 혹시 모를 파일 손상에 대비하기 위해 디렉토리 스냅샷이나 압축 보관을 수행합니다.
```bash
# NFS 서버에서 디렉토리 권한을 보존하여 tar 아카이브 수행
tar -cvpf gitlab-nfs-raw-backup.tar /data/gitlab-omnibus/data-dir
```

---

## 3. 신형 클러스터 상에서의 16.11.2 초기 복원(Restore) 절차

신형 클러스터로 이전한 후, 구형의 데이터를 v16.11.2 파드에 안전하게 주입하는 단계입니다.

1. **설정 및 복호화 키 주입**:
   * 신형 클러스터에 프로비저닝된 config PV 경로(예: `/data/gitlab_omnibus/config/`)에 구형 클러스터에서 백업받은 `gitlab-secrets.json`과 `gitlab.rb`를 먼저 복사해 넣습니다.
2. **백업 tar 파일 위치 지정 및 권한 설정**:
   * 신형 클러스터용 data PV 내의 백업 경로(`/var/opt/gitlab/backups/`)에 구형 클러스터의 백업 tar 파일을 업로드하고, 파일 소유권을 GitLab 엔진 권한으로 조정합니다:
     ```bash
     chown git:git /var/opt/gitlab/backups/[타임스탬프]_16.11.2_gitlab_backup.tar
     ```
3. **서비스 백그라운드 프로세스 중지**:
   * DB 덮어쓰기 도중 충돌을 막기 위해 Puma(웹서버)와 Sidekiq(배치/큐 처리) 프로세스를 일시 정지합니다:
     ```bash
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-ctl stop puma
     ```
     ```bash
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-ctl stop sidekiq
     ```
4. **복원 명령어 트리거**:
   * 백업 파일의 타임스탬프 명세를 인자로 주입하여 복원을 실행합니다 (질의창이 나타나면 `yes`를 입력):
     ```bash
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-backup restore BACKUP=[타임스탬프]_2026_06_08_16.11.2
     ```
5. **환경 재설정 및 재기동**:
   * 복원이 정상 완료되면 DB 스키마 갱신을 적용하고 중지한 프로세스들을 재기동합니다.
     ```bash
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-ctl reconfigure
     ```
     ```bash
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-ctl restart
     ```
6. **복원 상태 검증**:
   * Rake 자가 정합성 체크 툴을 돌려 정상 판정이 나오는지 검토합니다:
     ```bash
     kubectl exec -it deploy/gitlab-omnibus -n gitlab-omnibus -- gitlab-rake gitlab:check SANITIZE=true
     ```

---

## 4. 공식 필수 업그레이드 경로 및 K8s 최적화 (Required Stops)

신형 클러스터 상에서 데이터 복원이 완벽하게 완료된 후, LTS 최종 버전인 `18.11.4`를 향해 아래 명시된 **마이그레이션 필수 정지점(Upgrade Stops)** 순서로 `helm upgrade` 이미지 태그를 변경해가며 업그레이드를 수행합니다.

### 업그레이드 경로 요약
```text
[16.11.2] (복구 검증 완료) -> [16.11.10] -> [17.1.8] -> [17.3.7] -> [17.5.5] -> [17.8.7] -> [17.11.7] -> [18.2.8] -> [18.5.7] -> [18.8.10] -> [18.11.4]
```
* **참조 공식 링크**:
  * [GitLab Upgrade Path Tool (16.11.10 -> 18.11.4)](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/?current=16.11.10&target=18.11.4)
  * [GitLab 공식 Upgrade Paths 가이드](https://docs.gitlab.com/update/upgrade_paths/#upgrade-path-tool)

---

### ⚠️ 중요: K8s 프로브 IP 화이트리스트 사전 등록 (kube-probe 404 차단)
* GitLab은 기본 보안 정책으로 모니터링 경로(`/-/readiness`, `/-/liveness`)를 호출하는 IP를 엄격히 필터링합니다.
* 쿠버네티스의 프로브(kube-probe) 요청 IP 대역이 기본 대역(`127.0.0.0/8`, `10.0.0.0/8` 등) 외에 위치하는 경우(예: CNI 마스커레이딩 대역 `1.x.x.x` 등), **반드시 배포 전에 `charts/gitlab-omnibus/templates/configmap.yaml` 파일 내 `monitoring_whitelist` 설정 배열에 해당 대역을 미리 수동 추가**해야 합니다. 
* 그렇지 않으면 헬스체크 프로브가 `404 Not Found`로 차단당해 파드가 평생 `Ready` 상태로 들어가지 못하는 원인이 됩니다.
  ```ruby
  gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '1.0.0.0/8']
  ```

---

### ⚠️ 중요: PostgreSQL 업그레이드 대비 스토리지 여유 공간 확보 (50% 룰)
* GitLab 메이저 버전 진입 시(17.x 진입 시 PostgreSQL 14, 18.x 진입 시 PostgreSQL 16) 내장 데이터베이스 엔진의 메이저 업그레이드가 진행됩니다.
* 이때 GitLab Omnibus는 기존 PostgreSQL 데이터 디렉토리를 복제하여 변환하는 안전한 마이그레이션 기법을 사용하므로, **데이터베이스 크기의 최소 1배(전체 스토리지 기준 약 50%의 여유 용량) 이상의 추가 공간이 PV에 확보되어 있어야 합니다.**
* **조치 사항**: 마이그레이션 시작 전 PV/PVC의 스토리지 할당 크기가 현재 사용량 대비 최소 2배 이상 여유를 가질 수 있도록 확장 프로비저닝을 마친 후 작업을 수행하십시오.

---

### ⚠️ K8s 시작 프로브(Startup/Liveness Probe) 무한 재시작 회피 방안
주요 버전 정지점에서 DB 업그레이드(`pg-upgrade`) 및 `reconfigure`가 실행될 때 DB의 크기에 따라 수십 분 이상 걸릴 수 있습니다. 이때 쿠버네티스 프로브 기본 임계치를 초과하면 파드가 비정상 종료 및 무한 재시작 루프에 걸려 데이터가 파손됩니다. 아래 둘 중 하나의 대응책을 반드시 적용하십시오.

* **방안 A (임계치 일시적 연장)**:
  `deployment.yaml` 내 `startupProbe.failureThreshold` 값을 `120`회(60분 수준) 이상으로 늘려 충분한 시간을 줍니다.
* **방안 B (수동 기동 - 권장)**:
  1. `deployment.yaml`의 컨테이너 `command` 스펙에 `["sleep", "36000"]`을 임시 주입하여 자동 기동을 우회하고 백그라운드 슬립 상태로 파드를 띄웁니다.
  2. `kubectl exec -it [파드명] -n [네임스페이스] -- bash`로 직접 컨테이너 내부에 접속합니다.
  3. 컨테이너 내부에서 아래 명령을 차례대로 내려 수동으로 완료를 확인합니다:
     ```bash
     gitlab-ctl reconfigure
     gitlab-ctl pg-upgrade  # DB 엔진 메이저 변환 완료 확인
     ```
  4. 변환 완료 후 `deployment.yaml`의 `command` 설정을 원상 복구하여 헬름 배포를 원상 복구시킵니다.

---

## 5. 버전 이동 간 상태 검증 및 문제 해결 (Troubleshooting)

### 5.1. K8s kube-probe 404 Not Found (Readiness/Liveness 실패) 문제
* **현상**: 파드가 `Running` 상태임에도 불구하고 `Ready` 상태로 전환되지 않으며, 로그 상에 `GET /-/readiness HTTP/1.1" 404` 에러가 관측되는 경우.
* **원인**: GitLab은 외부 보안 정찰 및 DoS 공격 방지를 위해 모니터링 엔드포인트(`/-/readiness`, `/-/liveness`)에 접근할 수 있는 IP 화이트리스트(`monitoring_whitelist`)를 운영합니다. K8s 클러스터 내부의 프로브 소스 IP(예: CNI 마스커레이딩 IP 대역)가 configmap.yaml에 설정된 기본 대역을 벗어날 경우, GitLab Rails 애플리케이션(`HealthController`)이 요청을 차단하여 404 Not Found를 응답하고 프로브가 최종 실패하게 됩니다.
* **조치 방법**:
  `charts/gitlab-omnibus/templates/configmap.yaml` 파일 내의 `monitoring_whitelist` 리스트에 프로브가 시도되는 네트워크 대역(예: `'1.0.0.0/8'`) 혹은 사내 에어갭 보안 정책에 맞춰 모든 대역(`'0.0.0.0/0'`)을 추가한 뒤 Helm 업그레이드를 재수행하십시오:
  ```ruby
  gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '1.0.0.0/8']
  ```

---

각각의 `helm upgrade` 단계가 완료된 후, 다음 단계의 업그레이드 커맨드를 입력하기 전에 반드시 백그라운드 스키마 데이터 변환이 완전히 종료되었는지 확인하고 넘어가야 합니다.

### 5.2. 미완료 백그라운드 마이그레이션 확인 SQL
파드가 기동 완료(`Running` 상태 진입)되면 내부 DB에 접근해 다음 질의를 날립니다.
```bash
sudo gitlab-psql -c "
SELECT job_class_name, table_name, column_name, job_arguments, status 
FROM batched_background_migrations 
WHERE status NOT IN (3, 6);
"
```
* **성공 판정**: 조회 결과가 **0 rows**여야 합니다. 0 rows가 출력되기 전에 버전을 올리면 스키마가 충돌하여 데이터베이스가 오염됩니다.

### 5.3. 마이그레이션이 실패(failed) 혹은 대기 상태에 머물 때 강제 트리거
특정 백작업이 멈춰있어 진행이 안 될 경우, 컨테이너 내에서 아래의 Rails Runner 명령어로 즉시 강제 마무리를 트리거합니다.
```bash
sudo gitlab-rails runner -e production '
Gitlab::Database::BackgroundMigration::BatchedMigration.queued.each do |m|
  puts "Finalizing Migration: #{m.job_class_name}"
  m.finalize!
end'
```

---

## 6. 최종 이관 완료 후 기능 정밀 검증 시나리오

1. **Rake 자산 무결성 자가 점검**:
   ```bash
   sudo gitlab-rake gitlab:check SANITIZE=true
   ```
2. **로그인 및 세션**:
   * 기존 사용자 계정으로 로그인 가능 여부 및 패스워드 검증.
   * OTP 및 2FA가 연동된 계정의 복구 정합성 확인.
3. **CI/CD 파이프라인**:
   * 등록된 Runner 인스턴스가 정상 동작하는지 확인.
   * `CI_JOB_TOKEN`을 이용한 프라이빗 컨테이너 이미지 Pull/Push 파이프라인의 성공 여부 확인. (18.11.4 버전 패치로 버그 해결됨 검토)
4. **Terraform HTTP Backend State**:
   * 기존 PVC 볼륨(`/var/opt/gitlab/gitlab-rails/shared/terraform_state`) 내 데이터가 정상 적재되어 있으며 GitLab UI에 정상 표시되는지 확인.
