# Azure Payment Service Resilience — Quick Reference (8 Scenarios)

**Environment:** rg-ailab-kishore (eastus)  
**Test Focus:** Payment service resilience under critical failures  
**Total Runtime:** 2–2.5 hours | 8 scenarios

---

## Scenario Execution Checklist

| # | Scenario | Duration | RTO | Priority | Status |
|---|----------|----------|-----|----------|--------|
| 1 | Connection Pool Exhaustion | 5 min | 90s | CRITICAL-1 | ☐ |
| 2 | Payment Service OOM | 5 min | 60s | CRITICAL-2 | ☐ |
| 3 | Network Partition (App↔DB) | 4 min | 120s | CRITICAL-3 | ☐ |
| 4 | PostgreSQL Crash | 2 min | 120s | CRITICAL-4 | ☐ |
| 5 | Database Disk Full | 5 min | 90s | CRITICAL-5 | ☐ |
| 6 | Payment Crash | 2 min | 60s | HIGH | ☐ |
| 7 | Memory Pressure on DB | 3 min | 60s | MEDIUM | ☐ |
| 8 | Bastion Loss | 3 min | 150s | MEDIUM | ☐ |

---

## SCENARIO 1: Connection Pool Exhaustion (5 min)

**Command Sequence:**

```bash
# GO/NO-GO
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT count(*) FROM pg_stat_activity;"

# TRIGGER (220 sec)
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
for i in {1..22}; do
  (echo "BEGIN; SELECT pg_sleep(300);" | psql -h 10.0.2.10 -U labuser -d labdb >/dev/null 2>&1) &
done
echo "22 connections open (max: 20) — test window 300 sec"
wait
T

# MONITOR
psql -h 10.0.2.10 -U labuser -d labdb -t -c "SELECT count(*) FROM pg_stat_activity WHERE usename='labuser';"

# RECOVERY
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'R'
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='labuser' AND state='idle' LIMIT 10;"
R

# VALIDATE
ACTIVE=$(psql -h 10.0.2.10 -U labuser -d labdb -t -c "SELECT count(*) FROM pg_stat_activity WHERE usename='labuser';" | tr -d ' ')
echo "Active connections: $ACTIVE (target: <5)"
```

---

## SCENARIO 2: Payment Service OOM (5 min)

```bash
# GO/NO-GO
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
pgrep -f "java.*-Xmx4g" && echo "Running" || exit 1
T

# TRIGGER (simulate load)
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
JAVA_PID=$(pgrep -f "java.*-Xmx4g")
echo "Simulating memory pressure (PID: $JAVA_PID)..."
for i in {1..300}; do
  ps -p $JAVA_PID > /dev/null || { echo "Crashed at $i"; break; }
  sleep 0.2
done
T

# RECOVERY
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'R'
systemctl restart payment-service
sleep 5
echo "Restarted"
R

# VALIDATE
pgrep -f "java.*-Xmx4g" && echo "Running" || echo "Failed"
```

---

## SCENARIO 3: Network Partition (4 min)

```bash
# GO/NO-GO
az network nsg rule list --resource-group rg-ailab-kishore --nsg-name nsg-db \
  --query "[?name=='AllowPostgres'].priority" -o tsv | grep -q "100" && echo "OK" || exit 1

# TRIGGER (create deny rule, priority 90 > 100)
az network nsg rule create \
  --resource-group rg-ailab-kishore --nsg-name nsg-db \
  --name "BlockAppSubnet-TEST" --priority 90 --direction Inbound --access Deny \
  --protocol Tcp --source-address-prefixes "10.0.1.0/24" \
  --destination-port-ranges "5432" --output none
echo "Routing blocked (test: 240 sec)"
sleep 240

# RECOVERY
az network nsg rule delete \
  --resource-group rg-ailab-kishore --nsg-name nsg-db \
  --name "BlockAppSubnet-TEST" --no-wait
echo "Deleted; propagating (45 sec)..."
sleep 45

# VALIDATE
timeout 5 bash -c "cat < /dev/null > /dev/tcp/10.0.2.10/5432" && echo "Reachable" || echo "Still blocked"
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" && echo "OK" || echo "Failed"
```

---

## SCENARIO 4: PostgreSQL Crash (2 min)

```bash
# GO/NO-GO
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
sudo systemctl is-active postgresql && echo "OK" || exit 1
T

# TRIGGER
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
PG_PID=$(pgrep -f "postgres.*-D" | head -1)
echo "Killing PID $PG_PID..."
sudo kill -9 $PG_PID
echo "Monitoring recovery (60 sec)..."
for i in {1..60}; do
  timeout 3 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" 2>/dev/null | grep -q "^[[:space:]]*1" && { echo "Recovered in $i sec"; break; }
  sleep 1
done
T

# RECOVERY (auto-restart via systemd)
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'R'
sudo systemctl start postgresql 2>/dev/null
sleep 5
R

# VALIDATE
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" && echo "OK" || echo "Failed"
```

---

## SCENARIO 5: Disk Full (5 min)

```bash
# GO/NO-GO
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
USAGE=$(df / | awk 'NR==2 {print int($5)}')
[ "$USAGE" -lt 70 ] && echo "OK: ${USAGE}%" || exit 1
T

# TRIGGER (fill to 93%, hold 5 min)
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
echo "Allocating 28GB..."
dd if=/dev/zero of=/tmp/disk_fill_test.bin bs=1M count=28000 2>&1 | tail -1
USAGE=$(df / | awk 'NR==2 {print int($5)}')
echo "Disk usage: ${USAGE}%"
sleep 300
T

# RECOVERY
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'R'
rm -f /tmp/disk_fill_test.bin
sync
sleep 2
df / | tail -1
R

# VALIDATE
psql -h 10.0.2.10 -U labuser -d labdb -c "CREATE TEMP TABLE test AS SELECT now(); DROP TABLE test;" && echo "OK" || echo "Failed"
```

---

## SCENARIO 6: Payment Crash (2 min)

```bash
# GO/NO-GO
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
pgrep -f "java.*-Xmx4g" && echo "Running" || exit 1
T

# TRIGGER
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
JAVA_PID=$(pgrep -f "java.*-Xmx4g")
echo "Killing PID $JAVA_PID..."
kill -TERM $JAVA_PID 2>/dev/null || true
sleep 2
pgrep -f "java.*-Xmx4g" > /dev/null && kill -9 $JAVA_PID || true
echo "Crashed; holding 120 sec"
sleep 120
T

# RECOVERY
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'R'
systemctl restart payment-service
sleep 5
R

# VALIDATE
pgrep -f "java.*-Xmx4g" && echo "Running" || echo "Failed"
psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT 1;" && echo "DB OK" || echo "DB slow"
```

---

## SCENARIO 7: Memory Pressure on DB (3 min)

```bash
# GO/NO-GO
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
FREE=$(free -h | awk 'NR==2 {print int($7/1024)}')
[ "$FREE" -gt 2 ] && echo "OK: ${FREE}GB" || exit 1
T

# TRIGGER
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
echo "Allocating 5GB..."
dd if=/dev/zero of=/dev/shm/memfill bs=1M count=5000 > /dev/null 2>&1 &
for i in {1..5}; do
  sleep 30
  START=$(date +%s%N)
  timeout 5 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" > /dev/null 2>&1
  END=$(date +%s%N)
  LATENCY=$((($END - $START) / 1000000))
  echo "Query $i: ${LATENCY}ms"
done
pkill -9 -f "dd if=/dev/zero"
T

# RECOVERY
az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-db --query id -o tsv)" \
  --auth-type password --username labadmin <<'R'
pkill -9 -f "dd if=/dev/zero"
rm -f /dev/shm/memfill
sync
sleep 2
R

# VALIDATE
for i in {1..3}; do
  START=$(date +%s%N)
  timeout 5 psql -h 10.0.2.10 -U labuser -d labdb -c "SELECT version();" > /dev/null 2>&1
  END=$(date +%s%N)
  LATENCY=$((($END - $START) / 1000000))
  echo "Query $i: ${LATENCY}ms (target: <100ms)"
done
```

---

## SCENARIO 8: Bastion Loss (3 min)

```bash
# GO/NO-GO
timeout 15 az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
echo "Connected"
T

# TRIGGER (block Bastion subnet)
az network nsg rule create \
  --resource-group rg-ailab-kishore --nsg-name nsg-app \
  --name "BlockBastion-TEST" --priority 50 --direction Inbound --access Deny \
  --protocol Tcp --source-address-prefixes "10.0.3.0/27" \
  --destination-port-ranges "22" "3389" --output none
echo "Bastion blocked; test 180 sec"
sleep 180

# RECOVERY
az network nsg rule delete \
  --resource-group rg-ailab-kishore --nsg-name nsg-app \
  --name "BlockBastion-TEST" --no-wait
echo "Restored; propagating 45 sec"
sleep 45

# VALIDATE
timeout 15 az bastion ssh --name bastion-ailab --resource-group rg-ailab-kishore \
  --target-resource-id "$(az vm show -g rg-ailab-kishore -n vm-app --query id -o tsv)" \
  --auth-type password --username labadmin <<'T'
echo "Restored"
T
```

---

## Test Summary

| Scenario | Result | Recovery Time | Notes |
|----------|--------|----------------|-------|
| 1 | ☐ PASS ☐ FAIL | ___ min | |
| 2 | ☐ PASS ☐ FAIL | ___ min | |
| 3 | ☐ PASS ☐ FAIL | ___ min | |
| 4 | ☐ PASS ☐ FAIL | ___ min | |
| 5 | ☐ PASS ☐ FAIL | ___ min | |
| 6 | ☐ PASS ☐ FAIL | ___ min | |
| 7 | ☐ PASS ☐ FAIL | ___ min | |
| 8 | ☐ PASS ☐ FAIL | ___ min | |

**Tester:** ________________  
**Date:** ________________  
**Overall:** ☐ PASSED ☐ FAILED
