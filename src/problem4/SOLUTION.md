# Problem 4: Production-Ready CI/CD Pipelines

## 1. Executive Summary & Architecture

This solution establishes an automated, secure, and production-grade CI/CD foundation for both components of the web product:
1. **Frontend:** Single-Page Application (SPA) deployed to **Amazon S3** and distributed globally via **Amazon CloudFront CDN**.
2. **Backend:** HTTP REST API containerized and deployed to **Amazon EC2** via **AWS Systems Manager (SSM) / Amazon ECR**, managed with zero-downtime Blue/Green rolling container swaps and NGINX upstream switching.

### System Architecture & Pipeline Flow

```
                      [ Developer / Git Push / PR ]
                                   │
                                   ▼
                       [ GitHub Actions Platform ]
               ┌───────────────────┴───────────────────┐
               │                                       │
     [ Frontend Workflows ]                  [ Backend Workflows ]
  - Quality: Lint, Types, Tests           - Quality: Lint, Types, Tests
  - Security: Audit, Trivy FS             - Security: Gitleaks, Trivy Image
  - Build: Optimized SPA bundle           - Build: Multi-stage OCI Container
               │                                       │
               │ (OIDC STS Federation)                 │ (OIDC STS Federation)
               ▼                                       ▼
  [ AWS IAM Role: Frontend ]              [ AWS IAM Role: Backend ]
               │                                       │
       ┌───────┴───────┐                       ┌───────┴───────┐
       ▼               ▼                       ▼               ▼
  [ Amazon S3 ]  [ CloudFront ]           [ Amazon ECR ]  [ AWS SSM Agent ]
  - Two-Stage    - Targeted               - Immutable     - Tagged EC2
    Sync (Hashed   Cache Invalidation       Git SHA         Dispatch
    vs HTML)       (/index.html)            Digest        - Port Swap
                                                          - Health Check
                                                          - Rollback
```

---

## 2. What "Production Ready" Means

In enterprise engineering, automated pipelines are mission-critical control planes. A pipeline is only "production-ready" when it fulfills the following operational standards:

| Pillar | Production-Ready Standard | How We Implement It |
|---|---|---|
| **Identity & Security** | Zero long-lived AWS keys in GitHub. Ephemeral tokens only. | AWS OIDC (`AssumeRoleWithWebIdentity`) via STS. No static `AWS_ACCESS_KEY_ID`. |
| **Least Privilege** | Workflows only have permissions strictly necessary for their tasks. | Dedicated IAM roles per pipeline; frontend cannot touch EC2/ECR, backend cannot touch S3. |
| **Shift-Left Security** | Block secrets and CVEs before deployment. | Gitleaks for secret detection; Trivy for container & filesystem CVE scans; `npm audit`. |
| **Immutability & Traceability** | Workloads are 1:1 traceable back to a Git commit SHA. | Backend images tagged `sha-${{ github.sha }}`; frontend assets content-hashed (`[name].[hash].js`). |
| **Zero-Downtime Rollouts** | Deployments never serve broken bundles or drop HTTP requests. | Frontend: two-stage upload (assets first, then HTML). Backend: Blue/Green container swap with NGINX. |
| **Continuous Verification** | Deployments are not considered successful until validated. | Automated post-deployment smoke tests against public/edge endpoints before closing the job. |
| **Fault Isolation & Rollback** | Automated rollback if health checks fail; instant manual rollback. | EC2 script tests `/health` on idle port before switching traffic; GitHub Actions rollback dispatch. |
| **State & Concurrency Control** | Parallel runs do not overwrite or corrupt in-flight deployments. | `concurrency: cancel-in-progress: false` on CD pipelines ensures serial, atomic deployments. |

---

## 3. Pipeline Implementation

All workflow definitions are located in [`.github/workflows/`](.github/workflows/):

- [`frontend-ci.yml`](.github/workflows/frontend-ci.yml): Pull request validation, linting, tests, and build check.
- [`frontend-cd.yml`](.github/workflows/frontend-cd.yml): Production build, two-stage S3 sync, CloudFront invalidation, smoke tests.
- [`backend-ci.yml`](.github/workflows/backend-ci.yml): Quality checks, Gitleaks secret scan, Docker build, and Trivy CVE container scan.
- [`backend-cd.yml`](.github/workflows/backend-cd.yml): ECR image push, AWS SSM rolling deployment to EC2, live health validation.

---

### 3.1 Frontend CI/CD Pipeline (SPA to S3 + CloudFront)

#### Frontend CI ([`frontend-ci.yml`](.github/workflows/frontend-ci.yml))
Triggered on pull requests modifying `frontend/**`:
1. **Linter & Formatting:** Verifies code styling using ESLint and Prettier.
2. **Type Checking:** Runs `tsc --noEmit` to catch TypeScript compiler errors.
3. **Unit Tests:** Executes test suites with code coverage reporting.
4. **Dependency Audit:** Runs `npm audit` and Trivy filesystem vulnerability checks.
5. **Dry-Run Build:** Verifies that Vite/Webpack compiles cleanly and produces valid assets.

#### Frontend CD ([`frontend-cd.yml`](.github/workflows/frontend-cd.yml))
Triggered on push to `main` or via manual `workflow_dispatch`:
1. **OIDC STS Authentication:** Exchanges GitHub OIDC JWT for a 15-minute temporary AWS session via `aws-actions/configure-aws-credentials@v4`.
2. **Environment Build:** Injects production environment variables (`VITE_API_BASE_URL`) at bundle time.
3. **Two-Stage Atomic Cache-Optimized S3 Sync:**
   - **Stage 1 (Hashed Static Chunks):**
     ```bash
     aws s3 sync dist/assets/ s3://${S3_BUCKET}/assets/ \
       --cache-control "public, max-age=31536000, immutable"
     ```
     *Rationale:* Hashed JavaScript, CSS, and font files are uploaded **first** with a 1-year immutable cache header. If users load an existing `index.html` while deployment is underway, their chunk requests never 404.
   - **Stage 2 (Entrypoint & Metadata):**
     ```bash
     aws s3 sync dist/ s3://${S3_BUCKET}/ \
       --exclude "assets/*" \
       --cache-control "public, max-age=0, must-revalidate"
     ```
     *Rationale:* `index.html`, `manifest.json`, and `robots.txt` are uploaded **second** with `max-age=0, must-revalidate`. Browsers and CloudFront edge nodes immediately revalidate the HTML file on subsequent requests, instantly pointing users to new chunk hashes without caching stale HTML.
   - **Stage 3 (Prune Obsolete Assets):**
     ```bash
     aws s3 sync dist/ s3://${S3_BUCKET}/ --delete
     ```
4. **Targeted CloudFront Cache Invalidation:**
   Invalidates `/index.html`, `/manifest.json`, and `/robots.txt` rather than `/*`. This preserves CDN edge hit ratios for immutable chunks and eliminates AWS CloudFront invalidation costs.
5. **Synthetic Smoke Test:**
   Executes [`frontend/scripts/smoke-test.sh`](frontend/scripts/smoke-test.sh) to verify HTTP 200, valid `text/html` Content-Type, revalidation cache headers, and asset resolution.

---

### 3.2 Backend CI/CD Pipeline (HTTP API to EC2)

#### Backend CI ([`backend-ci.yml`](.github/workflows/backend-ci.yml))
Triggered on pull requests modifying `backend/**`:
1. **Linter & Unit Tests:** Runs language tests and coverage thresholds.
2. **Secret Leak Detection:** Executes Gitleaks to block committed credentials, AWS keys, or tokens.
3. **Dependency Scanning:** Scans application dependencies for known CVEs.
4. **Container Build Verification:** Builds Docker container image with layer caching (`cache-from: type=gha`).
5. **Container CVE Scan:** Scans the built image with Aquasecurity Trivy, identifying critical OS-level and runtime vulnerabilities before image promotion.

#### Backend CD ([`backend-cd.yml`](.github/workflows/backend-cd.yml))
Triggered on push to `main` or via manual `workflow_dispatch`:
1. **Build & Publish to Amazon ECR:**
   - Logs in to Amazon ECR via temporary OIDC credentials.
   - Builds production image using multi-stage [`backend/Dockerfile`](backend/Dockerfile).
   - Tags container with `${{ github.sha }}` (immutable primary tag) and `latest`.
   - Pushes image to Amazon ECR.
2. **Deploy to EC2 via AWS Systems Manager (SSM) Run Command:**
   - Targets EC2 instances dynamically using AWS resource tags (`App=backend-api, Environment=production`).
   - Dispatches [`backend/scripts/deploy.sh`](backend/scripts/deploy.sh) without opening inbound SSH port 22.
3. **Zero-Downtime Blue/Green Container Swap on EC2:**
   - Authenticates EC2 Docker daemon to Amazon ECR via instance IAM profile.
   - Pulls the newly built image tag.
   - Detects current active container (`backend_blue` on port 8080 vs `backend_green` on port 8081).
   - Starts target container on the **standby port**.
   - Loops checking `http://127.0.0.1:<target_port>/health` for up to 60 seconds.
   - **Automated Rollback on Failure:** If health checks fail, the target container is stopped and removed immediately; active traffic is untouched.
   - **Atomic Traffic Switch:** If healthy, updates `/etc/nginx/conf.d/upstream.inc` and reloads NGINX (`sudo nginx -s reload`). Incoming connections are rerouted with zero dropped packets.
   - **Graceful Drain:** Waits 10 seconds for active requests on the old container to drain, then stops and removes the old container.
   - **Disk Cleanup:** Runs `docker image prune -af --filter "until=48h"` to prevent disk exhaustion on root EBS volumes.
4. **External Smoke Test:**
   GitHub Actions queries the public API health endpoint via [`backend/scripts/healthcheck.sh`](backend/scripts/healthcheck.sh).
5. **Audit Trail:**
   Emits structured deployment details to `$GITHUB_STEP_SUMMARY`.

---

## 4. Supporting Files & Infrastructure Configuration

| File | Purpose |
|---|---|
| [`.github/workflows/frontend-ci.yml`](.github/workflows/frontend-ci.yml) | Frontend CI workflow (Lint, types, tests, audit, build). |
| [`.github/workflows/frontend-cd.yml`](.github/workflows/frontend-cd.yml) | Frontend CD workflow (S3 two-phase sync, CloudFront invalidation, smoke test). |
| [`.github/workflows/backend-ci.yml`](.github/workflows/backend-ci.yml) | Backend CI workflow (Lint, tests, Gitleaks, Trivy image scan). |
| [`.github/workflows/backend-cd.yml`](.github/workflows/backend-cd.yml) | Backend CD workflow (ECR publish, AWS SSM EC2 deployment, healthcheck). |
| [`backend/Dockerfile`](backend/Dockerfile) | Hardened multi-stage Dockerfile with unprivileged user (`appuser`), `dumb-init`, and healthcheck. |
| [`backend/docker-compose.prod.yml`](backend/docker-compose.prod.yml) | Production Docker Compose reference with log size limits (`max-size: 50m`). |
| [`backend/nginx/api.conf`](backend/nginx/api.conf) | EC2 NGINX reverse proxy configuration with dynamic upstream inclusion. |
| [`backend/scripts/deploy.sh`](backend/scripts/deploy.sh) | Zero-downtime Blue/Green rolling deployment script executed on EC2. |
| [`backend/scripts/healthcheck.sh`](backend/scripts/healthcheck.sh) | Healthcheck probe with retries, timeout, and response validation. |
| [`backend/appspec.yml`](backend/appspec.yml) | AWS CodeDeploy configuration for teams utilizing CodeDeploy agent. |
| [`frontend/scripts/smoke-test.sh`](frontend/scripts/smoke-test.sh) | Post-deployment synthetic test verifying SPA delivery and caching headers. |
| [`frontend/package.json`](frontend/package.json) | Reference frontend package configuration with build, lint, and test scripts. |
| [`infrastructure/iam-policies/github-oidc-trust-policy.json`](infrastructure/iam-policies/github-oidc-trust-policy.json) | AWS STS Web Identity trust policy for GitHub OIDC provider. |
| [`infrastructure/iam-policies/frontend-deployer-policy.json`](infrastructure/iam-policies/frontend-deployer-policy.json) | Least-privilege IAM policy for Frontend S3 and CloudFront. |
| [`infrastructure/iam-policies/backend-deployer-policy.json`](infrastructure/iam-policies/backend-deployer-policy.json) | Least-privilege IAM policy for Backend ECR and SSM Run Command. |

---

## 5. Assumptions Made and Justifications

1. **Monorepo Structure with Independent Delivery:**
   - *Assumption:* Frontend and backend reside within the same repository (`frontend/` and `backend/`), but their release cadences must remain completely decoupled.
   - *Why:* Monorepos streamline shared types, shared tooling, and end-to-end integration testing. Path filtering (`paths: ['frontend/**']` vs `paths: ['backend/**']`) ensures that pushing a frontend commit does not trigger an unnecessary backend container build and deployment, conserving GitHub Actions runner hours.
2. **AWS CloudFront in Front of S3:**
   - *Assumption:* The S3 bucket is not configured as an unencrypted public web host. Instead, S3 is private and accessed exclusively via CloudFront using Origin Access Control (OAC).
   - *Why:* S3 website hosting alone lacks HTTPS on custom domains, edge caching, and DDoS mitigation. CloudFront enables global SSL/TLS termination, edge compression (Brotli/Gzip), and instant cache invalidations.
3. **Containerized Workload on EC2 via Docker:**
   - *Assumption:* The backend HTTP API runs inside a container on EC2 rather than bare-metal Node/Python process.
   - *Why:* Bare-metal deployments suffer from environment drift, lingering dependency discrepancies, and difficult rollbacks. Containers provide immutable artifacts, reproducible dependencies, isolated processes, and straightforward zero-downtime port switching.
4. **AWS Systems Manager (SSM) Over Direct SSH:**
   - *Assumption:* EC2 instances are managed via AWS SSM Agent and EC2 Instance Profiles rather than opening port 22 to the public internet or bastion hosts.
   - *Why:* Storing SSH private keys in CI/CD secrets presents severe security risks (leaks, key rotation overhead). SSM requires zero open inbound security group ports, uses temporary IAM credentials, and maintains audit logs in AWS CloudTrail.
5. **Trunk-Based Development & GitHub Environments:**
   - *Assumption:* Teams develop using short-lived feature branches merged into `main`. The `main` branch automatically deploys to `staging` or `production` under GitHub Environment protection rules (e.g. required reviewers for production).
   - *Why:* Trunk-based workflows reduce merge conflicts and lead times, while GitHub Environment protection gates prevent unintended production deployments.

---

## 6. How the Pipelines Work, and What We Deliberately Left Out

### How the Pipelines Work (Operational Lifecycle)

```
PR Opened / Updated:
 ├── [Frontend CI]: Lint ➔ Type Check ➔ Unit Tests ➔ Dependency Audit ➔ Build Verification
 └── [Backend CI]:  Lint ➔ Unit Tests ➔ Gitleaks Secrets ➔ Docker Build ➔ Trivy CVE Scan

Merge to Main / Release Tag:
 ├── [Frontend CD]:
 │    ├── 1. OIDC STS Exchange (No static keys)
 │    ├── 2. Production Bundle Compilation (Vite/Webpack)
 │    ├── 3. Stage 1 Sync: Upload /assets/* (Cache-Control: immutable, 1 year)
 │    ├── 4. Stage 2 Sync: Upload index.html (Cache-Control: must-revalidate)
 │    ├── 5. Stage 3 Sync: Prune deleted remote files
 │    ├── 6. Invalidate CloudFront (/index.html)
 │    └── 7. Automated Synthetic Smoke Test
 │
 └── [Backend CD]:
      ├── 1. OIDC STS Exchange
      ├── 2. Build Multi-stage Container & Tag with Git SHA
      ├── 3. Push Image to Amazon ECR
      ├── 4. AWS SSM Command dispatched to target EC2 instances
      ├── 5. EC2 host pulls ECR image via IAM Instance Profile
      ├── 6. Launches standby container on alternate port (8081)
      ├── 7. Loops health check on http://127.0.0.1:8081/health
      ├── 8. Atomic NGINX upstream switch & reload
      ├── 9. Drains & stops old container (8080)
      ├── 10. External API Smoke Test & Step Summary
```

### What We Deliberately Left Out (and Why)

1. **Direct SSH / SCP with Stored Private Keys:**
   - *Why omitted:* Hardcoding SSH keys in CI secrets creates static credentials vulnerable to exfiltration and requires opening port 22 in VPC Security Groups. AWS SSM Run Command operates outbound-only via HTTPS over the AWS backbone, providing superior security and compliance.
2. **Blanket CloudFront Invalidation (`/*`):**
   - *Why omitted:* Invalidating `/*` clears the entire edge cache, forcing every edge PoP worldwide to fetch static JS and CSS files back from S3. This degrades client load times and incurs unnecessary AWS invalidation charges ($0.005/path after the first 1,000 monthly paths). Because hashed assets are unique per build, invalidating only `/index.html` instantly updates all clients while preserving CDN cache hit ratios.
3. **Database Migration Automation Inside Container Startup:**
   - *Why omitted:* Running database schema migrations (e.g. `prisma migrate deploy` or `flyway`) indiscriminately inside EC2 container startup scripts causes race conditions and deadlock if multiple EC2 instances start concurrently. Schema migrations should be handled in a dedicated, isolated pre-deployment migration step with backward-compatible schema design (expand/contract pattern).
4. **Heavy Kubernetes / ECS Orchestration Setup:**
   - *Why omitted:* The specification explicitly states the backend is deployed to **EC2**. Introducing Kubernetes (EKS) or ECS Fargate would violate the defined infrastructure parameters. Instead, we implemented a lightweight, container-based Blue/Green pattern with NGINX directly on EC2, achieving zero downtime without cluster overhead.
5. **Long-Lived Static AWS Access Keys:**
   - *Why omitted:* AWS IAM credentials generated as static keys (`AKIA...`) are a leading cause of cloud security incidents. We strictly employ GitHub Actions OpenID Connect (OIDC) federation with AWS STS, providing temporary tokens valid only for the lifespan of each job.

---

## 7. Rollback Procedures & Failure Recovery

### Automated Rollbacks
- **Backend:** If the new container fails the local healthcheck on `127.0.0.1:<target_port>/health` within 60 seconds, [`deploy.sh`](backend/scripts/deploy.sh) terminates the target container. NGINX upstream is never reloaded, and the existing live container continues serving traffic without interruption.
- **Frontend:** Because hashed chunks from previous releases remain in S3 (managed under lifecycle policies), re-uploading the previous commit's `index.html` instantly restores the application to the prior working state.

### Manual One-Click Rollback Runbook
If an unexpected application defect slips past automated tests into production:
1. **Frontend Rollback:**
   - Go to GitHub Actions ➔ **Frontend CD**.
   - Click **Run workflow**.
   - Select the target Git commit or tag of the known healthy release.
   - The workflow rebuilds, uploads the prior entrypoint, and invalidates CloudFront in under 60 seconds.
2. **Backend Rollback:**
   - Go to GitHub Actions ➔ **Backend CD**.
   - Click **Run workflow**.
   - Enter the previously known healthy Git SHA in the `rollback_image_tag` parameter.
   - The workflow skips rebuilding and commands EC2 to pull and switch directly to the specified ECR image tag.
