#!/usr/bin/env python3
"""Remote import helper for scripts/migrate-instance.sh (runs on VPS)."""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
from pathlib import Path

MIG = Path("/tmp/evo-migrate")
REMOTE_DIR = os.environ.get("REMOTE_DIR", "/opt/evoapi-fluxosmm")


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def compose_id(service: str) -> str:
    out = run(["docker", "compose", "-f", f"{REMOTE_DIR}/docker-compose.yml", "ps", "-q", service]).stdout.strip()
    if not out:
        raise SystemExit(f"service not found: {service}")
    return out


def psql(pg: str, sql: str) -> None:
    r = subprocess.run(
        ["docker", "exec", "-i", pg, "psql", "-U", "evolution", "-d", "evolution", "-v", "ON_ERROR_STOP=1", "-c", sql],
        check=False,
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print(r.stderr or r.stdout, file=sys.stderr)
        raise SystemExit(f"psql failed: {sql[:120]}...")


def lit(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (dict, list)):
        return "'" + json.dumps(v).replace("'", "''") + "'::jsonb"
    return "'" + str(v).replace("'", "''") + "'"


def redis_restore(rd: str, db: str, key: str, dump_b64: str) -> None:
    data = base64.b64decode(dump_b64.strip())
    bin_path = MIG / "redis_hash.bin"
    bin_path.write_bytes(data)
    run(["docker", "cp", str(bin_path), f"{rd}:/tmp/redis_hash.bin"])
    run(["docker", "exec", rd, "redis-cli", "-n", db, "DEL", key], check=False)
    # redis-cli -x reads the DUMP payload from stdin
    r = subprocess.run(
        ["docker", "exec", "-i", rd, "redis-cli", "-x", "-n", db, "RESTORE", key, "0", "REPLACE"],
        input=data,
        check=False,
        capture_output=True,
    )
    print("RESTORE:", (r.stdout or b"").decode(errors="replace"), (r.stderr or b"").decode(errors="replace"))
    hlen = run(["docker", "exec", rd, "redis-cli", "-n", db, "HLEN", key])
    print("HLEN:", hlen.stdout.strip())


def main() -> None:
    pg = compose_id("postgres")
    rd = compose_id("redis")
    try:
        api = compose_id("api")
    except SystemExit:
        api = ""

    run(["docker", "cp", str(MIG / "instance.json"), f"{pg}:/tmp/instance.json"])
    run(["docker", "cp", str(MIG / "session.json"), f"{pg}:/tmp/session.json"])
    run(["docker", "cp", str(MIG / "setting.json"), f"{pg}:/tmp/setting.json"])
    run(["docker", "cp", str(MIG / "proxy.json"), f"{pg}:/tmp/proxy.json"])

    # Read JSON on host (files already in /tmp/evo-migrate)
    inst = json.loads((MIG / "instance.json").read_text())
    sessions = json.loads((MIG / "session.json").read_text())
    setting = json.loads((MIG / "setting.json").read_text())
    proxy = json.loads((MIG / "proxy.json").read_text())
    dst_hash = (MIG / "dst_hash.txt").read_text().strip()
    dst_db = (MIG / "dst_db.txt").read_text().strip()
    dump_b64 = (MIG / "redis_hash.b64").read_text()

    if isinstance(sessions, dict):
        sessions = [sessions]

    print("==> Upsert Instance")
    psql(
        pg,
        f"""DELETE FROM "Session" WHERE "sessionId" IN (
              SELECT id FROM "Instance" WHERE name = {lit(inst["name"])} AND id <> {lit(inst["id"])});""",
    )
    psql(
        pg,
        f"""DELETE FROM "Setting" WHERE "instanceId" IN (
              SELECT id FROM "Instance" WHERE name = {lit(inst["name"])} AND id <> {lit(inst["id"])});""",
    )
    psql(pg, f"""DELETE FROM "Instance" WHERE name = {lit(inst["name"])} AND id <> {lit(inst["id"])};""")

    cols = [
        "id",
        "name",
        "connectionStatus",
        "ownerJid",
        "profileName",
        "profilePicUrl",
        "integration",
        "number",
        "businessId",
        "token",
        "clientName",
        "createdAt",
        "updatedAt",
        "disconnectionAt",
        "disconnectionReasonCode",
        "disconnectionObject",
    ]
    vals = []
    for c in cols:
        v = inst.get(c)
        if c in ("createdAt", "updatedAt", "disconnectionAt") and v:
            vals.append(f"{lit(v)}::timestamptz")
        elif c == "disconnectionReasonCode" and v is not None:
            vals.append(str(int(v)))
        else:
            vals.append(lit(v))
    col_sql = ", ".join(f'"{c}"' for c in cols)
    psql(
        pg,
        f"""
INSERT INTO "Instance" ({col_sql}) VALUES ({", ".join(vals)})
ON CONFLICT (id) DO UPDATE SET
  name=EXCLUDED.name,
  "ownerJid"=EXCLUDED."ownerJid",
  "profileName"=EXCLUDED."profileName",
  "profilePicUrl"=EXCLUDED."profilePicUrl",
  integration=EXCLUDED.integration,
  number=EXCLUDED.number,
  token=EXCLUDED.token,
  "clientName"=EXCLUDED."clientName",
  "updatedAt"=now();
""",
    )

    print("==> Upsert Session")
    for s in sessions or []:
        if not s:
            continue
        psql(
            pg,
            f"""
INSERT INTO "Session" (id, "sessionId", creds)
VALUES ({lit(s.get("id"))}, {lit(s.get("sessionId"))}, {lit(s.get("creds"))})
ON CONFLICT ("sessionId") DO UPDATE SET creds = EXCLUDED.creds;
""",
        )

    if setting:
        print("==> Upsert Setting")
        psql(pg, f"""DELETE FROM "Setting" WHERE "instanceId" = {lit(setting.get("instanceId"))};""")
        col_sql = ", ".join(f'"{k}"' for k in setting.keys())
        val_sql = ", ".join(
            f"{lit(v)}::timestamptz" if k in ("createdAt", "updatedAt") and v else lit(v) for k, v in setting.items()
        )
        psql(pg, f"""INSERT INTO "Setting" ({col_sql}) VALUES ({val_sql});""")

    if proxy:
        print("==> Upsert Proxy")
        psql(pg, f"""DELETE FROM "Proxy" WHERE "instanceId" = {lit(proxy.get("instanceId"))};""")
        col_sql = ", ".join(f'"{k}"' for k in proxy.keys())
        val_sql = ", ".join(
            f"{lit(v)}::timestamptz" if k in ("createdAt", "updatedAt") and v else lit(v) for k, v in proxy.items()
        )
        try:
            psql(pg, f"""INSERT INTO "Proxy" ({col_sql}) VALUES ({val_sql});""")
        except SystemExit as e:
            print("Proxy skipped:", e)

    print("==> Restore Redis", dst_hash, "db", dst_db)
    redis_restore(rd, dst_db, dst_hash, dump_b64)

    if api:
        print("==> Restart API")
        run(["docker", "compose", "-f", f"{REMOTE_DIR}/docker-compose.yml", "restart", "api"], check=False)

    print("OK")


if __name__ == "__main__":
    main()
