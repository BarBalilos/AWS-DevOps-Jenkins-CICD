#!/usr/bin/env bash
set -euo pipefail

JENKINS_URL="${JENKINS_URL:-http://localhost:8081}"
NAMESPACE="jenkins"
POD="jenkins-0"
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

echo "==> Reading Jenkins admin credentials from the controller pod..."
JENKINS_USER=$(kubectl exec -n "$NAMESPACE" "$POD" -c jenkins -- cat /run/secrets/additional/chart-admin-username)
JENKINS_PASS=$(kubectl exec -n "$NAMESPACE" "$POD" -c jenkins -- cat /run/secrets/additional/chart-admin-password)

echo "==> Fetching CSRF crumb..."
CRUMB_JSON=$(curl -sf -c "$COOKIE_JAR" -b "$COOKIE_JAR" -u "${JENKINS_USER}:${JENKINS_PASS}" "${JENKINS_URL}/crumbIssuer/api/json")
CRUMB_FIELD=$(echo "$CRUMB_JSON" | jq -r '.crumbRequestField')
CRUMB_VALUE=$(echo "$CRUMB_JSON" | jq -r '.crumb')

create_or_update_job() {
  local job_name="$1"
  local config_file="$2"

  echo "==> Checking whether job '${job_name}' exists..."
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -u "${JENKINS_USER}:${JENKINS_PASS}" \
    "${JENKINS_URL}/job/${job_name}/config.xml")

  if [ "$status" = "200" ]; then
    echo "==> Job '${job_name}' exists — updating config..."
    curl -sf -c "$COOKIE_JAR" -b "$COOKIE_JAR" -u "${JENKINS_USER}:${JENKINS_PASS}" \
      -H "${CRUMB_FIELD}: ${CRUMB_VALUE}" \
      -H "Content-Type: application/xml" \
      --data-binary "@${config_file}" \
      "${JENKINS_URL}/job/${job_name}/config.xml"
    echo "==> Updated '${job_name}'."
  else
    echo "==> Job '${job_name}' does not exist — creating..."
    curl -sf -c "$COOKIE_JAR" -b "$COOKIE_JAR" -u "${JENKINS_USER}:${JENKINS_PASS}" \
      -H "${CRUMB_FIELD}: ${CRUMB_VALUE}" \
      -H "Content-Type: application/xml" \
      --data-binary "@${config_file}" \
      "${JENKINS_URL}/createItem?name=${job_name}"
    echo "==> Created '${job_name}'."
  fi
}

create_or_update_job "application-ci" "jobs/application-ci-config.xml"
create_or_update_job "application-cd" "jobs/application-cd-config.xml"

echo "==> Done. Current job list:"
curl -g -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" -u "${JENKINS_USER}:${JENKINS_PASS}" \
  "${JENKINS_URL}/api/json?tree=jobs[name,url]" | jq .