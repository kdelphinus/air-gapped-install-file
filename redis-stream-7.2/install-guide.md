# Redis Stream 설치 가이드

본 가이드는 폐쇄망(Air-gapped) 환경에서 Redis Stream HA 클러스터를 설치하는 과정을 설명합니다.

## 1. 전제 조건

- Kubernetes 클러스터 접근 권한 (`kubectl` 설정 완료)
- Helm v3 이상
- Local Harbor 레지스트리 (기본 포트: 30002)

## 2. 이미지 준비

### 운영 환경 (Harbor 레지스트리)

`images/` 디렉토리의 tar 파일을 Harbor에 업로드합니다.

```bash
export HARBOR_REGISTRY="<NODE_IP>:30002"
./images/upload_images_to_harbor_v3-lite.sh
```

> **Sentinel 이미지 반입 필요**: `bitnami/redis-sentinel:7.2.4-debian-12-r7` tar 파일은
> 외부망에서 별도 반입해야 합니다.
>
> ```bash
> # 외부망에서 실행
> docker pull bitnami/redis-sentinel:7.2.4-debian-12-r7
> docker save bitnami/redis-sentinel:7.2.4-debian-12-r7 -o redis-sentinel.tar
> # tar 파일을 images/ 디렉토리로 반입 후 업로드 스크립트 재실행
> ```

### 로컬 테스트 환경 (ctr import)

tar 파일을 containerd에 직접 임포트합니다.

```bash
sudo ctr -n k8s.io images import images/*.tar
```

> **로컬 환경 구성**: values-local.yaml 적용 시 Master 1 + Replica 1 + Sentinel 2로 축소 배포됩니다.
> Sentinel 이미지 tar가 없는 경우 로컬 테스트가 불가합니다.

## 3. 설치 진행

```bash
# 대화형 실행
./scripts/install.sh

# 또는 환경 지정 실행
./scripts/install.sh local   # 로컬 환경
./scripts/install.sh prod    # 운영 환경
```

설치 중 아래 항목을 대화형으로 입력합니다.

- 설치 환경 선택 (prod / local)
- Storage 타입 선택 (hostpath / nfs)
- HostPath 선택 시: 대상 노드, 데이터 저장 경로
- NFS 선택 시: NFS 서버 IP, 기본 경로, PV 크기
- Redis 비밀번호 입력

### Storage 설정 상세

#### HostPath 선택 시

스크립트가 클러스터 노드 목록을 표시하고 대상 노드를 선택하게 합니다.
저장 경로를 지정하면 (`기본값: /data/redis-stream`) PV에 자동 반영됩니다.

대상 노드가 현재 머신과 다른 경우, 스크립트가 다음과 같이 SSH 명령을 출력합니다.

```text
⚠️  대상 노드(worker-node-01)가 현재 호스트(master)와 다릅니다.
   ssh worker-node-01 'sudo mkdir -p /custom/path/{master,replica-0,replica-1} ...'
```

해당 명령을 실행한 후 설치를 재시도하세요.

#### NFS 선택 시

정적 프로비저닝 방식으로, NFS 서버에 디렉토리를 **사전에 직접 생성**해야 합니다.

```bash
# NFS 서버에서 실행
sudo mkdir -p /nfs/redis-stream/{master,replica-0,replica-1}
sudo chmod -R 777 /nfs/redis-stream
```

디렉토리 생성 후 install.sh를 실행하면 NFS 서버 IP와 경로를 입력받아
3개의 PV(master, replica-0, replica-1)를 정적으로 생성합니다.

> **경로 관리**: Retain 정책으로 PV 삭제 후에도 NFS 디렉토리와 데이터가 보존됩니다.
> 완전 삭제 시 NFS 서버에서 해당 경로를 수동으로 제거하세요.

## 4. 스트림 테스트 및 At-Least-Once 검증

```bash
./scripts/test-stream.sh local   # 또는 prod
```

### 테스트 체크 포인트 및 기대값

| 단계 | 항목 | 기대값 | 목적 |
| :--- | :--- | :--- | :--- |
| 1 | 그룹 생성 | `OK` 또는 준비 완료 | 반복 실행(멱등성) 보장 확인 |
| 2 | 메시지 생산 | Redis ID (예: `1711...-0`) | OOM 방지: `MAXLEN` 제한 적용 확인 |
| 3 | 동기 복제 | `1` 이상 (Replica 가용 시) | 데이터 유실 방지: 복제본 저장 확인 |
| 4 | 메시지 소비 | 성공 메시지 | Consumer 그룹 읽기 기능 확인 |
| 5 | 미처리 목록 | Pending 건수 > 0 | At-Least-Once: 미완료 작업 보존 확인 |
| 6 | 스트림 통계 | `length`, `groups` 수치 | 전체 상태 점검 |

### 테스트 결과 해석

- **WAIT 결과가 0**: Replica Pod 부재 또는 복제 지연. 로컬 단일 Pod 환경에서는 정상입니다.
- **Pending 건수 누적**: 테스트는 `XACK`를 생략합니다. 실행마다 5건씩 증가하는 것이 정상입니다
  (데이터 보존 증명).

## 5. Spring Boot 연동

두 가지 빌드 방식을 모두 지원합니다.

| 빌드 도구 | 프로젝트 경로 | Spring Boot 버전 |
| :--- | :--- | :--- |
| Maven | `examples/spring-boot/` | 3.2.4 |
| Gradle Wrapper | `examples/spring-boot-gradle/` | 3.5.0 |

Sentinel 연결 설정은 `application.yml`에서 확인합니다.

```yaml
spring:
  data:
    redis:
      sentinel:
        master: mymaster
        nodes: redis-stream.redis-stream.svc:26379
      password: "${REDIS_PASSWORD}"
```

### Maven 빌드

```bash
cd examples/spring-boot
mvn clean package -DskipTests
java -jar target/redisstream-0.0.1-SNAPSHOT.jar
```

폐쇄망 환경에서는 `~/.m2/` 로컬 캐시를 포함하거나 내부 Nexus/Artifactory를 구성한 후 빌드합니다.

```bash
# 오프라인 모드 빌드
mvn clean package -DskipTests --offline
```

### Gradle 빌드

`gradlew` 스크립트 포함으로 Gradle 설치 없이 빌드 가능합니다.

```bash
cd examples/spring-boot-gradle
./gradlew bootJar
java -jar build/libs/redisstream-gradle-0.0.1-SNAPSHOT.jar
```

폐쇄망 환경에서는 Gradle 배포판과 의존성을 사전에 캐싱해야 합니다.

```bash
# 캐시 위치 확인
ls ~/.gradle/wrapper/dists/     # Gradle 배포판
ls ~/.gradle/caches/            # 의존성 캐시

# 오프라인 모드 빌드
./gradlew bootJar --offline
```

> **Gradle Wrapper 배포판 반입**: `gradle/wrapper/gradle-wrapper.properties`에 지정된
> 버전의 배포판(`gradle-X.Y.Z-bin.zip`)을 외부망에서 다운로드하여
> `~/.gradle/wrapper/dists/` 디렉토리에 배치 후 오프라인 빌드합니다.

### 실행 (공통)

```bash
# 운영 환경 (Kubernetes 내부 DNS 사용)
REDIS_PASSWORD=<password> java -jar <jar파일>

# 로컬 테스트 (application-local.yml 활성화)
REDIS_PASSWORD=<password> SPRING_PROFILES_ACTIVE=local java -jar <jar파일>
```

### 핵심 운영 주의사항

- **MAXLEN 필수 (OOM 방지)**: `XADD` 시 반드시 `MAXLEN`을 지정해야 합니다.
  설정 없이 운영 시 스트림이 무한 증가하여 Redis OOM이 발생합니다.
- **리밸런싱 부재 (Zombie 회수)**: Kafka와 달리 Consumer 장애 시 자동 재할당 기능이 없습니다.
  `examples/spring-boot`의 `autoClaimZombieMessages()` 패턴을 참고하여
  앱 레벨에서 주기적으로 `XCLAIM`을 실행해야 합니다.
- **At-Least-Once 중복 처리**: Producer의 WAIT 실패 시 메시지가 재전송되어 스트림에 중복
  저장될 수 있습니다. Consumer는 멱등성(idempotent) 처리를 구현해야 합니다.

## 6. 삭제

```bash
./scripts/uninstall.sh
```

PV는 `Retain` 정책으로 데이터 디렉토리가 보존됩니다.
완전히 삭제하려면 대상 노드에서 디렉토리를 수동으로 제거하세요.
