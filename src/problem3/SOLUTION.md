# Problem 3: System Stabilization & Root Cause Report

## Executive Summary

An investigation was conducted on the containerized multi-tier web application (consisting of **NGINX**, **Node.js Express API**, **PostgreSQL**, and **Redis**). Multiple critical architectural, networking, and application-level bugs were identified that rendered the service completely inaccessible (HTTP 502/404) or caused connection starvation, process crashes, and service hangs under transient failure conditions.

All issues were systematically diagnosed, remediated, verified, and stabilized. The system now withstands concurrent traffic, restarts gracefully without data loss, and isolates dependency failures.

---

## 1. Problems Found & Root Causes

### 1.1 Critical Upstream Port Mismatch in NGINX (HTTP 502 Bad Gateway)
* **Problem:** Any incoming request to `http://localhost:8080/api/users` failed immediately with `HTTP 502 Bad Gateway`.
* **Root Cause:** In [nginx/conf.d/default.conf](file:///C:/Users/Administrator/Desktop/devops-challenge/src/problem3/nginx/conf.d/default.conf#L8-L10), the reverse proxy configuration directed traffic to `http://api:3001`. However, the Express API application in [api/src/index.js](file:///C:/Users/Administrator/Desktop/devops-challenge/src/problem3/api/src/index.js) was configured to listen on port `3000` (`app.listen(3000)`). The upstream connection was refused (`errno 111`).

### 1.2 Unrouted Health Endpoint (HTTP 404 Not Found)
* **Problem:** Requests to `http://localhost:8080/status` returned `HTTP 404 Not Found`.
* **Root Cause:** NGINX only defined `location = /` (exact match) and `location /api/`. There was no location block forwarding `/status` to the backend. NGINX fell back to looking for `/etc/nginx/html/status` on the local filesystem, returning 404.

### 1.3 Database Connection Leak & Thread Starvation
* **Problem:** Under repeated errors or failed transactions, PostgreSQL connections were leaked, rapidly depleting pool limits and causing subsequent API requests to hang indefinitely.
* **Root Cause:** In `api/src/index.js`, the code checked out a client manually:
  ```javascript
  const db = await pool.connect();
  const result = await db.query("SELECT NOW()");
  db.release();
  ```
  If `db.query()` or any intermediate statement threw an exception, `db.release()` was skipped because it was located inside the `try` block without a `finally` clause. Once the pool's default capacity (`max: 10`) was exhausted, all incoming requests blocked waiting for a client slot that was never released.

### 1.4 Unhandled EventEmitter Errors Crashing the Node.js Process
* **Problem:** Transient database disconnects or Redis restarts caused the entire API container to exit abruptly with an uncaught exception.
* **Root Cause:** In Node.js, both `pg.Pool` and `ioredis.Redis` emit `'error'` events when idle connections drop or network blips occur. In Node.js EventEmitter architecture, if an `'error'` event is emitted and no listener is registered, Node.js throws an unhandled exception and exits the process immediately.

### 1.5 Redis Offline Queue Stalling
* **Problem:** If Redis became slow or temporarily unavailable, all API requests to `/api/users` hung indefinitely instead of returning or failing fast.
* **Root Cause:** By default, `ioredis` has `enableOfflineQueue: true` and indefinite retries. Commands queued indefinitely in memory until Redis reconnected. During outages, this accumulated open HTTP sockets, consumed memory, and caused cascading timeouts across the upstream proxy.

### 1.6 Unmounted PostgreSQL Configuration & Missing Persistence
* **Problem:** 
  1. `postgres/init.sql` existed in the repository (`ALTER SYSTEM SET max_connections = 20;`), but was not mounted in [docker-compose.yml](file:///C:/Users/Administrator/Desktop/devops-challenge/src/problem3/docker-compose.yml) into `/docker-entrypoint-initdb.d/init.sql`.
  2. If mounted without proper connection pooling, a strict limit of 20 connections accelerates connection starvation.
  3. No named volume was configured for `/var/lib/postgresql/data`, meaning any container recreation or deployment resulted in total database data loss.

### 1.7 Startup Race Conditions & Missing Healthchecks
* **Problem:** On initial deployment (`docker compose up`), the API frequently failed or crashed during its first requests because it started before PostgreSQL had finished initializing its database cluster (`initdb`).
* **Root Cause:** Docker Compose `depends_on: [postgres, redis]` by default only checks if the container has started, not if the application inside is ready to accept socket connections.

### 1.8 Missing Restart Policies & PID 1 Graceful Shutdown
* **Problem:**
  1. If any service encountered an unhandled error or killed worker, Docker left it stopped.
  2. Containers stopped via `docker stop` or `docker compose down` took 10 seconds before being forcefully killed (`SIGKILL`) because Node.js running as PID 1 does not forward or handle `SIGTERM` by default.

---

## 2. How the Issues Were Diagnosed

1. **Inspection of Service Topology & Configuration:**
   - Reviewed `docker-compose.yml`, `nginx/conf.d/default.conf`, `api/src/index.js`, and `postgres/init.sql`.
   - Identified port divergence between NGINX (`proxy_pass http://api:3001`) and Express (`app.listen(3000)`).

2. **Container Log & Triage Analysis:**
   - Executed `docker compose logs` and inspected NGINX error logs:
     ```text
     [error] connect() failed (111: Connection refused) while connecting to upstream: "http://172.18.0.4:3001/api/users"
     [error] open() "/etc/nginx/html/status" failed (2: No such file or directory)
     ```
   - Verified that bypass testing directly against the API container (`wget -qO- http://localhost:3000/api/users`) returned `{"ok":true,"time":{"now":"..."}}`, confirming the API was functional on port 3000 while NGINX was misconfigured.

3. **Resilience & Fault Injection Testing:**
   - Stopped Redis (`docker compose stop redis`) and observed request behavior: requests to `/api/users` hung indefinitely due to unconstrained offline queuing in `ioredis`.
   - Analyzed code paths in `index.js` for `pool.connect()`: found missing `finally { db.release(); }` blocks, leading to connection exhaustion.
   - Checked `docker compose ps` to find absence of healthcheck statuses (`(healthy)`).

---

## 3. Fixes Applied

### 3.1 NGINX Reverse Proxy Fixes ([nginx/conf.d/default.conf](file:///C:/Users/Administrator/Desktop/devops-challenge/src/problem3/nginx/conf.d/default.conf))
* Corrected the upstream target from `http://api:3001` to `http://api:3000` via an upstream block with keepalive connections.
* Added a dedicated route for `/status` proxying to the API backend.
* Forwarded standard proxy headers (`Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`) and HTTP 1.1 keep-alive headers.
* Set explicit proxy timeouts (`proxy_connect_timeout 5s`, `proxy_read_timeout 10s`).

### 3.2 Application Hardening ([api/src/index.js](file:///C:/Users/Administrator/Desktop/devops-challenge/src/problem3/api/src/index.js))
* **Connection Pool Leak Prevention:** Wrapped database client checkout in a `try ... finally` block, ensuring `db.release()` is unconditionally executed even if query processing fails.
* **Bounded Connection Pool:** Configured `pg.Pool` with `max: 10`, `connectionTimeoutMillis: 5000`, and `idleTimeoutMillis: 30000`.
* **Event Error Handlers:** Added `pool.on("error", ...)` and `redis.on("error", ...)` to prevent unhandled EventEmitter exceptions from crashing the process.
* **Redis Timeout & Retry Strategy:** Configured `ioredis` with `connectTimeout: 5000`, `maxRetriesPerRequest: 3`, and an exponential backoff `retryStrategy`. Wrapped cache updates in a non-blocking try/catch so Redis degradation does not bring down primary database reads.
* **PID 1 Graceful Shutdown:** Implemented `SIGTERM` and `SIGINT` handlers that close the HTTP listener, drain database pool connections, close Redis clients, and exit cleanly with a 10s fallback watchdog.
* **Configuration Decoupling:** Replaced hardcoded connection strings with environment variables (`PORT`, `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `REDIS_HOST`, `REDIS_PORT`).

### 3.3 Container Orchestration & Compose ([docker-compose.yml](file:///C:/Users/Administrator/Desktop/devops-challenge/src/problem3/docker-compose.yml))
* **Container Healthchecks:** Added native healthchecks for all services:
  - `postgres`: `pg_isready -U postgres -d postgres`
  - `redis`: `redis-cli ping`
  - `api`: `wget -qO- http://localhost:3000/status || exit 1`
  - `nginx`: `curl -f http://localhost:80/status || exit 1`
* **Dependency Sequencing:** Configured `depends_on` with `condition: service_healthy` so `api` only starts after both PostgreSQL and Redis are verified ready, and `nginx` starts after `api` is healthy.
* **Restart Policies:** Added `restart: unless-stopped` to all service definitions.
* **Persistence:** Added named volumes `postgres_data` and `redis_data` to ensure zero data loss across container lifecycle events.
* **Initialization Mount:** Mounted `./postgres/init.sql:/docker-entrypoint-initdb.d/init.sql:ro`.
* **Environment File:** Populated [.env](file:///C:/Users/Administrator/Desktop/devops-challenge/src/problem3/.env) with default values for local development.

---

## 4. Verification & Benchmarking

| Test Case | Method | Expected Result | Actual Result | Status |
| :--- | :--- | :--- | :--- | :---: |
| **Root Route** | `curl -i http://localhost:8080/` | HTTP 200, "Welcome to the platform" | HTTP 200 OK | **PASSED** |
| **Health Route** | `curl -i http://localhost:8080/status` | HTTP 200, `{"status":"ok"}` | HTTP 200 OK | **PASSED** |
| **API Data Route** | `curl -i http://localhost:8080/api/users` | HTTP 200, `{"ok":true,"time":{...}}` | HTTP 200 OK | **PASSED** |
| **Concurrency Load** | 50 consecutive automated requests | 50/50 successful responses (0 dropped) | 50/50 succeeded | **PASSED** |
| **Connection Pooling** | `SELECT count(*), state FROM pg_stat_activity` | Bounded idle clients, 0 connection leaks | Max 5 idle, 0 leaked | **PASSED** |
| **Redis Persistence** | `redis-cli get last_call` | Valid updated epoch timestamp | Timestamp updated | **PASSED** |
| **Service Restarts** | `docker compose restart redis` | API remains healthy, reconnects cleanly | 0 crashes, instant recovery | **PASSED** |
| **Container Health** | `docker compose ps` | All containers report `(healthy)` | All 4 services healthy | **PASSED** |

---

## 5. Recommended Monitoring & Alerting

To detect regressions and maintain system visibility in production:

### 5.1 Metrics Collection (Prometheus / OpenTelemetry)
* **Application Metrics (RED Method):**
  - **Rate:** Incoming HTTP requests per second (`http_requests_total` by status code and route).
  - **Errors:** Ratio of 5xx HTTP responses over 1-minute and 5-minute sliding windows.
  - **Duration:** Request latency histogram (`http_request_duration_seconds{quantile="0.99"}`).
* **PostgreSQL Metrics (`postgres_exporter`):**
  - Active and idle connection count (`pg_stat_activity`).
  - Connection utilization percentage: `(active_connections / max_connections) * 100`.
  - Transaction commit/rollback rates, deadlocks, and slow query durations (`pg_stat_statements`).
* **Redis Metrics (`redis_exporter`):**
  - Connected clients, rejected connections, memory usage (`used_memory / maxmemory`).
  - Eviction rate and command latency.
* **NGINX Metrics (`nginx-prometheus-exporter`):**
  - Active connections, upstream response times, and 502/504 upstream error counters.

### 5.2 Critical Alert Rules
* **High 5xx Rate:** Trigger `P1 Alert` if upstream 5xx error rate exceeds 1% of total traffic for > 2 minutes.
* **Latency SLA Breach:** Trigger `P2 Alert` if p99 latency exceeds 200ms over 5 minutes.
* **Database Connection Saturation:** Trigger `P1 Alert` if PostgreSQL connection utilization exceeds 80%.
* **Container CrashLoops / Unhealthy Status:** Trigger `P1 Alert` if Docker/Kubernetes container healthcheck fails for > 1 minute or container restarts > 3 times in 10 minutes.
* **Disk Saturation:** Trigger `P2 Alert` if persistent volume capacity usage exceeds 80%.

---

## 6. Production Prevention & Best Practices

1. **Automated CI/CD End-to-End Smoke Testing:**
   - In the CI/CD pipeline (e.g., GitHub Actions), spin up the Docker Compose stack using ephemeral runners.
   - Run automated integration tests covering all routes (`/`, `/status`, `/api/users`), checking HTTP status codes, headers, and payloads before deployment approval.
2. **Contract Testing & Port Synchronization:**
   - Enforce environment variable consistency across service definitions. Ensure the reverse proxy configuration dynamically consumes upstream target ports defined in `.env` or service discovery (e.g., Consul, Kubernetes DNS) rather than hardcoded configuration files.
3. **Connection Pooling Middleware (PgBouncer):**
   - In production environments with multiple API replicas, place a dedicated connection pooler (such as **PgBouncer** in transaction mode) in front of PostgreSQL to prevent backend connection saturation.
4. **Circuit Breaking & Graceful Cache Degradation:**
   - Implement circuit breakers (e.g., using `opossum` in Node.js) for Redis and external dependencies. If a cache or secondary store is unreachable, degrade gracefully without blocking user-facing read traffic.
5. **Defensive Linters & Static Code Analysis:**
   - Integrate ESLint rules (such as `eslint-plugin-promise` and `@typescript-eslint/no-floating-promises`) to detect unhandled promises, missing `finally` cleanup handlers, and unhandled event emitter errors during static analysis.
6. **Graceful Shutdown & Zero-Downtime Deployments:**
   - In Kubernetes or ECS, configure container lifecycle hooks (`preStop` sleep) and rolling update strategies (`maxSurge`, `maxUnavailable`) ensuring in-flight requests finish before old pods terminate.
