#!/usr/bin/env python3
"""Process doubles for the backup scripts; archives use real gzip and OpenSSL."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

root = Path(os.environ["FAKE_ROOT"])
command = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as output:
    output.write(json.dumps([command, *args]) + "\n")


def count(name):
    path = root / (name + ".count")
    value = int(path.read_text()) + 1 if path.exists() else 1
    path.write_text(str(value))
    return value


def option(name):
    for value in args:
        if value.startswith(name + "="):
            return value.split("=", 1)[1]
    return args[args.index(name) + 1]


if command == "pg_isready":
    ready = count("ready") >= int(os.environ.get("FAKE_READY_AFTER", "1"))
    sys.exit(0 if ready else 1)
elif command in {"pg_dump", "pg_dumpall"}:
    attempt = count("dump")
    Path(option("--file")).write_text(os.environ.get("FAKE_SQL", "CREATE TABLE example (id integer);\n"))
    if os.environ.get("FAKE_DUMP_FAIL") or (os.environ.get("FAKE_DUMP_FAIL_ONCE") and attempt == 1):
        sys.exit(42)
elif command == "aws":
    if "s3" in args:
        start = args.index("s3")
        source, destination = args[start + 2:start + 4]
        if source.startswith("s3://"):
            key = source.split("/", 3)[3]
            shutil.copyfile(root / "objects" / key, destination)
        else:
            if os.environ.get("FAKE_UPLOAD_FAIL"):
                sys.exit(43)
            key = destination.split("/", 3)[3]
            target = root / "objects" / key
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    elif "head-object" in args:
        content = (root / "objects" / option("--key")).read_bytes()
        sha = hashlib.sha256(content).hexdigest()
        if os.environ.get("FAKE_HEAD_MISMATCH"):
            sha = "0" * 64
        print(f"{len(content)}\t{sha}" if "ContentLength" in option("--query") else sha)
    elif "list-objects-v2" in args:
        prefix = option("--prefix")
        objects = [p for p in (root / "objects").rglob("*") if p.is_file()]
        keys = sorted(str(p.relative_to(root / "objects")) for p in objects)
        print(next((key for key in reversed(keys) if key.startswith(prefix)), "None"))
    else:
        sys.exit(44)
elif command == "psql":
    if os.environ.get("FAKE_SQL_FAIL"):
        sys.exit(45)
    if any(arg.startswith("--file=") for arg in args):
        shutil.copyfile(option("--file"), root / "restored.sql")
elif command == "sleep":
    if os.environ.get("FAKE_STOP_AFTER_SLEEPS") and count("sleep") >= int(os.environ["FAKE_STOP_AFTER_SLEEPS"]):
        sys.exit(46)
elif command in {"gzip", "openssl"}:
    if os.environ.get("FAKE_" + command.upper() + "_FAIL"):
        sys.exit(47)
    os.execv("/usr/bin/" + command, [command, *args])
else:
    sys.exit(48)
