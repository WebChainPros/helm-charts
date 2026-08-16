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

# Auto-fix Windows CRLF line endings if present
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
  --create-namespace \
  "$@"

echo ""
echo "=== Done. Check full-stack pod status: ==="
echo "  kubectl get pods -n ${K8S_NAMESPACE}"
