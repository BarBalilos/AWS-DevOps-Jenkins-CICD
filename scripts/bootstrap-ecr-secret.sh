#!/usr/bin/env bash
# bootstrap-ecr-secret.sh
#
# One-time, out-of-band bootstrap for the `ecr-pull-secret` Secret in the
# devops-app namespace.
#
# WHY THIS SCRIPT EXISTS:
# rbac/cd-deploy-rbac.yaml deliberately grants the CD ServiceAccount only
# get/update/patch on this one named Secret (via resourceNames), never
# create — Kubernetes RBAC cannot scope the `create` verb by resourceNames,
# so there is no safe way to let CD create *only* this one Secret without
# also granting it the ability to create arbitrary Secrets in the namespace.
# The accepted tradeoff (documented in that RBAC file) is that a human
# bootstraps this Secret once, out-of-band, and CD only ever refreshes its
# value afterward (see the "Refresh ECR Pull Secret" stage in
# pipelines/Jenkinsfile-cd).
#
# Run this once per cluster/namespace, before the first ever CD deploy.
# Safe to re-run: if the secret already exists, it exits cleanly without
# changing anything (CD's own refresh stage handles value rotation).
#
# Requires: kubectl configured against the target cluster, aws CLI
# authenticated with ECR read access for the target registry/region.

set -euo pipefail

NAMESPACE="${NAMESPACE:-devops-app}"
ECR_REGISTRY="${ECR_REGISTRY:-938834037970.dkr.ecr.us-east-1.amazonaws.com}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SECRET_NAME="ecr-pull-secret"

echo "Checking namespace '${NAMESPACE}' exists..."
kubectl get namespace "${NAMESPACE}" > /dev/null

if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" > /dev/null 2>&1; then
    echo "Secret '${SECRET_NAME}' already exists in '${NAMESPACE}' — nothing to do."
    echo "(CD's own 'Refresh ECR Pull Secret' stage keeps its value current on every deploy.)"
    exit 0
fi

echo "Secret '${SECRET_NAME}' not found — creating it now (one-time bootstrap)..."
ECR_PASSWORD=$(aws ecr get-login-password --region "${AWS_REGION}")

kubectl create secret docker-registry "${SECRET_NAME}" \
  --docker-server="${ECR_REGISTRY}" \
  --docker-username=AWS \
  --docker-password="${ECR_PASSWORD}" \
  -n "${NAMESPACE}"

echo "Bootstrapped '${SECRET_NAME}' in namespace '${NAMESPACE}'."
echo "From now on, CD refreshes its value automatically on every deploy — this script does not need to run again unless the Secret is deleted."