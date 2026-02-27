# Jenkins 파이프라인 폐쇄망 클러스터 마이그레이션 가이드

## 개요

| 항목 | 구망 | 신망 (폐쇄망 클러스터) |
| :--- | :--- | :--- |
| Jenkins | `210.217.178.150:8090` | K8s StatefulSet (NodePort 30000) |
| GitLab | `gitlab.strato.co.kr` | `gitlab.internal.net` |
| Harbor | `harbor-product.strato.co.kr:8443` | `1.1.1.213:30002` |
| 배포 타겟 IP | `210.217.178.150` | `1.1.1.50` (프론트엔드 등) |
| 대상 파이프라인 | 전체 497개 | goe 28개 (변환 완료) |

## 작업 흐름

```
[1] 이미지 반입        [2] Jenkins 배포       [3] DinD 파드 템플릿 설정
Harbor에 이미지 Push → Helm install         → JCasC ConfigMap 수정

[4] Credential 등록   [5] 파이프라인 Import   [6] 사후 검증
신규 Jenkins에 등록  → curl로 주입          → 빌드 상태 확인
```

---

## 1. 변환 결과 요약

- **출력 위치**: `final/manifests/transformed_pipelines/goe/` (28개)
- **리포트**: `final/reports/transformation_summary.txt`

### 적용된 변환 내용

| 항목 | 구망 | 신망 |
| :--- | :--- | :--- |
| GitLab URL | `gitlab.strato.co.kr` | `gitlab.internal.net` |
| Harbor URL | `harbor-product.strato.co.kr:8443` | `1.1.1.213:30002` |
| 배포 타겟 IP | `210.217.178.150` | `1.1.1.50` |
| GitLab Credential ID | `10-product-gitlab-Credential` 등 | `gitlab.internal.net` |
| Harbor Credential ID | `0-harbor-product-Credential` | `0-harbor-product-Credential` |
| Agent | `agent any` | `agent { label 'jenkins-agent' }` |

---

## 2. 사전 준비 — Credential 등록

파이프라인 Import 전 신규 Jenkins에 아래 Credential을 **ID 이름 그대로** 등록해야 함.

| ID | 타입 | 내용 |
| :--- | :--- | :--- |
| `gitlab.internal.net` | Username/Password | 신망 GitLab 계정 |
| `0-harbor-product-Credential` | Username/Password | Harbor admin 계정 |
| `iac-gitlab-pat` | Secret Text | GitLab Personal Access Token (IaC용) |
| `IMP_API_TOKEN` | Secret Text | IMP API 토큰 |

> Jenkins UI: `Dashboard > Manage Jenkins > Credentials > System > Global credentials`

---

## 3. Docker 빌드 환경 구성

goe 28개 중 Docker 빌드(`docker.build()` / `withDockerRegistry()`) 사용 파이프라인이 있음.
아래 3가지 방식 중 환경에 맞게 선택.

| 방식 | 파이프라인 수정 | 특징 |
| :--- | :--- | :--- |
| **A. Docker 소켓 마운트** | 없음 | 노드에 Docker 설치 필요, 가장 빠름 |
| **B. DinD 사이드카** | 없음 (권장) | Docker 설치 불필요, 격리 수준 양호 |
| **C. Kaniko** | 필요 | Docker 데몬 불필요, 보안 수준 최고 |

---

### 방식 B: DinD 사이드카 (권장)

#### Step 1. 이미지 반입

`final/images/` 참조 경로의 이미지를 폐쇄망 Harbor에 Push:

```bash
# 이미지 import (k8s 네임스페이스)
ctr -n k8s.io images import docker-dind.tar.gz
ctr -n k8s.io images import docker-cli.tar.gz
ctr -n k8s.io images import jenkins-agent.tar.gz

# 태그 변경
ctr -n k8s.io images tag \
  docker.io/library/docker:27-dind 1.1.1.213:30002/library/docker:27-dind
ctr -n k8s.io images tag \
  docker.io/library/docker:27-cli 1.1.1.213:30002/library/docker:27-cli
ctr -n k8s.io images tag \
  docker.io/jenkins/inbound-agent:latest 1.1.1.213:30002/library/inbound-agent:latest

# Harbor Push
ctr -n k8s.io images push --plain-http --user admin:<PW> \
  1.1.1.213:30002/library/docker:27-dind
ctr -n k8s.io images push --plain-http --user admin:<PW> \
  1.1.1.213:30002/library/docker:27-cli
ctr -n k8s.io images push --plain-http --user admin:<PW> \
  1.1.1.213:30002/library/inbound-agent:latest
```

#### Step 2. JCasC ConfigMap 수정

Jenkins는 `k8s-sidecar`가 JCasC ConfigMap을 감시하다 변경 감지 시 자동 리로드함.
Jenkins 재시작 없이 반영됨.

**ConfigMap 이름 확인:**

```bash
kubectl get configmap -n jenkins | grep jcasc
```

**ConfigMap 수정:**

```bash
kubectl edit configmap <jcasc-configmap-name> -n jenkins
```

에디터가 열리면 `data` 섹션에 아래 내용 추가:

```yaml
jenkins:
  clouds:
    - kubernetes:
        name: "kubernetes"
        templates:
          - name: "jenkins-agent"
            label: "jenkins-agent"
            containers:
              - name: "jnlp"
                image: "1.1.1.213:30002/library/inbound-agent:latest"
                env:
                  - key: "DOCKER_HOST"
                    value: "tcp://localhost:2375"
              - name: "dind"
                image: "1.1.1.213:30002/library/docker:27-dind"
                privileged: true
                env:
                  - key: "DOCKER_TLS_CERTDIR"
                    value: ""
            imagePullSecrets:
              - name: "regcred"
```

**반영 확인:**

```bash
# k8s-sidecar 로그에서 reload 확인
kubectl logs -n jenkins <jenkins-pod> -c config-reload -f

# Jenkins UI에서 확인
# http://<NODE_IP>:30000/manage/cloud/
```

> `privileged: true` 필요. 클러스터 PSA(Pod Security Admission) 정책 확인 필요.

---

### 방식 C: Kaniko (DinD 불가 시)

`privileged: true` 제한으로 DinD 사용이 불가한 경우 적용. 파이프라인 코드 수정 필요.

**변환 전:**

```groovy
agent { label 'jenkins-agent' }

stage('Docker Build & Push') {
    steps {
        script {
            def image = docker.build(CONTAINER_IMAGE_NAME, BUILD_LOCATION)
            withDockerRegistry(url: 'https://1.1.1.213:30002/',
                               credentialsId: '0-harbor-product-Credential') {
                image.push()
            }
        }
    }
}
```

**변환 후:**

```groovy
agent {
    kubernetes {
        yaml """
        spec:
          containers:
          - name: kaniko
            image: 1.1.1.213:30002/library/kaniko:debug
            command: ['sleep', '9999']
          - name: jnlp
            image: 1.1.1.213:30002/library/inbound-agent:latest
        """
    }
}

stage('Docker Build & Push') {
    steps {
        container('kaniko') {
            sh """
            /kaniko/executor \\
              --context=${BUILD_LOCATION} \\
              --dockerfile=${BUILD_LOCATION}/Dockerfile \\
              --destination=${CONTAINER_IMAGE_NAME} \\
              --insecure \\
              --skip-tls-verify
            """
        }
    }
}
```

---

## 4. Jenkins 배포

```bash
cd /path/to/jenkins-2.528.3

# REGISTRY_URL=1.1.1.213:30002 확인 후 실행
chmod +x deploy-jenkins.sh
./deploy-jenkins.sh
```

### 초기 계정 확인

```bash
kubectl get secret -n jenkins jenkins \
  -o jsonpath="{.data.jenkins-admin-password}" | base64 -d && echo
```

---

## 5. 파이프라인 Import (curl)

```bash
JENKINS_URL="http://<NODE_IP>:30000"
USER="admin"
PASS="<비밀번호>"
SOURCE_DIR="final/manifests/transformed_pipelines/goe"

# CSRF Crumb 획득
CRUMB=$(curl -s -u "$USER:$PASS" \
  "$JENKINS_URL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")

# 폴더 → 파일 순서 정렬 후 Import
find "$SOURCE_DIR" -name "*.xml" \
  | awk '{ print length, $0 }' | sort -n | cut -d" " -f2- \
  | while read -r XML_FILE; do

    RELATIVE="${XML_FILE#$SOURCE_DIR/}"
    JOB="${RELATIVE%.xml}"
    DIR=$(dirname "$JOB")
    NAME=$(basename "$JOB")

    if [ "$DIR" = "." ]; then
        CREATE_URL="$JENKINS_URL/createItem?name=$NAME"
        CHECK_URL="$JENKINS_URL/job/$NAME/config.xml"
    else
        PATH_CONV=$(echo "$DIR" | sed 's/\//\/job\//g')
        CREATE_URL="$JENKINS_URL/job/$PATH_CONV/createItem?name=$NAME"
        CHECK_URL="$JENKINS_URL/job/$PATH_CONV/job/$NAME/config.xml"
    fi

    CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$USER:$PASS" "$CHECK_URL")
    if [ "$CODE" -eq 200 ]; then
        curl -s -X POST "$CHECK_URL" -u "$USER:$PASS" \
          -H "$CRUMB" -H "Content-Type: application/xml" \
          --data-binary "@$XML_FILE" -o /dev/null
        echo "Updated : $JOB"
    else
        curl -s -X POST "$CREATE_URL" -u "$USER:$PASS" \
          -H "$CRUMB" -H "Content-Type: application/xml" \
          --data-binary "@$XML_FILE" -o /dev/null
        echo "Created : $JOB"
    fi
done
```

### Filesystem 직접 주입 (비상용)

curl이 실패할 경우:

```bash
POD=$(kubectl get pods -n jenkins -l app.kubernetes.io/name=jenkins \
  -o jsonpath='{.items[0].metadata.name}')

JOB_NAME="my-job"
kubectl exec -n jenkins $POD -- mkdir -p /var/jenkins_home/jobs/$JOB_NAME
kubectl cp ./${JOB_NAME}.xml jenkins/$POD:/var/jenkins_home/jobs/$JOB_NAME/config.xml

# 설정 리로드
curl -X POST -u admin:<PW> "http://<NODE_IP>:30000/reload"
```

---

## 6. 사후 검증 체크리스트

- [ ] `jenkins-agent` Pod 동적 생성 확인 (`kubectl get pods -n jenkins -w`)
- [ ] GitLab Checkout 성공 (`gitlab.internal.net` 연결)
- [ ] Harbor Push 성공 (`1.1.1.213:30002` 연결)
- [ ] Docker 빌드 파이프라인 샘플 실행 (DinD 동작 확인)
- [ ] Multibranch Pipeline Scan 결과 확인 (Scan Failed = Credential 또는 URL 문제)

### Import 후 일괄 수정이 필요한 경우

```bash
POD=$(kubectl get pods -n jenkins -l app.kubernetes.io/name=jenkins \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n jenkins $POD -- bash -c \
  "find /var/jenkins_home/jobs -name 'config.xml' \
   -exec sed -i 's|old-value|new-value|g' {} +"

curl -X POST -u admin:<PW> "http://<NODE_IP>:30000/reload"
```
