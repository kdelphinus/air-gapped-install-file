# Keycloak 기반 OSS SSO 범용 연동 가이드

이 문서는 특정 Keycloak 버전, Kubernetes 배포판, 도메인, 네임스페이스,
Ingress 구현에 종속되지 않는 OpenID Connect(OIDC) SSO 연동 기준을
정의합니다.

제품 버전에 따라 화면 이름이나 설정 필드가 달라질 수 있으므로, 적용 전에
각 제품의 공식 문서와 현재 설치 버전의 지원 범위를 함께 확인합니다.

## 1. 적용 대상

이 가이드는 다음 제품을 대상으로 합니다.

- GitLab Self-Managed
- Jenkins
- Gitea
- Harbor
- Argo CD
- Nexus Repository

Keycloak은 Identity Provider(IdP), 각 OSS는 OIDC Client 또는 Relying
Party(RP)로 동작합니다.

## 2. 환경 변수 정의

연동을 시작하기 전에 다음 값을 환경별 작업표에 기록합니다.

| 변수 | 설명 | 예시 |
| --- | --- | --- |
| `KEYCLOAK_BASE_URL` | 외부에서 접근하는 Keycloak URL | `https://sso.example.com` |
| `REALM` | OSS 사용자를 관리할 Realm | `oss` |
| `OIDC_ISSUER` | Keycloak OIDC issuer | `https://sso.example.com/realms/oss` |
| `APP_BASE_URL` | 연동할 OSS의 외부 URL | `https://jenkins.example.com` |
| `CLIENT_ID` | 제품별 OIDC Client ID | `jenkins` |
| `CLIENT_SECRET` | 제품별 OIDC Client Secret | Git에 저장하지 않음 |
| `GROUPS_CLAIM` | 그룹 정보를 전달할 claim | `groups` |
| `ADMIN_GROUP` | 제품 관리자에 매핑할 그룹 | `platform-admins` |

Issuer는 다음 공식으로 구성합니다.

```text
OIDC_ISSUER = KEYCLOAK_BASE_URL + /realms/REALM
```

Discovery URL은 다음과 같습니다.

```text
OIDC_ISSUER + /.well-known/openid-configuration
```

문서의 예시 URL을 그대로 복사하지 말고 환경 작업표의 값으로 교체합니다.

## 3. 필수 사전 조건

### 3.1. URL 일관성

다음 위치에서 사용하는 Scheme, Host, Port가 일치해야 합니다.

- Keycloak의 외부 hostname
- Discovery 응답의 `issuer`
- OSS에 입력한 issuer
- Keycloak Client의 redirect URI
- OSS 자체의 external URL 또는 root URL

예를 들어 외부 URL이 HTTPS이면 issuer와 redirect URI도 HTTPS여야 합니다.
HTTP와 HTTPS를 혼용하면 issuer 또는 redirect URI 검증이 실패합니다.

### 3.2. 양방향 DNS와 네트워크

OIDC 로그인에는 브라우저와 서버 양쪽의 연결이 필요합니다.

```text
사용자 브라우저 → OSS
사용자 브라우저 → Keycloak
OSS 서버 또는 Pod → Keycloak
Keycloak → 사용자 브라우저를 통한 OSS callback
```

클라이언트 PC의 `hosts` 파일만 변경하면 브라우저는 연결되지만 Kubernetes
Pod는 해당 설정을 알 수 없습니다. 사내 DNS, CoreDNS, Route 53, 사설 DNS
등 실제 실행 환경의 DNS에 Keycloak 레코드를 등록합니다.

Kubernetes 환경에서는 임시 Pod로 DNS와 Discovery 응답을 확인합니다.

```bash
kubectl run oidc-network-check \
  --rm -i --restart=Never \
  --image=curlimages/curl:<VERSION> \
  -- curl -fsS \
  <OIDC_ISSUER>/.well-known/openid-configuration
```

폐쇄망에서는 위 점검 이미지도 사전에 내부 레지스트리에 반입해야 합니다.

### 3.3. TLS 신뢰

운영 환경은 HTTPS를 사용합니다. 사설 CA를 사용하면 다음 구성 요소가 CA를
신뢰해야 합니다.

- 사용자 브라우저와 운영 단말
- GitLab, Jenkins, Gitea, Harbor, Argo CD, Nexus 실행 환경
- Reverse Proxy, Ingress Controller, Gateway
- 자동화 CLI와 Build Agent

인증서 검증 비활성화는 연결 원인을 분리하는 단기 테스트에만 사용합니다.

### 3.4. 시간 동기화

Keycloak과 각 OSS 노드의 시간이 동기화되어야 합니다. 시간 차이가 크면
토큰의 `iat`, `nbf`, `exp` 검증이 실패합니다.

## 4. Keycloak 공통 설계

### 4.1. Realm 분리

`master` Realm은 Keycloak 관리 전용으로 유지합니다. 일반 사용자와 OSS
Client를 위한 별도 Realm을 생성합니다.

Realm 이름 예시는 `oss`이지만 조직, 환경 또는 보안 경계에 따라 다음처럼
분리할 수 있습니다.

- 조직별 Realm
- 운영과 개발 환경별 Realm
- 외부 사용자와 내부 사용자별 Realm

Realm을 지나치게 세분화하면 사용자와 Client 관리가 복잡해지므로 실제
인증 경계가 다를 때만 분리합니다.

### 4.2. 공통 그룹

다음과 같은 최소 그룹 체계를 권장합니다.

| 그룹 예시 | 의미 |
| --- | --- |
| `platform-admins` | 플랫폼 관리자 |
| `developers` | 일반 개발 사용자 |
| `viewers` | 조회 전용 사용자 |

Keycloak 그룹은 인증 토큰에 권한 후보를 전달합니다. 실제 권한은 각 OSS의
Role, Team, Matrix Authorization 또는 RBAC 설정에서 다시 매핑합니다.

### 4.3. 그룹 Claim Scope

Realm에 OIDC Client Scope를 생성합니다.

| 항목 | 권장값 |
| --- | --- |
| Client Scope Name | `groups` |
| Protocol | OpenID Connect |
| Mapper Type | Group Membership |
| Token Claim Name | `groups` |
| Full group path | 조직 정책에 따라 선택 |
| Add to ID token | On |
| Add to access token | On |
| Add to userinfo | On |

단순 그룹 이름을 제품 권한과 매핑하려면 Full group path를 끕니다. 동일한
이름의 그룹이 여러 경로에 존재하거나 계층 구조가 중요하면 전체 경로를
사용하고 제품의 권한 매핑에도 같은 값을 사용합니다.

각 제품 Client에 `groups` Scope를 Default로 연결합니다.

### 4.4. 사용자 속성

테스트 사용자는 다음 값을 모두 가집니다.

- Username
- Email
- First name
- Last name
- 하나 이상의 검증 대상 그룹

제품에 따라 Email 또는 이름이 없으면 최초 사용자 생성이 실패할 수 있습니다.

## 5. OIDC Client 공통 템플릿

제품마다 별도의 Client를 생성합니다. Client Secret을 여러 제품이 공유하지
않습니다.

| Keycloak 설정 | 권장값 |
| --- | --- |
| Client type | OpenID Connect |
| Client authentication | On |
| Standard flow | On |
| Direct access grants | Off |
| Implicit flow | Off |
| Service accounts roles | Off |
| Valid redirect URIs | 제품의 정확한 callback URI |
| Web origins | 제품의 정확한 Base URL |
| Default Client Scope | `groups` 추가 |

Client authentication이 켜진 Client는 Confidential Client입니다. Argo CD
CLI처럼 PKCE 기반 Public Client가 필요한 사용 사례는 웹 UI Client와
분리하는 것을 권장합니다.

Wildcard redirect URI는 개발 중에도 가급적 사용하지 않습니다. 불가피한
경우 테스트 완료 후 정확한 callback URI로 축소합니다.

## 6. 제품별 callback URI

| 제품 | Client ID 예시 | Callback 경로 |
| --- | --- | --- |
| Gitea | `gitea` | `<GITEA_BASE_URL>/user/oauth2/<AUTH_SOURCE_NAME>/callback` |
| Argo CD Web UI | `argocd` | `<ARGOCD_BASE_URL>/auth/callback` |
| Jenkins | `jenkins` | `<JENKINS_BASE_URL>/securityRealm/finishLogin` |
| Harbor | `harbor` | `<HARBOR_BASE_URL>/c/oidc/callback` |
| GitLab | `gitlab` | `<GITLAB_BASE_URL>/users/auth/openid_connect/callback` |
| Nexus Pro 3.86 이상 | `nexus` | `<NEXUS_BASE_URL>/oidc/callback` |

제품 UI가 callback URI를 표시한다면 UI에 표시된 값을 최종 기준으로
사용합니다. Reverse Proxy의 경로 prefix를 사용하는 환경에서는 callback
경로에도 prefix가 포함될 수 있습니다.

## 7. 권장 적용 순서

1. Keycloak Realm, 그룹, 테스트 사용자 생성
2. Discovery와 클러스터 내부 DNS 검증
3. 기존 로컬 관리자와 복구 절차 확인
4. 한 제품의 Client 생성
5. 해당 제품만 OIDC 설정
6. 일반 사용자와 관리자 그룹 로그인 검증
7. 로그아웃, 권한, API와 CLI 영향 검증
8. 다음 제품으로 진행

여러 제품을 동시에 전환하면 issuer, DNS, claim, 제품 설정 중 어느 지점에서
실패했는지 분리하기 어렵습니다.

## 8. Gitea 연동

### 8.1. Keycloak Client

```text
Client ID: gitea
Root URL: <GITEA_BASE_URL>
Valid redirect URIs: <GITEA_BASE_URL>/user/oauth2/keycloak/callback
Web origins: <GITEA_BASE_URL>
```

Authentication Source Name을 `keycloak`이 아닌 다른 값으로 만들면 callback의
`keycloak` 부분도 같은 이름으로 변경합니다.

### 8.2. Gitea 설정

Gitea 로컬 관리자로 로그인하고 다음 메뉴로 이동합니다.

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
| Auto Discovery URL | `<OIDC_ISSUER>/.well-known/openid-configuration` |
| Group Claim Name | `groups` |
| Admin Group | `platform-admins` 또는 조직 지정값 |

Gitea 버전에 따라 UI 필드 또는 `gitea admin auth add-oauth` CLI 옵션이
달라질 수 있습니다. 현재 버전의 `gitea admin auth add-oauth --help`로
지원 옵션을 확인합니다.

### 8.3. 롤백

로컬 관리자 세션을 유지합니다. 실패하면 추가한 Authentication Source를
비활성화하거나 삭제합니다.

## 9. Argo CD 연동

### 9.1. Keycloak Client

```text
Client ID: argocd
Root URL: <ARGOCD_BASE_URL>
Valid redirect URIs: <ARGOCD_BASE_URL>/auth/callback
Valid post logout redirect URIs: <ARGOCD_BASE_URL>/applications
Web origins: <ARGOCD_BASE_URL>
```

### 9.2. Secret 저장

Client Secret은 `argocd-secret` 또는 Argo CD가 참조할 별도 Kubernetes
Secret에 저장합니다.

```bash
kubectl -n <ARGOCD_NAMESPACE> patch secret argocd-secret \
  --type merge \
  -p '{"stringData":{"oidc.keycloak.clientSecret":"<ARGOCD_CLIENT_SECRET>"}}'
```

### 9.3. ConfigMap과 RBAC

```yaml
configs:
  cm:
    url: <ARGOCD_BASE_URL>
    admin.enabled: true
    oidc.config: |
      name: Keycloak
      issuer: <OIDC_ISSUER>
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

조직 권한 정책에 따라 `policy.default`를 비워 로그인만 허용하고 명시적으로
Role을 부여할 수도 있습니다.

### 9.4. CLI SSO

Argo CD CLI는 로컬 callback과 PKCE가 필요할 수 있습니다. Web UI용
Confidential Client와 CLI용 Public Client를 분리하고 현재 Argo CD 버전의
공식 Keycloak 연동 문서를 따릅니다.

### 9.5. 롤백

검증이 끝날 때까지 로컬 `admin`을 활성화합니다. 실패하면 `oidc.config`와
관련 RBAC 행을 제거한 뒤 Argo CD Server를 재시작합니다.

## 10. Jenkins 연동

### 10.1. 플러그인 호환성

Jenkins에는 OpenID Connect Authentication 플러그인인 `oic-auth`가
필요합니다. Jenkins Controller 버전과 플러그인의 최소 요구 버전을 확인하고
검증된 플러그인 버전을 고정합니다.

폐쇄망에서는 플러그인 파일 하나뿐 아니라 모든 의존 플러그인을 인터넷 준비
서버에서 함께 내려받고 Jenkins 이미지 또는 오프라인 플러그인 번들에
포함합니다.

### 10.2. Keycloak Client

```text
Client ID: jenkins
Root URL: <JENKINS_BASE_URL>
Valid redirect URIs: <JENKINS_BASE_URL>/securityRealm/finishLogin
Valid post logout redirect URIs: <JENKINS_BASE_URL>/OicLogout
Web origins: <JENKINS_BASE_URL>
```

### 10.3. Jenkins Security Realm

```text
Manage Jenkins → Security → Security Realm → OpenID Connect
```

| 항목 | 값 |
| --- | --- |
| Client ID | `jenkins` |
| Client Secret | Keycloak에서 발급한 값 |
| Well-known configuration | `<OIDC_ISSUER>/.well-known/openid-configuration` |
| Scopes | `openid profile email groups` |
| User name field | `preferred_username` |
| Full name field | `name` |
| Email field | `email` |
| Groups field | `groups` |

플러그인의 Escape Hatch를 활성화하고 실제로 복구 로그인을 시험합니다.
Authorization Strategy는 `matrix-auth` 또는 `role-strategy`에서 Keycloak
그룹을 Jenkins 권한에 매핑합니다.

### 10.4. 자동화 영향

OIDC 사용자 비밀번호는 Jenkins가 알지 못하므로 Basic Authentication에
사용할 수 없습니다. Pipeline, CLI, REST 자동화는 Jenkins API Token을
사용합니다.

### 10.5. 롤백

Escape Hatch 또는 유지된 관리자 세션으로 로그인하여 Security Realm을
이전 설정으로 복원합니다. JCasC를 사용하면 이전 `securityRealm`과
Authorization Strategy를 함께 복원합니다.

## 11. Harbor 연동

### 11.1. 전환 전 점검

Harbor는 버전과 기존 사용자 상태에 따라 Database 인증에서 OIDC로 변경이
제한될 수 있습니다. 다음 항목을 먼저 확인합니다.

- `admin` 이외의 로컬 사용자가 존재하는지 확인합니다.
- 현재 Harbor 버전의 인증 모드 전환 조건을 확인합니다.
- Robot Account와 프로젝트 권한을 백업합니다.
- `externalURL`이 실제 Base URL과 같은지 확인합니다.
- 기존 관리자 브라우저 세션을 유지합니다.

### 11.2. Keycloak Client

```text
Client ID: harbor
Root URL: <HARBOR_BASE_URL>
Valid redirect URIs: <HARBOR_BASE_URL>/c/oidc/callback
Web origins: <HARBOR_BASE_URL>
```

### 11.3. Harbor OIDC 설정

```text
Administration → Configuration → Authentication
```

| 항목 | 값 |
| --- | --- |
| Auth Mode | OIDC |
| OIDC Provider Name | `Keycloak` |
| OIDC Provider Endpoint | `<OIDC_ISSUER>` |
| OIDC Client ID | `harbor` |
| OIDC Client Secret | Keycloak에서 발급한 값 |
| Group Claim Name | `groups` |
| OIDC Admin Group | 조직의 관리자 그룹 |
| OIDC Scope | `openid,profile,email,groups,offline_access` |
| Automatic onboarding | 조직 정책에 따라 선택 |
| Username Claim | `preferred_username` |

Harbor UI 하단에 표시되는 Redirect URI가 Keycloak Client 값과 정확히 같은지
확인한 뒤 **Test OIDC Server**를 실행합니다.

### 11.4. CLI 인증

Docker와 Helm CLI는 브라우저 OIDC 리디렉션을 처리하지 못합니다. OIDC 최초
로그인 후 Harbor가 발급하는 CLI Secret 또는 Robot Account를 사용합니다.

### 11.5. 롤백

Harbor 버전에서 제공하는 로컬 DB 로그인 경로와 `admin` 계정을 사전에
검증합니다. 인증 모드를 변경한 뒤에는 기존 사용자 상태 때문에 즉시 원복이
제한될 수 있으므로 백업과 별도 테스트 인스턴스 검증이 필요합니다.

## 12. GitLab 연동

### 12.1. Keycloak Client

```text
Client ID: gitlab
Root URL: <GITLAB_BASE_URL>
Valid redirect URIs: <GITLAB_BASE_URL>/users/auth/openid_connect/callback
Web origins: <GITLAB_BASE_URL>
```

### 12.2. Omnibus 설정 예시

Linux Package 또는 Omnibus Container는 `gitlab.rb`에 OIDC 설정을 추가합니다.
다른 설치 방식은 해당 배포판의 공식 설정 경로를 사용합니다.

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
      issuer: '<OIDC_ISSUER>',
      discovery: true,
      uid_field: 'preferred_username',
      pkce: true,
      client_auth_method: 'query',
      client_options: {
        identifier: 'gitlab',
        secret: '<GITLAB_CLIENT_SECRET>',
        redirect_uri: '<GITLAB_BASE_URL>/users/auth/openid_connect/callback'
      }
    }
  }
]
```

Client Secret을 ConfigMap이나 Git에 평문으로 저장하지 않습니다. Kubernetes
배포라면 Secret을 환경 변수 또는 파일로 주입하고 `gitlab.rb`가 해당 값을
참조하도록 구성합니다.

### 12.3. 계정 연결 정책

자동 사용자 생성과 기존 사용자 자동 연결은 별도 정책입니다. Email 또는
Username 충돌로 다른 계정이 연결되지 않도록 테스트 계정으로 검증합니다.
로컬 `root` 계정은 비상 복구용으로 유지합니다.

### 12.4. 롤백

OmniAuth 설정을 제거하고 `gitlab-ctl reconfigure` 또는 동일 배포 방식의
재배포를 수행합니다.

## 13. Nexus Repository 연동 판단

Nexus는 Edition과 버전을 먼저 확인해야 합니다.

### 13.1. 공식 네이티브 OIDC

Sonatype의 공식 네이티브 OIDC는 Nexus Repository Pro 3.86 이상에서
지원됩니다. 지원 대상이면 다음 callback을 사용합니다.

```text
<NEXUS_BASE_URL>/oidc/callback
```

Nexus의 OAuth 2.0 설정과 OAuth2 Realm을 활성화하고 `groups` claim을 Nexus
External Role Mapping에 연결합니다.

### 13.2. 지원되지 않는 버전 또는 Community Edition

공식 OIDC를 지원하지 않는 버전 또는 Edition에서는 Keycloak Client만
생성해도 SSO가 동작하지 않습니다. 다음 중 하나를 결정합니다.

1. 로컬 인증을 유지합니다.
2. 지원되는 Nexus Repository Pro 버전으로 업그레이드합니다.
3. Reverse Proxy와 Remote User Token Realm을 별도 보안 설계로 검토합니다.

신뢰 헤더 기반 인증은 Proxy를 우회하여 Nexus에 직접 접근할 수 없어야 하며,
헤더 제거와 재주입을 Proxy 한 곳에서만 수행해야 합니다. 비공식 또는
유지보수되지 않는 인증 플러그인은 표준 폐쇄망 번들에 바로 포함하지 않습니다.

## 14. Secret 관리

- Client마다 다른 Secret을 사용합니다.
- Client Secret을 `values.yaml`, ConfigMap, README, 명령 예시에 기록하지
  않습니다.
- Kubernetes Secret, External Secrets, Vault 등 승인된 저장소를 사용합니다.
- 명령행 인자로 Secret을 전달하면 셸 기록과 프로세스 목록에 남을 수 있습니다.
- Secret 교체 절차를 문서화하고 정기적으로 회전합니다.
- Realm Export에 Secret이 마스킹될 수 있으므로 별도 Secret 백업이 필요합니다.

## 15. 폐쇄망 준비

SSO 연동에 필요한 추가 자산을 외부망에서 함께 준비합니다.

- Jenkins OIDC 플러그인과 모든 의존 플러그인
- CA 인증서와 Truststore 반영 파일
- 점검용 curl 또는 BusyBox 이미지
- 제품 버전에 맞는 Helm Chart 또는 설치 패키지
- 공식 문서의 오프라인 사본

외부망에서 받은 플러그인과 이미지는 Checksum, 출처, 버전을 기록하고 내부
Harbor 또는 승인된 오프라인 저장소로 반입합니다.

## 16. 검증 체크리스트

### 16.1. 기능 검증

- SSO 버튼이 표시됩니다.
- Keycloak 로그인 후 원래 제품으로 돌아옵니다.
- callback URI가 Keycloak Client 설정과 정확히 같습니다.
- Username, Email, 이름이 정상 생성됩니다.
- `groups` claim이 ID Token 또는 UserInfo에 포함됩니다.
- 관리자, 개발자, 조회자 권한이 예상대로 매핑됩니다.
- 권한이 없는 사용자가 관리자 기능에 접근할 수 없습니다.
- 로그아웃과 세션 만료가 예상대로 동작합니다.

### 16.2. 복구 검증

- 기존 로컬 관리자 또는 Escape Hatch로 로그인할 수 있습니다.
- Keycloak 중단 중에도 비상 복구가 가능합니다.
- OIDC 설정 제거 후 이전 인증 방식으로 복원할 수 있습니다.
- Jenkins API Token, Harbor CLI Secret, Robot Account 등 비대화형 인증이
  계속 동작합니다.

### 16.3. 보안 검증

- Wildcard redirect URI가 없습니다.
- Client Secret이 Git과 ConfigMap에 없습니다.
- TLS 인증서 검증이 활성화되어 있습니다.
- 관리자 그룹이 최소 인원에게만 할당되어 있습니다.
- 로그인 성공과 실패 이벤트가 수집됩니다.

## 17. 장애 확인 순서

### 17.1. Redirect URI 오류

브라우저 또는 Keycloak 이벤트의 `redirect_uri`를 복사하여 등록된 값과 문자
단위로 비교합니다. Scheme, Host, Port, Path, 마지막 슬래시를 확인합니다.

### 17.2. Issuer 불일치

OSS에 입력한 issuer와 Discovery 응답의 `issuer`가 정확히 같은지 확인합니다.

```bash
curl -fsS <OIDC_ISSUER>/.well-known/openid-configuration
```

### 17.3. 브라우저만 접속 가능

OSS Pod 또는 서버에서 Keycloak FQDN을 조회하고 Discovery URL을 호출합니다.
실패하면 로컬 PC의 `hosts`가 아니라 서버 측 DNS 또는 NetworkPolicy를
확인합니다.

### 17.4. 로그인은 되지만 권한이 없음

- `groups` Scope가 Client의 Default Scope인지 확인합니다.
- Group Membership Mapper가 ID Token에 claim을 추가하는지 확인합니다.
- 제품의 그룹 이름과 claim 값의 대소문자 및 전체 경로를 비교합니다.
- 제품의 Authorization Strategy 또는 RBAC를 확인합니다.

### 17.5. 사용자 생성 실패

Email, First name, Last name을 확인하고 기존 로컬 사용자와 Username 또는
Email이 충돌하는지 확인합니다.

### 17.6. 인증서 오류

OSS 실행 환경이 Keycloak 인증서의 Root CA와 Intermediate CA를 신뢰하는지
확인합니다. 운영 환경에서 인증서 검증을 끄는 방식으로 해결하지 않습니다.

## 18. 운영 전환 기준

- Keycloak과 모든 OSS 외부 URL에 HTTPS가 적용되어 있습니다.
- 브라우저와 모든 서버가 인증서 Chain을 신뢰합니다.
- Client Secret이 제품별 보안 저장소에 분리되어 있습니다.
- Realm, Client, 그룹, Mapper를 재구성할 백업이 있습니다.
- MFA, 세션 만료, 토큰 수명이 운영 정책에 맞습니다.
- 비상 관리자와 복구 절차가 검증되었습니다.
- SSO 이벤트와 제품 인증 로그를 중앙에서 수집합니다.
- 테스트 계정과 임시 권한이 제거되었습니다.

## 19. 환경별 예제 문서 작성 규칙

범용 가이드를 실제 환경에 적용할 때는 별도 예제 문서를 만들고 다음 정보만
기록합니다.

- 제품 버전과 배포 방식
- 외부 URL과 callback URI
- Namespace와 Secret 이름
- 적용 명령과 롤백 명령
- 검증 결과

Client Secret과 사용자 비밀번호는 예제 문서에 기록하지 않습니다.

현재 로컬 Kind 환경의 구체적인 URL과 제품 버전은
[sso-integration-local-example.md](sso-integration-local-example.md)에서
확인할 수 있습니다.

## 20. 공식 참고 문서

- [Keycloak Server Administration Guide](https://www.keycloak.org/docs/latest/server_admin/)
- [GitLab OpenID Connect](https://docs.gitlab.com/administration/auth/oidc/)
- [Jenkins OpenID Connect Authentication Plugin](https://plugins.jenkins.io/oic-auth)
- [Gitea Authentication](https://docs.gitea.com/administration/authentication)
- [Harbor OIDC Authentication](https://goharbor.io/docs/main/administration/configure-authentication/oidc-auth/)
- [Argo CD Keycloak Integration](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/keycloak/)
- [Sonatype Nexus Repository OpenID Connect](https://help.sonatype.com/en/openid-connect.html)
