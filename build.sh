#!/usr/bin/env bash
# Build a custom Outline image and deploy it to the outline-dev namespace.
# Usage: ./build.sh [tag]   (default tag: latest)
set -euo pipefail

IMAGE_NAME="outline-custom"
IMAGE_TAG="${1:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
K3S_SOCK="/run/k3s/containerd/containerd.sock"
NERDCTL="nerdctl --address ${K3S_SOCK} --namespace k8s.io"
WORKER_NODES=(node2 node3 node4)
K8S_NS="outline-dev"
DEPLOY="outline-dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Building ${FULL_IMAGE} ..."
${NERDCTL} build \
  --file "${SCRIPT_DIR}/Dockerfile.custom" \
  --tag  "${FULL_IMAGE}" \
  "${SCRIPT_DIR}"

echo "==> Exporting image ..."
TMP_TAR="/tmp/${IMAGE_NAME}-${IMAGE_TAG}.tar"
${NERDCTL} save "${FULL_IMAGE}" -o "${TMP_TAR}"

echo "==> Distributing to worker nodes ..."
for NODE in "${WORKER_NODES[@]}"; do
  echo "    -> ${NODE}"
  scp -q "${TMP_TAR}" "${NODE}:${TMP_TAR}"
  ssh "${NODE}" "nerdctl --address ${K3S_SOCK} --namespace k8s.io load -i ${TMP_TAR} && rm ${TMP_TAR}"
done
rm "${TMP_TAR}"

echo "==> Updating deployment ..."
kubectl -n "${K8S_NS}" set image deployment/"${DEPLOY}" outline="${FULL_IMAGE}"
kubectl -n "${K8S_NS}" patch deployment "${DEPLOY}" \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"outline","imagePullPolicy":"IfNotPresent"}]}}}}'
kubectl -n "${K8S_NS}" rollout restart deployment/"${DEPLOY}"
kubectl -n "${K8S_NS}" rollout status deployment/"${DEPLOY}" --timeout=300s

echo "==> Health check ..."
if curl -sf "https://dev.gabouchieno.com/_health" | grep -q "OK"; then
  echo "    OK — https://dev.gabouchieno.com is healthy"
else
  echo "    WARNING: health check failed"
  echo "    kubectl -n ${K8S_NS} logs -l app=${DEPLOY} --tail=50"
  exit 1
fi

echo "==> Done!  ${FULL_IMAGE} is live at https://dev.gabouchieno.com"
