#!/usr/bin/env bash
set -euo pipefail

# Restore the WebLab DB inside the Vagrant VM from a JSON backup fixture.
# Usage:
#   scripts/restore_vagrant_db.sh [/path/in/vm/to/db.json]
# Example:
#   scripts/restore_vagrant_db.sh /home/vagrant/backups/db.json

BACKUP_PATH="${1:-/home/vagrant/backups/db.json}"
PROJECT_DIR="${PROJECT_DIR:-/opt/django/WebLab/weblab}"
SETTINGS_MODULE="${SETTINGS_MODULE:-config.settings.vagrant}"

# Temporary artifacts are created inside the VM so host files stay untouched.
FILTERED_FIXTURE="/tmp/db_filtered_restore.json"
LOAD_LOG="/tmp/loaddata_restore.log"
MIGRATE_LOG="/tmp/migrate_restore.log"
IGNORED_LOG="/tmp/restore_ignored_data.log"
IGNORED_JSON="/tmp/restore_ignored_data.json"
IGNORED_RECORDS_JSON="/tmp/restore_ignored_records.json"

if ! command -v vagrant >/dev/null 2>&1; then
  echo "Error: vagrant command not found in PATH." >&2
  exit 1
fi

if [[ ! -f Vagrantfile ]]; then
  echo "Error: run this script from the deployment folder (where Vagrantfile exists)." >&2
  exit 1
fi

if ! vagrant status --machine-readable | grep -q ',state,running'; then
  echo "Error: Vagrant VM is not running. Start it with: vagrant up" >&2
  exit 1
fi

echo "[1/5] Applying signal safety guards (raw fixture load)"
echo "[2/5] Clearing datasets directory"
echo "[3/5] Building filtered fixture from ${BACKUP_PATH}"
echo "[4/5] Flushing DB + loading fixture"
echo "[5/5] Running migrate"

# Quote values for safe transport through the vagrant ssh command boundary.
backup_q=$(printf '%q' "$BACKUP_PATH")
project_q=$(printf '%q' "$PROJECT_DIR")
settings_q=$(printf '%q' "$SETTINGS_MODULE")
filtered_q=$(printf '%q' "$FILTERED_FIXTURE")
load_log_q=$(printf '%q' "$LOAD_LOG")
migrate_log_q=$(printf '%q' "$MIGRATE_LOG")
ignored_log_q=$(printf '%q' "$IGNORED_LOG")
ignored_json_q=$(printf '%q' "$IGNORED_JSON")
ignored_records_json_q=$(printf '%q' "$IGNORED_RECORDS_JSON")

# Run the entire restore flow as the Django app user inside the VM.
vagrant ssh -c "sudo -u weblab_django env BACKUP_PATH=${backup_q} PROJECT_DIR=${project_q} SETTINGS_MODULE=${settings_q} FILTERED_FIXTURE=${filtered_q} LOAD_LOG=${load_log_q} MIGRATE_LOG=${migrate_log_q} IGNORED_LOG=${ignored_log_q} IGNORED_JSON=${ignored_json_q} IGNORED_RECORDS_JSON=${ignored_records_json_q} bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

# Workaround for non-interactive shells because venv activation references `PS1`.
export PS1="${PS1-}"
set +u
source /opt/django/venv/bin/activate
set -u
cd "$PROJECT_DIR"


# During loaddata, Django sends signals with raw=True. Adding a `raw` guard 
# avoids side effects (eg. repo creation) while fixture rows are being inserted.

python - <<'PY_PATCH'
from pathlib import Path
import os

project_dir = Path(os.environ["PROJECT_DIR"])

patch_targets = [
    (project_dir / "entities/signals.py", "def entity_created(sender, instance, created, **kwargs):"),
    (project_dir / "accounts/signals.py", "def user_created(sender, instance, created, **kwargs):"),
    (project_dir / "datasets/signals.py", "def dataset_created(sender, instance, created, **kwargs):"),
]

guard = "    if kwargs.get('raw', False):\n        return\n"

for path, signature in patch_targets:
    text = path.read_text()
    if "kwargs.get('raw', False)" in text:
        continue
    idx = text.find(signature)
    if idx == -1:
        raise RuntimeError(f"Could not find function signature in {path}")
    insert_at = idx + len(signature)
    updated = text[:insert_at] + "\n" + guard + text[insert_at:]
    path.write_text(updated)
PY_PATCH

# A clean datasets dir prevents stale files from earlier runs.
rm -rf "$PROJECT_DIR/data/datasets/"*


# Exclude framework-managed permission/content-type data that tends to mismatch
# across schema versions; Django will recreate the required rows.

python - <<'PY_FILTER'
import json
import os
from datetime import datetime

backup = os.environ["BACKUP_PATH"]
filtered_path = os.environ["FILTERED_FIXTURE"]
ignored_log_path = os.environ["IGNORED_LOG"]
ignored_json_path = os.environ["IGNORED_JSON"]
ignored_records_json_path = os.environ["IGNORED_RECORDS_JSON"]

with open(backup) as f:
    data = json.load(f)

excluded_models = {
    "auth.permission",
    "contenttypes.contenttype",
    "guardian.userobjectpermission",
    "guardian.groupobjectpermission",
}

ignored_counts = {model: 0 for model in excluded_models}
user_permission_links_removed = 0
user_records_touched = 0
ignored_records = []
stripped_user_permission_links = []

filtered = []
for obj in data:
    model = obj.get("model")
    if model in excluded_models:
        ignored_counts[model] += 1
        ignored_records.append(obj)
        continue
    if model == "accounts.user":
        # Remove direct permission links to avoid foreign key mismatches against
        # regenerated auth_permission ids after flush/migrate.
        fields = obj.get("fields", {})
        if "user_permissions" in fields:
            removed_links = fields.get("user_permissions", [])
            user_permission_links_removed += len(removed_links)
            if removed_links:
                stripped_user_permission_links.append(
                    {
                        "model": model,
                        "pk": obj.get("pk"),
                        "removed_permission_ids": removed_links,
                    }
                )
            fields["user_permissions"] = []
            user_records_touched += 1
    filtered.append(obj)

with open(filtered_path, "w") as f:
    json.dump(filtered, f)

ignored_total = sum(ignored_counts.values())
report = {
    "generated_at_utc": datetime.utcnow().isoformat() + "Z",
    "backup_path": backup,
    "original_records": len(data),
    "filtered_records": len(filtered),
    "ignored_records_total": ignored_total,
    "ignored_records_by_model": dict(sorted(ignored_counts.items())),
    "accounts_user_permission_links_removed": user_permission_links_removed,
    "accounts_user_records_touched": user_records_touched,
}

with open(ignored_json_path, "w") as f:
    json.dump(report, f, indent=2, sort_keys=True)

ignored_records_dump = {
    "generated_at_utc": report["generated_at_utc"],
    "backup_path": backup,
    "excluded_models": sorted(excluded_models),
    "ignored_fixture_records": ignored_records,
    "stripped_accounts_user_permission_links": stripped_user_permission_links,
}

with open(ignored_records_json_path, "w") as f:
    json.dump(ignored_records_dump, f, indent=2)

with open(ignored_log_path, "w") as f:
    f.write("Restore ignored-data summary\n")
    f.write(f"Generated (UTC): {report['generated_at_utc']}\n")
    f.write(f"Backup fixture: {backup}\n")
    f.write(f"Original records: {len(data)}\n")
    f.write(f"Filtered records: {len(filtered)}\n")
    f.write(f"Ignored records total: {ignored_total}\n")
    f.write("Ignored records by model:\n")
    for model, count in sorted(ignored_counts.items()):
        f.write(f"  - {model}: {count}\n")
    f.write(f"accounts.user records touched: {user_records_touched}\n")
    f.write(f"accounts.user permission links removed: {user_permission_links_removed}\n")

print(f"Original records: {len(data)}")
print(f"Filtered records: {len(filtered)}")
print(f"Ignored data log: {ignored_log_path}")
print(f"Ignored data JSON: {ignored_json_path}")
print(f"Ignored records JSON: {ignored_records_json_path}")
PY_FILTER

# Flush so imported private keys and relationships are loaded onto an empty DB.
python manage.py flush --no-input --settings="$SETTINGS_MODULE"

# Ignore unknown fields to tolerate fixture/schema drift (for example removed fields).
python manage.py loaddata "$FILTERED_FIXTURE" --ignorenonexistent --settings="$SETTINGS_MODULE" > "$LOAD_LOG" 2>&1

# Treat missing "Installed ..." lines as a failed import.
if ! grep -q '^Installed ' "$LOAD_LOG"; then
    echo "loaddata failed. Last lines from $LOAD_LOG:" >&2
    tail -n 60 "$LOAD_LOG" >&2
    exit 1
fi

grep '^Installed ' "$LOAD_LOG"

# Ensure schema is fully current and post_migrate hooks run for regenerated metadata.
python manage.py migrate --settings="$SETTINGS_MODULE" > "$MIGRATE_LOG" 2>&1
tail -n 8 "$MIGRATE_LOG"
REMOTE_SCRIPT

echo
echo "Restore completed successfully."
echo "loaddata log: $LOAD_LOG"
echo "migrate log:  $MIGRATE_LOG"
echo "ignored log:  $IGNORED_LOG"
echo "ignored json: $IGNORED_JSON"
echo "ignored records json: $IGNORED_RECORDS_JSON"
