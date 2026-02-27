# 폐쇄망 반입 파일 목록

Jenkins 파이프라인 마이그레이션을 위한 최종 반입 파일 목록.

---

## 1. Jenkins 설치 파일

| 경로 | 내용 |
| :--- | :--- |
| `origin/jenkins-2.528.3/images/` | Jenkins 컨테이너 이미지 tar (cmp-jenkins-full, k8s-sidecar) |
| `origin/jenkins-2.528.3/jenkins/` | Helm 차트 |
| `origin/jenkins-2.528.3/deploy-jenkins.sh` | 설치 자동화 스크립트 |
| `origin/jenkins-2.528.3/pv-volume.yaml` | PersistentVolume 매니페스트 |

## 2. DinD / Agent 이미지

| 파일 | 이미지 | 용도 |
| :--- | :--- | :--- |
| `gemini/images/docker-dind.tar.gz` | `docker:27-dind` | DinD 사이드카 |
| `gemini/images/docker-cli.tar.gz` | `docker:27-cli` | Docker 클라이언트 |
| `gemini/images/jenkins-agent.tar.gz` | `jenkins/inbound-agent:latest` | K8s 에이전트 |

## 3. 변환된 파이프라인 (goe)

| 경로 | 내용 |
| :--- | :--- |
| `final/manifests/transformed_pipelines/goe/` | 변환 완료 XML 28개 |
| `final/reports/transformation_summary.txt` | Credential 목록 및 변환 결과 |

### 적용된 변환 내용

| 항목 | 구망 | 신망 |
| :--- | :--- | :--- |
| GitLab URL | `gitlab.strato.co.kr` | `gitlab.internal.net` |
| Harbor URL | `harbor-product.strato.co.kr:8443` | `1.1.1.213:30002` |
| 배포 타겟 IP | `210.217.178.150` | `1.1.1.50` |
| GitLab Credential ID | `10-product-gitlab-Credential` 등 | `gitlab.internal.net` |
| Harbor Credential ID | `0-harbor-product-Credential` | `0-harbor-product-Credential` |
| Agent | `agent any` | `agent { label 'jenkins-agent' }` |

## 4. 가이드 및 스크립트

| 경로 | 내용 |
| :--- | :--- |
| `final/docs/JENKINS_CLUSTER_MIGRATION_GUIDE.md` | 마이그레이션 전체 가이드 |
| `final/scripts/transform_all.py` | 파이프라인 재변환 스크립트 (Python, 전체 497개) |
| `final/scripts/transform-jenkins-pipelines.sh` | 파이프라인 재변환 스크립트 (Bash, 필터 적용) |
| `final/scripts/cluster-status.sh` | 클러스터 상태 확인 스크립트 |

---

## 반입 후 작업 순서

1. DinD/Agent 이미지 → Harbor Push (`docker-dind`, `docker-cli`, `inbound-agent`)
2. Jenkins Helm 배포 (`deploy-jenkins.sh`, `REGISTRY_URL=1.1.1.213:30002` 확인)
3. JCasC ConfigMap에 `jenkins-agent` 파드 템플릿 추가 (DinD + `privileged: true`)
4. Credential 등록: `gitlab.internal.net`, `0-harbor-product-Credential`
5. 파이프라인 XML Import (curl)
6. 샘플 빌드로 동작 검증

자세한 내용은 `final/docs/JENKINS_CLUSTER_MIGRATION_GUIDE.md` 참조.
