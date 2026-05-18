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

REMOTE_PYTHON_SCRIPT="scripts/restore_vagrant_db_remote.py"

# Temporary artifacts are created inside the VM so host files stay untouched.
FILTERED_FIXTURE="/tmp/db_filtered_restore.json"
LOAD_LOG="/tmp/loaddata_restore.log"
MIGRATE_LOG="/tmp/migrate_restore.log"
IGNORED_LOG="/tmp/restore_ignored_data.log"
IGNORED_JSON="/tmp/restore_ignored_data.json"
IGNORED_RECORDS_DIR="/tmp/restore_ignored_records"
IGNORED_NONEXISTENT_FIELDS_JSON="/tmp/restore_ignored_nonexistent_fields.json"
CONVERTED_FIELDS_JSON="/tmp/restore_converted_fields.json"

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


if [[ ! -f "$REMOTE_PYTHON_SCRIPT" ]]; then
  echo "Error: remote script not found: $REMOTE_PYTHON_SCRIPT" >&2
  exit 1
fi

# Quote values for safe transport through the vagrant ssh command boundary.
backup_q=$(printf '%q' "$BACKUP_PATH")
project_q=$(printf '%q' "$PROJECT_DIR")
settings_q=$(printf '%q' "$SETTINGS_MODULE")
filtered_q=$(printf '%q' "$FILTERED_FIXTURE")
load_log_q=$(printf '%q' "$LOAD_LOG")
migrate_log_q=$(printf '%q' "$MIGRATE_LOG")
ignored_log_q=$(printf '%q' "$IGNORED_LOG")
ignored_json_q=$(printf '%q' "$IGNORED_JSON")
ignored_records_dir_q=$(printf '%q' "$IGNORED_RECORDS_DIR")
ignored_nonexistent_fields_json_q=$(printf '%q' "$IGNORED_NONEXISTENT_FIELDS_JSON")
converted_fields_json_q=$(printf '%q' "$CONVERTED_FIELDS_JSON")


# Run the entire restore flow as the Django app user inside the VM.
vagrant ssh -c "sudo -u weblab_django env \
  BACKUP_PATH=${backup_q} \
  PROJECT_DIR=${project_q} \
  SETTINGS_MODULE=${settings_q} \
  FILTERED_FIXTURE=${filtered_q} \
  LOAD_LOG=${load_log_q} \
  MIGRATE_LOG=${migrate_log_q} \
  IGNORED_LOG=${ignored_log_q} \
  IGNORED_JSON=${ignored_json_q} \
  IGNORED_RECORDS_DIR=${ignored_records_dir_q} \
  IGNORED_NONEXISTENT_FIELDS_JSON=${ignored_nonexistent_fields_json_q} \
  CONVERTED_FIELDS_JSON=${converted_fields_json_q} \
  /opt/django/venv/bin/python -" < "$REMOTE_PYTHON_SCRIPT"

echo
echo "Restore completed successfully."
echo "loaddata log: $LOAD_LOG"
echo "migrate log:  $MIGRATE_LOG"
echo "ignored log:  $IGNORED_LOG"
echo "ignored json: $IGNORED_JSON"
echo "ignored records per-model dir: $IGNORED_RECORDS_DIR"
echo "ignored --ignorenonexistent fields json: $IGNORED_NONEXISTENT_FIELDS_JSON"
echo "converted fields json: $CONVERTED_FIELDS_JSON"
