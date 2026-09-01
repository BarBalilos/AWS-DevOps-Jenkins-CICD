#!/usr/bin/env bash
# Idempotent Jenkins install/upgrade.
# Creates the jenkins namespace if missing, adds/updates the Jenkins Helm
# repo, and installs or upgrades the controller from jenkins/helm/values.yaml
# layered with jenkins/helm/values-jcasc.yaml (security realm, Kubernetes
# cloud, and all agent pod templates — JCasC). Both files are passed on
# every run so this stays idempotent/reproducible from code: a fresh
# `helm upgrade --install` without --reuse-values only keeps what's
# explicitly passed in that invocation, so omitting either file here would
# silently drop it from the release.
# Safe to re-run at any time to reconcile the cluster back to this repo's state.
set -euo pipefail

NAMESPACE="jenkins"
RELEASE="jenkins"
CHART="jenkins/jenkins"
CHART_VERSION="5.9.54"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/../jenkins/helm/values.yaml"
JCASC_VALUES_FILE="${SCRIPT_DIR}/../jenkins/helm/values-jcasc.yaml"

echo ">> Ensuring namespace '${NAMESPACE}' exists..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo ">> Adding/updating the Jenkins Helm repo..."
helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update jenkins

echo ">> Installing/upgrading Jenkins (chart ${CHART_VERSION})..."
helm upgrade --install "${RELEASE}" "${CHART}" \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  -f "${VALUES_FILE}" \
  -f "${JCASC_VALUES_FILE}" \
  --wait --timeout=5m

echo ">> Done. Run scripts/verify-jenkins.sh to confirm health."