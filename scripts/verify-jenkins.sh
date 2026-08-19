#!/usr/bin/env bash
# Read-only health checks for the Jenkins controller and its Kubernetes
# resources. Mirrors the evidence commands from the assignment spec (section 10).
set -euo pipefail

NAMESPACE="jenkins"

echo "== Namespaces =="
kubectl get namespaces

echo "== Pods =="
kubectl get pods -n "${NAMESPACE}" -o wide

echo "== Service / Ingress / PVC =="
kubectl get service,ingress,pvc -n "${NAMESPACE}"

echo "== ServiceAccount / Role / RoleBinding =="
kubectl get serviceaccount,role,rolebinding -n "${NAMESPACE}"

echo "== Helm release =="
helm list -n "${NAMESPACE}"

echo "== Waiting for controller readiness =="
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=jenkins-controller \
  -n "${NAMESPACE}" --timeout=60s

echo ">> Jenkins controller is Ready."