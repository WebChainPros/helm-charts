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

### 3.1 자동으로 배포하기 (`deploy.sh`)

`deploy.sh` 스크립트를 실행하면 헬름 패키지 종속성을 갱신하고 멀티체인 풀스택 전체가 자동으로 쿠버네티스 클러스터에 배포됩니다.

```bash
cd /home/joon/firefly/helm-charts
bash deploy.sh
```

### 3.2 멀티체인 파드 서비스 및 모니터링 적용 (Amoy / Sepolia / Prometheus / Grafana)

```bash
python3 /mnt/c/Users/kwanj/.gemini/antigravity-ide/brain/7ea86661-d66f-4335-bbc2-92bee23da781/scratch/apply_100pct_multichain_yaml.py
kubectl apply -f /tmp/multichain.yaml

python3 /mnt/c/Users/kwanj/.gemini/antigravity-ide/brain/7ea86661-d66f-4335-bbc2-92bee23da781/scratch/apply_monitoring_stack.py
kubectl apply -f /tmp/monitoring.yaml
```

---

## 🛑 4. 전체 컨테이너/파드 종료 및 삭제 방법

### 4.1 일시적 전체 재시작 (Rollout Restart)

설정 변경 후 컨테이너들을 완전히 재시작하고 싶을 때 사용합니다:

```bash
kubectl rollout restart deployment -n firefly
kubectl delete pod firefly-0 firefly-evmconnect-0 -n firefly
```

### 4.2 전체 헬름 패키지 완전 종료 및 깨끗한 삭제 (Clean Uninstall)

모든 데이터 및 파드를 깨끗하게 삭제하여 클러스터를 처음 상태로 되돌립니다:

```bash
# 1. 헬름 릴리즈 삭제
helm uninstall firefly -n firefly

# 2. 추가 멀티체인 & 모니터링 매니페스트 및 Secret 삭제
kubectl delete -f /tmp/multichain.yaml --ignore-not-found
kubectl delete -f /tmp/monitoring.yaml --ignore-not-found
kubectl delete secret web3signer-keystores web3signer-passwords -n firefly --ignore-not-found

# 3. 네임스페이스 리소스 전체 확인
kubectl get all -n firefly
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

---

## 🌐 6. 포트 포워딩 및 UI / 모니터링 접속

### 6.1 백그라운드 포트 포워딩 실행

```bash
# 1. 5109 포트 (기존 dev_15 Sandbox Explorer UI 전용)
kubectl port-forward svc/firefly-sandbox 5109:3001 -n firefly --address 0.0.0.0 &

# 2. 5000 포트 (통합 Nginx 프록시 - UI 및 API 겸용)
kubectl port-forward svc/firefly-ui-proxy 5000:5000 -n firefly --address 0.0.0.0 &

# 3. 3300 포트 (Grafana 실시간 그래픽 대시보드 UI)
kubectl port-forward svc/grafana 3300:3000 -n firefly --address 0.0.0.0 &

# 4. 9090 포트 (Prometheus 메트릭 타겟 대시보드)
kubectl port-forward svc/prometheus 9090:9090 -n firefly --address 0.0.0.0 &
```

### 6.2 브라우저 접속 주소 목록

| 용도 | 접속 주소 (URL) | 설명 / 로그인 |
| :--- | :--- | :--- |
| **Explorer 대시보드 UI (dev_15 동일)** | `http://127.0.0.1:5109` | 기존 `ff start` 개발환경과 100% 동일한 대시보드 |
| **통합 Explorer 대시보드 UI** | `http://127.0.0.1:5000/ui` | Nginx 프록시 기반 대시보드 화면 |
| **FireFly Swagger API 문서** | `http://127.0.0.1:5000/api` | REST API 대화형 Swagger 문서 |
| **Grafana 그래픽 대시보드** | `http://127.0.0.1:3300` | ID: `admin` / PW: `admin` (시스템 TPS & DB 모니터링) |
| **Prometheus 메트릭 타겟** | `http://127.0.0.1:9090` | Prometheus 메트릭 수집 현황 수집기 |

---

## 🛠️ 7. 팁: Base64 설정 원본 디코딩해서 꺼내보기

쿠버네티스 메모리 내부에 암호화 저장된 설정 원본을 직접 사람이 읽을 수 있는 평문 YAML로 꺼내는 법:

```bash
# Core 설정 원본 디코딩
kubectl get secret firefly-config -n firefly -o jsonpath='{.data.firefly\.core}' | base64 --decode

# EVMConnect 설정 원본 디코딩
kubectl get secret firefly-evmconnect-config -n firefly -o jsonpath='{.data.config\.yaml}' | base64 --decode
```
