# AWS DevOps — Jenkins CI/CD on Kubernetes

Jenkins running as a workload inside a Kubernetes cluster (k3d, `devops-k8s`), provisioning ephemeral, per-build agent pods to build, scan, and deploy the application in [`AWS-DevOps-Kubernetes`](https://github.com/BarBalilos/AWS-DevOps-Kubernetes) into the `devops-app` namespace. Everything — controller, agents, RBAC, secrets, network policy — is defined as code in this repository and reconciled with idempotent scripts.

## Architecture

Two diagrams live in [`diagrams/`](diagrams/):

- [`deployment-view.mmd`](diagrams/deployment-view.mmd) — the static topology: namespaces, pods, ServiceAccounts, Secrets, and NetworkPolicies across both the `jenkins` and `devops-app` namespaces, plus the AWS/GitHub resources they talk to.
- [`pipeline-flow.mmd`](diagrams/pipeline-flow.mmd) — the dynamic flow: every stage of `application-ci` and `application-cd`, in order, from a Git push to a verified rollout.

Render either with a Mermaid-compatible viewer (VS Code's Mermaid preview extension, or paste the source into [mermaid.live](https://mermaid.live)).

At a glance:

- **Jenkins controller** (`jenkins-0`, StatefulSet) runs in the `jenkins` namespace, configured entirely via JCasC (`jenkins/helm/values-jcasc.yaml`). It is never exposed outside the cluster — `ClusterIP` only, reached via `kubectl port-forward`.
- **Build and deploy work never runs on the controller.** The Kubernetes Cloud plugin provisions two ephemeral pod templates per build, torn down immediately after (`podRetention: never`):
  - `ci-agent` — `python`, `kaniko-backend`, `kaniko-worker` containers. Builds, tests, and pushes images. Has **no Kubernetes deploy permission whatsoever**.
  - `cd-agent` — a single `kubectl` container. Deploys to `devops-app` only. Cannot build or push images.
- **Application source and manifests live in the other repo** (`AWS-DevOps-Kubernetes`); this repo owns the pipeline definitions, RBAC, credentials handling, and Jenkins configuration.

## Repository Structure

```text
AWS-DevOps-Jenkins-CICD/
├── jenkins/
│   └── helm/
│       ├── values.yaml
│       └── values-jcasc.yaml
├── pipelines/
│   ├── Jenkinsfile-ci
│   └── Jenkinsfile-cd
├── jobs/
│   ├── application-ci-config.xml
│   └── application-cd-config.xml
├── rbac/
│   ├── ci-agent-rbac.yaml
│   └── cd-deploy-rbac.yaml
├── network/
│   └── jenkins-networkpolicy.yaml
├── iam/
│   ├── jenkins-ci-ecr-policy.json
│   └── jenkins-ci-ecr-access-key.json   # gitignored, real values, never committed
├── credentials/
│   └── credentials.example.yaml         # committed placeholder — shapes + rotation runbook, no real values
├── diagrams/
│   ├── deployment-view.mmd
│   └── pipeline-flow.mmd
├── scripts/
│   ├── install-jenkins.sh
│   ├── configure-jenkins.sh
│   ├── create-jobs.sh
│   ├── verify-jenkins.sh
│   └── uninstall-jenkins.sh
├── evidence/
│   ├── 01-jenkins-on-kubernetes/
│   ├── 02-pipeline-ci/
│   └── 03-pipeline-cd/
└── README.md
```

## Prerequisites

- A running Kubernetes cluster with `kubectl` pointed at it (this project targets a local `k3d` cluster, `devops-k8s`).
- `helm` (v3), `jq`, `aws` CLI configured with credentials that can manage IAM/ECR (used only for one-time setup, never used by Jenkins itself).
- Two ECR repositories already created: `devops-app-backend`, `devops-app-worker`.
- A scoped IAM user (`jenkins-ci-ecr`) with only the permissions in [`iam/jenkins-ci-ecr-policy.json`](iam/jenkins-ci-ecr-policy.json) — push/pull/describe/scan-read on exactly those two repositories, plus `ecr:GetAuthorizationToken`. This user is **never** the broad account-admin IAM user; it exists solely so Jenkins' blast radius is capped at two ECR repos.
- A local, gitignored access-key file for that user at `iam/jenkins-ci-ecr-access-key.json`, shaped like raw `aws iam create-access-key` output: `{"AccessKey": {"AccessKeyId": "...", "SecretAccessKey": "..."}}`.

## Setup & Deployment

Run in order from the repo root:

```
chmod +x scripts/*.sh

./scripts/install-jenkins.sh     # base Helm install/upgrade (jenkins/helm/values.yaml)
./scripts/configure-jenkins.sh   # JCasC overlay + RBAC + NetworkPolicy + jenkins-ecr-credentials Secret
./scripts/create-jobs.sh         # creates/updates application-ci and application-cd jobs
./scripts/verify-jenkins.sh      # runs the evidence/verification commands below
```

All four scripts are idempotent — safe to re-run at any time to reconcile the cluster back to this repo's state. Once complete, reach the UI with:

```
kubectl port-forward svc/jenkins 8081:8080 -n jenkins
```

then open `http://localhost:8081`. `application-ci` polls its GitHub repo every 5 minutes (`H/5 * * * *`); pushing a commit (or clicking Build Now) triggers the full pipeline.

To tear everything down: `./scripts/uninstall-jenkins.sh`. It only removes what this repo created in the `jenkins` namespace — the `devops-app` namespace, ECR repositories, and the `jenkins-ci-ecr` IAM user/policy are managed separately and untouched.

## Pipelines

### CI — `application-ci` (`pipelines/Jenkinsfile-ci`, runs on `ci-agent`)

1. **Checkout** — clones `Jenkinsfile-ci` from this repo, then the application source from `AWS-DevOps-Kubernetes` into `app-src/`.
2. **Validation** — confirms `Dockerfile` + `requirements.txt` + `requirements-test.txt` exist for both `backend` and `worker`.
3. **Lint / Static Analysis** — `flake8` on both services.
4. **Tests** — `pytest` on both services, JUnit results recorded.
5. **Build, Tag & Push (Kaniko)** — `kaniko-backend` and `kaniko-worker` build and push images to ECR tagged `<git-sha>-<build#>`, each in its own container so the two builds can't interfere with each other's build context. Image digests are captured.
6. **Image Scan Results** — reads ECR's scan-on-push status for both images (best-effort, non-blocking — the scan itself runs asynchronously in ECR).
7. **Publish Metadata** — archives `image-metadata.json` (commit, build number, tag, both digests) as a build artifact for traceability.
8. Triggers `application-cd`, passing the image tag and digests as parameters. If any earlier stage fails, every remaining stage is skipped and `application-cd` is never triggered — verified live (see Evidence).

### CD — `application-cd` (`pipelines/Jenkinsfile-cd`, runs on `cd-agent`)

1. **Checkout** — clones `Jenkinsfile-cd` from this repo, then the Kubernetes manifests from `AWS-DevOps-Kubernetes`.
2. **Input Validation** — confirms the passed image tag/digests are non-empty and the `devops-app` namespace exists.
3. **Manifest Discovery & Validation** — `kubectl apply --dry-run=client` and `--dry-run=server` against every manifest in `k8s/` (excluding namespace and secret files, which are applied separately and never blindly re-applied).
4. **Authenticate / RBAC Sanity Check** — `kubectl auth can-i` checks confirm the `jenkins-cd-agent` ServiceAccount has exactly the permissions it needs (patch deployments, exec into pods) and fails fast if not.
5. **Refresh ECR Pull Secret** — regenerates the `ecr-pull-secret` from a fresh ECR auth token and links it to `backend-sa`/`worker-sa`, so image pulls never rely on a long-lived pull secret.
6. **Deploy** — applies manifests, then pins `backend` and `worker` to their exact image **digest** (never a mutable tag), annotates the deployment with the triggering build, and restarts the rollout.
7. **Rollout** — waits on `kubectl rollout status` (180s timeout).
8. **Verify** — re-reads the running deployment's image reference and confirms it matches the requested digest exactly.
9. **Smoke Test** — execs into the live backend and worker pods and hits their `/api/health` / `/health` endpoints, expecting `200`.

Deploying by digest rather than tag means what actually ran through CI is guaranteed to be what's running in `devops-app` — there's no window where a mutable tag could point somewhere else by the time CD applies it.

## Rollback

Every deploy is pinned to an immutable image digest (never a mutable tag), and every CI run archives `image-metadata.json` — containing the exact `IMAGE_TAG`, `backend_digest`, and `worker_digest` for that build — as a permanent build artifact. That means any previously-deployed version can be redeployed exactly, with no ambiguity about what "the previous version" means.

**Standard rollback — re-run the CD pipeline against a known-good build.** Find the last good build's archived `image-metadata.json` (either in Jenkins under that build's artifacts, or by cross-referencing the `deployed-image-tag` / `deployed-by-build` annotations already present on the live Deployments — `kubectl get deployment backend -n devops-app -o jsonpath='{.metadata.annotations}'`), then trigger `application-cd` manually ("Build with Parameters") with that build's `IMAGE_TAG` and digests. This runs the full CD pipeline as normal — dry-run validation, RBAC check, deploy-by-digest, rollout wait, digest verification, and a smoke test — just pointed at the older, already-tested images. This is the preferred path: it goes through the same verification every forward deploy does, and leaves a normal, auditable Jenkins build record of the rollback.

**Emergency rollback — `kubectl rollout undo`.** If Jenkins itself is unavailable, Kubernetes' own revision history can revert instantly: `kubectl rollout undo deployment/backend -n devops-app` and `kubectl rollout undo deployment/worker -n devops-app` roll each Deployment back to its previous ReplicaSet. This is faster but bypasses the pipeline's RBAC sanity check and smoke test, so it's a break-glass option only — once used, a proper `application-cd` run should follow to bring the deployment's state (and its `deployed-image-tag` annotation) back in sync with what Jenkins believes is live.

## RBAC

| ServiceAccount | Namespace scope | Bindings | Notes |
|---|---|---|---|
| `jenkins-ci-agent` | `jenkins` | **None** — no Role or ClusterRole bound anywhere | `automountServiceAccountToken: false`, so even if a compromised build step tried to call the Kubernetes API, it has no token to authenticate with. CI cannot deploy, read, or modify anything in the cluster. |
| `jenkins-cd-agent` | `devops-app` (Role) + read-only cluster scope (ClusterRole) | `rbac/cd-deploy-rbac.yaml` | The Role grants exactly what the Deploy/Rollout/Verify/Smoke Test stages use — patch/get on Deployments, exec into pods, read Services/Pods — scoped to `devops-app` only. It deliberately excludes `create` on Secrets (secrets are refreshed via `apply`/`patch` on a pre-existing name, never created fresh, to avoid a broader `create` verb than necessary). The ClusterRole exists only to allow `kubectl get namespace devops-app` for the Input Validation stage, and is restricted via `resourceNames: ["devops-app"]` so it cannot list or read any other namespace. |

No ClusterRole with wildcard resources, no `cluster-admin` binding, anywhere in this project.

## Security

### Secrets and credentials

- **No secrets are committed to Git.** `.gitignore` excludes `iam/*access-key*.json`, `**/secret.yaml`, `**/*.kubeconfig`, `**/values.local.yaml`, `*.env`, `.env.*`. `credentials/credentials.example.yaml` documents every credential's shape and rotation procedure with placeholder values only.
- **Jenkins admin credential** is chart-managed: Helm auto-generates it as a Kubernetes Secret on install. It's retrieved on demand (`kubectl exec ... cat /run/secrets/additional/chart-admin-password`) and never written to a file.
- **AWS credentials** (`jenkins-ecr-credentials`, a Kubernetes Secret in the `jenkins` namespace) hold the `jenkins-ci-ecr` IAM user's access key. They're injected only into the containers that actually need AWS access — `python`, `kaniko-backend`, `kaniko-worker` in `ci-agent`, and `kubectl` in `cd-agent` — never into the `jnlp` agent-connection container, which has no need for them.
- **Console log masking**: the CD pipeline's ECR-login step wraps the password retrieval in `set +x` / `set -x` specifically so the token never appears in Jenkins console output, verified by inspecting real build logs.
- **Rotation**: documented per-credential in `credentials/credentials.example.yaml` — rotating the IAM access key means issuing a new key via AWS IAM, updating the local (gitignored) `iam/jenkins-ci-ecr-access-key.json`, re-running `configure-jenkins.sh` to refresh the Kubernetes Secret, and deactivating/deleting the old key once builds confirm the new one works. `configure-jenkins.sh` fails loudly (rather than silently writing a broken credential) if the access-key file's shape doesn't match what it expects.

### Build execution

- **No builds run on the controller.** Every build/deploy step runs in a freshly provisioned, single-use agent pod (`podRetention: never`), never on `jenkins-0` itself — confirmed live: the controller pod's container list is exactly `jenkins` and `config-reload`, nothing build-related.
- **No `docker.sock` mounting anywhere.** Images are built with Kaniko, which builds OCI images from a Dockerfile without a Docker daemon or any privileged host access — there's no daemon socket to mount and no privileged container required for the build itself.

### Pod-level hardening

- The controller's `securityContext` (`jenkins/helm/values.yaml`) is fully hardened: `runAsNonRoot: true`, fixed non-root UID/GID, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`.
- All four agent-pod containers that do real work (`python`, `kaniko-backend`, `kaniko-worker`, `kubectl`) have `allowPrivilegeEscalation: false` and `seccompProfile: RuntimeDefault` applied via a JCasC raw-pod-spec override, verified live against running pods.
- **Trade-off, stated explicitly per the brief's "as much as possible" wording**: `runAsNonRoot` and full capability-dropping are *not* forced on `python`, `kaniko-backend`, or `kaniko-worker`. `python` needs root to `apt-get install` build tooling mid-pipeline; Kaniko's own image-construction process needs root inside its own ephemeral, non-privileged container to unpack layers and assemble the filesystem — this is Kaniko's documented operating model, distinct from needing host-level privilege. Both still run with `allowPrivilegeEscalation: false`, a restricted seccomp profile, no host mounts, and no privileged flag — the escalation and syscall surface is minimized even where full non-root wasn't feasible without breaking the build.

### Image security

- Every image reference in this project is pinned to a specific version — `jenkins/jenkins:2.568.2-jdk21`, `python:3.11-slim`, `gcr.io/kaniko-project/executor:v1.23.2-debug`, `alpine/k8s:1.31.2`, `jenkins/inbound-agent:3383.vc8881d4b_0e76-1-jdk25` — nothing floats on `latest`.
- Application images (`devops-app-backend`, `devops-app-worker`) are scanned on push by ECR; the CI pipeline's "Image Scan Results" stage reads and surfaces that status.
- **Trade-off**: the Jenkins/tooling images themselves (controller, agent base images) are not separately vulnerability-scanned in this pipeline — only the application images that actually ship to `devops-app` are.

### Network exposure

- **Jenkins UI is never exposed to the internet.** `serviceType: ClusterIP` — no Ingress, no LoadBalancer. The only way to reach it is `kubectl port-forward`, which already requires cluster access. HTTPS/TLS is therefore not applicable here since there's no external listener to secure.
- **Required egress** for the pipeline to function: GitHub (`github.com`, HTTPS, for `git fetch`/`clone`), the ECR API and registry endpoints (`*.dkr.ecr.us-east-1.amazonaws.com`, `api.ecr.us-east-1.amazonaws.com`), the Kubernetes API server (in-cluster, `kubernetes.default.svc`), PyPI (`pypi.org`, `files.pythonhosted.org`, for `pip install` of lint/test/AWS-CLI tooling), the Alpine package mirror (`dl-cdn.alpinelinux.org`, used by `cd-agent` for `apk add git`), and Docker Hub / GCR for base images (`index.docker.io`, `gcr.io`).

### NetworkPolicy

Enforcement was verified to be genuinely active in this cluster (not just API-accepted) before relying on it, via a live functional test against the pre-existing `devops-app` policies:

- A pod outside `devops-app` (`kubectl run netpol-test ... -n default -- curl backend-service.devops-app.svc.cluster.local:5000/api/health`) was denied almost instantly (`Could not connect to server` after ~2ms).
- The same request from the `frontend` pod, which the existing `allow-backend-from-frontend` policy explicitly permits, succeeded (`{"status": "ok"}`).

That asymmetry — identical target, different result based on the policy's `podSelector` — is only possible if the CNI is actually enforcing NetworkPolicy. With that confirmed, [`network/jenkins-networkpolicy.yaml`](network/jenkins-networkpolicy.yaml) — applied by `configure-jenkins.sh`, kept in this repo rather than the application repo since it's Jenkins infrastructure, not something the app's CD pipeline should blindly apply — adds the same protection to the `jenkins` namespace: a default-deny on all ingress, with one explicit exception allowing traffic into the controller on ports `8080` (HTTP/API) and `50000` (JNLP agent tunnel) from pods within the `jenkins` namespace only. Applying it was verified not to break anything by running a full, real pipeline build immediately afterward — both `ci-agent` and `cd-agent` pods (freshly provisioned, so they had to establish their JNLP connection from scratch under the new policy) connected and completed successfully end to end.

## Trade-offs

- **No IRSA/OIDC federation for AWS access.** This runs on a local `k3d` cluster, not EKS, so IAM Roles for Service Accounts isn't available. A long-lived, tightly scoped IAM user access key is the practical substitute, mitigated by the documented rotation procedure and the fact that it's confined to exactly two ECR repositories.
- **No External Secrets Operator.** A native Kubernetes Secret plus the Jenkins Credentials store was sufficient for this project's single-cluster, single-environment scope; ESO would be the natural next step for a multi-cluster setup.
- **Jenkins/agent tooling images are not vulnerability-scanned** (see Image Security above) — only application images are.

## Evidence

Command output and screenshots proving the above (Jenkins running on Kubernetes, a full CI run, a deliberately failed CI run that didn't trigger CD, a full CD run, and the NetworkPolicy enforcement test) are captured under [`evidence/`](evidence/). `scripts/verify-jenkins.sh` reproduces the core verification commands directly.