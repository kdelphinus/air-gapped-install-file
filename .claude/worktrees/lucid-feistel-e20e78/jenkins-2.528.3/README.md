# 📝 Jenkins CI/CD System Specification (Air-gapped)

본 문서는 **Rocky Linux 9.6** 기반 폐쇄망 환경에서 운영되는 Jenkins 빌드 시스템의 구성 및 운영 명세를 정의합니다.

## 1. 시스템 개요 (System Overview)

Jenkins는 Kubernetes 환경에서 **StatefulSet**으로 운영되며, 빌드 부하에 따라 동적으로 에이전트(Worker)를 생성하는 구조를 가집니다.

| 항목 | 사양 | 비고 |
| --- | --- | --- |
| **Jenkins Role** | Controller (Master) | 웹 UI 및 잡 스케줄링 |
| **Deployment Type** | **StatefulSet** | 고유한 상태 및 데이터 유지 필요 |
| **Config Strategy** | **JCasC** (Configuration as Code) | YAML 기반 설정 자동화 |
| **Host OS** | Rocky Linux 9.6 | 클러스터 인프라 환경 |

---

## 2. 스토리지 및 데이터 보존 (Storage & Data)

Jenkins의 모든 설정, 플러그인, 빌드 히스토리는 전용 PV에 저장됩니다.

### 💾 영구 볼륨 명세 (PV/PVC)

| PVC Name | PV Name | Capacity | Reclaim Policy | StorageClass | 파일 |
| --- | --- | --- | --- | --- | --- |
| **jenkins** | **jenkins-pv** | **20Gi** | **Retain** | **manual** | `pv-volume.yaml` |
| **gradle-cache-pvc** | **gradle-cache-pv** | **5Gi** | **Retain** | - | `gradle-cache-pv-pvc.yaml` |

#### jenkins PV

* **데이터 경로**: `/var/jenkins_home`
* **보관 가치**: 플러그인 데이터, 사용자 계정, Pipeline Definition, Build Logs 및 Artifacts.

#### gradle-cache PV

* **데이터 경로 (노드)**: `/data/gradle-cache`
* **마운트 경로 (컨테이너)**: `/var/jenkins_home/.gradle`
* **보관 가치**: Gradle 의존성 캐시 — 빌드 시 Nexus 재다운로드 방지.
* **적용 범위**: Jenkins K8s agent Pod의 `volumeMounts`에 추가 필요 (`gradle-cache-pv-pvc.yaml` 내 Jenkinsfile 예시 참고).

---

## 3. 네트워크 통신 및 접속 (Network)

NodePort 서비스를 통해 외부(사내망)에서 대시보드에 접근할 수 있도록 구성되어 있습니다.

| 서비스 이름 | 포트(내부:외부) | 타입 | 용도 |
| --- | --- | --- | --- |
| `jenkins` | **8080:30000** | **NodePort** | **Jenkins 웹 대시보드 접속** |
| `jenkins-agent` | 50000 | ClusterIP | Controller-Agent 간 JNLP 통신 |

---

## 4. 핵심 설정 리소스 (Configuration & Secrets)

### ⚙️ 주요 ConfigMap

* **jenkins-jenkins-jcasc-config**: Jenkins의 시스템 설정(LDAP, 클라우드 에이전트 설정, 보안 설정 등)이 코드화되어 저장되어 있습니다.
* **jenkins (CM)**: 기본 환경 변수 및 스크립트 정보.

### 🔐 주요 Secret

* **jenkins (Secret)**: 관리자(`admin`) 로그인 초기 비밀번호 및 API 토큰.
* **helm.release**: Jenkins 배포 히스토리 관리 (v1 ~ v3).

---

## 5. 폐쇄망 운영 가이드 (Air-gapped Operation)

### ✅ 플러그인 관리

* 외부 인터넷 연결이 불가능하므로, 신규 플러그인 설치가 필요할 경우 외부에서 `.hpi` 파일을 다운로드하여 `jenkins-pv`의 `plugins` 디렉토리에 수동으로 배치하거나, 플러그인이 포함된 새 이미지를 빌드해야 합니다.

### ✅ 동적 에이전트(Slave) 구성

* 빌드 시 생성되는 Pod은 `jenkins-agent` 서비스를 통해 Master와 통신합니다.
* **중요**: Pipeline 작성 시 `agent { kubernetes { ... } }` 블록에서 사용하는 이미지는 반드시 내부 **GitLab Registry** 혹은 **Harbor**에 존재하는 이미지여야 합니다.

### ✅ Jenkins Pod 구성

Jenkins Pod는 `jenkins-controller` 컨테이너와 `config-reloader` 사이드카 컨테이너가 함께 실행 중입니다.
따라서 **JCasC ConfigMap** 을 수정하고 적용하면 사이드카가 이를 감지하여 Jenkins 재시작 없이 설정을 반영합니다.
