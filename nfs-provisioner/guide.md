폐쇄망 환경에서 외부 도움 없이 **클러스터 내부 자원만으로 NAS 기능을 구현**하기 위한 설치 패키지 구성을 가이드해 드립니다. 가장 널리 쓰이고 안정적인 `nfs-subdir-external-provisioner`를 기반으로, 외부망에서 준비해야 할 사항과 내부에서 실행해야 할 매니페스트를 정리했습니다.

---

## 1. 폐쇄망 도입 전 준비 사항 (외부망에서 수행)

폐쇄망 내부에는 인터넷이 되지 않으므로, 필요한 **컨테이너 이미지**를 미리 확보하여 내부 레지스트리(Harbor 등)에 등록해야 합니다.

* **필요 이미지:** `registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2`
* **작업 절차:**
1. 이미지 다운로드: `docker pull registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2`
2. 파일로 저장: `docker save registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2 > nfs-provisioner.tar`
3. 폐쇄망 반입 후 로컬 레지스트리에 푸시 (`docker tag` 및 `docker push`).



---

## 2. 클러스터 내부 NAS 서버 및 Provisioner 구성

이 구성은 특정 워커 노드의 디스크를 NFS 저장소로 선언하고, 이를 클러스터 전체에서 `StorageClass`로 쓸 수 있게 만듭니다.

### Step 1: 권한 설정 (RBAC)

프로비저너가 볼륨을 생성하고 관리할 수 있도록 권한을 부여합니다.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-client-provisioner
  namespace: default
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: nfs-client-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: run-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: default
roleRef:
  kind: ClusterRole
  name: nfs-client-provisioner-runner
  apiGroup: rbac.authorization.k8s.io

```

### Step 2: NFS Provisioner 배포 (Deployment)

이 포드가 실제 NFS 마운트 지점을 관리합니다. **중요:** `nfs.server` IP와 `nfs.path`는 실제 NFS 서버(혹은 노드 IP) 정보를 넣어야 합니다.

> 만약 완전한 자급자족을 원하신다면, 노드 한 대에 실제 NFS 서버 패키지(`nfs-kernel-server`)를 설치한 뒤 해당 노드 IP를 기입하세요.

```yaml
kind: Deployment
apiVersion: apps/v1
metadata:
  name: nfs-client-provisioner
  namespace: default
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nfs-client-provisioner
  template:
    metadata:
      labels:
        app: nfs-client-provisioner
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
        - name: nfs-client-provisioner
          image: <내부-레지스트리-주소>/nfs-subdir-external-provisioner:v4.0.2
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: k8s-sigs.io/nfs-subdir-external-provisioner
            - name: NFS_SERVER
              value: 192.168.1.100 # NFS 서버 역할을 할 노드 IP
            - name: NFS_PATH
              value: /data/nfs-share # NFS 서버의 공유 디렉토리
      volumes:
        - name: nfs-client-root
          nfs:
            server: 192.168.1.100
            path: /data/nfs-share

```

### Step 3: StorageClass 정의

이제 개발자들이 사용할 `StorageClass`를 생성합니다.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-cmsk8s # 앞서 언급하신 SC 이름과 동일하게 설정 가능
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "false" # PVC 삭제 시 데이터를 보관할지 여부
reclaimPolicy: Delete
volumeBindingMode: Immediate

```

---

## 3. 기술적 분석 및 트레이드오프

| 항목 | 직접 구축 방식 (In-cluster) | 외부 지원 방식 (Managed NAS) |
| --- | --- | --- |
| **자율성** | 인프라 팀 협조 없이 즉시 구축 가능 | 인프라 팀의 일정과 정책에 종속됨 |
| **운영 부담** | NFS 서버 소프트웨어 관리를 직접 해야 함 | 저장소 안정성은 인프라 팀이 책임짐 |
| **성능** | 워커 노드의 네트워크/디스크 성능을 공유함 | 전용 스토리지 네트워크 사용으로 고성능 |
| **데이터 보호** | 노드 디스크 장애 시 데이터 유실 위험 (백업 필수) | 하드웨어 RAID 등으로 높은 안정성 제공 |

---

## 4. 폐쇄망 운영 전문가의 조언

1. **NFS 서버 역할 노드 고정:** NFS 서버 역할을 하는 노드가 재부팅되거나 IP가 바뀌면 클러스터 전체 스토리지가 중단됩니다. 해당 노드는 고정 IP를 사용하고, `nodeSelector`나 `taint/toleration`을 사용하여 안정적인 노드에만 배포되도록 관리해야 합니다.
2. **OS 패키지 확인:** 쿠버네티스 객체만 생성한다고 끝이 아닙니다. **모든 워커 노드**에 `mount.nfs` 명령어가 실행 가능하도록 `nfs-common` (Ubuntu) 혹은 `nfs-utils` (CentOS/RHEL) 패키지가 설치되어 있어야 합니다. 폐쇄망이라면 이 패키지들도 `yum`이나 `apt` 로컬 리포지토리를 통해 미리 설치해 두어야 합니다.
3. **방화벽 개방:** 노드들 사이에서 TCP/UDP 2049(NFS), 111(RPC) 포트가 서로 통신 가능한지 반드시 확인하십시오.

---

### 💡 더 깊은 이해를 위한 질문

1. **고가용성 (HA):** 위 구성에서 NFS 서버 역할을 하는 노드(192.168.1.100) 자체가 물리적으로 고장난다면, Grafana 데이터를 어떻게 살릴 수 있을까요?
2. **데이터 마이그레이션:** 기존 `hostPath`에 있던 데이터를 새로 생성된 NFS 기반 PVC로 옮길 때, 데이터 권한(UID/GID 472)을 유지하면서 복사하는 가장 효율적인 방법은 무엇일까요?
3. **확장성:** 클러스터 규모가 커져서 여러 팀이 이 NAS를 공유하게 될 때, 특정 팀이 디스크 용량을 독점하지 못하게 제한(Resource Quota)하는 방법은 무엇일까요?

위의 YAML들을 하나의 파일로 합쳐서 배포해 보시겠어요? 아니면, 특정 노드에 NFS 서버 패키지를 직접 설치하는 리눅스 명령어 가이드가 필요하신가요?
