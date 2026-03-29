# Doris — Operational Notes

## Loading TPC-H Data

Use `fixtures/tpch_setup.sh` to generate and load TPC-H data. Key operational rules:

**Always run from inside the cluster, not locally.**
Doris FE responds to stream load with an HTTP 307 redirect to the BE's internal cluster DNS
(e.g. `doris-doris-be-0.doris-doris-be.crucible-research.svc.cluster.local`). This address
is unreachable from outside the cluster, so local port-forwarding silently fails.

**Copy files to the pod before executing — don't use `kubectl exec < local_file`.**
`kubectl exec pod -- cmd < file` only redirects the local shell's stdin; it does not pipe the
file into the pod. Always `kubectl cp` the file first, then exec inside the pod.

**Recommended workflow:**

```bash
# 1. Copy DDL to the pod and create schema
kubectl cp fixtures/tpch_ddl.sql crucible-research/doris-doris-fe-0:/tmp/tpch_ddl.sql
kubectl exec -n crucible-research doris-doris-fe-0 -- \
  bash -c 'mysql --protocol=tcp -h 127.0.0.1 -P 9030 -u root < /tmp/tpch_ddl.sql'

# 2. Generate data locally (tpch_setup.sh --skip-load handles this)
bash fixtures/tpch_setup.sh --host 127.0.0.1 --skip-load

# 3. Copy data files to the pod
for tbl in region nation part supplier partsupp customer orders lineitem; do
  kubectl cp /tmp/tpch-data/sf1/${tbl}.tbl \
    crucible-research/doris-doris-fe-0:/tmp/tpch-data/sf1/${tbl}.tbl
done

# 4. Write a load script to the pod and execute it from there
kubectl cp fixtures/tpch_setup.sh crucible-research/doris-doris-fe-0:/tmp/tpch_setup.sh
kubectl exec -n crucible-research doris-doris-fe-0 -- \
  bash -c 'bash /tmp/tpch_setup.sh --host 127.0.0.1 --skip-generate'
```

**Write multi-step scripts to the pod — don't inline complex bash in `bash -c`.**
Heavily-quoted `bash -c` strings passed through `kubectl exec` are fragile. Write scripts
to a file on the pod with `kubectl cp`, then execute with `bash /tmp/script.sh`.

**Verify load success by querying row counts directly:**

```bash
kubectl exec -n crucible-research doris-doris-fe-0 -- \
  bash -c 'mysql --protocol=tcp -h 127.0.0.1 -P 9030 -u root -e "
    USE tpch;
    SELECT '\''lineitem'\'', COUNT(*) FROM lineitem
    UNION ALL SELECT '\''orders'\'', COUNT(*) FROM orders;"'
```

Expected SF1 counts: `lineitem` ~6M, `orders` 1.5M, `customer` 150K, `partsupp` 800K.
