#!/usr/bin/env bash
set -euo pipefail

# Sanity checks for a restored WebLab DB inside the Vagrant VM.
# Usage:
#   scripts/verify_vagrant_db_restore.sh
# Optional env vars:
#   PROJECT_DIR=/opt/django/WebLab/weblab
#   SETTINGS_MODULE=config.settings.vagrant
#   EXPECT_MIN_USERS=1
#   EXPECT_MIN_ENTITIES=1
#   EXPECT_MIN_DATASETS=0

PROJECT_DIR="${PROJECT_DIR:-/opt/django/WebLab/weblab}"
SETTINGS_MODULE="${SETTINGS_MODULE:-config.settings.vagrant}"

EXPECT_MIN_USERS="${EXPECT_MIN_USERS:-1}"
EXPECT_MIN_ENTITIES="${EXPECT_MIN_ENTITIES:-1}"
EXPECT_MIN_DATASETS="${EXPECT_MIN_DATASETS:-0}"

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

# Quote values before passing them through ssh to avoid shell parsing issues.
project_q=$(printf '%q' "$PROJECT_DIR")
settings_q=$(printf '%q' "$SETTINGS_MODULE")
min_users_q=$(printf '%q' "$EXPECT_MIN_USERS")
min_entities_q=$(printf '%q' "$EXPECT_MIN_ENTITIES")
min_datasets_q=$(printf '%q' "$EXPECT_MIN_DATASETS")

echo "Running restore verification checks inside VM..."

# Execute checks as the Django runtime user to mirror app behavior.
vagrant ssh -c "sudo -u weblab_django env PROJECT_DIR=${project_q} SETTINGS_MODULE=${settings_q} EXPECT_MIN_USERS=${min_users_q} EXPECT_MIN_ENTITIES=${min_entities_q} EXPECT_MIN_DATASETS=${min_datasets_q} bash -s" <<'REMOTE_VERIFY'
set -euo pipefail

# Workaround for non-interactive shells because venv activation references `PS1`.
export PS1="${PS1-}"
set +u
source /opt/django/venv/bin/activate
set -u
cd "$PROJECT_DIR"

python - <<'PY_VERIFY'
import os
import sys
import json

os.environ.setdefault("DJANGO_SETTINGS_MODULE", os.environ["SETTINGS_MODULE"])

import django
django.setup()

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Permission
from django.contrib.contenttypes.models import ContentType
from django.db import connection

checks = []
failures = []

min_users = int(os.environ["EXPECT_MIN_USERS"])
min_entities = int(os.environ["EXPECT_MIN_ENTITIES"])
min_datasets = int(os.environ["EXPECT_MIN_DATASETS"])

# Sanity checking for core user/permission tables
User = get_user_model()
user_count = User.objects.count()
perm_count = Permission.objects.count()
ctype_count = ContentType.objects.count()

# Core metadata tables must exist after a valid restore/migrate sequence.
checks.append(("users.count", user_count, f">= {min_users}"))
if user_count < min_users:
    failures.append(f"users.count={user_count} < {min_users}")

checks.append(("auth_permission.count", perm_count, "> 0"))
if perm_count <= 0:
    failures.append("auth_permission is empty")

checks.append(("contenttypes.count", ctype_count, "> 0"))
if ctype_count <= 0:
    failures.append("contenttypes is empty")

# Check model counts. Missing models are reported as SKIPPED instead of failing.
for label, minimum in [("entities.Entity", min_entities), ("datasets.Dataset", min_datasets), ("stories.StoryGraph", 0)]:
    try:
        model = django.apps.apps.get_model(label)
        count = model.objects.count()
        checks.append((f"{label}.count", count, f">= {minimum}"))
        if count < minimum:
            failures.append(f"{label}.count={count} < {minimum}")
    except Exception as exc:
        checks.append((f"{label}.count", "SKIPPED", str(exc)))

# Check foreign key sanity for accounts_user_user_permissions -> auth_permission.
with connection.cursor() as cursor:
    cursor.execute(
        """
        SELECT COUNT(*)
        FROM accounts_user_user_permissions up
        LEFT JOIN auth_permission p ON p.id = up.permission_id
        WHERE p.id IS NULL
        """
    )
    orphan_perm_links = cursor.fetchone()[0]

checks.append(("accounts_user_user_permissions.orphans", orphan_perm_links, "== 0"))
if orphan_perm_links != 0:
    failures.append(f"accounts_user_user_permissions has {orphan_perm_links} orphan permission links")

# A tiny smoke check: fetch one active user and print basic identifying fields.
smoke_user = User.objects.filter(is_active=True).order_by("id").values("id", "email").first()
checks.append(("smoke.active_user", smoke_user if smoke_user else "NONE", "any active user preferred"))

print("=== Restore Verification Summary ===")
for name, value, expected in checks:
    print(f"- {name}: {value} (expected {expected})")

if failures:
    print("\nFAILURES:")
    for item in failures:
        print(f"- {item}")
    sys.exit(1)

print("\nAll checks passed.")
PY_VERIFY
REMOTE_VERIFY

echo "Verification completed successfully."
