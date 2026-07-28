# Kubernetes v1.30.14 보안 조치 운영 영향도 분석

## 1. 목적 및 전제

이 문서는 다음 작업이 현재 운영 중인 Kubernetes 서비스에 미치는 영향을 정리합니다.

- 업체 제공 취약점 점검 가이드의 API Server, Controller Manager, Scheduler, etcd,
  Kubelet, RBAC, ServiceAccount, Pod, Secret, 파일 권한, 이미지 및 로그 조치
- Kubernetes v1.30.11에서 v1.30.14로의 보안 패치
- Rocky Linux 기반 kubeadm, Control Plane 3대, Stacked etcd, VIP, containerd 환경

실제 서비스의 replica, PodDisruptionBudget, 배치 노드 및 저장소 사용 상태는 운영
클러스터 조회 결과로 최종 판정해야 합니다. 이 문서의 영향도는 조치 자체가 가질 수
있는 최대 운영 영향을 기준으로 합니다.

## 2. 영향도 기준

| 등급 | 의미 | 작업 조건 |
| :--- | :--- | :--- |
| 낮음 | 조회 또는 로그·모니터링 수준의 영향 | 업무 시간 작업 가능 |
| 보통 | 일부 클라이언트, 모니터링 또는 단일 Pod 재연결 가능 | 순차 작업 및 모니터링 필요 |
| 높음 | Pod 기동 실패, Node `NotReady`, API 또는 서비스 단절 가능 | 18시 이후, 백업·롤백·담당자 대기 |
| 매우 높음 | etcd quorum 상실, 전체 API 중단, 복구 불가 데이터 손실 가능 | 별도 작업계획과 복구훈련 필요 |

점검 명령 자체는 대부분 조회 작업이므로 운영 영향이 낮습니다. 실제 영향은 설정
파일 변경, 인증서 교체, 정적 Pod 재생성, kubelet 재시작, 워크로드 재배포 및 Node
`drain` 단계에서 발생합니다.

## 3. 공통 영향 원칙

### 3.1 즉시 영향과 지연 영향

- API Server, etcd, Controller Manager, Scheduler manifest를 변경하면 해당 노드의
  정적 Pod가 즉시 재생성됩니다.
- Kubelet 설정 변경 후 kubelet을 재시작하면 해당 Node가 잠시 `NotReady`가 될 수
  있습니다.
- RBAC 변경은 저장 즉시 적용되어 사용자, Controller 또는 Pod의 API 요청이 바로
  `Forbidden`으로 실패할 수 있습니다.
- Pod Security, ServiceAccount 및 Pod `securityContext` 변경은 기존 Pod보다 새로
  생성되거나 재시작되는 Pod에서 문제가 드러나는 경우가 많습니다.
- 이미지 정책 변경은 현재 실행 중인 Pod에는 영향이 없지만 다음 배포, 장애 복구 또는
  자동 재스케줄링을 실패시킬 수 있습니다.

### 3.2 HA 환경 공통 조건

- Control Plane과 etcd는 반드시 한 대씩 작업합니다.
- 각 노드 작업 후 API Server `/readyz`, etcd endpoint health와 전체 Node `Ready`를
  확인한 뒤 다음 노드로 이동합니다.
- 동시에 두 개의 etcd member를 재시작하면 3중화 quorum을 잃을 수 있습니다.
- VIP가 있더라도 클라이언트의 기존 연결은 끊길 수 있으므로 짧은 재연결 오류는
  발생할 수 있습니다.
- Control Plane에 업무 Pod가 배치되어 있으면 Control Plane 작업도 서비스 작업으로
  취급합니다.

## 4. API Server 보안 설정 영향

| 조치 | 운영 영향 | 영향도 | 적용 전 확인 |
| :--- | :--- | :--- | :--- |
| `anonymous-auth=false` | 인증 없이 API를 호출하던 점검 도구와 클라이언트가 `401`로 실패 | 보통 | 익명 API 호출 및 비인증 헬스체크 사용 여부 |
| `token-auth-file` 제거 | 정적 토큰을 사용하는 사용자와 자동화가 즉시 인증 실패 | 높음 | API Server Audit Log와 kubeconfig의 정적 토큰 사용 여부 |
| `authorization-mode=Node,RBAC` | 권한이 없는 요청이 차단되며 잘못 설정하면 모든 API 작업 실패 | 높음 | 현재 인가 모드, ClusterRoleBinding 및 시스템 컴포넌트 권한 |
| Admission Plugin 정비 | 금지된 리소스 생성·수정이 실패하며 배포 파이프라인이 중단될 수 있음 | 높음 | 현재 Plugin 목록과 배포 manifest 호환성 |
| API Server TLS 인증서 정비 | 노드별 API Server 재시작, SAN 또는 CA 오류 시 VIP 접속 실패 | 높음 | VIP·모든 Control Plane IP·DNS의 SAN 포함 여부 |
| TLS 최소 버전·Cipher 제한 | 구형 TLS 클라이언트, 에이전트 및 모니터링 연동 실패 가능 | 보통 | `kubectl`, 자동화 도구, Java 클라이언트의 TLS 지원 |
| Audit Log 활성화 | API Server 재시작, 디스크 I/O·용량 증가, 디스크 고갈 시 API 장애 가능 | 보통 | 로그 경로 용량, 권한, rotation 및 수집 정책 |

`anonymous-auth=false`는 일반적인 kubelet, Controller 및 인증된 `kubectl` 사용에는
영향이 없습니다. 다만 외부 로드밸런서가 인증 없이 API 경로를 점검한다면 TCP
헬스체크 또는 인증이 필요 없는 별도 방식으로 변경해야 합니다.

Admission 설정은 기존 실행 Pod를 즉시 종료하지 않습니다. 그러나 Deployment
재시작, 장애 복구, HPA 확장 및 신규 배포 시 Pod 생성이 거부될 수 있으므로 사전
검증 없이 `enforce`하면 지연 장애가 발생합니다.

### 4.1 API Server 적용 중단 기준

- `/readyz`가 1분 이상 정상으로 돌아오지 않음
- VIP를 통한 `kubectl get --raw='/readyz'` 실패
- 새로운 `Unauthorized`, `Forbidden` 오류가 다수 발생
- Audit Log 경로의 사용률이 80% 이상이거나 로그 파일 생성 실패

## 5. Scheduler 및 Controller Manager 영향

| 조치 | 운영 영향 | 영향도 | 적용 전 확인 |
| :--- | :--- | :--- | :--- |
| `bind-address=127.0.0.1` | 외부에서 직접 수집하던 metrics endpoint 접근 중단 | 보통 | Prometheus scrape 주소와 ServiceMonitor 구성 |
| 인증·인가 설정 강화 | 비인증 metrics 수집과 관리 요청 차단 | 보통 | 모니터링 인증 방식 |
| `use-service-account-credentials=true` | 각 Controller가 별도 ServiceAccount 권한을 사용하며 누락 권한 시 제어 루프 실패 | 높음 | `kube-system` Controller 권한과 오류 로그 |
| ServiceAccount 개인키·Root CA 경로 정비 | 경로·권한 오류 시 토큰 발급과 Controller 동작 실패 | 높음 | 파일 존재, 소유자, 권한 및 인증서 체인 |
| Kubelet client 인증서·인증서 rotation 정비 | 인증서 오류 시 Controller와 kubelet 간 통신 실패 | 높음 | CSR, 인증서 만료 및 Controller 로그 |

Scheduler 또는 Controller Manager 한 대의 정적 Pod 재시작은 3중화 환경에서 보통
서비스 트래픽을 끊지 않습니다. 다만 leader election이 다시 이루어지는 동안 신규
Pod 스케줄링, Replica 복구, Endpoint 갱신 및 Job 처리가 잠시 지연될 수 있습니다.

### 5.1 Scheduler 및 Controller 적용 중단 기준

- Pending Pod가 계속 증가하거나 2분 이상 스케줄되지 않음
- Deployment replica 복구와 Endpoint 갱신이 진행되지 않음
- Controller Manager 로그에 반복적인 `Forbidden` 또는 인증서 오류 발생
- 리더가 선출되지 않거나 정적 Pod가 반복 재시작

## 6. etcd 보안 설정 영향

| 조치 | 운영 영향 | 영향도 | 적용 전 확인 |
| :--- | :--- | :--- | :--- |
| Client TLS 인증 강제 | API Server의 인증서·CA·endpoint가 맞지 않으면 전체 API 실패 | 매우 높음 | API Server etcd client 인증서와 CA 검증 |
| Peer TLS 인증 강제 | member 간 연결 실패 시 quorum 상실 가능 | 매우 높음 | 모든 member의 peer URL, SAN, CA 및 시간 동기화 |
| 외부 접근 제한 | 외부 백업·모니터링 도구가 차단될 수 있음 | 높음 | etcd 직접 접속 주체와 방화벽 규칙 |
| Secret Encryption at Rest 적용 | API Server 재시작과 기존 Secret 재기록 부하 발생 | 높음 | 동일 키 파일 배포, 백업, 디스크 여유 |
| 암호화 키 rotation | 순서 오류 또는 이전 키 제거 시 기존 데이터 복호화 실패 | 매우 높음 | 이전 키 유지, 전체 Secret 재기록 및 복호화 검증 |
| Snapshot 권한 강화 | 백업 계정의 읽기 권한이 제거될 수 있음 | 보통 | 백업 실행 계정과 보관 경로 |
| Snapshot 암호화 | 백업·복구 절차와 키 관리가 변경됨 | 높음 | 암호화 키 별도 보관과 복구 시험 |
| Snapshot 복구 검증 | 운영 etcd에 복원하면 전체 장애 발생 | 매우 높음 | 운영과 분리된 검증 환경 사용 |

Encryption at Rest를 설정해도 기존 Secret은 자동으로 모두 다시 암호화되지 않습니다.
API Server 설정 적용 후 Secret을 읽어 다시 저장하는 단계에서 etcd write와 Audit Log
양이 증가할 수 있습니다. 이 작업은 트래픽이 낮은 시간에 수행합니다.

etcd Snapshot 복구 시험은 운영 클러스터에서 실행하지 않습니다. 별도 노드 또는
격리된 디렉터리와 포트에서 복구 가능성만 확인합니다.

### 6.1 etcd 적용 중단 기준

- `etcdctl endpoint health`에서 한 개 이상 비정상
- 3개 member 중 2개가 동시에 비정상
- API Server 로그에 `x509`, `connection refused`, `context deadline exceeded` 반복
- Secret 조회 또는 생성 실패
- 암호화 설정 적용 후 기존 Secret 복호화 실패

## 7. Kubelet 보안 설정 영향

| 조치 | 운영 영향 | 영향도 | 적용 전 확인 |
| :--- | :--- | :--- | :--- |
| 익명 접근 비활성화 | 무인증으로 10250을 호출하던 수집·운영 도구 실패 | 보통 | metrics, log, exec 연동의 인증 방식 |
| Read-only Port 비활성화 | 10255를 사용하던 구형 모니터링 수집 중단 | 보통 | Prometheus 및 Node 수집 대상 포트 |
| Webhook 인증·인가 | API Server 통신 실패 또는 설정 오류 시 kubelet API 요청 실패 | 높음 | Node Authorizer, RBAC 및 API 연결 |
| `protectKernelDefaults=true` | OS 커널 파라미터가 기준과 다르면 kubelet 기동 실패 | 높음 | kubelet 로그와 필요한 sysctl 선조치 |
| Client·Server TLS 정비 | 인증서·CA 오류 시 metrics, log, exec 및 Node 통신 실패 | 높음 | 인증서 SAN, CA, 만료 및 파일 권한 |
| Server 인증서 rotation | CSR 미승인 시 새 인증서 발급 지연 또는 기능 실패 | 보통 | `kubectl get csr`, 승인 정책 |
| TLS Cipher 제한 | 구형 metrics 또는 운영 클라이언트 접속 실패 | 보통 | 모든 kubelet API 클라이언트 호환성 |
| Kubelet 설정 파일 권한 강화 | 소유자·권한 오류 시 kubelet 기동 실패 | 높음 | `root:root`, 파일별 권장 권한 |

Kubelet 재시작만으로 실행 중인 컨테이너가 즉시 종료되는 것은 아니지만, Node 상태
보고와 Pod 관리가 잠시 중단됩니다. 설정 오류로 kubelet이 복구되지 않으면 Node가
`NotReady`가 되고 Pod 재스케줄링 또는 서비스 Endpoint 제외가 발생할 수 있습니다.

`protectKernelDefaults=true`는 바로 일괄 적용하지 않습니다. 먼저 각 Node에서
kubelet 로그가 요구하는 커널 파라미터를 확인하고 OS 설정을 맞춘 뒤 한 대씩
활성화합니다.

### 7.1 Kubelet 적용 중단 기준

- kubelet 재시작 후 2분 내 Node가 `Ready`로 복귀하지 않음
- `journalctl -u kubelet`에 kernel default, 인증서 또는 Webhook 오류 반복
- metrics 수집, `kubectl logs` 또는 `kubectl exec` 실패
- 해당 Node의 Pod readiness가 연속으로 실패

## 8. RBAC 및 ServiceAccount 영향

| 조치 | 운영 영향 | 영향도 | 적용 전 확인 |
| :--- | :--- | :--- | :--- |
| 과도한 `cluster-admin` 회수 | 사용자·자동화·운영 도구의 API 요청이 즉시 `Forbidden` 처리 | 높음 | Audit Log와 `kubectl auth can-i` |
| `system:authenticated` 등 광범위 binding 제거 | 해당 그룹의 모든 사용자 권한 변경 | 높음 | binding 주체와 실제 사용 계정 |
| ServiceAccount 최소 권한화 | Operator, Controller 및 애플리케이션의 조회·갱신 실패 | 높음 | ServiceAccount별 API 동작 목록 |
| `default` ServiceAccount 사용 중단 | 새 Pod의 API 접근과 이미지 pull 동작 변경 가능 | 높음 | workload별 ServiceAccount와 imagePullSecrets |
| 토큰 자동 Mount 비활성화 | Kubernetes API를 사용하는 Pod가 재생성 후 인증 실패 | 높음 | Pod 내부 API 호출 여부 |
| 장기 Token 교체 | 외부 자동화와 애플리케이션 인증 실패 가능 | 높음 | Token 사용 주체와 이중화된 교체 절차 |

RBAC 변경은 재시작 없이 즉시 반영됩니다. 권한을 먼저 삭제하지 말고 대체 Role과
RoleBinding을 추가한 뒤 `kubectl auth can-i --as`로 검증하고 기존 권한을
회수합니다.

ServiceAccount 토큰 자동 Mount 비활성화는 기존 Pod보다 재생성된 Pod에서 장애가
발생하기 쉽습니다. Deployment rollout 전에 API 사용 여부를 확인해야 합니다.

## 9. Pod 및 워크로드 보안 영향

| 조치 | 운영 영향 | 영향도 | 적용 전 확인 |
| :--- | :--- | :--- | :--- |
| Privileged 금지 | CNI, CSI, 보안·모니터링 Agent 및 장치 Plugin 기동 실패 가능 | 높음 | 예외가 필요한 시스템 DaemonSet |
| Host Network·PID·IPC 금지 | Ingress, 네트워크 Agent 및 Host 감시 기능 실패 가능 | 높음 | `kube-system`과 운영 Agent 사용 현황 |
| Root 실행 금지 | 비root를 지원하지 않는 이미지가 시작 실패 | 높음 | 이미지 UID와 파일 소유권 |
| 권한 상승 금지 | `sudo`, setuid 또는 일부 초기화 작업 실패 | 높음 | entrypoint와 Init Container 동작 |
| Capability 제거 | 네트워크·시간·시스템 조작 기능 실패 | 높음 | 필요한 Capability별 예외 |
| `readOnlyRootFilesystem=true` | 임시·로그·캐시 파일을 쓰는 컨테이너가 실패 | 높음 | 쓰기 경로와 `emptyDir` Mount |
| HostPath 제한 | 노드 파일을 사용하는 Agent·스토리지·업무 Pod 실패 | 높음 | 경로별 목적과 대체 Volume |
| containerd Socket Mount 제한 | 빌드·이미지 관리·보안 Agent 기능 중단 | 높음 | `/run/containerd/containerd.sock` 사용자 |
| Pod Security Admission 적용 | 기준을 위반한 새 Pod 생성·갱신 거부 | 높음 | namespace별 `warn`·`audit` 결과 |

Pod Security Admission의 `enforce`는 기존 실행 Pod를 삭제하지 않습니다. 그러나
Pod 재시작, Node drain, HPA 확장 및 장애 복구 시 대체 Pod가 생성되지 않을 수 있어
운영 중에는 가장 주의해야 할 지연 영향 항목입니다.

다음 순서로 적용합니다.

1. namespace에 `warn`과 `audit`만 적용합니다.
1. 전체 workload의 위반 Event를 수집합니다.
1. CNI, CSI, Envoy, 모니터링 Agent 등 시스템 namespace의 예외를 확정합니다.
1. 업무 namespace별 manifest를 수정하고 rollout을 검증합니다.
1. 마지막에 namespace 단위로 `enforce`를 적용합니다.

## 10. Secret 관리 영향

| 조치 | 운영 영향 | 영향도 | 적용 전 확인 |
| :--- | :--- | :--- | :--- |
| Secret RBAC 최소화 | Secret을 읽는 Pod·Controller의 API 호출 실패 | 높음 | 실제 Secret 접근 주체 |
| 환경변수 노출 축소 | manifest 및 애플리케이션 설정 변경과 Pod 재시작 필요 | 보통 | Secret 참조 방식 |
| Secret·Token 교체 | DB, API 및 외부 연동 연결 실패 가능 | 높음 | 구·신 자격증명 동시 허용 여부 |
| 인증서 교체 | TLS 연결 재수립, 신뢰체인 오류 및 Pod 재시작 가능 | 높음 | CA, SAN, 만료 및 reload 지원 |
| Encryption at Rest | API Server와 etcd 영향은 6장 참조 | 높음 | 키 백업과 전 노드 동일 설정 |

MariaDB 계정 비밀번호 등 외부 시스템 자격증명은 새 값을 먼저 허용하고 Kubernetes
Secret과 Pod를 전환한 뒤 기존 값을 폐기합니다. 한 번에 기존 자격증명을 폐기하면
모든 CMP Pod의 DB 연결이 동시에 끊길 수 있습니다.

## 11. 파일 및 인증서 권한 영향

| 조치 | 운영 영향 | 영향도 | 적용 전 확인 |
| :--- | :--- | :--- | :--- |
| kubeconfig·manifest 권한 강화 | 잘못된 소유자·과도한 제한 시 컴포넌트 기동 실패 | 높음 | 실행 사용자와 현재 권한 |
| 개인키 `600` 적용 | root 외 백업·운영 계정 접근 중단 가능 | 보통 | 백업 실행 계정 |
| 공개 인증서 `644` 또는 더 엄격하게 유지 | 일반적으로 서비스 영향 없음 | 낮음 | 개인키와 공개 인증서 구분 |
| `/var/lib/etcd` 권한 강화 | etcd 실행 사용자가 읽지 못하면 member 기동 실패 | 매우 높음 | etcd static Pod의 UID와 Mount |
| 인증서 갱신 | 해당 컴포넌트 재시작과 연결 재수립 발생 | 높음 | SAN, CA, 만료, 배포 범위 |
| CA 교체 | 모든 클라이언트와 컴포넌트의 신뢰체인 변경 | 매우 높음 | 별도 CA rotation 계획 |

파일 권한은 일괄 `chmod -R`로 변경하지 않습니다. 파일 종류별 권장값과 현재 실행
사용자를 확인하고 한 파일씩 적용합니다. 공개 인증서, kubeconfig, 개인키 및 etcd
데이터 디렉터리에 동일한 권한값을 적용하면 장애가 발생할 수 있습니다.

이 취약점 조치 범위에서는 CA 교체를 수행하지 않습니다. 인증서 만료 갱신과 CA
rotation은 영향 범위가 다르므로 별도 작업으로 분리합니다.

## 12. 컨테이너 이미지 보안 영향

| 조치 | 운영 영향 | 영향도 | 적용 전 확인 |
| :--- | :--- | :--- | :--- |
| 이미지 취약점 검사 | 이미지 실행 상태에는 영향 없음, 검사 자원 사용 | 낮음 | 오프라인 DB와 결과 기준일 |
| `latest` 제거·버전 고정 | manifest 변경 시 rollout과 이미지 pull 발생 | 보통 | 새 이미지 사전 반입 |
| 승인 Registry 강제 | 미승인 Registry 이미지의 신규 Pod 생성 실패 | 높음 | 전체 workload 이미지 목록 |
| 취약 이미지 배포 차단 | 기존 Pod는 유지되나 재배포·복구가 거부될 수 있음 | 높음 | 예외 승인 및 차단 기준 |
| 이미지 서명 검증 | 서명되지 않은 기존 이미지의 신규 배포 실패 | 높음 | 서명·키 배포와 검증 정책 |

폐쇄망에서는 정책을 적용하기 전에 모든 대상 이미지를 Harbor 또는 각 Node의
containerd에 반입해야 합니다. 현재 Pod가 실행 중이라는 사실만으로 장애 복구 시
이미지를 다시 가져올 수 있다고 판단하면 안 됩니다.

이미지 스캔 결과는 스캔 DB 기준일을 함께 기록합니다. 인터넷이 차단된 환경에서는
DB가 오래되면 최신 CVE가 탐지되지 않을 수 있습니다.

## 13. Audit Log, Event 및 운영 로그 영향

| 조치 | 운영 영향 | 영향도 | 적용 전 확인 |
| :--- | :--- | :--- | :--- |
| API Server Audit Log 활성화 | API Server 재시작, CPU·디스크 I/O와 저장량 증가 | 보통 | 정책 범위, 디스크, rotation |
| Audit 정책 상세화 | Request·Response 기록량과 민감정보 노출 증가 | 보통 | Secret 본문 제외와 보관 권한 |
| Event 보존 확대 | etcd 저장량과 API Server 부하 증가 | 보통 | 현재 Event 발생량 |
| kubelet·시스템 로그 수집 | Node 디스크·네트워크 사용량 증가 | 낮음 | 수집량, buffer 및 전송 장애 처리 |
| 로그 rotation·보존 | 설정 오류 시 필요한 감사 로그 조기 삭제 가능 | 보통 | 보존기간과 외부 이관 여부 |

Audit Log는 `RequestResponse`를 광범위하게 적용하지 않습니다. Secret, Token 및
인증정보가 로그에 남지 않도록 정책을 제한하고, 로그 디렉터리 사용률과 rotation을
먼저 구성합니다.

## 14. Kubernetes v1.30.14 패치 영향

### 14.1 변경 범위

v1.30.11에서 v1.30.14로 올릴 때 kubeadm 기준 필수 이미지는 다음과 같습니다.

- `registry.k8s.io/kube-apiserver:v1.30.14`
- `registry.k8s.io/kube-controller-manager:v1.30.14`
- `registry.k8s.io/kube-scheduler:v1.30.14`
- `registry.k8s.io/kube-proxy:v1.30.14`
- `registry.k8s.io/coredns/coredns:v1.11.3`
- `registry.k8s.io/pause:3.9`
- `registry.k8s.io/etcd:3.5.15-0`

v1.30.11과 v1.30.14의 kubeadm 기본 이미지 목록을 비교하면 CoreDNS, pause 및 etcd
버전은 동일하고 Kubernetes 핵심 컴포넌트 4종만 변경됩니다. 다만 폐쇄망 반입
묶음에는 kubeadm이 요구하는 7종 전체를 포함하여 Node의 이미지 누락을 방지합니다.

### 14.2 컴포넌트별 영향

| 대상 | 예상 영향 | 영향도 | HA 조건 |
| :--- | :--- | :--- | :--- |
| API Server | 노드별 정적 Pod 재시작, 기존 연결 재수립 | 보통 | Control Plane 한 대씩 |
| etcd | v1.30.11과 기본 이미지 동일, manifest 재생성 시 짧은 연결 지연 가능 | 높음 | endpoint health 확인 후 다음 노드 |
| Scheduler·Controller | leader election 동안 신규 배치·복구가 잠시 지연 | 보통 | 한 대씩 작업 |
| kube-proxy | 마지막 Control Plane 이후 DaemonSet 갱신 가능, 네트워크 규칙 동기화 | 보통 | 전체 Node 상태와 통신 확인 |
| CoreDNS | 기본 이미지가 동일해도 manifest 조정 또는 Pod 재시작 가능 | 보통 | replica 2 이상과 노드 분산 확인 |
| Kubelet | 재시작과 컨테이너 spec 변경에 따른 Pod 재시작 가능 | 높음 | Node 한 대씩 drain |
| Calico CNI | 동일 마이너 패치에서 자동 업그레이드하지 않음 | 낮음 | 기존 DaemonSet 상태 확인 |
| Envoy Gateway | 해당 Node drain 시 Pod 이동과 연결 재수립 | 높음 | replica 2 이상, 노드 분산 |
| CMP 업무 서비스 | Pod eviction·재생성, 단일 replica는 서비스 중단 | 높음 | replica, PDB, 여유 자원 확인 |
| 외부 MariaDB Galera | DB 자체는 패치 대상이 아니나 CMP Pod 재시작으로 연결 재수립 | 보통 | JDBC 재연결과 connection pool 확인 |
| 모니터링·로그 | 수집 Pod 이동과 짧은 수집 공백 | 보통 | replica와 buffer 확인 |
| Job·CronJob | 실행 중인 Job 중단 또는 재실행 가능 | 보통 | 작업 시간 동안 스케줄 정지 검토 |

Kubernetes v1.30 내 패치이므로 API 제거에 따른 manifest 호환성 영향은 낮습니다.
주요 운영 영향은 버전 호환성보다 정적 Pod 재시작, kubelet 재시작 및 Worker
`drain`에서 발생합니다.

### 14.3 `drain`에 따른 서비스 영향

- replica가 2 이상이고 서로 다른 Node에 배치되며 PDB가 허용하면 연결 재수립 수준의
  짧은 영향으로 끝날 가능성이 높습니다.
- replica가 1이면 해당 Pod가 종료되고 다른 Node에서 Ready가 될 때까지 서비스가
  중단됩니다.
- `hostPath` 또는 Local PV를 사용하는 Pod는 다른 Node로 이동하지 못하거나 동일
  데이터를 보지 못할 수 있습니다.
- `emptyDir` 데이터는 Pod가 삭제되면 사라집니다.
- DaemonSet Pod는 `--ignore-daemonsets`로 eviction되지 않지만 Node 재시작과
  kubelet 변경의 영향을 받을 수 있습니다.
- PDB의 `ALLOWED DISRUPTIONS`가 0이면 정상 drain이 멈춥니다. 운영 승인 없이
  `--disable-eviction` 또는 강제 삭제를 사용하지 않습니다.
- Worker 여유 자원이 부족하면 대체 Pod가 Pending 상태가 되어 서비스 용량이
  감소하거나 단절될 수 있습니다.

### 14.4 보안 설정 보존 영향

`kubeadm upgrade`는 정적 Pod manifest와 kubelet 설정을 다시 생성할 수 있습니다.
기존 가이드에 따라 직접 추가한 API Server 옵션, Audit Log Mount 또는
`/var/lib/kubelet/config.yaml` 설정이 덮어써질 수 있습니다.

따라서 다음 중 하나로 보안 설정을 보존합니다.

- v1.30.14 패치를 먼저 수행하고 이후 보안 설정을 적용
- 이미 적용한 설정은 kubeadm patch 또는 cluster-wide KubeletConfiguration으로
  관리하고 패치 후 재검증
- 작업 전후 manifest와 kubelet 설정의 diff를 확인하고 승인된 항목만 재적용

## 15. 운영 서비스별 최종 판정 기준

| 서비스 유형 | 낮은 영향 조건 | 높은 영향 조건 |
| :--- | :--- | :--- |
| Envoy·Ingress | replica 2 이상, 노드 분산, readiness 정상 | 단일 replica, 동일 노드 집중 |
| CMP Web·API | replica 2 이상, 무중단 종료와 readiness 정상 | 단일 replica, 긴 기동 시간 |
| StatefulSet | 복제·quorum 정상, PDB와 스토리지 이동 검증 | 단일 replica, Local PV |
| CoreDNS | replica 2 이상, 노드 분산 | 단일 replica 또는 같은 Node 배치 |
| 모니터링·로그 | buffer·재전송 가능, 다중 replica | 단일 collector, 로컬 buffer |
| 배치·Job | 작업 시간 외 또는 중지 가능 | 장기 실행 Job, 중복 실행 위험 |
| 외부 MariaDB 연동 | 재연결과 이중화 검증 | 재연결 미지원, 단일 connection |

## 16. 작업 전 필수 조회

다음 스크립트는 설정을 변경하지 않고 영향 판정 자료만 수집합니다.

```bash
chmod +x scripts/collect_k8s_1.30.14_patch_impact.sh
./scripts/collect_k8s_1.30.14_patch_impact.sh
```

최소한 다음 결과를 서비스 담당자와 확인합니다.

```bash
kubectl get nodes -o wide
kubectl get deployment,statefulset,daemonset -A -o wide
kubectl get poddisruptionbudget -A -o wide
kubectl get pods -A -o wide
kubectl get pv,pvc -A -o wide
kubectl get ingress,gateway,httproute -A
kubectl get events -A --sort-by='.metadata.creationTimestamp'
```

다음 항목이 하나라도 있으면 18시 이후 작업 대상으로 판정합니다.

- 단일 replica 업무 서비스
- `ALLOWED DISRUPTIONS`가 0인 PDB
- HostPath 또는 Local PV 사용
- Envoy Gateway 또는 CoreDNS의 단일 replica·동일 Node 집중
- Worker 여유 자원 부족
- RBAC, ServiceAccount Token 또는 Admission 정책 변경
- API Server·etcd TLS, Secret Encryption at Rest 또는 인증서 작업
- kubelet `protectKernelDefaults`, 인증·인가 또는 TLS 설정 변경

## 17. 단계별 중단 조건

각 Control Plane 또는 Worker 한 대의 작업 후 다음 조건을 모두 충족해야 다음 노드로
이동합니다.

```bash
kubectl get --raw='/readyz?verbose'
kubectl get nodes
kubectl get pods -A -o wide
kubectl get poddisruptionbudget -A
kubectl get events -A --sort-by='.metadata.creationTimestamp' | tail -n 50
```

- 모든 기존 Node가 `Ready`
- Control Plane 정적 Pod가 `Running`
- etcd endpoint health 정상
- CoreDNS, Envoy 및 CMP 핵심 서비스의 Ready replica 정상
- 신규 `CrashLoopBackOff`, `ImagePullBackOff`, `Pending` Pod 없음
- `Unauthorized`, `Forbidden`, TLS 및 Secret 복호화 오류 없음
- 사용자 대표 기능과 MariaDB 연결 정상

조건을 충족하지 못하면 다음 노드 작업을 중지하고 현재 노드 설정을 롤백합니다.
