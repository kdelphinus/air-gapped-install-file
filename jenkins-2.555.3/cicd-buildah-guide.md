# Jenkins Buildah CI/CD 구성 가이드

이 문서는 Jenkins, GitLab Omnibus, Harbor, Argo CD를 사용하여 폐쇄망 CI/CD
흐름을 구성하는 절차를 정의합니다. Jenkins는 Kubernetes agent Pod에서
Buildah rootless 방식으로 애플리케이션 이미지를 빌드하고 Harbor로 push합니다.
Argo CD는 GitLab 매니페스트 저장소를 감시하여 배포를 수행합니다.

## 1. 구성 개요

| 구성 요소 | 역할 | 기준 버전 |
| --- | --- | --- |
| Jenkins | CI 파이프라인 실행 및 이미지 빌드 | 2.555.3 |
| GitLab Omnibus | 소스 저장소, 매니페스트 저장소, Webhook | 18.11.4 |
| Harbor | 컨테이너 이미지 레지스트리 | 2.10.3 |
| Argo CD | GitOps 배포 | 3.4.3 |
| Buildah agent | Jenkins Kubernetes agent 이미지 빌드 런타임 | rocky9, JDK 17/21 |

Kaniko와 Docker-in-Docker는 기본 구성에서 사용하지 않습니다. Kaniko는 유지보수
종료 리스크가 있고, Docker-in-Docker는 privileged Pod가 필요하므로 기본 운영
경로에서 제외합니다.

## 2. 온라인 준비

인터넷 연결이 가능한 준비 서버에서 Jenkins 기본 에셋과 Buildah base image를
수집합니다.

```bash
cd jenkins-2.555.3
sudo ./scripts/download_assets_offline.sh
```

Buildah agent 이미지를 빌드하고 tar 파일로 저장합니다. 기본 실행은 Rocky 9 기반 JDK 21 agent를 `jenkins-buildah-agent:jdk21-rocky9` 태그로 생성합니다.

```bash
cd jenkins-build/buildah-agent
chmod +x build-buildah-agent.sh
./build-buildah-agent.sh
```

기본 출력 파일은 다음과 같습니다.

```text
jenkins-2.555.3/images/jenkins-buildah-agent_jdk21_rocky9.tar
```

서비스별로 JDK 버전이 다르면 `--jdk` 옵션으로 버전별 agent 이미지를 생성합니다.

```bash
./build-buildah-agent.sh --jdk 21
./build-buildah-agent.sh --jdk 17
```

실제 빌드 전에 생성될 이미지명과 tar 경로만 확인하려면 `--dry-run`을 함께 사용합니다.

```bash
./build-buildah-agent.sh --jdk 21 --dry-run
./build-buildah-agent.sh --jdk 17 --dry-run
```

기본 base image는 `rockylinux:9`입니다. 준비 서버에서 필요한 Rocky repository를 사용할 수 있으면 JDK 17과 JDK 21 agent를 같은 방식으로 생성할 수 있습니다. 운영망에서 특정 사내 repository만 사용해야 하는 경우에는 `jenkins-build/buildah-agent/repos/` 아래에 사내 `.repo` 파일을 추가한 뒤 빌드합니다.

```bash
cp internal-rocky.repo jenkins-build/buildah-agent/repos/
./build-buildah-agent.sh --jdk 17
```

버전별 빌드의 이미지 태그와 tar 파일명은 다음 규칙을 사용합니다.

```text
jenkins-buildah-agent:jdk21-rocky9
jenkins-buildah-agent:jdk17-rocky9
jenkins-2.555.3/images/jenkins-buildah-agent_jdk21_rocky9.tar
jenkins-2.555.3/images/jenkins-buildah-agent_jdk17_rocky9.tar
```

준비가 끝나면 `jenkins-2.555.3` 전체 디렉터리를 폐쇄망으로 반입합니다.

## 3. Harbor 업로드

폐쇄망에서 Harbor가 준비된 후 Jenkins 이미지와 Buildah agent 이미지를 업로드합니다.

```bash
cd jenkins-2.555.3
sudo ./scripts/upload_images_to_harbor_v3-lite.sh
```

업로드 모드는 `2) Harbor 레지스트리로 업로드`를 선택합니다. Harbor 프로젝트는
예시 기준으로 `devops`를 사용합니다.

업로드 후 다음 이미지가 존재해야 합니다. JDK 버전별 agent를 생성한 경우에는 `jdk17-rocky9`, `jdk21-rocky9`처럼 서비스 빌드 JDK에 맞는 태그도 함께 확인합니다.

```text
<HARBOR_REGISTRY>/devops/jenkins:2.555.3-jdk21
<HARBOR_REGISTRY>/devops/inbound-agent:3355.v388858a_47b_33-22
<HARBOR_REGISTRY>/devops/k8s-sidecar:2.7.3
<HARBOR_REGISTRY>/devops/jenkins-buildah-agent:jdk21-rocky9
<HARBOR_REGISTRY>/devops/jenkins-buildah-agent:jdk17-rocky9
```

## 4. Secret 생성

Jenkins namespace에 Harbor imagePullSecret을 생성합니다. Harbor project가 public이고
Jenkins agent 이미지도 인증 없이 pull 가능한 경우에는 이 Secret을 생략할 수
있습니다.

```bash
kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jenkins create secret docker-registry harbor-regcred \
  --docker-server=<HARBOR_REGISTRY> \
  --docker-username=<HARBOR_USER> \
  --docker-password=<HARBOR_PASSWORD> \
  --dry-run=client -o yaml | kubectl apply -f -
```

Jenkins에는 다음 Credential을 생성합니다.

| Credential ID | 종류 | 용도 |
| --- | --- | --- |
| `harbor-jenkins-credential` | Username with password | Buildah `login/push` |
| `gitlab-jenkins-token` | Username with password | GitLab checkout 및 manifest push |

Argo CD에는 GitLab 매니페스트 저장소 접근용 repository credential을 생성합니다.

```bash
kubectl -n argocd create secret generic argocd-repo-credential \
  --from-literal=type=git \
  --from-literal=url=http://gitlab.devops.internal/root/sample-app-manifests.git \
  --from-literal=username=<GITLAB_USER> \
  --from-literal=password=<GITLAB_TOKEN> \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd label secret argocd-repo-credential \
  argocd.argoproj.io/secret-type=repository --overwrite
```

## 5. Jenkins 적용

### 5.1. Harbor 주소 및 DNS 기준

CI/CD 파이프라인에서 사용하는 Harbor 주소는 Jenkins가 이미지를 push할 때와
Kubernetes 노드가 이미지를 pull할 때 모두 접근 가능한 동일한 주소로 정합니다.
이미지 이름에는 `http://` 또는 `https://` 프로토콜을 포함하지 않습니다.

```text
좋은 예: harbor.example.local/devops/sample-app:1.0.0
좋은 예: harbor.example.local:30080/devops/sample-app:1.0.0
나쁜 예: http://harbor.example.local/devops/sample-app:1.0.0
```

DNS에 Harbor 도메인이 등록되어 있으면 별도 hostAlias가 필요 없습니다. DNS에
등록되어 있지 않은 PoC 또는 테스트 환경에서는 Jenkins buildah agent Pod가 Harbor
주소를 해석할 수 있도록 `values-cicd-buildah.local.yaml`에 `hostAliases`를
추가합니다.

```yaml
agent:
  podTemplates:
    buildah: |
      - name: buildah
        label: buildah
        serviceAccount: jenkins-agent
        yaml: |
          spec:
            hostAliases:
              - ip: <HARBOR_GATEWAY_OR_LB_IP>
                hostnames:
                  - harbor.example.local
```

이 설정은 Jenkins가 빌드 시 생성하는 `buildah-xxxxx` agent Pod에만 적용됩니다.
실제 애플리케이션 Pod가 이미지를 pull하려면 모든 Kubernetes worker node도 같은
Harbor 주소를 해석할 수 있어야 합니다. 운영 환경에서는 사내 DNS 등록을 우선
사용하고, DNS가 없을 때만 노드의 `/etc/hosts` 또는 containerd registry 설정을
환경 표준에 맞게 적용합니다.

Harbor를 HTTP로 노출하고 인증서를 사용하지 않는 경우에는 Buildah 명령에
`--tls-verify=false`를 사용하고, Kubernetes 노드의 containerd에도 insecure
registry 설정이 필요합니다. Harbor의 `externalURL`은 Jenkinsfile과 매니페스트에
사용하는 실제 접근 주소와 동일해야 합니다.

```text
Harbor externalURL 예: http://harbor.example.local:30080
Jenkins image 예: harbor.example.local:30080/devops/sample-app:<TAG>
```

### 5.2. Buildah agent override 적용

`values-cicd-buildah.yaml`의 Harbor placeholder를 폐쇄망 주소로 치환합니다. JDK 21이 필요한 서비스라면 agent image tag를 `jenkins-buildah-agent:jdk21-rocky9`처럼 서비스 빌드 버전에 맞게 지정합니다.

여러 JDK 버전을 동시에 운영하려면 podTemplate을 label별로 나누고 Jenkinsfile에서 서비스에 맞는 label을 선택합니다.

```yaml
agent:
  podTemplates:
    buildah-jdk17: |
      - name: buildah-jdk17
        label: buildah-jdk17
        containers:
          - name: buildah
            image: harbor.example.local:30080/devops/jenkins-buildah-agent:jdk17-rocky9
    buildah-jdk21: |
      - name: buildah-jdk21
        label: buildah-jdk21
        containers:
          - name: buildah
            image: harbor.example.local:30080/devops/jenkins-buildah-agent:jdk21-rocky9
```

```groovy
agent {
  label 'buildah-jdk21'
}
```

```bash
cp values-cicd-buildah.yaml values-cicd-buildah.local.yaml
sed -i \
  -e 's|<HARBOR_REGISTRY>|harbor.example.local:30080|g' \
  -e 's|<HARBOR_PROJECT>|devops|g' \
  values-cicd-buildah.local.yaml
```

Jenkins 설치 또는 업그레이드 시 Buildah agent override를 함께 적용합니다.

```bash
helm upgrade --install jenkins ./charts/jenkins \
  -n jenkins --create-namespace \
  -f values.yaml \
  -f values-cicd-buildah.local.yaml
```

기존 `scripts/install.sh`를 사용한 경우에는 설치 완료 후 위 Helm 명령을 한 번 더
실행하여 Buildah agent override를 추가 적용합니다.

## 6. GitLab Webhook 설정

GitLab 애플리케이션 소스 저장소에서 Jenkins Webhook을 추가합니다.

```text
http://jenkins.test.com/gitlab/build_now
```

Jenkins Job은 `examples/Jenkinsfile.buildah`를 기준으로 생성합니다. 실제 저장소에
맞게 다음 값을 수정합니다.

```groovy
APP_NAME = 'sample-app'
HARBOR_REGISTRY = 'harbor.example.local:30080'
HARBOR_PROJECT = 'devops'
MANIFEST_REPO_URL = 'http://gitlab.devops.internal/root/sample-app-manifests.git'
MANIFEST_PATH = 'deploy/overlays/prod/deployment.yaml'
```

## 7. 사내 GitLab 소스 빌드 예시

사내 Jenkins에서 사용하던 파라미터 기반 Pipeline을 kind Jenkins에서 그대로 쓰려면
Git 저장소는 사내 GitLab URL을 유지하고, 실행 agent만 Kubernetes Buildah agent로
변경합니다. 예시는 `examples/Jenkinsfile.strato-gitlab-buildah`를 사용합니다.

이 방식에서는 Jenkins와 Jenkins agent Pod가 사내 GitLab에 접근할 수 있어야
합니다. 사내 GitLab이 사설 인증서를 사용하면 Buildah agent 이미지 또는 Jenkins
truststore에 해당 CA 인증서를 추가해야 합니다.

이 예시는 Gradle 빌드를 Buildah agent 안에서 실행하므로 Buildah agent 이미지에
JDK 17이 포함되어 있어야 합니다. 제공 Dockerfile은 `java-17-openjdk-devel`을
포함하도록 구성합니다.

폐쇄망 또는 사내망 환경에서는 Gradle wrapper의 `distributionUrl`이 접근 가능한
사내 미러를 바라보거나, 필요한 Gradle distribution이 사전에 캐시되어 있어야
합니다. 또한 `backend/Dockerfile`의 base image도 Buildah agent가 pull할 수 있는
Harbor 주소로 지정되어 있어야 합니다.

Jenkins Credential은 기존 사내 ID를 그대로 맞추거나 Jenkinsfile의 값을 수정합니다.

| Credential ID | 종류 | 용도 |
| --- | --- | --- |
| `gitlab.strato.co.kr` | Username with password 또는 token | 사내 GitLab checkout |
| `0-harbor-product-Credential` | Username with password | Harbor login/push |

Jenkins Job은 Pipeline script 또는 Pipeline from SCM 방식으로 만들 수 있습니다.
Pipeline script로 붙여 넣는 경우 다음 기본 파라미터를 환경에 맞게 조정합니다.

```groovy
GIT_URL = 'https://gitlab.strato.co.kr/strato-solution/strato-marketplace.git'
GIT_BRANCH = 'uzbek'
ACTIVE_PROFILE = 'uzbek'
IMAGE_NAME = 'uzbek/strato-software-catalog-backend'
IMAGE_VERSION = '1.0.1'
HARBOR_URL = 'http://harbor.test-cluster.com:30080'
```

기존 사내 Jenkinsfile의 `docker.build`, `withDockerRegistry`, `docker push`는
Docker daemon이 있는 Jenkins 환경을 전제로 합니다. kind의 Kubernetes agent에서는
Docker daemon 대신 Buildah를 사용하므로 다음 명령으로 대체합니다.

```bash
buildah bud -t "${REMOTE_IMAGE}" .
buildah login --tls-verify=false \
  --username "${HARBOR_USER}" \
  --password "${HARBOR_PASSWORD}" \
  "${HARBOR_REGISTRY}"
buildah push --tls-verify=false "${REMOTE_IMAGE}"
```

Harbor가 HTTPS 인증서를 사용하는 운영 환경이면 `HARBOR_URL`을 `https://...`로
입력하고, HTTP 테스트 환경이면 `http://...`로 입력합니다. Jenkinsfile 예시는 URL
scheme에 따라 Buildah의 `--tls-verify` 값을 자동으로 선택합니다.

Argo CD까지 배포를 이어가려면 Argo CD가 감시하는 매니페스트 저장소도 사내
GitLab에 있어야 하며, Argo CD Pod가 해당 GitLab에 접근 가능해야 합니다. Jenkins가
이미지를 push하는 것만으로는 Argo CD가 자동 배포하지 않으므로 다음 중 하나를
선택합니다.

1. Jenkins가 빌드 후 매니페스트 저장소의 image tag를 commit/push합니다.
1. Argo CD Image Updater를 별도로 구성합니다.
1. 매니페스트가 고정 태그 대신 환경별로 갱신되는 Helm/Kustomize 값을 참조하도록
   구성합니다.

## 8. Argo CD Application 생성

샘플 Application을 환경에 맞게 수정한 뒤 적용합니다.

```bash
kubectl apply -f examples/argocd-application-sample.yaml
```

Argo CD는 GitLab 매니페스트 저장소의 `deploy/overlays/prod` 경로를 감시합니다.
Jenkins는 빌드된 Harbor 이미지 태그를 매니페스트 저장소에 commit/push하고,
Argo CD가 자동으로 변경분을 동기화합니다.

## 9. 검증

Buildah agent Pod 동작을 확인합니다.

```bash
kubectl -n jenkins get pods
kubectl -n jenkins logs -l jenkins/label=buildah --tail=100
```

Jenkins 파이프라인에서 다음 단계가 성공해야 합니다.

1. GitLab 소스 checkout
1. `buildah bud -t <IMAGE> .`
1. `buildah login --tls-verify=false <HARBOR_REGISTRY>`
1. `buildah push --tls-verify=false <IMAGE>`
1. GitLab 매니페스트 저장소 image tag commit/push
1. Argo CD 자동 sync

Harbor push 실패 시 `harbor-jenkins-credential`, registry 주소, `--tls-verify=false`
옵션, Harbor `externalURL` 값을 확인합니다. agent Pod가 Harbor 도메인을 해석하지
못하면 `hostAliases` 또는 DNS 등록 상태를 확인합니다. 애플리케이션 Pod가 image
pull에 실패하면 worker node의 DNS 또는 insecure registry 설정과 `harbor-regcred`,
`values-cicd-buildah.local.yaml`의 `agent.imagePullSecretName`을 확인합니다.
