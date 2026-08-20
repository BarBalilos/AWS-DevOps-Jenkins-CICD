#!/usr/bin/env bash
# Tears down everything install-jenkins.sh / configure-jenkins.sh set up.
# Leaves the devops-app namespace and its resources untouched.
set -euo pipefail

NAMESPACE="jenkins"
RELEASE="jenkins"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

echo ">> Uninstalling Helm release '${RELEASE}' (if present)..."
helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" || true

echo ">> Removing RBAC objects..."
kubectl delete -f "${REPO_ROOT}/rbac/ci-agent-rbac.yaml" --ignore-not-found
kubectl delete -f "${REPO_ROOT}/rbac/cd-deploy-rbac.yaml" --ignore-not-found

echo ">> Removing jenkins-ecr-credentials Secret..."
kubectl delete secret jenkins-ecr-credentials --namespace "${NAMESPACE}" --ignore-not-found

echo ">> Removing NetworkPolicies in the jenkins namespace..."
kubectl delete networkpolicy jenkins-default-deny-ingress jenkins-allow-agents-to-controller \
  --namespace "${NAMESPACE}" --ignore-not-found

echo ">> Deleting namespace '${NAMESPACE}'..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

echo ">> Done. Jenkins and all its cluster-side resources have been removed."
echo ">> Note: this does NOT touch the devops-app namespace, ECR repositories,"
echo ">> or the jenkins-ci-ecr IAM user/policy — those are managed separately."