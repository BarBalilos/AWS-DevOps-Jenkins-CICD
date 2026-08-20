#!/usr/bin/env bash
# One-time (idempotent) Jenkins cluster-side configuration.
# Run AFTER install-jenkins.sh has installed the base Helm release.
# Applies:
#   1. The JCasC overlay (security realm, Kubernetes cloud, agent pod
#      templates) via a second `helm upgrade` layering values-jcasc.yaml
#      on top of the base values.yaml.
#   2. RBAC for the CI and CD agent ServiceAccounts (least privilege).
#   3. NetworkPolicy for the jenkins namespace (default-deny + scoped
#      controller access) — kept here, not in the app's CD pipeline,
#      since it's Jenkins infra, not an application manifest.
#   4. The jenkins-ecr-credentials Secret, built from a local
#      (gitignored) AWS access-key JSON file — never hardcoded here.
# Safe to re-run at any time to reconcile the cluster back to this
# repo's state.
set -euo pipefail

NAMESPACE="jenkins"
RELEASE="jenkins"
CHART="jenkins/jenkins"
CHART_VERSION="5.9.54"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
VALUES_FILE="${REPO_ROOT}/jenkins/helm/values.yaml"
JCASC_FILE="${REPO_ROOT}/jenkins/helm/values-jcasc.yaml"
ACCESS_KEY_FILE="${REPO_ROOT}/iam/jenkins-ci-ecr-access-key.json"

echo ">> Applying JCasC overlay (security realm, Kubernetes cloud, agent templates)..."
helm upgrade --install "${RELEASE}" "${CHART}" \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  -f "${VALUES_FILE}" \
  -f "${JCASC_FILE}" \
  --wait --timeout=5m

echo ">> Applying RBAC (ci-agent, cd-agent ServiceAccounts + least-privilege bindings)..."
kubectl apply -f "${REPO_ROOT}/rbac/ci-agent-rbac.yaml"
kubectl apply -f "${REPO_ROOT}/rbac/cd-deploy-rbac.yaml"

echo ">> Applying NetworkPolicy (default-deny + scoped controller access)..."
kubectl apply -f "${REPO_ROOT}/network/jenkins-networkpolicy.yaml"

echo ">> Creating/updating jenkins-ecr-credentials Secret..."
if [ ! -f "${ACCESS_KEY_FILE}" ]; then
  echo "!! ${ACCESS_KEY_FILE} not found." >&2
  echo "!! Create it locally (gitignored) with the jenkins-ci-ecr IAM user's" >&2
  echo "!! access key, shaped like raw 'aws iam create-access-key' output:" >&2
  echo "!! {\"AccessKey\": {\"AccessKeyId\": \"...\", \"SecretAccessKey\": \"...\"}}" >&2
  exit 1
fi
AWS_ACCESS_KEY_ID=$(jq -r '.AccessKey.AccessKeyId' "${ACCESS_KEY_FILE}")
AWS_SECRET_ACCESS_KEY=$(jq -r '.AccessKey.SecretAccessKey' "${ACCESS_KEY_FILE}")
if [ "${AWS_ACCESS_KEY_ID}" = "null" ] || [ "${AWS_SECRET_ACCESS_KEY}" = "null" ]; then
  echo "!! Failed to extract AccessKeyId/SecretAccessKey from ${ACCESS_KEY_FILE}." >&2
  echo "!! Check the file's shape matches {\"AccessKey\": {\"AccessKeyId\": ..., \"SecretAccessKey\": ...}}." >&2
  exit 1
fi
kubectl create secret generic jenkins-ecr-credentials \
  --namespace "${NAMESPACE}" \
  --from-literal=aws-access-key-id="${AWS_ACCESS_KEY_ID}" \
  --from-literal=aws-secret-access-key="${AWS_SECRET_ACCESS_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> Done. Jenkins is configured."