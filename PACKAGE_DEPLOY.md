# 🚀 FireFly 멀티체인 풀스택 쿠버네티스(Helm) 패키지 배포 & 운영 가이드

본 문서는 **Hyperledger FireFly 메인넷(Meta-net), Polygon Amoy, Ethereum Sepolia** 3개 멀티체인 아키텍처를 쿠버네티스(Helm) 기반으로 설치, 실행, 종료, 로그 분석 및 포트/UI 모니터링하는 전체 운영 프로세스를 설명합니다.

---

## 🏗️ 1. 아키텍처 개요

본 풀스택 패키지는 다음과 같은 고성능 튜닝 및 멀티체인 컴포넌트로 구성되어 있습니다:

- **FireFly Core Engine (`firefly-0`)**: 3개 체인(`eth0`, `eth-amoy`, `eth-sepolia`) 및 3개 네임스페이스(`meta`, `amoy`, `sepolia`) 통합 관리
- **PostgreSQL Database (`firefly-postgres`)**: 고성능 튜닝 파라미터 적용 (`synchronous_commit=off`, `fsync=off`, `max_connections=400` 등) 및 `evm0`, `evm_amoy`, `evm_sepolia` 스키마 데이터 영속화
- **Web3Signer 서비스 (3종)**:
  - `firefly-evmconnect-web3signer` (Meta-net: Chain ID `202607`)
  - `web3signer-amoy` (Polygon Amoy: Chain ID `80002`)
  - `web3signer-sepolia` (Ethereum Sepolia: Chain ID `11155111`)
  - 모든 서명기 파드는 K8s Secret(`web3signer-keystores`, `web3signer-passwords`)으로 암호화 키 마운트 및 Vertx/JVM 고속 튜닝(`WEB3SIGNER_OPTS`) 적용
- **EVMConnect 블록체인 커넥터 (3종)**:
  - `firefly-evmconnect-0` (Meta-net)
  - `evmconnect-amoy` (Polygon Amoy)
  - `evmconnect-sepolia` (Ethereum Sepolia)
- **ERC20/ERC721 토큰 커넥터 (3종)**: `firefly-erc20-erc721`, `tokens-amoy`, `tokens-sepolia`
- **통합 Nginx 프록시 (`firefly-ui-proxy`)**: 5000번 포트로 대시보드 UI (`/ui`)와 REST API (`/api`) 통합 라우팅
- **모니터링 풀스택 (Prometheus + Grafana + Postgres Exporter)**: 포트 9090 (Prometheus), 포트 3300 (Grafana UI), 포트 9187 (Postgres Exporter)

### 1.1 매니페스트 분리 배포 구조 및 구성 이유

본 패키지는 메인 헬름 차트(`charts/firefly`)와 확장 매니페스트(`manifests/`)로 이원화되어 배포됩니다:

* **메인 헬름 차트 (`./deploy.sh`)**: FireFly Core 엔진, Meta-net EVMConnect/Web3Signer 및 PostgreSQL DB 관리
* **확장 매니페스트 (`manifests/`)**: 멀티체인 확장 파드(`multichain.yaml`), UI 프록시(`ui-proxy.yaml`), 모니터링 스택(`monitoring.yaml`) 관리

**💡 매니페스트를 분리 구성한 이유**:
1. **기본 헬름 차트의 구조적 한계 극복**: 공식 FireFly 헬름 차트는 단일 체인 전용이므로, 기존 메인 차트를 건드리지 않고 Polygon Amoy 및 Ethereum Sepolia용 파드 6개를 애드온(Add-on) 형태로 유연하게 연동하기 위함입니다.
2. **통합 Nginx UI 프록시 (`firefly-ui-proxy`)의 독립성**: 5000번 단일 포트로 대시보드 UI(`/ui`)와 REST API(`/api`)를 동시 라우팅하는 게이트웨이 파드로, 코어 엔진과 독립적으로 동작하도록 구성되었습니다.
3. **모듈화 및 운용 유연성**: 모니터링 인프라 및 체인별 컴포넌트를 필요에 따라 독립적으로 개별 컨트롤(추가/삭제/업데이트)이 가능합니다.

---

## 🔑 2. 사전 준비 사항 (키스토어 Secret 생성)

배포 전, 서명에 필요한 keystores 및 passwords 파일들을 쿠버네티스 Secret으로 미리 등록합니다:

```bash
# 1. 기존 Secret 정리 (필요시)
kubectl delete secret web3signer-keystores web3signer-passwords -n firefly --ignore-not-found

# 2. 로컬 키스토어 및 암호 디렉토리를 K8s Secret으로 생성
kubectl create secret generic web3signer-keystores \
  --from-file=/home/joon/.firefly/web3signer-bulk/keystores -n firefly

kubectl create secret generic web3signer-passwords \
  --from-file=/home/joon/.firefly/web3signer-bulk/passwords -n firefly
```

---

## 🚀 3. 전체 배포 및 실행 프로세스

### 3.1 원스톱 자동 배포 (Meta-net 코어 풀스택 + UI Proxy + Monitoring 🚀)

`./deploy.sh` 스크립트 하나로 **Core 엔진, EVMConnect, DB, Web3Signer Secret 생성, UI Proxy, 모니터링 스택까지 한 번에 자동 배포**됩니다:

```bash
# 1. 템플릿 복사 (최초 1회)
cp values/.env.example values/.env

# 2. 원라인 풀스택 배포 (끝!)
./deploy.sh

# 3. 5500번 포트 포워딩 실행
nohup kubectl port-forward svc/firefly-ui-proxy 5500:5000 -n firefly --address 0.0.0.0 > /dev/null 2>&1 &
```

👉 **대시보드 접속**: [http://127.0.0.1:5500/ui/](http://127.0.0.1:5500/ui/)

---

### 3.2 멀티체인 풀스택 배포 (Meta-net + Amoy + Sepolia 🚀)

FireFly 코어 엔진 설정(`firefly-config`)에 등록된 `meta`, `amoy`, `sepolia` 3개 멀티체인 전체를 연결하려면 `./deploy.sh` 실행 후 `multichain.yaml`만 추가 적용합니다:

```bash
./deploy.sh
kubectl apply -f manifests/multichain.yaml
```

---

### 3.3 🎨 커스텀 Explorer UI 개발 및 GHCR 배포 원칙

* **일상 배포**: `manifests/ui-proxy.yaml`이 원격 컨테이너 저장소(`ghcr.io/webchainpro-cpu/firefly-custom-ui:v11`)를 참조하므로, **UI 소스코드 빌드 없이 즉시 배포**됩니다.
* **UI 소스코드 수정 시**: React 컴포넌트(`ui/src/pages/Home/views/BlockchainSync.tsx` 등)를 새로 개발/수정했을 때만 도커 멀티스테이지 빌드 후 GHCR로 푸시합니다:

```bash
# UI 빌드 및 GHCR 푸시
cd /Users/joon/workspaces/firefly/ui
docker build -t ghcr.io/webchainpro-cpu/firefly-custom-ui:v11 -f - . << 'EOF'
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install --legacy-peer-deps
COPY . .
ENV DISABLE_ESLINT_PLUGIN=true
RUN npm run build
FROM nginx:alpine
RUN rm -rf /usr/share/nginx/html/*
COPY --from=builder /app/build /usr/share/nginx/html
COPY --from=builder /app/build /usr/share/nginx/html/ui
EOF
docker push ghcr.io/webchainpro-cpu/firefly-custom-ui:v11

# 파드 롤아웃 리스타트
cd /Users/joon/workspaces/helm-charts
kubectl rollout restart deploy/firefly-ui-proxy -n firefly
```

---

### 3.4 🔄 PC / 도커 데스크탑 재부팅 후 일상적인 재기동 순서 (Daily Resume Guide)

PC 및 도커 데스크탑을 재부팅한 경우 아래 순서로 빠르게 서비스를 복구합니다:

```bash
# STEP 1. 네임스페이스 내 모든 파드 일괄 순차 재시작 (깔끔한 재기동)
kubectl rollout restart deployment,statefulset -n firefly

# STEP 2. 모든 파드가 Running (READY 1/1) 상태인지 확인
kubectl get pods -n firefly -w

# STEP 3. 5500 포트 포워딩 실행
nohup kubectl port-forward svc/firefly-ui-proxy 5500:5000 -n firefly --address 0.0.0.0 > /dev/null 2>&1 &
```

---

## 🛑 4. 전체 컨테이너/파드 종료 및 삭제 방법

### 4.1 일시적 전체 재시작 (Rollout Restart)

설정 변경 후 네임스페이스 내의 모든 워크로드(StatefulSet 및 Deployment)를 순차적으로 완전 재시작합니다:

```bash
# 네임스페이스 내 모든 Deployment 및 StatefulSet 재시작
kubectl rollout restart deployment,statefulset -n firefly

# (참고) 특정 StatefulSet/파드만 직접 재시작할 경우
# kubectl rollout restart statefulset -n firefly
# kubectl delete pod firefly-0 firefly-evmconnect-0 -n firefly
```

### 4.2 전체 헬름 패키지 완전 종료 및 깨끗한 삭제 (Clean Uninstall)

모든 데이터 및 파드를 깨끗하게 삭제하여 클러스터를 처음 상태로 되돌립니다:

```bash
cd /home/joon/firefly/helm-charts

# 1. 헬름 릴리즈 삭제
helm uninstall firefly -n firefly

# 2. 추가 멀티체인, UI 프록시 & 모니터링 매니페스트 및 Secret 삭제
kubectl delete -f manifests/multichain.yaml --ignore-not-found
kubectl delete -f manifests/ui-proxy.yaml --ignore-not-found
kubectl delete -f manifests/monitoring.yaml --ignore-not-found
kubectl delete secret web3signer-keystores web3signer-passwords -n firefly --ignore-not-found

# 3. 네임스페이스 리소스 전체 확인
kubectl get all -n firefly
```

### 4.3 완전 삭제 후 처음부터 완벽 재배포 (Clean Redeploy Process)

기존 배포를 흔적 없이 완전 삭제하고 처음부터 100% 자동 재배포하는 원스톱 순서입니다:

```bash
# STEP 1. 작업 디렉토리 이동
cd /home/joon/firefly/helm-charts

# STEP 2. 기존 풀스택 완전 삭제
helm uninstall firefly -n firefly --ignore-not-found
kubectl delete -f manifests/multichain.yaml --ignore-not-found
kubectl delete -f manifests/ui-proxy.yaml --ignore-not-found
kubectl delete -f manifests/monitoring.yaml --ignore-not-found
kubectl delete secret web3signer-keystores web3signer-passwords -n firefly --ignore-not-found

# STEP 3. 원스톱 자동 재배포 (Secret 생성, 헬름 배포, UI Proxy, 모니터링 자동 실행)
./deploy.sh

# STEP 4. (선택) 멀티체인 확장 파드 적용
kubectl apply -f manifests/multichain.yaml

# STEP 5. 5500번 포트 포워딩 실행
nohup kubectl port-forward svc/firefly-ui-proxy 5500:5000 -n firefly --address 0.0.0.0 > /dev/null 2>&1 &
```

---

## 📊 5. 로그 추출 및 실시간 트러블슈팅 가이드

기존 `docker logs -f 컨테이너이름` 대신 **`kubectl logs`** 명령어를 사용합니다.

### 5.1 각 컴포넌트별 로그 확인 명령어

- **FireFly Core 메인 엔진 로그**:
  ```bash
  kubectl logs -f firefly-0 -n firefly
  ```

- **Meta-net EVMConnect 커넥터 로그**:
  ```bash
  kubectl logs -f firefly-evmconnect-0 -n firefly
  ```

- **Meta-net Web3Signer 서명기 로그**:
  ```bash
  kubectl logs -f deploy/firefly-evmconnect-web3signer -n firefly
  ```

- **Polygon Amoy EVMConnect 로그**:
  ```bash
  kubectl logs -f deploy/evmconnect-amoy -n firefly
  ```

- **Ethereum Sepolia EVMConnect 로그**:
  ```bash
  kubectl logs -f deploy/evmconnect-sepolia -n firefly
  ```

- **PostgreSQL 데이터베이스 로그**:
  ```bash
  kubectl logs -f deploy/firefly-postgres -n firefly
  ```

### 5.2 장애발생 시 과거 직전 로그(CrashLog) 확인

컨테이너가 종료 후 재시작(BackOff) 되었을 때는 `-p` (previous) 옵션을 붙여서 직전 오류 원인을 확인합니다:

```bash
kubectl logs firefly-evmconnect-web3signer-7f86cd856-gjbh8 -n firefly -p
```

### 5.3 ⚠️ 자주 발생하는 트러블슈팅 (포트 포워딩 및 미배포 에러)

1. **`Error from server (NotFound): services "..." not found`**
   - **원인**: FireFly 메인 헬름 차트 또는 확장 매니페스트(`monitoring.yaml` 등)가 클러스터에 배포되지 않아 서비스가 존재하지 않는 상태입니다.
   - **해결**: [4.3 완전 삭제 후 처음부터 완벽 재배포 Process](#43-완전-삭제-후-처음부터-완벽-재배포-clean-redeploy-process)를 수행하여 `./deploy.sh` 및 `kubectl apply`를 재배포하세요.

2. **`error: unable to forward port because pod is not running. Current status=Pending` (또는 `ContainerCreating`)**
   - **원인**: 대상 파드가 아직 생성 중이거나 준비 단계(`ContainerCreating` / `Pending`)라서 포트 포워딩 연결을 맺을 수 없습니다.
   - **해결**: `kubectl get pods -n firefly -w` 명령어로 모든 파드가 **`Running` (READY 1/1 또는 2/2)** 상태가 되는 것을 확인한 후 포트 포워딩을 재실행하세요.

---

## 🌐 6. 포트 포워딩 및 UI / 모니터링 접속

### 6.1 백그라운드 포트 포워딩 실행 (5500번 포트 표준)

> 💡 **안내 (macOS AirPlay 5000번 포트 충돌 방지)**: macOS에서는 AirPlay 수신 모드(AirTunes)가 5000번 포트를 점유하고 있어 충돌(403 Forbidden)이 발생하므로, UI 프록시 포워딩 시 **5500번 포트(`5500:5000`)를 표준으로 사용**합니다.

```bash
# 1. 5109 포트 (기존 dev_15 Sandbox Explorer UI 전용)
kubectl port-forward svc/firefly-sandbox 5109:3001 -n firefly --address 0.0.0.0 &

# 2. 5500 포트 (통합 Nginx 프록시 - UI 및 API 겸용 표준 포트)
kubectl port-forward svc/firefly-ui-proxy 5500:5000 -n firefly --address 0.0.0.0 &

# 3. 3300 포트 (Grafana 실시간 그래픽 대시보드 UI)
kubectl port-forward svc/grafana 3300:3000 -n firefly --address 0.0.0.0 &

# 4. 9090 포트 (Prometheus 메트릭 타겟 대시보드)
kubectl port-forward svc/prometheus 9090:9090 -n firefly --address 0.0.0.0 &
```

### 6.2 브라우저 접속 주소 목록

| 용도 | 접속 주소 (URL) | 설명 / 로그인 |
| :--- | :--- | :--- |
| **통합 Custom Explorer 대시보드 UI** | `http://127.0.0.1:5500/ui` | Nginx 프록시 기반 대시보드 화면 |
| **FireFly Swagger API 문서** | `http://127.0.0.1:5500/api` | REST API 대화형 Swagger 문서 |
| **Explorer 대시보드 UI (Sandbox)** | `http://127.0.0.1:5109` | 기존 `ff start` 개발환경과 100% 동일한 대시보드 |
| **Grafana 그래픽 대시보드** | `http://127.0.0.1:3300` | ID: `admin` / PW: `admin` (시스템 TPS & DB 모니터링) |
| **Prometheus 메트릭 타겟** | `http://127.0.0.1:9090` | Prometheus 메트릭 수집 현황 수집기 |

---

## 🛠️ 7. 유용한 운영/검증 팁 (실제 배포 상태 및 설정 확인)

### 7.1 현재 떠 있는 Pod들의 실제 컨테이너 이미지 확인
클러스터에 실행 중인 각 파드가 실제로 어떤 컨테이너 이미지를 바라보고 있는지 확인합니다:

```bash
kubectl get pods -n firefly -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[*].image'
```
> 💡 **확인 팁**: `firefly-evmconnect-0`이 `ghcr.io/webchainpro-cpu/evmconnect:head` 커스텀 이미지를 정상적으로 사용 중인지 확인할 수 있습니다.

### 7.2 Helm이 렌더링해서 배포한 전체 Kubernetes 매니페스트 확인
Helm이 템플릿을 렌더링하여 클러스터에 실제 배포한 최종 Kubernetes 매니페스트(StatefulSet, Deployment, Service, Secret 등) 전체를 확인합니다:

```bash
helm get manifest firefly -n firefly
```

### 7.3 실제 배포에 적용된 사용자 Helm Values 확인
배포 시점에 실제로 주입되어 클러스터에 저장된 최종 `values` 설정을 확인합니다:

```bash
helm get values firefly -n firefly
```

### 7.4 Base64 설정 원본 디코딩해서 꺼내보기
쿠버네티스 Secret 내부에 암호화 저장된 설정 원본을 직접 사람이 읽을 수 있는 평문 YAML로 꺼내는 법:

```bash
# Core 설정 원본 디코딩
kubectl get secret firefly-config -n firefly -o jsonpath='{.data.firefly\.core}' | base64 --decode

# EVMConnect 설정 원본 디코딩
kubectl get secret firefly-evmconnect-config -n firefly -o jsonpath='{.data.config\.yaml}' | base64 --decode
```

---

## 📌 관련 참고 문서
- [운영모니터링.md](file://wsl.localhost/Ubuntu/home/joon/firefly/helm-charts/%EC%9A%B4%EC%98%81%EB%AA%A8%EB%8B%88%ED%84%B0%EB%A7%81.md): 펜딩 트랜잭션 추적, 논스 동기화, Policy Loop 및 DB/API 병목 분석을 위한 운영 모니터링 명령어 가이드
