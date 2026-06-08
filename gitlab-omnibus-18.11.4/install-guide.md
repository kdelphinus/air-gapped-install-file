# 🚀 GitLab Omnibus 업그레이드 및 마이그레이션 가이드 (v16.11.2 ──> v18.11.4)

본 문서는 사내 GitLab Omnibus 단일 파드(Kubernetes 환경)를 버전 `16.11.2`에서 최신 LTS 안정 버전인 `18.11.4`로 데이터 유실 없이 안전하게 업그레이드하기 위한 가이드입니다.

---

## 1. 사전 필수 전제 조건 (Kubernetes vs VM)

> [!IMPORTANT]
> **대상 환경 구분**
> * 본 가이드의 기본 패키지 명령은 **Omnibus Linux Package (VM 환경)** 기준입니다.
> * **Kubernetes 환경에서 Omnibus 컨테이너**를 직접 운영하는 경우에는 실제 패키지 설치 명령 대신 **컨테이너 이미지 태그 교체 및 Pod 생명주기 제어 절차**로 치환하여 적용해야 합니다.
> * **공식 GitLab Helm Chart**를 사용하여 업그레이드할 경우에는 본 Omnibus 단일 설정과 다르므로, GitLab 버전과 Chart 버전 간의 버전 매핑 테이블을 사전에 별도로 확인해야 합니다.

> [!CAUTION]
> **치명적 리스크: 시작 프로브(Startup/Liveness Probe)에 의한 파드 강제 재시작 방지**
> 주요 버전 정지점에서 PostgreSQL 엔진 업그레이드(`pg-upgrade`) 및 스키마 변경(`reconfigure`)이 실행될 때, 데이터베이스 크기에 따라 완료까지 수십 분 이상 소요될 수 있습니다. 이때 Kubernetes 프로브 임계값을 초과하면 Kubelet이 파드를 비정상으로 판단하고 강제로 종료한 뒤 재시작합니다. 이는 데이터베이스 파일 손상 및 마이그레이션 깨짐을 초래하므로 아래 둘 중 하나의 조치를 취해야 합니다.
> * **방안 A (임계치 연장)**: 업그레이드 실행 전 `deployment.yaml` 내 `startupProbe.failureThreshold` 값을 `120`회(60분 대기) 이상으로 임시 상향합니다.
> * **방안 B (수동 기동 - 권장)**: `deployment.yaml`의 컨테이너 `command` 스펙에 `["sleep", "36000"]`을 주입하여 자동 기동을 강제 우회한 뒤, `kubectl exec`로 컨테이너 내부로 직접 들어가 `gitlab-ctl reconfigure` 및 `gitlab-ctl pg-upgrade`를 수동 진행합니다.

---

## 2. 공식 필수 업그레이드 경로 (Required Upgrade Stops)

* **공식 업그레이드 경로 참조 링크**:
  * [GitLab Upgrade Path Tool (16.11.10 -> 18.11.4)](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/?current=16.11.10&target=18.11.4)
  * [GitLab 공식 Upgrade Paths 가이드](https://docs.gitlab.com/update/upgrade_paths/#upgrade-path-tool)

GitLab은 마이그레이션 중단점을 준수해야 하며, 데이터 마이그레이션이 완료되는 시점을 SQL로 대조해가며 순차 이동해야 합니다.

```text
[16.11.2] (시작 및 백업 복원 완료 단계)
   │
   ▼
[16.11.10] ── (최종 16버전 안정화 패치 완료)
   │
   ▼
[17.1.8]  ── (PostgreSQL 14 상태 보장 진입) *중요 Stop* (1)
   │
   ▼
[17.3.7]  ── (17.x 중간 정지점)
   │
   ▼
[17.5.5]
   │
   ▼
[17.8.7]
   │
   ▼
[17.11.7] ── (17.x 최종 안정화 패치 완료)
   │
   ▼
[18.2.8]  ── (PostgreSQL 16 상태 보장 진입) *중요 Stop* (2)
   │
   ▼
[18.5.7]
   │
   ▼
[18.8.10]
   │
   ▼
[18.11.4] ── (최종 18버전 마이그레이션 완료 및 검증)
```

*(1) **17.1.8 정지점 사유**: 17.1.8은 공식 문서상 대규모 `ci_pipeline_messages` 테이블을 가진 인스턴스에 대한 조건부 Required Stop이지만, 본 계획에서는 GitLab Support Upgrade Path Tool 결과와 보수적 운영 원칙에 따라 전체 데이터 안전성을 확보하기 위해 필수 정지점으로 규정하여 포함합니다.*

---

## 3. 마이그레이션 및 업그레이드 상세 절차

### 3.1단계: 테스트 환경 구성 및 16.11.2 초기 백업 복원
1. 테스트 네임스페이스 또는 전용 K8s 노드를 격리 확보합니다.
2. `gitlab-omnibus-16.11.2` 컴포넌트 폴더를 이용하여 16.11.2 버전의 GitLab 파드를 최초 기동합니다.
3. 운영 서버에서 `gitlab-backup create` 및 `gitlab-ctl backup-etc`로 떠둔 백업본과 암호화 비밀키(`gitlab-secrets.json`, `gitlab.rb`)를 복원하여 정상 동작하는 상태를 검증합니다.

### 3.2단계: 순차 업그레이드 시뮬레이션 실행
`gitlab-omnibus-18.11.4` 컴포넌트 내의 차트를 사용하되, 이미지 태그(`image.tag`)를 명령어로 오버라이드하여 필수 정지점 순서대로 차례대로 헬름 업그레이드를 수행합니다.

```bash
# 1. 16.11.10 최종 패치 적용
helm upgrade gitlab-omnibus ./charts/gitlab-omnibus -n gitlab-omnibus --set image.tag=16.11.10-ee.0
# (기동 완료 및 DB Background Migration 확인 필수)

# 2. 17.1.8 업그레이드 (PostgreSQL 14 상태 보장 확인)
# [주의] 이 단계 기동 전 deployment.yaml의 startupProbe 임계치 조정 권장
helm upgrade gitlab-omnibus ./charts/gitlab-omnibus -n gitlab-omnibus --set image.tag=17.1.8-ee.0

# 3. 17.3.7 -> 17.5.5 -> 17.8.7 -> 17.11.7 순차 적용
helm upgrade gitlab-omnibus ./charts/gitlab-omnibus -n gitlab-omnibus --set image.tag=17.3.7-ee.0
helm upgrade gitlab-omnibus ./charts/gitlab-omnibus -n gitlab-omnibus --set image.tag=17.5.5-ee.0
helm upgrade gitlab-omnibus ./charts/gitlab-omnibus -n gitlab-omnibus --set image.tag=17.8.7-ee.0
helm upgrade gitlab-omnibus ./charts/gitlab-omnibus -n gitlab-omnibus --set image.tag=17.11.7-ee.0

# 4. 18.2.8 업그레이드 (PostgreSQL 16 상태 보장 확인)
# [주의] 이 단계 기동 전 deployment.yaml의 startupProbe 임계치 조정 권장
helm upgrade gitlab-omnibus ./charts/gitlab-omnibus -n gitlab-omnibus --set image.tag=18.2.8-ee.0

# 5. 18.5.7 -> 18.8.10 -> 18.11.4 최종 버전 순차 적용
helm upgrade gitlab-omnibus ./charts/gitlab-omnibus -n gitlab-omnibus --set image.tag=18.5.7-ee.0
helm upgrade gitlab-omnibus ./charts/gitlab-omnibus -n gitlab-omnibus --set image.tag=18.8.10-ee.0
helm upgrade gitlab-omnibus ./charts/gitlab-omnibus -n gitlab-omnibus --set image.tag=18.11.4-ee.0
```

---

## 4. 버전 이동 간 데이터베이스 상태 검증 방법 (핵심)

각각의 헬름 업그레이드 명령어 적용 후, 다음 버전으로 넘어가기 전 반드시 아래의 백그라운드 스키마 데이터 변환이 완전히 종료되었는지 확인하고 넘어가야 합니다.

### 4.1. 배치가 완료되지 않은 마이그레이션 확인 SQL
파드가 기동 완료(`Running` 상태 진입)되면 컨테이너 내부로 실행 진입하여 아래 SQL을 질의합니다.
```bash
# 컨테이너 내 접속 후 psql 쿼리 실행
sudo gitlab-psql -c "
SELECT job_class_name, table_name, column_name, job_arguments, status 
FROM batched_background_migrations 
WHERE status NOT IN (3, 6);
"
```
* **성공 기준**: 조회 결과가 **0 rows**여야 정상 종료된 상태입니다.
* **대기**: 만약 행이 출력된다면 백그라운드 배치 마이그레이션이 돌고 있는 상태이므로 완료될 때까지 기다리십시오.

### 4.2. 마이그레이션이 실패(failed) 혹은 멈춤 상태일 때 수동 강제 트리거
특정 태스크가 정지되었거나 멈춤 상태일 경우 아래 명령으로 강제 강도 완료를 시도합니다.
```bash
sudo gitlab-rails runner -e production '
Gitlab::Database::BackgroundMigration::BatchedMigration.queued.each do |m|
  puts "Finalizing Migration: #{m.job_class_name}"
  m.finalize!
end'
```

---

## 5. 업그레이드 완료 후 기능 정밀 검증 시나리오

최종 `18.11.4`까지 업그레이드가 완료되면 아래 항목들을 빠짐없이 확인합니다.

1. **Rake 자산 무결성 자가 점검**:
   ```bash
   sudo gitlab-rake gitlab:check SANITIZE=true
   ```
   * 모든 항목이 `green` 및 `yes`인지 확인합니다.
2. **로그인 및 세션**:
   * 기존 사용자 계정으로 로그인 가능 여부 및 패스워드 검증.
   * OTP 및 2FA가 연동된 계정의 복구 정합성 확인.
3. **CI/CD 파이프라인**:
   * 등록된 Runner 인스턴스가 정상 동작하는지 확인.
   * `CI_JOB_TOKEN`을 이용한 프라이빗 컨테이너 이미지 Pull/Push 파이프라인의 성공 여부 확인. (18.11.4 버전 패치로 버그 해결됨 검토)
4. **Terraform HTTP Backend State**:
   * 기존 PVC 볼륨(`/var/opt/gitlab/gitlab-rails/shared/terraform_state`) 내 데이터가 정상 적재되어 있으며 GitLab UI에 정상 표시되는지 확인.
