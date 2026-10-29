# Problem 5: Fortify The Castle — Architecture Security Blueprint

## Executive Summary & Security Philosophy

In financial trading systems — particularly cryptocurrency exchanges handling real-time asset settlement — security cannot be treated as a perimeter firewall or an audit checklist appended after deployment. A single compromised container, unauthorized memory read, or race condition in order processing can lead to catastrophic capital loss, front-running, regulatory shutdown, or market manipulation.

This document redesigns the high-throughput (500 RPS), sub-100ms p99 trading platform designed in **Problem 1** into a **zero-trust, defense-in-depth architecture**. Security is embedded directly into the network topology, compute runtime, communication buses, matching engine memory space, database ledger schemas, and operational workflows.

---

## 1. Updated Secure Architecture

### Architecture Diagram

The diagram below reflects the evolved Problem 1 architecture with explicit security annotations:
- `[SEC-ADD]`: New security component introduced to fortify the architecture.
- `[SEC-MOD]`: Existing component modified or hardened from Problem 1.
- `[SEC-UNCHANGED]`: Component retained with original performance baseline.

```
                             [ Public Internet: Institutional & Retail ]
                                                  │
                 ┌────────────────────────────────┴────────────────────────────────┐
                 │                                                                 │
      [ REST / Public API Traffic ]                                   [ Market Data WebSockets ]
                 │                                                                 │
                 ▼                                                                 ▼
      ┌─────────────────────────────────┐                             ┌─────────────────────────────────┐
      │ [SEC-ADD] Route 53 DNSSEC       │                             │ [SEC-ADD] Route 53 DNSSEC       │
      │ + AWS Shield Advanced (L3/L4)   │                             │ + AWS Shield Advanced (L3/L4)   │
      │ + AWS WAF (Rate Limit, Bot Ctl) │                             │ + AWS Shield DDoS Protection    │
      └────────────────┬────────────────┘                             └────────────────┬────────────────┘
                       │                                                               │
                       ▼                                                               ▼
      ┌─────────────────────────────────┐                             ┌─────────────────────────────────┐
      │ [SEC-MOD] AWS CloudFront        │                             │ [SEC-MOD] AWS Global Accelerator│
      │ - TLS 1.3 / Strict Ciphers      │                             │ - L4 TCP Anycast Backbone       │
      │ - Origin Access Control (OAC)   │                             │ - Anti-Jitter Fast Failover     │
      └────────────────┬────────────────┘                             └────────────────┬────────────────┘
                       │                                                               │
                       ▼                                                               ▼
 ┌─────────────────────┼───────────────────────────────────────────────────────────────┼─────────────────────┐
 │ AWS VPC (Isolated CIDR 10.100.0.0/16, Multi-AZ)                                     │                     │
 │                                                                                     │                     │
 │ ── PUBLIC INGRESS SUBNETS (AZ-a, AZ-b, AZ-c) ────────────────────────────────────── │ ─────────────────── │
 │                     │                                                               │                     │
 │                     ▼                                                               ▼                     │
 │      ┌──────────────────────────────┐                              ┌──────────────────────────────┐       │
 │      │ [SEC-MOD] Dual-Stack ALB     │                              │ [SEC-MOD] Dual-Stack NLB     │       │
 │      │ - AWS WAF Ingress Inspection │                              │ - TLS 1.3 Termination        │       │
 │      │ - Drops Invalid HTTP Headers │                              │ - [SEC-ADD] Client mTLS for  │       │
 │      │ - Custom Header from CF (OAC)│                              │   Institutional Accounts     │       │
 │      └──────────────┬───────────────┘                              └──────────────┬───────────────┘       │
 │                     │                                                             │                       │
 │ ── PRIVATE APPLICATION SUBNET (EKS - Bottlerocket Minimal OS, Cilium eBPF) ─────── │ ─────────────────── │
 │                     │                                                             │                       │
 │                     ▼                                                             ▼                       │
 │      ┌──────────────────────────────┐                              ┌──────────────────────────────┐       │
 │      │ [SEC-MOD] API Gateway Pods   │                              │ [SEC-MOD] WS Gateway Pods    │       │
 │      │ - HMAC / Ed25519 Request Sig │                              │ - Read-Only Market Stream    │       │
 │      │ - Nonce & Timestamp Anti-Rep │                              │ - Token-Bucket Rate Limit    │       │
 │      │ - IRSA Scoped IAM Roles      │                              │ - Read-Only Root Filesystem  │       │
 │      └──────────────┬───────────────┘                              └──────────────▲───────────────┘       │
 │                     │                                                             │ (Pub/Sub)             │
 │                     ▼                                                             │                       │
 │      ┌──────────────────────────────┐                                             │                       │
 │      │ [SEC-MOD] Order Service Pods │                                             │                       │
 │      │ - Pre-Trade Balance Check    │                                             │                       │
 │      │ - Deterministic Ingest Clock │                                             │                       │
 │      │ - Restrictive Linux Caps     │                                             │                       │
 │      └──────────────┬───────────────┘                                             │                       │
 │                     │                                                             │                       │
 │ ── PRIVATE MESSAGING SUBNET (Encrypted Event Bus, Zero Internet Routing) ─────────── │ ─────────────────── │
 │                     │                                                             │                       │
 │                     ▼                                                             │                       │
 │      ┌─────────────────────────────────────────────────────────────┐              │                       │
 │      │ [SEC-MOD] Amazon MSK Kafka: `orders.inbound`                │              │                       │
 │      │ - Mutual TLS (mTLS) + SASL/SCRAM Authentication             │              │                       │
 │      │ - Encryption in-transit (TLS 1.3) & at-rest (KMS CMK)       │              │                       │
 │      │ - Topic ACLs: Only Order Service can Write, Engine can Read │              │                       │
 │      └──────────────────────────────┬──────────────────────────────┘              │                       │
 │                                     │                                             │                       │
 │ ── CORE MATCHING SUBNET (Isolated Dedicated Compute, Zero Egress) ───────────────── │ ─────────────────── │
 │                                     │                                             │                       │
 │                                     ▼                                             │                       │
 │      ┌─────────────────────────────────────────────────────────────┐              │                       │
 │      │ [SEC-MOD] Matching Engine (Dedicated c7i.2xlarge)           │              │                       │
 │      │ - [SEC-ADD] Nitro Enclaves / TPM Secure Enclave Execution   │              │                       │
 │      │ - In-Memory Ring Buffer (Zero Allocations in Critical Path)  │              │                       │
 │      │ - Local NVMe Journal with KMS CMK / LUKS Hardware Key       │              │                       │
 │      │ - Single-Pair Partition Pinning (Prevents Thread Contention)│              │                       │
 │      └──────────────────────────────┬──────────────────────────────┘              │                       │
 │                                     │                                             │                       │
 │ ── PRIVATE MESSAGING SUBNET ────────┼─────────────────────────────────────────────┼───────────────────── │
 │                                     ▼                                             │                       │
 │      ┌─────────────────────────────────────────────────────────────┐              │                       │
 │      │ [SEC-MOD] Amazon MSK Kafka: `orders.matched`                │              │                       │
 │      │ - Topic ACLs: Only Matching Engine can Produce              │              │                       │
 │      │ - Multi-AZ Replicated Stream (`min.insync.replicas=2`)      │              │                       │
 │      └──────────────┬──────────────────────────────┬───────────────┘              │                       │
 │                     │                              │                              │                       │
 │ ── PRIVATE DATA TIER SUBNETS (Zero-Egress, No NAT Gateways, VPC Endpoints) ─────── │ ─────────────────── │
 │                     │                              │                              │                       │
 │                     ▼                              ▼                              │                       │
 │      ┌──────────────────────────────┐┌─────────────────────────────┐              │                       │
 │      │ [SEC-MOD] Ledger & Clearing  ││[SEC-MOD] Market Data Service│              │                       │
 │      │ - Double-Entry Bookkeeping   ││- Strips PII / Account IDs   │              │                       │
 │      │ - Cryptographic Hash Chain   ││- Publishes Aggregate Depth  │              │                       │
 │      └──────────────┬───────────────┘└─────────────┬───────────────┘              │                       │
 │                     │                              │                              │                       │
 │                     │                              ▼                              │                       │
 │                     │                ┌─────────────────────────────┐              │                       │
 │                     │                │ [SEC-MOD] Redis Cluster     │──────────────┘                       │
 │                     │                │ - In-Transit TLS & AUTH     │                                      │
 │                     │                │ - Encrypted at Rest (KMS)   │                                      │
 │                     │                └─────────────────────────────┘                                      │
 │                     ▼                                                                                     │
 │      ┌─────────────────────────────────────────────────────────────┐                                      │
 │      │ [SEC-MOD] Aurora PostgreSQL (Multi-AZ Cluster)              │                                      │
 │      │ - Row-Level Security (RLS) & Column-Level Encryption        │                                      │
 │      │ - Immutable Ledger Tables (Append-Only Triggers, No DELETE) │                                      │
 │      │ - AWS KMS CMK Dedicated Customer Managed Key                │                                      │
 │      └─────────────────────────────────────────────────────────────┘                                      │
 │                                                                                                           │
 │ ── [SEC-ADD] PRIVATE ENDPOINTS & CONTROL PLANE (AWS PrivateLink) ──────────────────────────────────────── │
 │    - Interface Endpoints: KMS, Secrets Manager, S3, CloudWatch, ECR, STS (No traffic leaves AWS backbone) │
 └───────────────────────────────────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
        ┌────────────────────────────────────────────────────────────────────────────┐
        │ [SEC-ADD] AUDIT, DETECTION & COMPLIANCE TIER (Isolated Security AWS Account)│
        │ - AWS CloudTrail Lake with WORM S3 Object Lock (Compliance Mode)           │
        │ - Amazon GuardDuty (EKS Runtime Monitoring, S3 Malware, RDS Anomaly)       │
        │ - AWS Security Hub & Automated FinTech Fraud / Flash-Crash Alerting        │
        └────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Architectural Security Enhancements & Rationale

| # | Architectural Change | Origin Component | Threat / Attack Vector Protected Against | Implementation Mechanism |
|---|---|---|---|---|
| **1** | **Route 53 DNSSEC & AWS Shield Advanced** | Edge / Ingress | DNS spoofing, cache poisoning, Layer 3/4 SYN floods, reflection attacks | Route 53 DNSSEC signing with automated key rotation; AWS Shield Advanced protecting Anycast IPs and ALBs with 24/7 DDoS Response Team (DRT) support. |
| **2** | **AWS WAF with Custom Ingress Rules & Bot Control** | Edge / Ingress | Layer 7 HTTP floods, scraping bots, credential stuffing, API abuse | Rate-limiting rules (100 req/min per IP on order endpoints, 2000 req/min on public depth endpoints); managed bot control signatures; custom origin secret headers between CloudFront and ALB to block direct-to-IP bypass. |
| **3** | **Institutional Client mTLS & API Signature Verification** | Ingress & API Gateway | Stolen API keys, Man-in-the-Middle (MITM) tampering, replay attacks | Dual-track ingress: retail clients use Ed25519/HMAC-SHA256 request signatures with timestamp anti-replay verification (5-second drift limit); institutional high-frequency traders terminate mutual TLS (mTLS) directly on NLBs using enterprise X.509 certificates. |
| **4** | **Strict Subnet Stratification & Zero-Egress Network Isolation** | VPC Network Topology | Lateral movement, data exfiltration, reverse shells from compromised services | Multi-tier VPC: Ingress Subnet, App Subnet, Messaging Subnet, Matching Subnet, Data Subnet. Matching and Database subnets have **zero route table entries** to Internet Gateways or NAT Gateways. Outbound AWS API calls route exclusively through AWS PrivateLink Interface Endpoints. |
| **5** | **Cilium eBPF CNI with Pod-to-Pod WireGuard Encryption** | Kubernetes (EKS) | Inter-pod eavesdropping, ARP spoofing, lateral movement within EKS | Cilium replaces standard AWS-VPC CNI to provide kernel-level transparent WireGuard encryption between nodes without Envoy sidecar CPU overhead. Default-deny L3/L4/L7 Kubernetes NetworkPolicies ensure only authorized service pairs communicate. |
| **6** | **Amazon Bottlerocket OS & Restricted Pod Security Standards** | Container Host & Runtime | Container breakout, privilege escalation, root persistence, host file tampering | Worker nodes run Bottlerocket OS (read-only root filesystem, SELinux in enforcing mode, no package manager, no SSH server). Pods enforce Kubernetes `Restricted` PSS: `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `runAsNonRoot: true`, `capabilities: { drop: ["ALL"] }`. |
| **7** | **AWS Nitro Enclaves & TPM-Bound NVMe Storage** | Matching Engine (c7i.2xlarge) | Unauthorized memory dumps, hypervisor/host OS compromise, cold-boot disk theft | The matching engine runs inside an isolated AWS Nitro Enclave with no persistent storage, no interactive access, and no external network interface; communicates with the host only via a local virtual socket (`vsock`). Local NVMe ring buffers are encrypted using ephemeral keys derived from the Nitro TPM chip and KMS CMK. |
| **8** | **Kafka Topic ACLs, SASL/SCRAM & mTLS** | Event Bus (Amazon MSK) | Rogue publisher injecting fraudulent orders, unauthorized subscriber reading market order flow | MSK enforces TLS 1.3 in-transit and KMS CMK at rest. Strict Apache Kafka Access Control Lists (ACLs) dictate that only the Order Service can produce to `orders.inbound`, only the Matching Engine can consume `orders.inbound` and produce to `orders.matched`, and only Ledger/Market Data can consume `orders.matched`. |
| **9** | **Append-Only Immutable Ledger with Double-Entry Constraints** | Data Tier (Aurora PostgreSQL) | Account balance tampering, negative balance exploits, unauthorized updates/deletions | Aurora enforces double-entry accounting where every trade generates equal and opposite debit/credit entries. Database triggers prevent any `UPDATE` or `DELETE` on the `ledger_entries` table. PostgreSQL Row-Level Security (RLS) isolates client balances. Each block of ledger entries contains a cryptographic SHA-256 hash pointer linking to the preceding block. |
| **10** | **WORM S3 Object Lock & GuardDuty Threat Detection** | Audit & Compliance Tier | Insider threat altering audit trails, rogue admin deleting evidence of exploit | Centralized audit logs (CloudTrail, VPC Flow Logs, Kafka execution logs) are streamed to a dedicated, cross-account AWS S3 bucket configured with **S3 Object Lock in Compliance Mode**. Neither the root account nor any IAM administrator can overwrite or delete records during the mandatory 7-year retention period. Amazon GuardDuty continuously analyzes runtime EKS syscalls and database query anomalies. |

---

## 3. Deep-Dive Security Controls by Architectural Tier

### Tier 1: Ingress, Perimeter Defense & API Authentication
1. **CloudFront to ALB Origin Protection:**
   Direct IP access to the Application Load Balancer is blocked. CloudFront attaches an automated rotating cryptographic header (`X-Origin-Verify: <secret>`) verified by AWS WAF on the ALB. If the header is missing or invalid, the request is dropped with HTTP 403 before parsing request bodies.
2. **Deterministic Request Signing & Replay Protection:**
   Every authenticated trading endpoint requires:
   - Header `X-API-KEY`: Public key identifier.
   - Header `X-SIGNATURE`: Ed25519 or HMAC-SHA256 signature calculated over `HTTP_METHOD + PATH + TIMESTAMP + NONCE + BODY`.
   - Header `X-TIMESTAMP`: Milliseconds since epoch. The API Gateway validates that `|Server_Time - X-TIMESTAMP| < 5000ms`. Nonces are checked against Redis with an expiring 10-second TTL to guarantee absolute replay resistance.
3. **Institutional Low-Latency Bypass (NLB + mTLS):**
   High-frequency market makers connect over WebSocket/TCP through AWS Global Accelerator into an NLB. NLB terminates mutual TLS using client certificates issued by an internal AWS Private Certificate Authority (Private CA). If the certificate does not match the pinned public key associated with the institutional account, the TCP handshake is terminated immediately.

### Tier 2: Network Segmentation & Zero-Trust Perimeters
1. **Subnet Topology & Route Table Segregation:**
   ```
   [Public Ingress Subnet]       --> Route: 0.0.0.0/0 via Internet Gateway
   [Private App Subnet (EKS)]    --> Route: 0.0.0.0/0 via NAT Gateway (Egress only for updates)
   [Private MSK Subnet]          --> Route: Local VPC Only (Zero Internet / No NAT)
   [Core Matching Subnet]        --> Route: Local VPC Only (Zero Internet / No NAT)
   [Private Data Subnet]         --> Route: Local VPC Only (Zero Internet / No NAT)
   ```
2. **AWS PrivateLink VPC Interface Endpoints:**
   Because the core matching engine, messaging cluster, and database subnets have zero internet access, internal communication to AWS managed services is maintained through PrivateLink VPC Endpoints provisioned inside the private subnets:
   - `com.amazonaws.<region>.kms` (Key cryptographic operations)
   - `com.amazonaws.<region>.secretsmanager` (Credential rotation)
   - `com.amazonaws.<region>.s3` (Gateway endpoint for audit data streaming)
   - `com.amazonaws.<region>.ecr.api` & `ecr.dkr` (Secure container image pulls)
   - `com.amazonaws.<region>.logs` & `monitoring` (CloudWatch metrics/logs)
3. **Security Group Strictness Matrix:**
   - **ALB SG:** Ingress `443` from CloudFront IP ranges only; Egress `8080` to EKS API Gateway SG only.
   - **EKS App SG:** Ingress `8080` from ALB SG only; Egress `9092/9094` to MSK SG only.
   - **MSK SG:** Ingress `9094` from EKS App SG and Matching Engine SG only; Egress: none.
   - **Matching Engine SG:** Ingress `9094` from MSK SG only; Egress `9094` to MSK SG only.
   - **Aurora DB SG:** Ingress `5432` from Ledger Pods SG only; Egress: none.
   - **Redis SG:** Ingress `6379` from Market Data & WS Gateway SG only; Egress: none.

### Tier 3: Compute, Container & Supply Chain Hardening
1. **Minimal Host OS (Bottlerocket):**
   EKS worker nodes run AWS Bottlerocket OS. Bottlerocket has no Python, no Bash, no package managers (no `apt` or `yum`), and uses dm-verity for kernel-level block device verification. Host updates are applied as atomic A/B partition swaps orchestrated by the Bottlerocket Update Operator.
2. **Container Security & Admission Enforcement:**
   - **Image Signing:** All container images are built via an automated GitHub Actions CI pipeline, signed using Cosign (Sigstore), and stored in private Amazon ECR.
   - **Admission Controller (Kyverno):** Enforces that pods cannot be scheduled unless the image signature verifies against the organizational Cosign public key.
   - **Pod Security Context:**
     ```yaml
     securityContext:
       allowPrivilegeEscalation: false
       readOnlyRootFilesystem: true
       runAsNonRoot: true
       runAsUser: 10001
       capabilities:
         drop:
           - ALL
     ```
3. **Cilium eBPF Kernel Security & WireGuard:**
   Cilium bypasses `iptables` using Linux eBPF, reducing network latency by 15–20% compared to standard kube-proxy while injecting transparent WireGuard encryption between nodes. It inspects Layer 7 HTTP calls pod-to-pod to enforce exact HTTP verb and path constraints (e.g., Ledger pods can only call `POST /reconcile` and cannot invoke administrative endpoints).

### Tier 4: Core Matching Engine Protection & Determinism
1. **AWS Nitro Enclave Isolation:**
   The C7i instance runs the order matching engine inside an AWS Nitro Enclave:
   - Nitro Enclaves have no external network adapters, no interactive terminal sessions, and zero access from the parent EC2 instance except through a point-to-point `vsock`.
   - Even an operator with root access on the parent EC2 host cannot inspect memory or attach a debugger (`gdb`, `ptrace`) to the matching engine process.
2. **MEV & Front-Running Mitigation:**
   - **Strict Kafka Partition Sequencing:** Orders for a specific trading pair (e.g., `BTC/USDT`) are mapped deterministically to a single partition in `orders.inbound` using the symbol as the partition key.
   - **Monotonic Hardware Sequencing:** The API Gateway stamps every inbound order with a nanosecond monotonic timestamp (`clock_gettime(CLOCK_MONOTONIC_RAW)`) before producing to Kafka.
   - The matching engine processes orders strictly in sequence, rendering internal network race conditions or selective order reordering impossible.
3. **Encrypted Local NVMe Journaling:**
   The C7i instance uses attached local NVMe drives formatted with LUKS. The encryption key is derived using AWS Nitro TPM attestation and AWS KMS Customer Managed Keys. If the EC2 instance is terminated or unmounted, the data on the NVMe drive becomes cryptographically unrecoverable.

### Tier 5: Financial Ledger & Database Integrity
1. **Double-Entry Bookkeeping Guarantees:**
   The Aurora PostgreSQL database is architected so money cannot be created or destroyed out of thin air. The database schema enforces that every trade consists of balanced debit and credit entries across maker and taker accounts:
   $$\sum \text{Debits} = \sum \text{Credits}$$
2. **Immutable Append-Only Ledger Schema:**
   ```sql
   -- Trigger preventing any UPDATE or DELETE operations on financial ledger
   CREATE OR REPLACE FUNCTION enforce_ledger_immutability()
   RETURNS TRIGGER AS $$
   BEGIN
       RAISE EXCEPTION 'SECURITY VIOLATION: Ledger entries are immutable. Operation % is forbidden.', TG_OP;
   END;
   $$ LANGUAGE plpgsql;

   CREATE TRIGGER trg_protect_ledger
   BEFORE UPDATE OR DELETE ON financial_ledger
   FOR EACH ROW EXECUTE FUNCTION enforce_ledger_immutability();
   ```
3. **Cryptographic Tamper-Evidence (Merkle / Hash Chaining):**
   Each record in `financial_ledger` contains a `previous_entry_hash` column:
   $$\text{EntryHash}_n = \text{HMAC-SHA256}(\text{EntryHash}_{n-1} \,\|\, \text{AccountID} \,\|\, \text{Delta} \,\|\, \text{SequenceID} \,\|\, \text{Timestamp})$$
   Any out-of-band database modification breaks the cryptographic hash chain, triggering immediate automated reconciliation alerts and halting balance withdrawals.

### Tier 6: Observability, WORM Auditability & Threat Detection
1. **WORM S3 Object Lock (Compliance Mode):**
   All order lifecycle events, trade fills, administrative configuration changes, and VPC Flow Logs are streamed via Kinesis Data Firehose into an Amazon S3 Audit Bucket:
   - **Object Lock:** Set to `COMPLIANCE` mode with a 7-year retention period.
   - **Root Account Protection:** In Compliance mode, no user — including the AWS Account Root User or AWS IAM Administrators — can alter, delete, or reduce the retention period of any log object.
2. **Automated Threat & Anomaly Detection:**
   - **Amazon GuardDuty:** Enabled across EKS (monitoring abnormal API calls, container process launches), S3 (detecting exfiltration patterns), and RDS (monitoring unusual database logins or bulk queries).
   - **Real-Time Financial Anomaly Stream:** An Apache Flink stream running on EKS continuously calculates account velocity, sudden withdrawal spikes, and wash-trading heuristics across `orders.matched`. If an account exhibits abnormal behavior, an automated circuit breaker freezes trading for that account via Redis lock in < 50ms.

---

## 4. Deliberate Trade-Offs & Accepted Risks

In a mission-critical trading engine targeting 500 RPS with a **sub-100ms p99 SLA**, security controls must not destroy system throughput or add jitter. The following trade-offs were deliberately made:

### Trade-Off 1: WireGuard Node-Level Encryption vs In-Process mTLS on Matching Engine
- **Accepted Risk:** Internal TCP/vsock traffic between the Ingest consumer and the Matching Engine is not encrypted with application-layer mutual TLS.
- **Why We Left It Out:** Running full TLS termination inside the single-threaded matching engine loop introduces 4–8ms of cryptographic CPU overhead and unpredictable GC/memory allocation pauses. This would directly violate the 2ms matching budget and breach the 100ms p99 SLA.
- **Compensating Controls:**
  1. The matching engine runs inside an isolated AWS Nitro Enclave.
  2. Physical traffic between EC2 nodes is encrypted at the Linux kernel level via Cilium WireGuard.
  3. Security Groups enforce single-port, single-protocol isolation with zero egress.

### Trade-Off 2: Asynchronous Database Settlement vs Synchronous 2-Phase Commit (2PC)
- **Accepted Risk:** Trades are acknowledged to the client after execution in the matching engine memory and durability in Kafka, *before* the trade is written to Aurora PostgreSQL.
- **Why We Left It Out:** Synchronous two-phase commit across a relational database cluster takes 30–75ms per transaction under load. Forcing synchronous DB writes in the hot order path would cause head-of-line blocking and breach the p99 SLA.
- **Compensating Controls:**
  1. Orders are journaled to local NVMe storage within 2ms.
  2. Matched events are published to Kafka MSK with `acks=all` and `min.insync.replicas=2` across 3 AZs before the client receives an execution ACK. If the ledger service crashes, the event stream is replayed from Kafka with zero state loss.

### Trade-Off 3: AWS KMS Customer Managed Keys (CMKs) vs Hardware CloudHSM
- **Accepted Risk:** We do not deploy dedicated AWS CloudHSM hardware security modules for order validation and ledger signing at launch.
- **Why We Left It Out:** CloudHSM costs $1,500/month per appliance (minimum $4,500/month for Multi-AZ) and requires complex PKCS#11 client daemon management, introducing operational fragility.
- **Compensating Controls:** AWS KMS with Customer Managed Keys (CMKs), strict IAM resource policies, CloudTrail logging, and automatic annual key rotation provide FIPS 140-3 Level 3 physical HSM security managed by AWS at a fraction of the complexity and cost.

### Trade-Off 4: Selective WAF Inspection vs Deep Packet Inspection on WebSocket Streams
- **Accepted Risk:** Layer 7 AWS WAF inspection is applied only during the initial HTTP/WebSocket upgrade handshake, not on every individual market data packet streamed over the established WebSocket connection.
- **Why We Left It Out:** Inspecting every 100-byte market tick inside an inline Layer 7 WAF proxy adds 5–15ms of jitter, creates buffering delays, and fragments high-speed tick data.
- **Compensating Controls:**
  1. Client authentication and authorization occur during the initial TLS/HTTP upgrade.
  2. WebSocket gateway pods enforce an in-memory token-bucket rate limiter.
  3. The outbound market data stream contains only sanitized, public market depth (no PII or account data).

---

## 5. Triaging & Implementation Priorities

If engineering resources or deployment deadlines are constrained, security must be prioritized systematically. Below is the operational prioritization framework:

```
┌────────────────────────────────────────────────────────────────────────────┐
│ TIER 0: "REFUSE TO SHIP WITHOUT" (Absolute Non-Negotiables)                │
│ - Zero-egress network isolation for Database, Messaging, and Engine        │
│ - Double-entry database constraints & immutable ledger table triggers      │
│ - KMS CMK encryption at rest (Aurora, MSK, S3) & TLS 1.3 in-transit        │
│ - Request signature verification (HMAC/Ed25519) + Anti-replay timestamps   │
│ - IAM Least Privilege with IRSA (no hardcoded credentials anywhere)        │
│ - S3 Object Lock Compliance Mode for financial execution audit trails      │
└─────────────────────────────────────┬──────────────────────────────────────┘
                                      │
                                      ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ TIER 1: "MVP LAUNCH PRIORITIES" (Secured Before First Public Trade)        │
│ - AWS WAF rate limiting & bot control on API endpoints                     │
│ - Bottlerocket minimal OS & Kubernetes Restricted Pod Security Standards   │
│ - Cilium eBPF NetworkPolicies & WireGuard pod-to-pod encryption            │
│ - Kafka MSK SASL/SCRAM + mTLS and strict topic-level ACLs                  │
│ - GuardDuty runtime anomaly detection across EKS and RDS                   │
└─────────────────────────────────────┬──────────────────────────────────────┘
                                      │
                                      ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ TIER 2: "DEFERRED TO PHASE 2" (Post-Launch Hardening)                      │
│ - AWS Nitro Enclaves for Matching Engine (launch with dedicated EC2 C7i)   │
│ - Institutional Client mTLS termination on NLBs (launch with HMAC API keys)│
│ - Real-Time Flink automated fraud / wash-trading detection pipeline        │
│ - Dedicated AWS CloudHSM integration for institutional custodial keys      │
│ - Automated continuous chaos & red-teaming pipelines in production         │
└────────────────────────────────────────────────────────────────────────────┘
```

### Why We Refuse to Ship Without Tier 0:
A vulnerability in Tier 0 results in **irreversible financial theft, ledger corruption, or unprovable solvency**. If an attacker modifies balances in Aurora, the exchange is insolvent. If credentials are leaked, all funds are compromised. If audit logs can be wiped, an insider can steal funds and erase their tracks. These controls cannot be retrofitted post-launch.

### Why We Can Safely Defer Tier 2:
Running the matching engine on dedicated, single-tenant C7i instances with strict Security Groups provides robust baseline isolation. Nitro Enclaves add an extra layer of hypervisor isolation that can be rolled out seamlessly in Phase 2 without altering the external API contract.

---

## 6. Unknown Facts, Assumptions & Information Gathering Plan

When engineering real-world FinTech infrastructure, certain business and regulatory facts are unknown at the outset. The table below articulates what is needed, how to obtain it, and what was assumed in the meantime:

| Unknown Fact / Question | Impact on Security Architecture | How to Obtain It | Interim Assumption Made |
|---|---|---|---|
| **1. Target Regulatory Jurisdictions & Licensing** | Dictates data residency (GDPR, MAS, MiCA, FinCEN), KYC/AML storage rules, and whether cryptographic keys must reside in specific geographical zones. | Review requirements with Compliance Officer and local legal counsel in Singapore (MAS), EU (MiCA), and US (FinCEN). | Assumed global operations adhering to **SOC 2 Type II, ISO 27001, and MAS TRM (Technology Risk Management)** guidelines. Multi-region cross-border replication is restricted until data sovereignty is approved. |
| **2. Client Traffic Distribution (Retail vs Institutional)** | If institutional FIX protocol volume exceeds 40%, public internet ingress is insufficient and requires dedicated AWS Direct Connect cross-connects with hardware MACsec encryption. | Analyze Business Development pipeline and signed Market Maker Letters of Intent (LOIs). | Assumed **80% Retail (Web/Mobile via CloudFront & Global Accelerator)** and **20% Institutional (REST API & WebSockets with API Key/mTLS)**. Direct Connect deferred to Phase 2. |
| **3. Cryptocurrency Custody Model (Hot/Cold Wallets)** | If the platform directly manages private keys for blockchain deposits/withdrawals, an MPC (Multi-Party Computation) cluster or hardware signing service (e.g., Fireblocks) must be integrated into the ledger subnet. | Architecture review with the Chief Information Security Officer (CISO) and Treasury Team. | Assumed **the exchange runs an off-chain ledger for matching and trading**. On-chain deposits and withdrawals sit behind an asynchronous withdrawal approval queue service outside the hot trading path. |
| **4. Maximum Permissible Maintenance Window / RPO & RTO** | Defines database snapshot frequency, automated failover automation, and disaster recovery orchestration. | Establish SLA targets with Executive Stakeholders and Product Managers. | Assumed **RPO = 0 (zero data loss for confirmed trades)** via Kafka multi-AZ replication, and **RTO < 60 seconds** via Aurora Multi-AZ automatic failover. |

---

## 7. Threat Modeling & Attack Surface Verification Matrix (STRIDE)

| STRIDE Threat Category | Real-World Attack Scenario | Architecture Mitigation & Detection Control | Residual Risk Level |
|---|---|---|---|
| **Spoofing Identity** | Attacker intercepts API credentials and submits rogue sell orders. | Request signing with Ed25519; short-lived nonces; institutional mTLS; IP whitelisting on API keys. | **Low** |
| **Tampering with Data** | Malicious insider executes SQL update on `accounts` table to credit balance. | Immutable ledger trigger rejects `UPDATE/DELETE`; cryptographic hash chaining on ledger rows; CloudTrail Lake audit. | **Negligible** |
| **Repudiation** | Rogue trader claims a liquidated order was never submitted by their system. | Every order payload is hashed and timestamped at ingress, preserved in WORM S3 Object Lock compliance storage. | **Zero** |
| **Information Disclosure** | Competitor intercepts raw internal market data to gain an unfair trading advantage. | Cilium transparent WireGuard encryption for all pod-to-pod traffic; MSK in-transit TLS 1.3; private subnet isolation. | **Low** |
| **Denial of Service** | Volumetric SYN flood or L7 HTTP flood targeting order book depth during high volatility. | AWS Shield Advanced at edge; CloudFront edge caching; AWS WAF rate-limiting; NLB TCP connection limits. | **Low** |
| **Elevation of Privilege** | Attacker exploits zero-day in Web Gateway container to gain host root access. | Bottlerocket immutable OS; Kyverno admission controller drops ALL capabilities; `readOnlyRootFilesystem: true`. | **Low** |

---

## Summary of Architectural Upgrades Over Problem 1

1. **Ingress:** Hardened with Route 53 DNSSEC, AWS Shield Advanced, AWS WAF, Origin Access Control, and institutional mTLS termination.
2. **Network:** Stratified into 5 distinct trust tiers; core matching and ledger tiers operate in **zero-egress, zero-internet subnets** utilizing AWS PrivateLink.
3. **Compute:** Migrated from generic Linux hosts to Amazon Bottlerocket minimal OS, Kubernetes Restricted Pod Security Standards, and Cilium eBPF WireGuard encryption.
4. **Matching Engine:** Isolated inside an AWS Nitro Enclave with TPM-encrypted local NVMe storage and nanosecond deterministic sequencing.
5. **Ledger & Persistence:** Hardened with double-entry accounting constraints, append-only triggers, Row-Level Security, and cryptographic hash chaining.
6. **Auditability:** Elevated to Write-Once-Read-Many (WORM) S3 Object Lock in Compliance Mode with Amazon GuardDuty continuous threat detection.
