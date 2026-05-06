# MariaDB 백업 구성 (선택 사항)

Galera Cluster 환경에서 **mariabackup**을 사용한 정기 백업 구성입니다.

NFS 스토리지(`nfs-cmsk8s`)를 백업 저장소로 사용하며,
Kubernetes `CronJob`으로 자동 실행됩니다.

> **선택 사항**: 기본 Galera 설치와 독립적으로 적용 가능합니다.
> NFS Provisioner(`nfs-provisioner-4.0.2`)가 먼저 구성되어 있어야 합니다.

---

## 구조

```text
backup/
└── manifests/
    ├── 01-backup-pvc.yaml        # 백업 저장용 NFS PVC (RWX, 100Gi)
    ├── 02-backup-secret.yaml     # 접속 정보 (host, user, password)
    └── 03-backup-cronjob.yaml    # 정기 백업 CronJob (매일 새벽 2시)
```

---

## 적용 전 수정 사항

### 02-backup-secret.yaml

| 항목 | 설명 |
| :--- | :--- |
| `MYSQL_HOST` | Galera StatefulSet의 Pod-0 headless DNS 주소 |
| `MYSQL_PASSWORD` | `CHANGE_ME` → 실제 root 비밀번호로 변경 |

`MYSQL_HOST` 형식:

```text
<statefulset-pod-name>.<headless-service-name>.<namespace>.svc.cluster.local
```

예시:

```text
mariadb-0.mariadb-headless.mariadb.svc.cluster.local
```

### 03-backup-cronjob.yaml

| 항목 | 설명 |
| :--- | :--- |
| `image` | `<NODE_IP>:30002/library/mariadb:10.11.14` → 실제 Harbor 주소로 변경 |
| `schedule` | `"0 2 * * *"` → 필요 시 변경 |

---

## 적용 순서

```bash
# 1. Secret 수정 후 적용
kubectl apply -f manifests/02-backup-secret.yaml

# 2. PVC 생성
kubectl apply -f manifests/01-backup-pvc.yaml

# 3. CronJob 등록
kubectl apply -f manifests/03-backup-cronjob.yaml
```

### 즉시 테스트 실행

```bash
kubectl create job --from=cronjob/mariadb-backup mariadb-backup-test -n mariadb
kubectl logs -f job/mariadb-backup-test -n mariadb
```

---

## 백업 동작 방식

1. Galera `Pod-0`에 접속 (부하 분산을 위해 replica 노드 고정)
2. `mariabackup --backup --galera-info` 실행
   - `xtrabackup_galera_info` 파일 생성 (wsrep 시퀀스 번호 기록)
3. `mariabackup --prepare` 실행 → 복원 가능한 일관된 상태로 변환
4. `/backup/YYYYMMDD_HHMMSS/` 디렉토리에 저장
5. 7일 초과 백업 자동 삭제

---

## 복원 절차

```bash
# 복원 대상 Pod에서 실행

# 1. MariaDB 프로세스 중지 (Pod 종료 또는 서비스 중단)

# 2. 데이터 디렉토리 비우기
rm -rf /var/lib/mysql/*

# 3. 백업 복원
mariabackup --copy-back \
  --target-dir=/backup/20260303_020000 \
  --datadir=/var/lib/mysql

# 4. 권한 복구
chown -R mysql:mysql /var/lib/mysql
```

---

## 보관 정책

| 항목 | 기본값 | 변경 위치 |
| :--- | :--- | :--- |
| 보관 기간 | 7일 | CronJob `find -mtime +7` |
| 실행 주기 | 매일 02:00 | CronJob `schedule` |
| 저장 용량 | 100Gi | PVC `resources.requests.storage` |
