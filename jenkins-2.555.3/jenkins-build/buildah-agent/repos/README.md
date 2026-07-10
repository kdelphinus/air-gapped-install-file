# Buildah Agent 추가 RPM Repository

JDK 17 등 기본 Buildah base image repository에 없는 패키지가 필요하면 이 디렉터리에 사내 `.repo` 파일을 추가합니다.

빌드 시 Dockerfile이 `*.repo` 파일을 `/etc/yum.repos.d/`로 복사한 뒤 `dnf install`을 실행합니다.

예시 파일명:

```text
internal-jdk17.repo
```
