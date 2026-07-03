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
| Buildah agent | Jenkins Kubernetes agent 이미지 빌드 런타임 | 1.41.4 |

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

Buildah agent 이미지를 빌드하고 tar 파일로 저장합니다.

```bash
cd jenkins-build/buildah-agent
chmod +x build-buildah-agent.sh
./build-buildah-agent.sh
```

기본 출력 파일은 다음과 같습니다.

```text
jenkins-2.555.3/images/jenkins-buildah-agent_1.41.4.tar
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

업로드 후 다음 이미지가 존재해야 합니다.

```text
<HARBOR_REGISTRY>/devops/jenkins:2.555.3-jdk21
<HARBOR_REGISTRY>/devops/inbound-agent:3355.v388858a_47b_33-22
<HARBOR_REGISTRY>/devops/k8s-sidecar:2.7.3
<HARBOR_REGISTRY>/devops/jenkins-buildah-agent:1.41.4
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

`values-cicd-buildah.yaml`의 Harbor placeholder를 폐쇄망 주소로 치환합니다.

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

## 7. Argo CD Application 생성

샘플 Application을 환경에 맞게 수정한 뒤 적용합니다.

```bash
kubectl apply -f examples/argocd-application-sample.yaml
```

Argo CD는 GitLab 매니페스트 저장소의 `deploy/overlays/prod` 경로를 감시합니다.
Jenkins는 빌드된 Harbor 이미지 태그를 매니페스트 저장소에 commit/push하고,
Argo CD가 자동으로 변경분을 동기화합니다.

## 8. 검증

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
