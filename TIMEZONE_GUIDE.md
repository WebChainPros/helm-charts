# 🕒 Hyperledger FireFly 쿠버네티스 타임존(KST, UTC+9) 설정 & 트러블슈팅 가이드

본 문서는 **Hyperledger FireFly 코어 및 EVMConnect, Web3Signer 등 쿠버네티스 파드(Pod)의 로그 타임스탬프를 한국 표준시(KST, UTC+9)로 적용**하기 위한 원인 분석, 설정 방법 및 검증 절차를 정리한 가이드입니다.

---

## 📌 1. 증상 및 문제 상황

### 증상
* 쿠버네티스 환경에서 `kubectl logs` 조회 시 실제 한국 시간(예: 오전 9시)과 달리 로그 타임스탬프가 **UTC 기준(00시)**으로 출력되는 현상 발생.
* 컨테이너 환경변수에 `TZ=Asia/Seoul`을 설정하더라도 파드 내부 시간(`date`) 및 앱 로그가 계속 `UTC`로 출력됨.

```text
# 문제 상황 (실제 시간: 오전 09:05:00 KST)
[2026-08-11T00:05:00.123Z] DEBUG evmconnect: RPC[000000010] --> eth_getFilterChanges role=blocklistener
```

---

## 🔍 2. 근본 원인 분석 (Root Cause)

1. **타임존 데이터 파일 미비 (Fallback to UTC)**
   * Alpine 및 Distroless 기반 경량 Docker 이미지에는 `/etc/localtime` 및 `/usr/share/zoneinfo` 타임존 DB 파일이 포함되어 있지 않거나 마운트되어 있지 않습니다.
   * 이에 따라 컨테이너 OS 및 Go 언어의 `time.Now()`가 `Asia/Seoul` 시간대 데이터를 로드하지 못하고 **자동으로 UTC로 복구(Fallback)**됩니다.

2. **FireFly 기본 로거 포맷 (`Z07:00`)**
   * FireFly 공통 로거 모듈(`firefly-common`)의 `LogTimeFormat` 기본값은 `"2006-01-02T15:04:05.000Z07:00"`으로 설정되어 있습니다.
   * Go 시간 포맷 명세상 `Z07:00` 서식은 시간대가 UTC일 경우 `Z`로 표시되고, KST일 경우 `+09:00`으로 표시됩니다.

---

## 🛠️ 3. 단계별 설정 가이드 (Solution)

### Step 1. Dockerfile 기본 타임존 환경변수 지정
* `Dockerfile.custom`의 실행(Runtime) 스테이지에 `TZ=Asia/Seoul` 환경 변수를 지정합니다.

```dockerfile
FROM alpine:3.21.3
WORKDIR /evmconnect
RUN addgroup -g 1001 evmgroup && adduser -D -u 1001 -G evmgroup evmuser
RUN chgrp -R 0 /evmconnect && chmod -R g+rwX /evmconnect
RUN apk add --no-cache curl jq
ENV TZ=Asia/Seoul
```

---

### Step 2. Helm 차트 템플릿 호스트 타임존 마운트 (`hostPath`)
쿠버네티스 노드(Host)의 `/etc/localtime` 및 `/usr/share/zoneinfo`를 파드 내부에 읽기 전용(`readOnly: true`)으로 마운트합니다.

대상 파일:
* `charts/firefly/templates/core/statefulset.yaml`
* `charts/firefly/templates/ethconnect/statefulset.yaml`
* `charts/firefly-evmconnect/templates/statefulset.yaml`

#### 템플릿 수정 내용 (`volumeMounts` & `volumes`):
```yaml
spec:
  template:
    spec:
      containers:
        - name: evmconnect
          volumeMounts:
            - mountPath: /etc/localtime
              name: tz-config
              readOnly: true
            - mountPath: /usr/share/zoneinfo
              name: tz-data
              readOnly: true

      volumes:
        - name: tz-config
          hostPath:
            path: /etc/localtime
        - name: tz-data
          hostPath:
            path: /usr/share/zoneinfo
```

---

### Step 3. Helm Values 및 Manifests 로그 서식 구성

`values/custom-fullstack-values.yaml` 및 `manifests/multichain.yaml` 파일에 `log.utc: false`, `log.timeFormat`, 그리고 각 서비스별 `TZ` 환경변수를 등록합니다.

#### 1) `values/custom-fullstack-values.yaml`
```yaml
# FireFly Core
core:
  extraEnv:
    - name: TZ
      value: "Asia/Seoul"

config:
  templateOverride: |
    log:
      level: debug
      utc: false
      timeFormat: "2006-01-02T15:04:05.000-07:00"

# EVMConnect
ethconnect:
  extraEnv:
    - name: TZ
      value: "Asia/Seoul"

evmconnect:
  enabled: true
  extraEnv:
    - name: TZ
      value: "Asia/Seoul"
  config:
    log:
      level: debug
      utc: false
      timeFormat: "2006-01-02T15:04:05.000-07:00"

# PostgreSQL / ERC20-721 / Sandbox
postgresql:
  extraEnv:
    - name: TZ
      value: "Asia/Seoul"

erc20erc721:
  extraEnv:
    - name: TZ
      value: "Asia/Seoul"

sandbox:
  extraEnv:
    - name: TZ
      value: "Asia/Seoul"
```

#### 2) `manifests/multichain.yaml` (Amoy & Sepolia 파드용)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: evmconnect-amoy-config
  namespace: firefly
data:
  config.yaml: |
    log:
      level: debug
      utc: false
      timeFormat: "2006-01-02T15:04:05.000-07:00"
```

---

### Step 4. 배포 및 롤아웃 리스타트 실행

수정된 Helm 차트와 매니페스트를 적용하고 파드를 재시작합니다.

```bash
cd /home/joon/firefly/helm-charts

# 1. 헬름 차트 업그레이드 배포
./deploy.sh

# 2. 멀티체인 매니페스트 적용
kubectl apply -f manifests/multichain.yaml

# 3. 파드 롤링 리스타트
kubectl rollout restart statefulset -n firefly
kubectl rollout restart deployment -n firefly
```

---

## ✅ 4. 검증 및 결과 확인

### 1) 파드 내부 시계(`date`) 검증
```bash
kubectl exec firefly-evmconnect-0 -n firefly -- date
```
* **정상 결과**: `Tue Aug 11 09:06:35 KST 2026` (KST 출력)

### 2) 파드 로그 타임스탬프 검증
```bash
kubectl logs statefulset/firefly-evmconnect -n firefly --tail 10
```
* **정상 결과**: `[2026-08-11T09:06:35.159+09:00]` (`+09:00` 오프셋 반영)

```text
[2026-08-11T09:06:35.159+09:00]  INFO evmconnect: RPC[000000013] <-- eth_getFilterChanges [200] OK (6.73ms) role=blocklistener
```

---

## 💡 요약 및 체크리스트

| 체크 항목 | 설정 방법 |
|---|---|
| **컨테이너 TZ 환경변수** | `TZ=Asia/Seoul` 지정 |
| **호스트 타임존 DB 마운트** | `/etc/localtime` 및 `/usr/share/zoneinfo` `hostPath` 마운트 |
| **FireFly 로거 설정** | `log.utc: false`, `log.timeFormat: "2006-01-02T15:04:05.000-07:00"` 지정 |
