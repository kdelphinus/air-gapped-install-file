# Docker Engine 29.1.5 오프라인 설치 가이드

폐쇄망 환경에서 Docker Engine 29.1.5를 설치하는 절차를 안내합니다.

## 전제 조건

- Rocky Linux 9.6 (RHEL 계열) 서버
- `rpm/` 또는 `static/` 디렉토리 내 설치 파일이 준비되어 있을 것

## Phase 1: RPM 패키지로 설치 (권장)

가장 안정적인 방법입니다. 의존성 문제가 없다면 이 방법을 사용하세요.

```bash
# 1. rpm 파일이 있는 폴더로 이동
cd ~/docker-offline/rpm

# 2. 폴더 내 모든 rpm 일괄 설치 (의존성 포함)
sudo dnf localinstall -y --disablerepo='*' ./*.rpm

# 3. Docker 실행 및 자동 시작 등록
sudo systemctl enable --now docker

# 4. 상태 확인 (Active: running 확인)
sudo systemctl status docker
```

## Phase 2: Static Binary로 설치 (비상용)

RPM 설치가 실패했을 때만 사용합니다.

```bash
# 1. 파일이 있는 폴더로 이동 및 압축 해제
cd ~/docker-offline/static
tar -xzvf docker-*.tgz

# 2. 실행 파일을 시스템 경로로 복사
sudo cp docker/* /usr/bin/

# 3. Docker 데몬 실행 (백그라운드)
# 주의: 정식 운영 시에는 docker.service 파일 등록이 필요합니다
sudo dockerd > /var/log/dockerd.log 2>&1 &

# 4. 버전 확인
docker --version
```

## Phase 3: 설치 확인

```bash
# Docker 버전 및 정보 확인
sudo docker info

# 이미지 로드 테스트 (tar 파일이 있는 경우)
sudo docker load -i <이미지파일>.tar
```
