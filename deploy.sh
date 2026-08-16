#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/values/.env"

# .env 로드
if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: ${ENV_FILE} not found."
  echo "  Copy values/.env.example to values/.env and fill in actual values."
  exit 1
fi

# Auto-fix Windows CRLF line endings if present (macOS BSD sed & Linux GNU sed compatible)
sed -i '' -e 's/\r$//' "${ENV_FILE}" 2>/dev/null || sed -i -e 's/\r$//' "${ENV_FILE}" 2>/dev/null || true

set -a
source "${ENV_FILE}"
set +a

echo "=== Deploying FireFly Full-Stack (Core + Custom EVMConnect + Web3Signer) ==="
echo "  BESU_EXTERNAL_HOST : ${BESU_EXTERNAL_HOST}"
echo "  METANET_CHAIN_ID   : ${METANET_CHAIN_ID}"
echo "  GHCR_IMAGE_TAG     : ${GHCR_IMAGE_TAG}"
echo "  K8S_NAMESPACE      : ${K8S_NAMESPACE}"
echo ""

# 네임스페이스 생성 (미존재 시)
kubectl create namespace "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 서명기 키스토어 Secret 자동 등록 (로컬에 키가 존재하고 시크릿이 없을 경우)
if ! kubectl get secret web3signer-keystores -n "${K8S_NAMESPACE}" >/dev/null 2>&1; then
  if [ -d "${HOME}/.firefly/web3signer-bulk/keystores" ] && [ -d "${HOME}/.firefly/web3signer-bulk/passwords" ]; then
    echo "Creating Web3Signer secrets in namespace '${K8S_NAMESPACE}'..."
    kubectl create secret generic web3signer-keystores \
      --from-file="${HOME}/.firefly/web3signer-bulk/keystores" -n "${K8S_NAMESPACE}" || true
    kubectl create secret generic web3signer-passwords \
      --from-file="${HOME}/.firefly/web3signer-bulk/passwords" -n "${K8S_NAMESPACE}" || true
  fi
fi

# 의존성 모듈 로컬 동기화
helm dependency update "${SCRIPT_DIR}/charts/firefly"

# 메인 풀스택 차트 배포
helm upgrade --install firefly "${SCRIPT_DIR}/charts/firefly" \
  -f "${SCRIPT_DIR}/values/custom-fullstack-values.yaml" \
  --set "evmconnect.config.jsonRpcUrl=http://${BESU_EXTERNAL_HOST}:8545" \
  --set "evmconnect.web3signer.chainId=${METANET_CHAIN_ID}" \
  --set "evmconnect.web3signer.downstreamHttpHost=${BESU_EXTERNAL_HOST}" \
  --set "evmconnect.image.tag=${GHCR_IMAGE_TAG}" \
  --namespace "${K8S_NAMESPACE}" \
  "$@"

# 확장 매니페스트 자동 적용 (UI Proxy & Monitoring)
if [ -f "${SCRIPT_DIR}/manifests/ui-proxy.yaml" ]; then
  echo ""
  echo "=== Applying UI Proxy Manifest ==="
  kubectl apply -f "${SCRIPT_DIR}/manifests/ui-proxy.yaml"
fi

if [ -f "${SCRIPT_DIR}/manifests/monitoring.yaml" ]; then
  echo ""
  echo "=== Applying Monitoring Stack Manifest ==="
  kubectl apply -f "${SCRIPT_DIR}/manifests/monitoring.yaml"
fi

echo ""
echo "=== 🚀 All Components Successfully Deployed! ==="
echo "1. Check Pod status:"
echo "   kubectl get pods -n ${K8S_NAMESPACE}"
echo ""
echo "2. Run Port-Forwarding (5500 port for UI & API):"
echo "   nohup kubectl port-forward svc/firefly-ui-proxy 5500:5000 -n ${K8S_NAMESPACE} --address 0.0.0.0 > /dev/null 2>&1 &"
echo "   👉 Access Explorer UI: http://127.0.0.1:5500/ui/"
echo "   👉 Access Core API   : http://127.0.0.1:5500/api/v1/status"
