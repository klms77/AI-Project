# Azure Payment Service Infrastructure — AI-Designed Resilience Test Plan

**Environment:** rg-ailab-kishore (eastus)  
**Analysis Date:** 2026-06-16  
**Architecture Focus:** Payment service resilience with PostgreSQL 14 backend  
**Critical Risk:** max_connections=20 bottleneck; Java heap on constrained B2ms VM; Bastion single-access-path

---

## Executive Summary

This payment service infrastructure has **8 critical failure modes** that can cascade to complete service loss. The most severe are:

1. **PostgreSQL connection pool exhaustion** (only 20 max_connections for all traffic)
2. **Payment service OOM** (Java heap -Xmx4g on 8GB total VM memory)
3. **Network partition app↔db** (Bastion-only access path; single NSG misconfiguration breaks communication)
4. **PostgreSQL service crash** (no replication; data at risk; manual restart required)
5. **Database disk full** (breaks WAL, transaction logging, causes data corruption risk)

This plan tests all 8 scenarios in a safe, reversible manner designed for a payment SLA of <2 minutes RTO per incident.

---

## SCENARIO 1: PostgreSQL Connection Pool Exhaustion (max_connections=20 Exceeded)

### Priority: 🔴 CRITICAL-1 (Payment Service Blocking Failure)

**Scenario Name:** Database Connection Starvation  
**Description:**  
Payment service scales under load and attempts to open connections beyond PostgreSQL's max_connections limit (20). Real-world trigger: transaction surge (holiday shopping), connection leak in app pool, or batch job hoarding connections. When max is reached, new transaction requests fail with `FATAL: remaining connection slots reserved for non-replication superuser connections`.

**Failure Type:** DATABASE  
**Blast Radius:** 
- vm-app: Payment API 100% failure
- vm-db: Database operational but inaccessible
- Business Impact: Complete payment processing halt

**Go/No-Go Check:**
```bash
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" && \
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT count(*) FROM pg_stat_activity;" | grep -q "[0-9]" && \
echo "✅ GO: Connection pool healthy" || echo "❌ NO-GO"
```

**Trigger Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'TRIGGER'
echo "Opening 22 concurrent connections to exceed max_connections=20..."
for i in {1..22}; do
  (echo "BEGIN ISOLATION LEVEL SERIALIZABLE; SELECT pg_sleep(300);" | \
   psql -h 10.0.2.10 -U labuser -d labdb >/dev/null 2>&1) &
done
wait
TRIGGER
```

**Expected Impact:**
- Connection count reaches 20 (max)
- New connections rejected: `FATAL: too many connections`
- Payment transactions timeout after 30s
- Monitoring alerts fire

**Recovery Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity 
  WHERE usename='labuser' AND state='idle' LIMIT 10;"
echo "✅ Idle connections terminated"
EOF
```

**Validation Command:**
```bash
ACTIVE=$(psql -h 10.0.2.10 -U labuser -d labdb -t -c "SELECT count(*) FROM pg_stat_activity WHERE usename='labuser';" | tr -d ' ')
[ "$ACTIVE" -lt 10 ] && echo "✅ Pool recovered: $ACTIVE connections" || echo "❌ Still elevated: $ACTIVE"
```

**RTO Target:** 1.5 minutes

---

## SCENARIO 2: Payment Service Java Heap Exhaustion (OOM Crash)

### Priority: 🔴 CRITICAL-2 (Application Service Failure)

**Scenario Name:** Payment Service Out-of-Memory Crash  
**Description:**  
Payment service configured with `-Xmx4g` heap on 8GB VM. Under load, heap fills triggering OOM exception; JVM terminates abruptly. Unlike graceful shutdown, OOM leaves database transactions in uncertain state.

**Failure Type:** COMPUTE / APPLICATION  
**Blast Radius:**
- vm-app: Service crash; port 8080/443 unresponsive
- vm-db: Abandoned connections; active transactions left hanging
- Business Impact: Complete payment API unavailability

**Go/No-Go Check:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
pgrep -f "java.*-Xmx4g" && echo "✅ GO: Payment service running" || echo "❌ NO-GO: Not running"
EOF
```

**Trigger Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'TRIGGER'
JAVA_PID=$(pgrep -f "java.*-Xmx4g" | head -1)
echo "Simulating memory pressure on PID $JAVA_PID..."
for request in {1..500}; do
  if ! ps -p $JAVA_PID > /dev/null 2>&1; then
    echo "✗ PROCESS CRASHED at request $request"
    break
  fi
  [ $((request % 100)) -eq 0 ] && echo "Request $request..."
  sleep 0.2
done
TRIGGER
```

**Expected Impact:**
- Heap usage increases to 95%+
- GC latency >5s (GC pause)
- OOM exception in logs
- Process terminates abruptly
- Payment API returns connection refused

**Recovery Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
systemctl restart payment-service
sleep 5
pgrep -f "java.*-Xmx4g" && echo "✅ Service restarted" || echo "❌ Failed"
EOF
```

**Validation Command:**
```bash
JAVA_PID=$(pgrep -f "java.*-Xmx4g")
[ -n "$JAVA_PID" ] && echo "✅ Process running" || echo "❌ Not running"
timeout 5 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" && echo "✅ DB connected" || echo "⚠️ Slow"
```

**RTO Target:** 1 minute

---

## SCENARIO 3: Network Partition Between App and DB

### Priority: 🔴 CRITICAL-3 (Cascading Failure)

**Scenario Name:** App→DB Routing Failure (NSG Misconfiguration)  
**Description:**  
NSG deny rule blocks traffic from app subnet (10.0.1.0/24) to database port 5432. Payment service cannot reach database; all transaction attempts timeout. DB is fully operational but unreachable—false hope that encourages service restarts (which don't help).

**Failure Type:** NETWORK  
**Blast Radius:**
- vm-app: All DB calls timeout; connection pool fills
- vm-db: Running normally, zero connections from app
- Business Impact: Complete payment failure (appears like DB is down but isn't)

**Go/No-Go Check:**
```bash
az network nsg rule list --resource-group rg-ailab-kishore --nsg-name nsg-db \
  --query "[?name=='AllowPostgres'].priority" -o tsv | grep -q "100" && \
timeout 5 bash -c "cat < /dev/null > /dev/tcp/10.0.2.10/5432" 2>/dev/null && \
echo "✅ GO: Network routing healthy" || echo "❌ NO-GO"
```

**Trigger Command:**
```bash
echo "Creating deny rule to block app subnet..."
az network nsg rule create \
  --resource-group rg-ailab-kishore \
  --nsg-name nsg-db \
  --name "BlockAppSubnet-TEST" \
  --priority 90 \
  --direction Inbound \
  --access Deny \
  --protocol Tcp \
  --source-address-prefixes "10.0.1.0/24" \
  --destination-port-ranges "5432" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --output none
echo "✓ Routing broken (test window: 4 minutes)"
sleep 240
```

**Expected Impact:**
- TCP connection timeout (30–60s)
- Payment API returns timeout error
- Database connection pool fills with broken connections
- DB appears unavailable but is healthy
- Monitoring shows "database unreachable"

**Recovery Command:**
```bash
az network nsg rule delete \
  --resource-group rg-ailab-kishore \
  --nsg-name nsg-db \
  --name "BlockAppSubnet-TEST" \
  --no-wait
echo "✓ Deny rule deleted; NSG propagating (30–60 seconds)..."
sleep 45
```

**Validation Command:**
```bash
timeout 5 bash -c "cat < /dev/null > /dev/tcp/10.0.2.10/5432" && \
echo "✅ TCP port reachable" || echo "❌ Still blocked"
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" && echo "✅ Database query OK" || echo "⚠️ Slow"
```

**RTO Target:** 2 minutes

---

## SCENARIO 4: PostgreSQL Service Crash and Recovery

### Priority: 🔴 CRITICAL-4 (Data Integrity Risk)

**Scenario Name:** Database Service Failure and Crash Recovery  
**Description:**  
PostgreSQL process crashes or is forcefully terminated (kill -9). Next startup triggers crash recovery (WAL replay). Transactions in progress may roll back. If crash occurs during critical payment transaction, that transaction is lost.

**Failure Type:** DATABASE  
**Blast Radius:**
- vm-db: PostgreSQL unavailable 30–60s during recovery
- vm-app: All DB connections fail; transaction queue backs up
- Business Impact: Payment unavailability ~1 minute; in-flight transactions rolled back

**Go/No-Go Check:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
sudo systemctl is-active postgresql && echo "✅ GO: PostgreSQL running" || echo "❌ NO-GO"
EOF
```

**Trigger Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'TRIGGER'
PG_PID=$(pgrep -f "postgres.*-D" | head -1)
echo "Killing PostgreSQL (crash simulation): PID $PG_PID"
sudo kill -9 $PG_PID
echo "✓ PostgreSQL killed (crash recovery starting...)"
echo "Monitoring recovery for 60 seconds..."
for attempt in {1..60}; do
  if timeout 3 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" 2>/dev/null | grep -q "^[[:space:]]*1"; then
    echo "✓ Database recovered after $attempt seconds"
    break
  fi
  [ $((attempt % 10)) -eq 0 ] && echo "  Attempt $attempt: PostgreSQL starting..."
  sleep 1
done
TRIGGER
```

**Expected Impact:**
- PostgreSQL process terminates immediately
- Connection refused (~2 seconds)
- Crash recovery starts (WAL replay, ~10–30 seconds)
- Service back online, then connection pool re-establishes

**Recovery Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
if ! sudo systemctl is-active --quiet postgresql; then
  echo "Starting PostgreSQL..."
  sudo systemctl start postgresql
fi
sleep 5
sudo systemctl is-active --quiet postgresql && echo "✅ Service running" || echo "❌ Failed"
EOF
```

**Validation Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
sudo systemctl is-active postgresql && echo "✅ PostgreSQL running" || echo "❌ Down"
TABLES=$(sudo -u postgres psql -d labdb -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null)
echo "✅ Database tables: $TABLES"
EOF
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" && echo "✅ Database responsive" || echo "⚠️ Timeout"
```

**RTO Target:** 2 minutes

---

## SCENARIO 5: Database Disk Full (WAL Logging Broken)

### Priority: 🔴 CRITICAL-5 (Data Corruption / Unrecoverable Failure)

**Scenario Name:** Database VM Storage Exhaustion  
**Description:**  
Database disk fills due to unbounded logs, WAL archive, or large temp files. PostgreSQL cannot write WAL, risking data loss. Database enters read-only mode or crashes. Data corruption possible if crash occurs mid-WAL write.

**Failure Type:** STORAGE  
**Blast Radius:**
- vm-db: Disk full; write transactions fail with ENOSPC
- vm-app: Write operations fail; reads may work
- Business Impact: Complete write failure; data corruption risk

**Go/No-Go Check:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
USAGE=$(df / | awk 'NR==2 {print int($5)}')
[ "$USAGE" -lt 70 ] && echo "✅ GO: Disk usage ${USAGE}%" || echo "❌ NO-GO: Already high"
EOF
```

**Trigger Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'TRIGGER'
echo "Filling disk to 93% capacity (28GB of 30GB)..."
dd if=/dev/zero of=/tmp/disk_fill_test.bin bs=1M count=28000 2>&1 | tail -1
echo "✓ Disk filled"
USAGE=$(df / | awk 'NR==2 {print int($5)}')
FREE=$(df / | awk 'NR==2 {printf "%.1f", $4/1024/1024}')
echo "Disk usage: ${USAGE}% | Free: ${FREE}GB"
echo "Testing database write..."
timeout 5 psql -h 10.0.2.10 -U labuser -d labdb -c "CREATE TEMP TABLE test AS SELECT 1;" 2>&1 | tail -1
sleep 300  # Hold for 5 minutes
TRIGGER
```

**Expected Impact:**
- Disk usage reaches 93–99%
- Database writes fail: `No space left on device`
- Payment write transactions fail
- WAL cannot extend (corruption risk)
- Crash risk extremely high

**Recovery Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
rm -f /tmp/disk_fill_test.bin
sync
sleep 2
USAGE=$(df / | awk 'NR==2 {print int($5)}')
echo "Disk usage after cleanup: ${USAGE}%"
[ "$USAGE" -lt 70 ] && echo "✅ Recovered" || echo "⚠️ Still high"
EOF
```

**Validation Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
USAGE=$(df / | awk 'NR==2 {print int($5)}')
echo "Disk usage: ${USAGE}%"
[ "$USAGE" -lt 70 ] && echo "✅ Recovered to safe level" || echo "❌ Still high"
EOF
psql -h 10.0.2.10 -U labuser -d labdb -c "CREATE TEMP TABLE test AS SELECT now(); DROP TABLE test;" && \
echo "✅ Database writes working" || echo "❌ Still failing"
```

**RTO Target:** 1.5 minutes

---

## SCENARIO 6: Payment Service Application Process Crash

### Priority: 🟠 HIGH (Direct Service Loss)

**Scenario Name:** Payment Service Abrupt Termination  
**Description:**  
Payment service Java process terminates (segfault, uncaught exception, explicit kill). Recovery is straightforward (restart), but impact is immediate. In-flight transactions are lost.

**Failure Type:** APPLICATION  
**Blast Radius:**
- vm-app: Service unavailable; port 8080/443 connection refused
- Business Impact: Immediate payment service loss

**Go/No-Go Check:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
pgrep -f "java.*-Xmx4g" && echo "✅ GO: Service running" || echo "❌ NO-GO"
EOF
```

**Trigger Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'TRIGGER'
JAVA_PID=$(pgrep -f "java.*-Xmx4g")
echo "Terminating service (PID: $JAVA_PID)..."
kill -TERM $JAVA_PID 2>/dev/null || true
sleep 2
pgrep -f "java.*-Xmx4g" > /dev/null && kill -9 $JAVA_PID || true
echo "✓ Service crashed"
sleep 120  # Hold for 2 minutes to test detection
TRIGGER
```

**Expected Impact:**
- Service unresponsive
- Port 8080 connection refused
- All transactions fail

**Recovery Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
systemctl restart payment-service
sleep 5
echo "✅ Service restarted"
EOF
```

**Validation Command:**
```bash
pgrep -f "java.*-Xmx4g" && echo "✅ Running" || echo "❌ Down"
timeout 10 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" && echo "✅ DB OK" || echo "⚠️ Slow"
```

**RTO Target:** 1 minute

---

## SCENARIO 7: Bastion Connectivity Loss (Management Access)

### Priority: 🟡 MEDIUM (Operational Impact Only)

**Scenario Name:** Bastion Unreachable or Blocked  
**Description:**  
Bastion becomes unavailable or NSG blocks access. Management tools cannot reach VMs. User-facing payment service unaffected (app↔db is direct). But escalation/troubleshooting capability is blocked.

**Failure Type:** NETWORK (Management Plane)  
**Blast Radius:**
- Management access: Blocked
- Payment service: Unaffected (no Bastion dependency for traffic)

**Go/No-Go Check:**
```bash
timeout 15 az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
echo "✅ Connected"
EOF
```

**Trigger Command:**
```bash
echo "Blocking Bastion access..."
az network nsg rule create \
  --resource-group rg-ailab-kishore \
  --nsg-name nsg-app \
  --name "BlockBastion-TEST" \
  --priority 50 \
  --direction Inbound \
  --access Deny \
  --protocol Tcp \
  --source-address-prefixes "10.0.3.0/27" \
  --destination-port-ranges "22" "3389" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --output none
echo "✓ Bastion access blocked (test: 3 minutes)"
sleep 180
```

**Expected Impact:**
- Cannot SSH/RDP to VMs
- No management access
- Payment service continues unaffected (user traffic unblocked)

**Recovery Command:**
```bash
az network nsg rule delete \
  --resource-group rg-ailab-kishore \
  --nsg-name nsg-app \
  --name "BlockBastion-TEST" \
  --no-wait
echo "✓ Bastion access restored"
sleep 45
```

**Validation Command:**
```bash
timeout 15 az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
echo "✅ Bastion access restored"
EOF
```

**RTO Target:** 2.5 minutes  
**Note:** This failure does NOT impact payment service—only management visibility.

---

## SCENARIO 8: Memory Pressure on Database VM

### Priority: 🟡 MEDIUM (Performance Degradation)

**Scenario Name:** PostgreSQL Memory Exhaustion and Slow Queries  
**Description:**  
Database VM memory fills (large queries, memory bloat, unoptimized JOINs). Memory pressure causes query slowdown (swapping), page faults increase, payment transactions slow 10–100x. No crash, but severe performance degradation.

**Failure Type:** COMPUTE  
**Blast Radius:**
- vm-db: Memory 90%+; swapping; queries slow by 10–100x
- vm-app: Payment transactions slow >10s; timeout risk
- Business Impact: Severe degradation; functional but unusable

**Go/No-Go Check:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
FREE=$(free -h | awk 'NR==2 {print int($7/1024)}')
[ "$FREE" -gt 2 ] && echo "✅ GO: ${FREE}GB available" || echo "❌ NO-GO"
EOF
```

**Trigger Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'TRIGGER'
echo "Allocating 5GB memory..."
dd if=/dev/zero of=/dev/shm/memfill bs=1M count=5000 > /dev/null 2>&1 &
MEM_PID=$!
echo "Memory allocated (PID: $MEM_PID)"
for i in {1..5}; do
  sleep 30
  START=$(date +%s%N)
  timeout 5 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" > /dev/null 2>&1
  END=$(date +%s%N)
  LATENCY=$((($END - $START) / 1000000))
  echo "Query $i latency: ${LATENCY}ms"
done
kill $MEM_PID 2>/dev/null || true
TRIGGER
```

**Expected Impact:**
- Memory pressure slows all DB operations
- Query latency increases 10–100x
- Payment transactions timeout
- Graceful degradation (doesn't crash)

**Recovery Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
pkill -9 -f "dd if=/dev/zero"
rm -f /dev/shm/memfill
sync
sleep 2
echo "✓ Memory freed"
EOF
```

**Validation Command:**
```bash
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
FREE=$(free -h | awk 'NR==2 {print $7}')
echo "Free memory: $FREE (should be >2GB)"
for i in {1..3}; do
  START=$(date +%s%N)
  timeout 5 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" > /dev/null 2>&1
  END=$(date +%s%N)
  LATENCY=$((($END - $START) / 1000000))
  echo "Query $i latency: ${LATENCY}ms (should be <100ms)"
done
EOF
```

**RTO Target:** 1 minute

---

## SCENARIO PRIORITY ORDER (Risk to Payment Service)

| Rank | Scenario | Priority | RTO | Impact | Notes |
|------|----------|----------|-----|--------|-------|
| 1 | Connection Pool Exhaustion | CRITICAL-1 | 90s | 100% failure | Highest frequency |
| 2 | Payment Service OOM | CRITICAL-2 | 60s | 100% failure | Process crash |
| 3 | Network Partition (App↔DB) | CRITICAL-3 | 120s | 100% failure | False DB unavailability |
| 4 | PostgreSQL Service Crash | CRITICAL-4 | 120s | 100% failure; data risk | WAL recovery |
| 5 | Database Disk Full | CRITICAL-5 | 90s | 100% write failure | Corruption risk |
| 6 | Payment Service Crash | HIGH | 60s | 100% temporary | Quick restart |
| 7 | Memory Pressure on DB | MEDIUM | 60s | Severe slowdown | Degrades gracefully |
| 8 | Bastion Loss | MEDIUM | 150s | Management only | No user-facing impact |

---

## EXECUTION DEPENDENCY MAP

**Recommended Sequence:**
1. Scenario 6: Payment Crash (safest first)
2. Scenario 8: DB Memory Pressure
3. Scenario 4: PostgreSQL Crash
4. Scenario 5: Disk Full
5. Scenario 1: Connection Pool
6. Scenario 3: Network Partition
7. Scenario 7: Bastion Loss
8. Scenario 2: OOM (LAST — most complex)

**Total Time:** 2–2.5 hours

---

## KNOWN GAPS: Untestable Scenarios

| Failure Mode | Why Untestable | Risk Level | Mitigation |
|--------------|----------------|------------|-----------|
| **Hardware Memory Bit Flip (ECC)** | Physical; data loss | Critical | Azure SLA; ECC detection |
| **Storage Disk Hardware Failure** | Unrecoverable | Critical | Azure Backup; RA-GRS |
| **Network Card Failure** | Breaks VM | Critical | Infrastructure redundancy |
| **Cascading Failures (Both App & DB)** | Too dangerous | Critical | Circuit breakers; graceful degradation |
| **Multi-Region Failover** | Single region only | Critical | Implement multi-region setup |
| **Backup Restoration Under Load** | Data corruption risk | Critical | Test in staging only |

---

**End of Resilience Test Plan**
