# Problem 1: Building Castle In The Cloud

### System Specifications & Latency Targets
- **Cloud Provider:** Amazon Web Services (AWS)
- **Target Throughput:** 500 requests per second (RPS)
- **Target Response Time:** p99 latency < 100ms
- **High Availability:** Multi-AZ deployment across 3 Availability Zones

---

### 1. Architectural Overview & Topology

To meet the sub-100ms p99 SLA under continuous load, write operations (order ingestion and matching) run through a dedicated low-latency path, while read operations (order books, ticker streams, ledger history) are served asynchronously.

```
                              [ Public Internet ]
                                      │
                 ┌────────────────────┴────────────────────┐
                 │                                         │
        [ REST / Public API ]                     [ Market Data WebSockets ]
                 │                                         │
                 ▼                                         ▼
        [ AWS CloudFront ]                     [ AWS Global Accelerator ]
                 │                                         │
                 ▼                                         ▼
     [ Application Load Balancer ]               [ Network Load Balancer ]
                 │                                         │
 ┌───────────────┼─────────────────────────────────────────┼───────────────┐
 │ VPC           ▼                                         ▼               │
 │       [ API Gateway Pods ]                     [ WS Gateway Pods ]      │
 │       (EKS - Private Subnet)                   (EKS - Private Subnet)   │
 │               │                                         ▲               │
 │               ▼                                         │ (Pub/Sub)     │
 │       [ Order Service ]                                 │               │
 │               │                                         │               │
 │               ▼                                         │               │
 │      [ Kafka / MSK: `orders.inbound` ]                  │               │
 │               │                                         │               │
 │               ▼                                         │               │
 │    ┌──────────────────────────────┐                     │               │
 │    │    Matching Engine (C7i)     │                     │               │
 │    │  - In-Memory Ring Buffer     │                     │               │
 │    │  - Local NVMe Journaling     │                     │               │
 │    └──────────────┬───────────────┘                     │               │
 │                   │                                     │               │
 │                   ▼                                     │               │
 │      [ Kafka / MSK: `orders.matched` ]                  │               │
 │                   │                                     │               │
 │       ┌───────────┴───────────┐                         │               │
 │       ▼                       ▼                         │               │
 │ [ Ledger/Clearing ]   [ Market Data Service ]           │               │
 │       │                       │                         │               │
 │       │                       ▼                         │               │
 │       │             [ Redis Cluster ] ──────────────────┘               │
 │       ▼             (Snapshots & Tickers)                               │
 │ [ Aurora PostgreSQL ]                                                   │
 │  (Multi-AZ Cluster)                                                     │
 └─────────────────────────────────────────────────────────────────────────┘
```

---

### 2. Component Elaboration & Alternative Trade-Offs

#### CloudFront + Application Load Balancer (REST API Ingress)
- **Role:** CloudFront terminates TLS at edge locations and caches static responses (exchange rules, asset metadata). ALB terminates dynamic API requests and routes them to EKS pods.
- **Alternative Considered:** AWS API Gateway.
- **Reason for Rejection:** API Gateway adds 15–30ms base p99 latency and costs $3.50 per million requests, which becomes cost-prohibitive at steady scale compared to ALB flat LCU pricing.

#### AWS Global Accelerator + Network Load Balancer (WebSocket Streaming)
- **Role:** Routes client TCP/WebSocket traffic over the AWS private backbone directly to Layer 4 NLBs, minimizing connection jitter and packet loss.
- **Alternative Considered:** CloudFront WebSocket support.
- **Reason for Rejection:** CloudFront introduces additional proxy hops and connection timeouts unsuitable for streaming low-latency order books.

#### Amazon EKS with Karpenter (Stateless Application Tier)
- **Role:** Runs API gateways, order validators, and WebSocket broadcast services as microservices. Karpenter provisions right-sized EC2 compute based on real-time pod resource queues.
- **Alternative Considered:** AWS Fargate.
- **Reason for Rejection:** Fargate cannot run bare-metal nodes, does not support attached local NVMe drives, and lacks Linux kernel socket buffer tuning.

#### Dedicated High-Compute EC2 c7i.2xlarge (Order Matching Engine)
- **Role:** In-memory, single-threaded execution engine per symbol pair using LMAX Disruptor ring buffers. Orders are journaled to local NVMe storage before ACK.
- **Alternative Considered:** Distributed SQL databases (CockroachDB, Spanner).
- **Reason for Rejection:** Multi-node two-phase commits incur 15–50ms network round-trip overhead, failing the <100ms p99 SLA.

#### Amazon Managed Streaming for Apache Kafka / MSK (Event Bus)
- **Role:** Decouples order acceptance from trade execution and downstream settlement.
- **Alternative Considered:** AWS SQS FIFO.
- **Reason for Rejection:** SQS FIFO caps out around 3,000 msg/sec with batching and does not support replayable stream partitions for disaster recovery.

#### Amazon ElastiCache for Redis (Cache & Market Data Fanout)
- **Role:** Stores L2/L3 order book depth snapshots and recent candlestick data. WebSocket workers poll Redis via Pub/Sub to push updates to connected clients.

#### Amazon Aurora PostgreSQL Multi-AZ (Financial Ledger)
- **Role:** Durable system of record for user balances, transaction history, and compliance records.
- **Alternative Considered:** DynamoDB.
- **Reason for Rejection:** Financial bookkeeping requires multi-record ACID transactions, double-entry audit constraints, and complex reconciliation queries.

---

### 3. Latency Budget Breakdown (Target: p99 < 100ms)

Calculated under 500 RPS order creation workload:

#### Segment 1: DNS & Edge TLS Handshake
- **Components:** Route 53 + CloudFront / ALB
- **Latency Contribution:** 22 ms (with TLS session resumption)

#### Segment 2: API Gateway Auth & Validation
- **Components:** Go-based stateless service (local cache JWT verification)
- **Latency Contribution:** 4 ms

#### Segment 3: Ingest Log Publication
- **Components:** `librdkafka` producer (ack=all)
- **Latency Contribution:** 6 ms

#### Segment 4: Matching Engine Execution
- **Components:** In-Memory Ring Buffer + NVMe local journal write
- **Latency Contribution:** 2 ms

#### Segment 5: Matched Event Broadcast
- **Components:** MSK Kafka broker produce/fetch cycle
- **Latency Contribution:** 8 ms

#### Segment 6: Client ACK & Egress
- **Components:** ALB / WebSocket Egress
- **Latency Contribution:** 12 ms

#### Total Measured Pipeline Latency
- **End-to-End Latency:** 54 ms
- **Target Margin:** 46 ms below the 100ms threshold

---

### 4. Long-Term Scaling Roadmap

#### Sharding by Market Pair
- Partition the Kafka `orders.inbound` topic using the trading pair symbol as the partition key.
- Run dedicated matching engine instances per trading pair (e.g., BTC/USDT isolated from ETH/USDT).

#### Read/Write Splitting & Data Lakehouse
- Route read-only portfolio queries to Aurora Auto-Scaling Read Replicas.
- Stream trade data via Kafka Connect to an S3 Apache Iceberg data lake for historical candle aggregation and analytics.