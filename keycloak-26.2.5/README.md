# Keycloak 26.2.5

폐쇄망 Kubernetes 환경에서 GitLab, Nexus, Jenkins 등 OSS의 OIDC 기반 SSO를 검증하기 위한 Keycloak 번들입니다.

## 구성

| 구성 요소 | 버전 | 용도 |
| --- | --- | --- |
| Keycloak | 26.2.5 | OIDC Identity Provider |
| PostgreSQL | 16.9 | Keycloak 영속 데이터베이스 |
| Envoy HTTPRoute | 기존 클러스터 구성 | Keycloak FQDN 외부 노출 |

## 보안 원칙

- 관리자 및 DB 비밀번호는 `keycloak/keycloak-credentials` Secret에만 저장됩니다.
- `install.conf`에는 접속 정보와 스토리지 설정만 저장됩니다.
- 테스트 환경에서도 HTTPRoute에는 TLS 리스너를 사용해야 합니다. OIDC 클라이언트의 redirect URI와 issuer는 HTTPS FQDN으로 고정해야 합니다.

## SSO 테스트 순서

1. Keycloak을 설치하고 `oss` Realm을 생성합니다.
2. GitLab, Nexus, Jenkins에 각각 Confidential OIDC Client를 생성합니다.
3. 각 OSS의 redirect URI와 Keycloak Client의 Valid redirect URIs를 정확히 일치시킵니다.
4. Keycloak 사용자로 각 OSS 로그인을 검증합니다.

상세 설치 및 수동 절차는 [install-guide.md](install-guide.md)를 참고하십시오.
