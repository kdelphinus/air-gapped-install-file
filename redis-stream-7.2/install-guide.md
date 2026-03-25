# Redis Stream 설치 가이드

본 가이드는 폐쇄망(Air-gapped) 또는 로컬 개발 환경에서 Redis Stream HA 클러스터를 설치하는 과정을 설명합니다.

## 1. 전제 조건
- Kubernetes 클러스터 접근 권한 (`kubectl` 설정 완료)
- Helm v3 이상
- (운영 환경 시) Local Harbor 레지스트리 (기본 포트: 30002)

## 2. 설치 환경 선택 및 이미지 준비
- **운영 (Production)**: Harbor 레지스트리 사용. `images/` 내 이미지를 Harbor로 업로드 필수.
- **로컬 (Local/Dev)**: `docker.io/bitnamilegacy/redis` 사용. k3s 등에 이미지 임포트 필수.

## 3. 설치 진행
```bash
# 방식 1: 대화형 실행
./scripts/install.sh

# 방식 2: 인자 실행
./scripts/install.sh local  # 로컬 환경
./scripts/install.sh prod   # 운영 환경
```

### 📦 Storage 설정 (HostPath 선택 시)
- **노드 선택**: 스크립트에서 클러스터 노드 목록 중 하나를 선택.
- **노드 고정**: `nodeAffinity` 자동 적용.
- **디렉토리 생성**: 타겟 노드에서 직접 `/data/redis-stream/*` 생성 필요.

## 4. 스트림 테스트 및 At-Least-Once 검증
```bash
./scripts/test-stream.sh local  # 또는 prod
```

### 📋 테스트 체크 포인트 및 기대값

| 단계 | 항목 | 기대값 (Expected) | 목적 (Reason) |
| :--- | :--- | :--- | :--- |
| **1** | **그룹 생성** | `OK` 또는 `준비되었습니다` | 반복 실행(멱등성) 보장 확인 |
| **2** | **메시지 생산** | `1711...-0` (Redis ID) | **OOM 방지**: `MAXLEN` 제한 적용 생산 |
| **3** | **동기 복제** | `1` 이상 (Replica 가용 시) | **데이터 유실 방지**: 복제본 저장 확인 |
| **4** | **메시지 소비** | (성공 메시지) | Consumer 그룹 읽기 기능 확인 |
| **5** | **미처리 목록** | `Pending 건수: 5 건` 이상 | **At-Least-Once**: 미완료 작업 보존 확인 |
| **6** | **스트림 통계** | `length` 및 `groups` 수치 | 전체 상태 및 부하 점검 |

### ⚠️ [중요] 테스트 결과 해석 가이드
- **WAIT 결과가 0인 경우**: 가용 가능한 Replica Pod가 없거나 복제 지연 발생 상태임. (로컬 단일 Pod 환경 시 발생 가능)
- **Pending 건수 누적**: 본 테스트는 `XACK`를 생략함. 실행 시마다 5건씩 증가하는 것이 정상 (데이터 보존 증명).

---

## 5. Spring Boot 연동
`examples/spring-boot` 프로젝트 참조.

### ⚠️ 핵심 운영 주의사항
1. **MAXLEN 필수 (OOM 방지)**: `XADD` 시 반드시 `MAXLEN`을 지정하여 메모리 점유율 무한 증가를 방지할 것.
2. **리밸런싱 부재 (Zombie 회수)**: Consumer 장애 시 자동 재할당 기능 없음. 앱 레벨에서 `XAUTOCLAIM` 주기적 실행 필수.

## 6. 삭제
```bash
./scripts/uninstall.sh
```
- PV는 `Retain` 정책으로 데이터 디렉토리는 보존됨.
