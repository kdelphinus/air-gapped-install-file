# Gitea 1.25.5

경량 Git 서버. GitLab 대비 리소스 소모가 적고 단일 바이너리로 동작한다.

## 구성 명세

| 항목 | 값 |
| :--- | :--- |
| Gitea | v1.25.5 |
| Helm Chart | gitea/gitea v12.5.3 |
| Namespace | gitea |
| DB (기본) | SQLite (내장) |
| DB (선택) | PostgreSQL 17.x |
| NodePort HTTP | 30003 |
| NodePort SSH | 30022 |

## 이미지 목록

| 이미지 | 태그 | 파일명 | 필수 |
| :--- | :--- | :--- | :--- |
| `docker.gitea.com/gitea` | `1.25.5` | `gitea.tar` | ✅ |
| `bitnami/postgresql` | `17.x` | `postgresql.tar` | PostgreSQL 선택 시 |

## 디렉토리 구조

```text
gitea-1.25.5/
├── charts/gitea/             # Helm chart v12.5.3 (압축 해제)
├── images/
│   ├── gitea.tar
│   ├── postgresql.tar        # 선택
│   └── upload_images_to_harbor_v3-lite.sh
├── manifests/
│   ├── pv-gitea.yaml
│   └── httproute-gitea.yaml
├── scripts/
│   ├── install.sh
│   └── uninstall.sh
└── values.yaml
```

## 빠른 시작

```bash
# 1. 이미지 Harbor 업로드
./images/upload_images_to_harbor_v3-lite.sh

# 2. 설치
chmod +x scripts/install.sh
./scripts/install.sh
```

자세한 내용은 `install-guide.md` 참조.
