# Resilience Test Execution Checklist (8 Scenarios)

**Test Date:** ______________ | **Tester:** ________________ | **Environment:** rg-ailab-kishore

---

## Pre-Test (Do This Once)

```bash
# Backup database
az vm run-command invoke -g rg-ailab-kishore -n vm-db \
  --command-id RunShellScript \
  --scripts 'sudo -u postgres pg_dump labdb > /tmp/labdb.backup.sql'

# Verify all 3 VMs running
az vm list --resource-group rg-ailab-kishore --query "[].{Name:name, State:powerState}"

# Verify Bastion working
timeout 15 az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
echo "OK"
EOF

# Verify database
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();"
```

- [ ] Database backed up
- [ ] All VMs running
- [ ] Bastion SSH working
- [ ] Database responding

---

## Scenario 1: Connection Pool Exhaustion

**Baseline Check:**
```bash
psql -h 10.0.2.10 -U labuser -d labdb -c "SHOW max_connections;" # Should be 20
psql -h 10.0.2.10 -U labuser -d labdb -t -c "SELECT count(*) FROM pg_stat_activity;" # Should be <5
```
- [ ] max_connections = 20
- [ ] Active connections < 5

**Trigger:**
- [ ] 22 background connections spawned
- [ ] Start time: ____________

**Monitor (every 60 seconds):**
- [ ] Minute 1: Active connections: ____/20
- [ ] Minute 2: Active connections: ____/20
- [ ] Minute 3: Active connections: ____/20
- [ ] Minute 4: Active connections: ____/20
- [ ] Minute 5: Connections released

**Validate:**
```bash
ACTIVE=$(psql -h 10.0.2.10 -U labuser -d labdb -t -c "SELECT count(*) FROM pg_stat_activity WHERE usename='labuser';" | tr -d ' ')
[ "$ACTIVE" -lt 5 ] && echo "✅ PASS" || echo "❌ FAIL"
```
- [ ] Active connections < 5
- [ ] New connection accepted
- [ ] Recovery time: ___ seconds

**Result:** ☐ PASS ☐ FAIL

---

## Scenario 2: Payment Service OOM

**Baseline Check:**
```bash
az bastion ssh ... <<'EOF'
pgrep -f "java.*-Xmx4g"
java -XshowSettings:vm 2>&1 | grep -i heap
EOF
```
- [ ] Java process running
- [ ] Heap size: ________

**Trigger:**
- [ ] Memory pressure simulation started
- [ ] Start time: ____________

**Monitor (every 30 seconds):**
- [ ] Process still running (ps check)
- [ ] Service responds to health check

**Expected Impact:**
- [ ] Heap usage increases 80%+
- [ ] GC pauses occur (CPU high)
- [ ] Process crashes

**Validate:**
```bash
pgrep -f "java.*-Xmx4g" && echo "Running" && \
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" && echo "DB OK"
```
- [ ] Process restarted successfully
- [ ] DB connection restored
- [ ] Recovery time: ___ seconds

**Result:** ☐ PASS ☐ FAIL

---

## Scenario 3: Network Partition

**Baseline Check:**
```bash
az network nsg rule list --resource-group rg-ailab-kishore --nsg-name nsg-db \
  --query "[?name=='AllowPostgres']"
timeout 5 bash -c "cat < /dev/null > /dev/tcp/10.0.2.10/5432"
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;"
```
- [ ] AllowPostgres rule exists (priority 100)
- [ ] Port 5432 reachable
- [ ] Database query succeeds

**Trigger:**
- [ ] Deny rule created (priority 90, blocks app subnet)
- [ ] Start time: ____________

**Monitor (every 60 seconds):**
- [ ] Minute 1: TCP port 5432 reachable? ☐ YES ☐ NO
- [ ] Minute 2: TCP port 5432 reachable? ☐ YES ☐ NO
- [ ] Minute 3: TCP port 5432 reachable? ☐ YES ☐ NO
- [ ] Minute 4: Deny rule deleted

**Expected Behavior:**
- [ ] Timeout on TCP connection (30–60s)
- [ ] Payment API returns timeout error
- [ ] Database itself is operational
- [ ] nsqlookup works but TCP blocked

**Validate:**
```bash
sleep 45  # Wait for NSG propagation
timeout 5 bash -c "cat < /dev/null > /dev/tcp/10.0.2.10/5432" && echo "Port reachable"
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" 
az network nsg rule list --resource-group rg-ailab-kishore --nsg-name nsg-db \
  --query "[?name=='BlockAppSubnet-TEST']" # Should be empty
```
- [ ] TCP port 5432 reachable again
- [ ] Database query succeeds
- [ ] Deny rule deleted
- [ ] Recovery time: ___ seconds

**Result:** ☐ PASS ☐ FAIL

---

## Scenario 4: PostgreSQL Service Crash

**Baseline Check:**
```bash
az bastion ssh --target-resource-id="$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --name bastion-ailab --resource-group rg-ailab-kishore \
  --auth-type password --username labadmin <<'EOF'
sudo systemctl is-active postgresql
sudo systemctl status postgresql
EOF
```
- [ ] PostgreSQL is active
- [ ] No hung processes

**Trigger:**
- [ ] PostgreSQL process killed (kill -9)
- [ ] Start time: ____________

**Monitor (every 10 seconds for 60 seconds):**
- [ ] 0–10s: PostgreSQL restarting (connection refused)
- [ ] 10–30s: WAL recovery in progress
- [ ] 30–60s: Service coming online
- [ ] Checkpoint: First successful query at __ seconds

**Expected Behavior:**
- [ ] Immediate connection refused
- [ ] PostgreSQL automatically restarts (systemd)
- [ ] WAL recovery logs show in syslog
- [ ] Service becomes responsive after recovery

**Validate:**
```bash
az bastion ssh ... <<'EOF'
sudo systemctl is-active postgresql
sudo -u postgres psql -d labdb -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
EOF
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();"
```
- [ ] PostgreSQL is active
- [ ] Database tables intact
- [ ] Database query succeeds
- [ ] Recovery time: ___ seconds

**Result:** ☐ PASS ☐ FAIL

---

## Scenario 5: Database Disk Full

**Baseline Check:**
```bash
az bastion ssh --target-resource-id="$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --name bastion-ailab --resource-group rg-ailab-kishore \
  --auth-type password --username labadmin <<'EOF'
df -h /
df -i /
EOF
```
- [ ] Disk usage: _____% (should be <50%)
- [ ] Free space: ____ GB (should be >5GB)
- [ ] Inodes: _____% (should be <50%)

**Trigger:**
- [ ] 28GB fill file created (28000 MB)
- [ ] Start time: ____________

**Monitor (every 60 seconds):**
- [ ] Minute 1: Disk usage: _____% | Free: ____ GB
- [ ] Minute 2: Disk usage: _____% | Free: ____ GB
- [ ] Minute 3: Disk usage: _____% | Free: ____ GB
- [ ] Minute 4: Disk usage: _____% | Free: ____ GB
- [ ] Minute 5: File deleted; cleanup starts

**Expected Behavior:**
- [ ] Disk fills to 93–99%
- [ ] Free space drops to <500MB
- [ ] Database write operations fail (ENOSPC)
- [ ] PostgreSQL may become read-only or crash

**Validate:**
```bash
az bastion ssh ... <<'EOF'
df -h / | tail -1 | awk '{print "Usage:", $(NF-1), "Free:", $(NF-3)}'
ls -lh /tmp/disk_fill_test.bin  # Should NOT exist
[ ! -f /tmp/disk_fill_test.bin ] && echo "File deleted"
EOF
psql -h 10.0.2.10 -U labuser -d labdb -c "CREATE TEMP TABLE test AS SELECT 1; DROP TABLE test;"
```
- [ ] Fill file deleted
- [ ] Disk usage back to <50%
- [ ] Database write succeeds
- [ ] Recovery time: ___ seconds

**Result:** ☐ PASS ☐ FAIL

---

## Scenario 6: Payment Service Crash

**Baseline Check:**
```bash
az bastion ssh --target-resource-id="$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --name bastion-ailab --resource-group rg-ailab-kishore \
  --auth-type password --username labadmin <<'EOF'
pgrep -f "java.*-Xmx4g"
systemctl is-active payment-service
EOF
```
- [ ] Java process running (PID: _______)
- [ ] payment-service active

**Trigger:**
- [ ] Service killed (SIGTERM then SIGKILL)
- [ ] Start time: ____________

**Monitor (every 30 seconds for 120 seconds):**
- [ ] 0–2m: Service unresponsive (connection refused)
- [ ] Minute 2: Restart initiated

**Expected Behavior:**
- [ ] Immediate failure (process terminates)
- [ ] Port 8080/443 connection refused
- [ ] Monitoring alerts fire

**Validate:**
```bash
az bastion ssh ... <<'EOF'
JAVA_PID=$(pgrep -f "java.*-Xmx4g")
[ -n "$JAVA_PID" ] && echo "PID: $JAVA_PID" || echo "Not running"
systemctl is-active payment-service
EOF
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;"
```
- [ ] Java process restarted
- [ ] payment-service active
- [ ] Database connection restored
- [ ] Recovery time: ___ seconds

**Result:** ☐ PASS ☐ FAIL

---

## Scenario 7: Memory Pressure on DB

**Baseline Check:**
```bash
az bastion ssh ... <<'EOF'
free -h
ps aux | grep postgres | grep -v grep | wc -l
EOF
```
- [ ] Free memory: ____ GB (should be >2GB)
- [ ] PostgreSQL processes: _____

**Trigger:**
- [ ] 5GB memory allocated (/dev/shm/memfill)
- [ ] Start time: ____________

**Monitor (every 30 seconds, 5 iterations):**
```bash
# Measure query latency while under memory pressure
START=$(date +%s%N); timeout 5 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" >/dev/null 2>&1; END=$(date +%s%N); LATENCY=$((($END - $START) / 1000000)); echo "Query latency: ${LATENCY}ms"
```
- [ ] Query 1 latency: _____ ms (expect 10–100x slowdown)
- [ ] Query 2 latency: _____ ms
- [ ] Query 3 latency: _____ ms
- [ ] Query 4 latency: _____ ms
- [ ] Query 5 latency: _____ ms

**Expected Behavior:**
- [ ] Query latency increases 10–100x
- [ ] Memory usage spikes to 90%+
- [ ] No crash, just severe slowdown
- [ ] Graceful degradation

**Validate:**
```bash
az bastion ssh ... <<'EOF'
pkill -9 -f "dd if=/dev/zero"
rm -f /dev/shm/memfill
free -h  # Should show recovered memory
for i in {1..3}; do
  START=$(date +%s%N); timeout 5 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" >/dev/null 2>&1; END=$(date +%s%N); LATENCY=$((($END - $START) / 1000000)); echo "Query $i: ${LATENCY}ms (target: <100ms)"
done
EOF
```
- [ ] Memory fill process killed
- [ ] Free memory recovered (>2GB)
- [ ] Query latency back to <100ms
- [ ] Recovery time: ___ seconds

**Result:** ☐ PASS ☐ FAIL

---

## Scenario 8: Bastion Loss

**Baseline Check:**
```bash
timeout 15 az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id="$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
echo "Connected"
EOF
```
- [ ] Bastion SSH working

**Trigger:**
- [ ] NSG deny rule created (blocks Bastion subnet 10.0.3.0/27)
- [ ] Start time: ____________

**Monitor (every 60 seconds):**
- [ ] Minute 1: Attempt SSH — ☐ Connected ☐ Failed (timeout)
- [ ] Minute 2: Attempt SSH — ☐ Connected ☐ Failed (timeout)
- [ ] Minute 3: Deny rule deleted

**Expected Behavior:**
- [ ] SSH/RDP cannot connect (timeout)
- [ ] Management access blocked
- [ ] **Payment service still running** (user traffic NOT affected)

**Validate:**
```bash
# Wait 45 sec for NSG propagation
sleep 45
timeout 15 az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id="$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'EOF'
echo "Connected"
EOF
# Verify payment service still running (despite management loss)
# This would require separate monitoring, or assume payment service logic already verified
```
- [ ] Bastion SSH reconnected
- [ ] Management access restored
- [ ] Recovery time: ___ seconds

**⚠️ NOTE:** This scenario tests management plane only. Payment service should remain unaffected.

**Result:** ☐ PASS ☐ FAIL

---

## Summary

| Scenario | Result | RTO Achieved | Notes |
|----------|--------|--------------|-------|
| 1. Connection Pool | ☐ ☐ | ___ min | |
| 2. Payment OOM | ☐ ☐ | ___ min | |
| 3. Network Partition | ☐ ☐ | ___ min | |
| 4. PostgreSQL Crash | ☐ ☐ | ___ min | |
| 5. Disk Full | ☐ ☐ | ___ min | |
| 6. Payment Crash | ☐ ☐ | ___ min | |
| 7. Memory Pressure | ☐ ☐ | ___ min | |
| 8. Bastion Loss | ☐ ☐ | ___ min | |

**Overall Result:** ☐ ALL PASSED ☐ SOME FAILED

**Issues Encountered:**
```
1. _________________________________________________________________
2. _________________________________________________________________
3. _________________________________________________________________
```

**Data Loss:** ☐ None ☐ Yes (describe)  
**Cascading Failures:** ☐ None ☐ Yes (describe)  
**All RTO Targets Met:** ☐ YES ☐ NO

---

## Sign-Off

**Tester:** ________________________  
**Date/Time:** _____________________  
**Approved By (Ops):** ________________________  
**Date:** _____________________
