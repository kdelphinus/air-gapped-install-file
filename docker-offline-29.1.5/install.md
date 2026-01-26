
### 1. 방법 A: RPM 패키지로 설치 (권장)

**가장 깔끔하고 안정적입니다.** 의존성 문제만 없다면 무조건 이 방법을 쓰세요.

```bash
# 1. rpm 파일이 있는 폴더로 이동
cd ~/docker-offline/rpm

# 2. 폴더 내 모든 rpm 일괄 설치 (의존성 포함)
sudo dnf install ./*.rpm -y

# 3. Docker 실행 및 자동 시작 등록
sudo systemctl enable --now docker

# 4. 상태 확인 (Active: running 확인)
sudo systemctl status docker

```

---

### 2. 방법 B: Static Binary로 설치 (비상용)

RPM 설치가 꼬이거나 실패했을 때만 사용하세요.

```bash
# 1. 파일이 있는 폴더로 이동 및 압축 해제
cd ~/docker-offline/static
tar -xzvf docker-*.tgz

# 2. 실행 파일을 시스템 경로로 복사
sudo cp docker/* /usr/bin/

# 3. Docker 데몬 실행 (백그라운드)
# 주의: 정식 운영 시엔 아까 알려준 docker.service 파일 등록이 필요함
sudo dockerd > /var/log/dockerd.log 2>&1 &

# 4. 버전 확인
docker --version

```

---

### 3. 최종 확인 (공통)

설치가 끝났으면 잘 동작하는지 확인합니다.

```bash
# Docker 버전 및 정보 확인
sudo docker info

# (이미지 로드 테스트) 아까 만든 temurin tar 파일이 있다면
sudo docker load -i temurin-11.tar

```
