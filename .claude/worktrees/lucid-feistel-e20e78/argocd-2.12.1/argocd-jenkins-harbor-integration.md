# ArgoCD — Jenkins · Harbor 연동 가이드

본 문서는 ArgoCD 2.12.1을 Jenkins CI/CD 및 Harbor 레지스트리와 연동하는 방법을 설명합니다.
폐쇄망 환경을 전제로 하며, 전체 흐름은 **GitOps 패턴**을 따릅니다.

---

## 전체 CI/CD 흐름

```text
[개발자]
   │ git push
   ▼
[GitLab] ──webhook──▶ [Jenkins]
                          │
                    1. 소스 빌드 (Gradle)
                    2. Kaniko → 이미지 빌드 & Harbor Push
                    3. GitOps 레포 manifest 이미지 태그 업데이트
                    4. ArgoCD sync 트리거
                          │
                          ▼
                      [ArgoCD] ──pulls manifests──▶ [GitLab: GitOps Repo]
                          │
                    K8s에 배포 (Harbor에서 이미지 Pull)
                          │
                          ▼
                      [Kubernetes]
```

---

## 1. Harbor 연동 — ArgoCD Repository 등록

ArgoCD가 Helm 차트 또는 K8s 매니페스트를 보관하는 GitLab 레포지토리를 참조하도록 등록합니다.

### 1-1. GitLab 레포지토리 등록 (매니페스트 / Helm 차트)

ArgoCD가 GitLab에 접속할 수 있도록 Credential을 먼저 등록합니다.

```bash
# ArgoCD CLI 설치 (air-gapped 환경 — argocd 바이너리는 로컬에서 복사)
# kubectl cp 또는 pod exec 방식으로 argocd CLI 활용

# ArgoCD 서버 로그인
argocd login <NODE_IP>:30001 \
  --username admin \
  --password <ARGOCD_ADMIN_PASSWORD> \
  --insecure

# GitLab 레포지토리 등록 (HTTP 접속)
argocd repo add http://<GITLAB_IP>:<GITLAB_PORT>/<GROUP>/<GITOPS_REPO>.git \
  --username <GITLAB_USER> \
  --password <GITLAB_TOKEN> \
  --insecure-skip-server-verification
```

### 1-2. Harbor OCI 레지스트리 등록 (Helm 차트를 OCI로 관리할 경우)

Harbor에 Helm 차트를 OCI 형식으로 저장한 경우 아래와 같이 등록합니다.

```bash
argocd repo add oci://<NODE_IP>:30002/<HARBOR_PROJECT> \
  --type helm \
  --name harbor-oci \
  --username admin \
  --password <HARBOR_PASSWORD> \
  --insecure-skip-server-verification
```

### 1-3. Secret으로 직접 등록 (argocd CLI 없이)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitops-repo-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: http://<GITLAB_IP>:<GITLAB_PORT>/<GROUP>/<GITOPS_REPO>.git
  username: <GITLAB_USER>
  password: <GITLAB_TOKEN>
  insecure: "true"
```

```bash
kubectl apply -f gitops-repo-secret.yaml
```

### 1-4. 웹 UI(GUI)로 등록

1. ArgoCD 웹 접속 (`http://<NODE_IP>:30001`) 및 로그인
2. 좌측 메뉴 **Settings** > **Repositories** 클릭
3. 상단 **+ CONNECT REPO** 버튼 클릭
4. 설정 입력:
    - **Choose connection method**: `VIA HTTPS`
    - **Type**: `git`
    - **Repository URL**: `http://<GITLAB_IP>:<PORT>/.../<GITOPS_REPO>.git`
    - **Username / Password**: GitLab 사용자명 및 Access Token 입력
    - **TLS Skip Server Verification**: 체크 (사설 인증서 사용 시)
5. **CONNECT** 클릭하여 `Successful` 상태 확인

---

## 2. ArgoCD Application 생성

GitLab GitOps 레포의 매니페스트(또는 Helm 차트)를 바라보는 Application을 생성합니다.

### 2-1. CLI로 생성

```bash
argocd app create my-app \
  --repo http://<GITLAB_IP>:<GITLAB_PORT>/<GROUP>/<GITOPS_REPO>.git \
  --path k8s/overlays/prod \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace my-app \
  --sync-policy automated \
  --self-heal \
  --auto-prune
```

### 2-2. YAML로 생성

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://<GITLAB_IP>:<GITLAB_PORT>/<GROUP>/<GITOPS_REPO>.git
    targetRevision: main
    path: k8s/overlays/prod          # 매니페스트 경로
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```bash
kubectl apply -f argocd-app.yaml
```

### 2-3. 웹 UI(GUI)로 생성

1. ArgoCD 메인 화면에서 **+ NEW APP** 클릭
2. **General** 설정:
    - **Application Name**: `my-app`
    - **Project Name**: `default`
    - **Sync Policy**: `Automatic` (권장) 또는 `Manual`
3. **Source** 설정:
    - **Repository URL**: 위에서 등록한 GitLab 레포지토리 선택
    - **Revision**: `main` (또는 배포 브랜치)
    - **Path**: `k8s/overlays/prod` (매니페스트 경로)
4. **Destination** 설정:
    - **Cluster URL**: `https://kubernetes.default.svc` (내부 배포 시)
    - **Namespace**: `my-app`
5. 상단 **CREATE** 클릭하여 배포 상태 확인

---

## 3. Jenkins 연동 — 파이프라인에서 ArgoCD Sync 트리거

### 3-1. ArgoCD API 토큰 발급

```bash
# ArgoCD 로그인 후 토큰 생성
argocd account generate-token --account admin
# 출력된 토큰 값을 복사
```

### 3-2. Jenkins Credential 등록

Jenkins 웹 UI에서 등록합니다.

```text
Jenkins 관리 > Credentials > (global) > Add Credentials
  Kind      : Secret text
  Secret    : <위에서 발급한 ArgoCD 토큰>
  ID        : argocd-token
  Description: ArgoCD API Token
```

### 3-3. Jenkinsfile — ArgoCD sync 단계 추가

기존 `Jenkinsfile.template`의 `stage('2. Kaniko Build & Push')` 이후에 아래 stage를 추가합니다.

```groovy
stage('3. Update GitOps Manifest') {
    steps {
        container('shell') {
            script {
                // GitOps 레포 클론 후 이미지 태그 업데이트
                withCredentials([usernamePassword(
                    credentialsId: '<GITLAB_IP>:<PORT>',
                    passwordVariable: 'GIT_PASS',
                    usernameVariable: 'GIT_USER'
                )]) {
                    def gitopsRepo = "http://<GITLAB_IP>:<PORT>/<GROUP>/<GITOPS_REPO>.git"
                    def authUrl = gitopsRepo.replaceFirst('://', "://${GIT_USER}:${GIT_PASS}@")
                    def newImage = "${env.REGISTRY_URL}/${env.CONTAINER_IMAGE_NAME}"

                    sh """
                        git clone ${authUrl} gitops-repo
                        cd gitops-repo

                        # deployment.yaml 의 이미지 태그 업데이트
                        sed -i 's|image: ${env.REGISTRY_URL}/.*|image: ${newImage}|g' \\
                            k8s/overlays/prod/deployment.yaml

                        git config user.email "jenkins@ci.internal"
                        git config user.name "Jenkins"
                        git add -A
                        git commit -m "ci: update image to ${newImage}"
                        git push origin main
                    """
                }
            }
        }
    }
}

stage('4. ArgoCD Sync') {
    steps {
        container('shell') {
            script {
                withCredentials([string(
                    credentialsId: 'argocd-token',
                    variable: 'ARGOCD_TOKEN'
                )]) {
                    // ArgoCD REST API로 sync 트리거
                    sh """
                        curl -sk -X POST \\
                          -H "Authorization: Bearer \${ARGOCD_TOKEN}" \\
                          -H "Content-Type: application/json" \\
                          -d '{"prune": true}' \\
                          https://<NODE_IP>:30001/api/v1/applications/my-app/sync
                    """
                }
            }
        }
    }
}
```

> **참고:** ArgoCD `syncPolicy.automated` 설정 시 GitOps 레포 변경 감지 후 자동 sync됩니다.
> `stage('4. ArgoCD Sync')`는 즉시 sync가 필요한 경우에만 추가합니다.

---

## 4. Harbor 이미지 — ArgoCD 배포 Pod에서 Pull 설정

배포 대상 네임스페이스에 Harbor 접속용 imagePullSecret을 생성합니다.

```bash
kubectl create secret docker-registry harbor-pull-secret \
  --docker-server=<NODE_IP>:30002 \
  --docker-username=admin \
  --docker-password=<HARBOR_PASSWORD> \
  -n my-app
```

Deployment 매니페스트에 참조 추가:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: harbor-pull-secret
      containers:
        - name: my-app
          image: <NODE_IP>:30002/<HARBOR_PROJECT>/my-app:1.0.0
```

---

## 5. ArgoCD API 토큰 계정 최소 권한 설정 (선택)

Jenkins 전용 계정을 만들어 sync 권한만 부여하는 것을 권장합니다.

### 5-1. ArgoCD ConfigMap 수정

```bash
kubectl edit configmap argocd-cm -n argocd
```

```yaml
data:
  accounts.jenkins: apiKey    # jenkins 계정 추가, apiKey 권한
```

### 5-2. RBAC 정책 추가

```bash
kubectl edit configmap argocd-rbac-cm -n argocd
```

```yaml
data:
  policy.csv: |
    p, role:ci-sync, applications, sync, */*, allow
    p, role:ci-sync, applications, get, */*, allow
    g, jenkins, role:ci-sync
  policy.default: role:readonly
```

### 5-3. jenkins 계정 토큰 발급

```bash
argocd account generate-token --account jenkins
```

---

## 6. 연동 확인

```bash
# ArgoCD Application 상태 확인
argocd app get my-app

# 동기화 히스토리 확인
argocd app history my-app

# Sync 수동 실행
argocd app sync my-app
```

| 확인 항목 | 정상 상태 |
| :--- | :--- |
| ArgoCD App Health | `Healthy` |
| ArgoCD App Sync | `Synced` |
| Pod 이미지 | Harbor 주소(`<NODE_IP>:30002/...`) |
| Jenkins 빌드 | `SUCCESS` (stage 4까지) |
