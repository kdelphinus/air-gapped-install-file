# Keycloak 기반 OSS SSO 로컬 테스트 예제

이 문서는 현재 로컬 Kind 테스트 클러스터의 Keycloak 26.2.5를 기준으로
GitLab, Jenkins, Gitea, Harbor, Argo CD의 OpenID Connect(OIDC) SSO를
구성하는 절차를 설명합니다.

Nexus Repository 3.70.1은 지원 조건이 다르므로 별도 절에서 제한 사항을
설명합니다.

## 1. 적용 범위와 현재 상태

| 항목 | 값 |
| --- | --- |
| Keycloak URL | `http://keycloak.test-cluster.com` |
| 관리 콘솔 | `http://keycloak.test-cluster.com/admin/` |
| SSO Realm | `oss` |
| OIDC issuer | `http://keycloak.test-cluster.com/realms/oss` |
| Discovery URL | `http://keycloak.test-cluster.com/realms/oss/.well-known/openid-configuration` |

현재 클러스터에는 Gitea, Harbor, Jenkins, Argo CD가 배포되어 있습니다.
GitLab과 Nexus는 저장소에 설치 번들만 있고 현재 클러스터에는 배포되어
있지 않습니다.

이 문서의 HTTP 주소는 로컬 기능 검증 전용입니다. 운영 환경에서는 모든
제품의 외부 URL과 Keycloak issuer를 신뢰할 수 있는 인증서가 적용된
HTTPS 주소로 동시에 변경해야 합니다. OIDC 구성에서 HTTP와 HTTPS 주소를
섞으면 issuer 또는 redirect URI 검증이 실패합니다.

## 2. 연동 구조와 원칙

각 OSS는 동일한 `oss` Realm을 사용하되 서로 다른 OIDC Client와 Client
Secret을 사용합니다.

```text
Keycloak Realm: oss
├── Client: gitea
├── Client: argocd
├── Client: jenkins
├── Client: harbor
└── Client: gitlab
```

- `master` Realm은 Keycloak 관리 전용으로 유지합니다.
- 사용자와 OSS Client는 `oss` Realm에 생성합니다.
- 제품마다 Client Secret을 별도로 발급합니다.
- Client Secret은 Git에 커밋하지 않고 Kubernetes Secret 또는 제품의
  보안 설정 저장소에 보관합니다.
- SSO 검증이 끝날 때까지 각 제품의 기존 로컬 관리자 계정을 유지합니다.
- 자동화 계정은 사용자 SSO 계정과 분리하고 API Token 또는 Robot Account를
  사용합니다.

## 3. 사전 점검

### 3.1. 브라우저 연결 확인

Windows의 `hosts` 파일 또는 내부 DNS에 다음 레코드가 필요합니다.

```text
127.0.0.1 keycloak.test-cluster.com
127.0.0.1 gitea.test-cluster.com
127.0.0.1 argocd.test-cluster.com
127.0.0.1 jenkins.test-cluster.com
127.0.0.1 harbor.test-cluster.com
```

### 3.2. 클러스터 내부 DNS 확인

브라우저뿐 아니라 Jenkins, Gitea, Harbor, Argo CD Pod도 Keycloak issuer에
접속할 수 있어야 합니다. Windows `hosts` 설정은 Kubernetes Pod에
전달되지 않습니다.

```bash
kubectl run keycloak-dns-check \
  --rm -i --restart=Never \
  --image=busybox:1.36 \
  -- nslookup keycloak.test-cluster.com
```

조회되지 않으면 사내 DNS에 레코드를 등록하거나 테스트 클러스터의 CoreDNS에
`keycloak.test-cluster.com`을 Envoy Gateway 주소로 해석하는 규칙을 추가해야
합니다. DNS가 해결되기 전에는 제품 설정을 시작하지 않습니다.

### 3.3. Discovery 응답 확인

```bash
curl -sS \
  http://keycloak.test-cluster.com/realms/oss/.well-known/openid-configuration
```

응답의 `issuer`는 다음 값과 정확히 같아야 합니다.

```text
http://keycloak.test-cluster.com/realms/oss
```

## 4. Keycloak 공통 구성

### 4.1. `oss` Realm 생성

1. Keycloak 관리 콘솔에 `admin` 계정으로 로그인합니다.
2. 왼쪽 위 Realm 선택 메뉴에서 **Create realm**을 선택합니다.
3. Realm name에 `oss`를 입력합니다.
4. Enabled가 활성화된 상태로 생성합니다.

### 4.2. 공통 그룹 생성

| 그룹 | 용도 |
| --- | --- |
| `platform-admins` | 각 OSS 관리자 후보 |
| `developers` | 개발 및 일반 사용 권한 |
| `viewers` | 조회 전용 권한 |

Keycloak 그룹이 곧바로 모든 제품의 권한이 되는 것은 아닙니다. 각 제품에서
그룹 이름을 해당 제품의 Role 또는 권한 전략에 매핑해야 합니다.

### 4.3. `groups` Client Scope 생성

1. **Client scopes**에서 **Create client scope**를 선택합니다.
2. Name은 `groups`, Protocol은 `OpenID Connect`로 생성합니다.
3. 생성된 Scope의 **Mappers**에서 **Configure a new mapper**를 선택합니다.
4. Mapper type으로 **Group Membership**을 선택합니다.
5. 다음과 같이 설정합니다.

| 항목 | 값 |
| --- | --- |
| Name | `groups` |
| Token Claim Name | `groups` |
| Full group path | Off |
| Add to ID token | On |
| Add to access token | On |
| Add to userinfo | On |

각 OSS Client의 **Client scopes** 탭에서 이 Scope를 `Default`로 연결합니다.

### 4.4. 테스트 사용자 생성

1. **Users**에서 테스트 사용자를 생성합니다.
2. Username, Email, First name, Last name을 모두 입력합니다.
3. **Credentials**에서 임시 비밀번호를 설정합니다.
4. **Groups**에서 `developers` 그룹을 할당합니다.
5. 관리자 검증용 별도 사용자는 `platform-admins`에 할당합니다.

GitLab과 일부 제품은 Email, First name, Last name이 비어 있으면 최초 사용자
등록이 실패할 수 있으므로 모두 입력합니다.

## 5. 제품별 Keycloak Client 값

모든 Client의 Client type은 `OpenID Connect`를 사용합니다. 별도 언급이
없으면 Client authentication을 활성화하고 Standard flow만 활성화합니다.
Direct access grants와 Service accounts roles는 비활성화합니다.

| 제품 | Client ID | Valid redirect URI | 현재 배포 |
| --- | --- | --- | --- |
| Gitea | `gitea` | `http://gitea.test-cluster.com/user/oauth2/keycloak/callback` | 배포됨 |
| Argo CD | `argocd` | `http://argocd.test-cluster.com/auth/callback` | 배포됨 |
| Jenkins | `jenkins` | `http://jenkins.test-cluster.com/securityRealm/finishLogin` | 배포됨 |
| Harbor | `harbor` | `http://harbor.test-cluster.com/c/oidc/callback` | 배포됨 |
| GitLab | `gitlab` | `http://gitlab.test-cluster.com/users/auth/openid_connect/callback` | 미배포 |

각 Client의 Web origins에는 해당 제품의 Base URL만 등록합니다. 테스트
편의를 위한 `*` redirect URI는 사용하지 않습니다.

## 6. 권장 적용 순서

1. Gitea
2. Argo CD
3. Jenkins
4. Harbor
5. GitLab
6. Nexus 지원 방식 결정

Gitea와 Argo CD는 기존 로컬 관리자를 유지한 채 SSO 버튼을 추가할 수 있어
초기 검증에 적합합니다. Jenkins와 Harbor는 인증 모드 변경 시 잠금 위험이
있으므로 뒤에서 적용합니다.

## 7. Gitea 1.25.5 연동

### 7.1. Keycloak Client 생성

```text
Root URL: http://gitea.test-cluster.com
Valid redirect URIs: http://gitea.test-cluster.com/user/oauth2/keycloak/callback
Web origins: http://gitea.test-cluster.com
```

`groups` Client Scope를 Default로 연결하고 Client Secret을 별도로 보관합니다.

### 7.2. Gitea Authentication Source 추가

Gitea 로컬 관리자로 로그인한 뒤 다음 메뉴로 이동합니다.

```text
Site Administration → Authentication Sources → Add Authentication Source
```

| 항목 | 값 |
| --- | --- |
| Authentication Type | OAuth2 |
| Authentication Name | `keycloak` |
| OAuth2 Provider | OpenID Connect |
| Client ID | `gitea` |
| Client Secret | Keycloak에서 발급한 값 |
| OpenID Connect Auto Discovery URL | `http://keycloak.test-cluster.com/realms/oss/.well-known/openid-configuration` |
| Group Claim Name | `groups` |
| Admin Group | `platform-admins` |

자동 사용자 생성을 사용할 경우 `ENABLE_AUTO_REGISTRATION`과 Username Claim
정책도 검토합니다. 기존 계정과 같은 Email을 사용하는 SSO 계정은 자동
연결 정책에 따라 충돌할 수 있으므로 테스트 계정으로 먼저 확인합니다.

### 7.3. 검증과 롤백

시크릿 브라우저에서 `keycloak` 로그인 버튼을 선택하고 Keycloak 테스트
사용자로 로그인합니다. 사용자 이름, Email, 그룹 기반 권한을 확인합니다.

실패하면 로컬 관리자 세션에서 추가한 Authentication Source를 비활성화하거나
삭제합니다.

## 8. Argo CD 3.4.3 연동

### 8.1. Keycloak Client 생성

```text
Root URL: http://argocd.test-cluster.com
Valid redirect URIs: http://argocd.test-cluster.com/auth/callback
Valid post logout redirect URIs: http://argocd.test-cluster.com/applications
Web origins: http://argocd.test-cluster.com
```

### 8.2. Client Secret 저장

`<ARGOCD_CLIENT_SECRET>`은 실제 Secret으로 교체합니다. 명령 실행 후 셸
기록에 Secret이 남지 않도록 주의합니다.

```bash
kubectl -n argocd patch secret argocd-secret \
  --type merge \
  -p '{"stringData":{"oidc.keycloak.clientSecret":"<ARGOCD_CLIENT_SECRET>"}}'
```

### 8.3. Argo CD values 설정

`argocd-3.4.3/values.yaml`의 `configs.cm`과 `configs.rbac`에 다음 값을
반영합니다.

```yaml
configs:
  cm:
    url: http://argocd.test-cluster.com
    admin.enabled: true
    oidc.config: |
      name: Keycloak
      issuer: http://keycloak.test-cluster.com/realms/oss
      clientID: argocd
      clientSecret: $oidc.keycloak.clientSecret
      requestedScopes:
        - openid
        - profile
        - email
        - groups
  rbac:
    policy.default: role:readonly
    scopes: "[groups]"
    policy.csv: |
      g, platform-admins, role:admin
      g, developers, role:readonly
      g, viewers, role:readonly
```

```bash
cd argocd-3.4.3
./scripts/install.sh
```

### 8.4. 검증과 롤백

SSO 로그인 후 사용자 그룹과 Argo CD Role을 확인합니다. 문제가 있으면
`oidc.config`와 SSO RBAC 행을 제거하고 다시 업그레이드합니다. 검증이 끝날
때까지 `admin.enabled: true`를 유지합니다.

Argo CD CLI SSO는 별도의 PKCE/Public Client 설계가 필요합니다. 첫 테스트는
웹 UI 연동만 수행합니다.

## 9. Jenkins 2.555.3 연동

### 9.1. OIDC 플러그인 준비

Jenkins에는 `oic-auth` 플러그인이 필요합니다. 현재 Jenkins 2.555.3은
플러그인의 최소 Jenkins 버전 2.539 조건을 충족합니다. 폐쇄망에서는 인터넷
준비 서버에서 플러그인과 모든 의존성을 다운로드하여 Jenkins 이미지에
포함한 뒤 반입해야 합니다.

`jenkins-2.555.3/jenkins-build/plugins.txt`에 검증할 버전을 고정합니다.

```text
oic-auth:4.715.vf202e4229f61
```

### 9.2. Keycloak Client 생성

```text
Root URL: http://jenkins.test-cluster.com
Valid redirect URIs: http://jenkins.test-cluster.com/securityRealm/finishLogin
Valid post logout redirect URIs: http://jenkins.test-cluster.com/OicLogout
Web origins: http://jenkins.test-cluster.com
```

### 9.3. Jenkins Security Realm 변경

```text
Manage Jenkins → Security → Security Realm → OpenID Connect
```

| 항목 | 값 |
| --- | --- |
| Client ID | `jenkins` |
| Client Secret | Keycloak에서 발급한 값 |
| Well-known configuration | `http://keycloak.test-cluster.com/realms/oss/.well-known/openid-configuration` |
| Scopes | `openid profile email groups` |
| User name field | `preferred_username` |
| Full name field | `name` |
| Email field | `email` |
| Groups field | `groups` |

플러그인의 Escape Hatch를 활성화하고 복구용 관리자 Credential을 설정합니다.
이 기능을 검증하기 전에는 Jenkins 로컬 인증을 복구할 수 없는 방식으로
JCasC를 고정하지 않습니다.

Authorization Strategy는 기존 `matrix-auth` 또는 `role-strategy`에서
`platform-admins`, `developers`, `viewers` 그룹에 필요한 권한을 부여합니다.

### 9.4. 검증과 롤백

새 시크릿 브라우저로 로그인하여 사용자 이름, Email, 그룹 권한을 확인합니다.
CLI와 Pipeline 자동화는 Keycloak 비밀번호가 아니라 Jenkins API Token을
사용합니다.

실패하면 Escape Hatch로 로그인하여 Security Realm을 Jenkins local로
되돌립니다. JCasC로 적용한 경우 이전 `securityRealm` 설정을 복원하고
Jenkins를 재시작합니다.

## 10. Harbor 2.10.3 연동

### 10.1. 사전 주의 사항

Harbor는 `admin` 이외의 로컬 사용자가 이미 존재하면 Database 인증에서
OIDC 인증으로 변경할 수 없습니다.

- `admin` 이외의 로컬 사용자가 있는지 확인합니다.
- Robot Account와 프로젝트 권한을 백업합니다.
- 기존 관리자 브라우저 세션을 유지합니다.
- Harbor의 `externalURL`이 실제 브라우저 URL과 같은지 확인합니다.

현재 테스트 환경의 `externalURL`은 다음 값이어야 합니다.

```text
http://harbor.test-cluster.com
```

### 10.2. Keycloak Client 생성

```text
Root URL: http://harbor.test-cluster.com
Valid redirect URIs: http://harbor.test-cluster.com/c/oidc/callback
Web origins: http://harbor.test-cluster.com
```

### 10.3. Harbor OIDC 설정

```text
Administration → Configuration → Authentication
```

| 항목 | 값 |
| --- | --- |
| Auth Mode | OIDC |
| OIDC Provider Name | `Keycloak` |
| OIDC Provider Endpoint | `http://keycloak.test-cluster.com/realms/oss` |
| OIDC Client ID | `harbor` |
| OIDC Client Secret | Keycloak에서 발급한 값 |
| Group Claim Name | `groups` |
| OIDC Admin Group | `platform-admins` |
| OIDC Scope | `openid,profile,email,groups,offline_access` |
| Automatic onboarding | On |
| Username Claim | `preferred_username` |

화면 아래에 표시되는 Redirect URI가 Keycloak에 등록한 값과 정확히 같은지
확인하고 **Test OIDC Server**를 먼저 실행합니다.

### 10.4. 검증과 롤백

SSO 최초 로그인 후 Harbor 사용자와 그룹을 확인합니다. Docker와 Helm CLI는
브라우저 리디렉션을 처리하지 못하므로 Keycloak 비밀번호가 아닌 Harbor의
사용자별 CLI Secret을 사용합니다.

로컬 `admin`은 다음 경로에서 계속 로그인할 수 있습니다.

```text
http://harbor.test-cluster.com/account/sign-in
```

## 11. GitLab Omnibus 18.11.4 연동

GitLab은 현재 로컬 클러스터에 배포되어 있지 않으므로 설치 후 진행합니다.

### 11.1. Keycloak Client 생성

```text
Root URL: http://gitlab.test-cluster.com
Valid redirect URIs: http://gitlab.test-cluster.com/users/auth/openid_connect/callback
Web origins: http://gitlab.test-cluster.com
```

### 11.2. GitLab Omnibus 설정

현재 번들은
`gitlab-omnibus-18.11.4/charts/gitlab-omnibus/templates/configmap.yaml`에서
`gitlab.rb`를 생성합니다. 다음 설정을 추가하되 Client Secret은 별도
Kubernetes Secret에서 주입하도록 구현해야 합니다.

```ruby
gitlab_rails['omniauth_enabled'] = true
gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']
gitlab_rails['omniauth_block_auto_created_users'] = false
gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']
gitlab_rails['omniauth_providers'] = [
  {
    name: 'openid_connect',
    label: 'Keycloak',
    args: {
      name: 'openid_connect',
      scope: ['openid', 'profile', 'email', 'groups'],
      response_type: 'code',
      issuer: 'http://keycloak.test-cluster.com/realms/oss',
      discovery: true,
      uid_field: 'preferred_username',
      pkce: true,
      client_auth_method: 'query',
      client_options: {
        identifier: 'gitlab',
        secret: '<GITLAB_CLIENT_SECRET>',
        redirect_uri: 'http://gitlab.test-cluster.com/users/auth/openid_connect/callback'
      }
    }
  }
]
```

기존 Email과 SSO Email이 같을 때 계정을 자동 연결하는 정책은 운영 적용 전에
반드시 별도 테스트 계정으로 검증합니다. 로컬 `root` 계정은 비상 복구용으로
유지합니다.

실패하면 위 OmniAuth 설정을 제거하고 기존 Helm 값으로 다시 배포합니다.

## 12. Nexus Repository 3.70.1 제한 사항

현재 저장소의 Nexus Repository 3.70.1에는 공식 네이티브 OIDC 기능이
없습니다. Sonatype의 공식 OIDC 지원은 Nexus Repository Pro 3.86 이상에서
제공됩니다. 따라서 현재 Nexus 3.70.1 Community 설치에 Keycloak Client만
생성해도 SSO가 동작하지 않습니다.

다음 중 하나를 선택해야 합니다.

1. 현재 3.70.1에서는 로컬 인증을 유지합니다.
2. Nexus Repository Pro 3.86 이상으로 업그레이드한 뒤 공식 OIDC를
   구성합니다.
3. 별도 Reverse Proxy와 Remote User Token Realm을 검토합니다. 이 방식은
   신뢰 헤더 위조 방지와 네트워크 격리가 필수이므로 별도 설계 및 보안
   검증 없이 적용하지 않습니다.

비공식 또는 장기간 유지보수되지 않은 Keycloak 플러그인을 폐쇄망 표준
번들에 바로 포함하는 방식은 권장하지 않습니다.

## 13. 통합 검증 체크리스트

- 시크릿 브라우저에서 SSO 버튼이 표시됩니다.
- Keycloak 로그인 후 원래 제품으로 돌아옵니다.
- OIDC callback URL이 Keycloak Client 설정과 정확히 같습니다.
- 신규 사용자의 Username, Email, 이름이 정상 생성됩니다.
- `groups` claim이 ID Token 또는 UserInfo 응답에 포함됩니다.
- `platform-admins`, `developers`, `viewers` 권한이 예상대로 매핑됩니다.
- 권한이 없는 사용자는 관리자 기능을 사용할 수 없습니다.
- 로그아웃 후 제품과 Keycloak 세션 동작을 확인합니다.
- 기존 로컬 관리자 또는 복구 경로로 로그인할 수 있습니다.
- Jenkins API Token, Harbor CLI Secret, Robot Account 등 비대화형 인증이
  계속 동작합니다.

## 14. 장애 확인 순서

### 14.1. Redirect URI 오류

Keycloak 이벤트 또는 브라우저 오류의 `redirect_uri` 값을 복사하여 Client의
Valid redirect URIs와 문자 단위로 비교합니다. Scheme, Port, Path, 마지막
슬래시 차이도 오류 원인이 됩니다.

### 14.2. Issuer 불일치

제품에 설정한 issuer와 Discovery 응답의 `issuer`가 정확히 같은지 확인합니다.

### 14.3. Pod에서 Keycloak에 연결할 수 없음

제품 Pod 내부에서 Keycloak FQDN의 DNS와 HTTP 연결을 확인합니다. 브라우저만
정상이고 Pod에서 실패하면 Windows `hosts`가 아니라 클러스터 DNS 문제입니다.

### 14.4. 로그인은 되지만 권한이 없음

Keycloak Client에 `groups` Scope가 Default로 연결되었는지, Group Membership
Mapper가 ID Token에 claim을 추가하는지, 제품의 그룹 이름이 Keycloak 값과
대소문자까지 같은지 확인합니다.

### 14.5. 사용자 생성 실패

Keycloak 사용자에 Email, First name, Last name이 입력되었는지 확인합니다.
기존 로컬 계정과 Email 또는 Username이 충돌하는지도 확인합니다.

## 15. 운영 전환 시 필수 변경

- Keycloak과 모든 OSS 외부 URL을 HTTPS로 변경합니다.
- 사내 CA 또는 공인 CA 인증서를 모든 Pod가 신뢰하도록 배포합니다.
- Client Secret을 제품별 Kubernetes Secret으로 분리합니다.
- Realm과 Client 설정을 내보내 백업 절차를 마련합니다.
- 테스트용 사용자와 비밀번호를 제거합니다.
- SSO 장애 시 사용할 최소 권한의 비상 관리자 계정을 별도 보관합니다.
- Realm 이벤트와 각 제품의 인증 로그를 수집합니다.
- 토큰 수명, 세션 만료, MFA 정책을 운영 기준에 맞게 적용합니다.

## 16. 공식 참고 문서

- [Keycloak Server Administration Guide](https://www.keycloak.org/docs/latest/server_admin/)
- [GitLab OpenID Connect](https://docs.gitlab.com/administration/auth/oidc/)
- [Jenkins OpenID Connect Authentication Plugin](https://plugins.jenkins.io/oic-auth)
- [Gitea Command Line Authentication Sources](https://docs.gitea.com/usage/command-line)
- [Harbor OIDC Authentication](https://goharbor.io/docs/2.10.0/administration/configure-authentication/oidc-auth/)
- [Argo CD Keycloak Integration](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/keycloak/)
- [Sonatype Nexus Repository OpenID Connect](https://help.sonatype.com/en/openid-connect.html)
