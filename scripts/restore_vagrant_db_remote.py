#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import List, Optional

import django
from django.apps import apps
from django.core.management import CommandError, call_command
from django.test.utils import override_settings


def patch_signal_handlers(project_dir: Path) -> None:
    """
    During loaddata, Django sends signals with raw=True. Adding a `raw` guard
    avoids side effects (eg. repo creation) while fixture rows are being inserted.
    """
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


def clear_datasets_dir(project_dir: Path) -> None:
    """
    A clean datasets dir prevents stale files from earlier runs.
    """
    datasets_dir = project_dir / "data/datasets"
    if not datasets_dir.exists():
        return
    for child in datasets_dir.iterdir():
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def run_manage_py(args: List[str], project_dir: Path, settings_module: str, log_path: Optional[Path] = None) -> int:
    cmd = [sys.executable, "manage.py", *args, f"--settings={settings_module}"]
    if log_path is None:
        subprocess.run(cmd, cwd=project_dir, check=True)
        return 0

    with log_path.open("w") as handle:
        result = subprocess.run(cmd, cwd=project_dir, stdout=handle, stderr=subprocess.STDOUT, check=False)
    return result.returncode


def run_loaddata_no_email(fixture_path: Path, log_path: Path) -> int:
    # Use Django's dummy backend to guarantee fixture imports never emit emails.
    with log_path.open("w") as handle:
        with redirect_stdout(handle), redirect_stderr(handle):
            try:
                with override_settings(EMAIL_BACKEND="django.core.mail.backends.dummy.EmailBackend"):
                    call_command("loaddata", str(fixture_path), ignorenonexistent=True)
            except CommandError:
                return 1
    return 0


def run_migrate_no_email(log_path: Path) -> int:
    # Keep migrations side-effect free from outbound email.
    with log_path.open("w") as handle:
        with redirect_stdout(handle), redirect_stderr(handle):
            try:
                with override_settings(EMAIL_BACKEND="django.core.mail.backends.dummy.EmailBackend"):
                    call_command("migrate")
            except CommandError:
                return 1
    return 0


def print_tail(path: Path, lines: int) -> None:
    if not path.exists():
        return
    content = path.read_text().splitlines()
    for line in content[-lines:]:
        print(line)


def filter_fixture(
    backup: str,
    excluded_models: set,
    model_path_rename_from: str,
    model_path_rename_to: str,
) -> tuple:
    """
    Load backup fixture and filter it: exclude framework models, remove stale
    permission links from accounts.user, rename model paths, and detect
    nonexistent schema fields.

    Returns tuple of:
      (original_record_count, filtered_data, ignored_counts, ignored_records_by_model,
       user_permission_links_removed, user_records_touched, model_path_replacements,
       converted_field_records, ignored_nonexistent_fields_records,
       ignored_nonexistent_fields_by_model)
    """
    with open(backup) as handle:
        data = json.load(handle)

    original_record_count = len(data)
    ignored_counts = {model: 0 for model in excluded_models}
    user_permission_links_removed = 0
    user_records_touched = 0
    ignored_records = []
    ignored_records_by_model = {model: [] for model in excluded_models}
    stripped_user_permission_links = []
    model_path_replacements = 0
    converted_field_records = []

    def replace_model_path(value, path=None, changes=None):
        # Walk any nested fixture structure (dict/list/scalar), replace exact
        # occurrences of the old model path in both values and dict keys,
        # and record each replacement with its location for reporting.
        nonlocal model_path_replacements
        if path is None:
            path = []
        if changes is None:
            changes = []
        if isinstance(value, str):
            if value == model_path_rename_from:
                model_path_replacements += 1
                changes.append(
                    {
                        "kind": "value",
                        "path": "/".join(str(p) for p in path),
                        "from": model_path_rename_from,
                        "to": model_path_rename_to,
                    }
                )
                return model_path_rename_to
            return value
        if isinstance(value, list):
            return [replace_model_path(item, path + [idx], changes) for idx, item in enumerate(value)]
        if isinstance(value, dict):
            updated = {}
            for key, item in value.items():
                new_key = model_path_rename_to if key == model_path_rename_from else key
                if new_key != key:
                    model_path_replacements += 1
                    changes.append(
                        {
                            "kind": "key",
                            "path": "/".join(str(p) for p in path + [str(key)]),
                            "from": model_path_rename_from,
                            "to": model_path_rename_to,
                        }
                    )
                converted_item = replace_model_path(item, path + [str(new_key)], changes)
                if key == model_path_rename_from and not isinstance(converted_item, list):
                    # The old field stores a single value; the new field expects a list.
                    converted_item = [] if converted_item is None else [converted_item]
                    changes.append(
                        {
                            "kind": "value_to_list",
                            "path": "/".join(str(p) for p in path + [str(new_key)]),
                            "from_type": type(item).__name__,
                            "to_type": "list",
                        }
                    )
                updated[new_key] = converted_item
            return updated
        return value

    filtered = []
    for index, obj in enumerate(data):
        original_model = obj.get("model")
        original_pk = obj.get("pk")
        record_changes = []
        obj = replace_model_path(obj, path=[], changes=record_changes)
        if record_changes:
            converted_field_records.append(
                {
                    "record_index": index,
                    "model_before": original_model,
                    "pk": original_pk,
                    "change_count": len(record_changes),
                    "changes": record_changes,
                }
            )

        model = obj.get("model")
        if model in excluded_models:
            ignored_counts[model] += 1
            ignored_records.append(obj)
            ignored_records_by_model[model].append(obj)
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

    ignored_nonexistent_fields_records = []
    ignored_nonexistent_fields_by_model = defaultdict(lambda: defaultdict(int))
    model_fields_cache = {}

    for obj in filtered:
        model_label = obj.get("model", "")
        if "." not in model_label:
            continue
        app_label, model_name = model_label.split(".", 1)
        cache_key = f"{app_label}.{model_name}"

        if cache_key not in model_fields_cache:
            try:
                model_cls = apps.get_model(app_label, model_name)
            except LookupError:
                model_fields_cache[cache_key] = None
            else:
                allowed = set()
                for field in model_cls._meta.get_fields():
                    if field.auto_created and not field.concrete:
                        continue
                    allowed.add(field.name)
                    attname = getattr(field, "attname", None)
                    if attname:
                        allowed.add(attname)
                model_fields_cache[cache_key] = allowed

        allowed_fields = model_fields_cache[cache_key]
        if allowed_fields is None:
            continue

        fixture_fields = obj.get("fields", {})
        ignored_field_names = sorted(name for name in fixture_fields if name not in allowed_fields)
        if not ignored_field_names:
            continue

        ignored_values = {name: fixture_fields.get(name) for name in ignored_field_names}
        ignored_nonexistent_fields_records.append(
            {
                "model": model_label,
                "pk": obj.get("pk"),
                "ignored_fields": ignored_values,
            }
        )
        for name in ignored_field_names:
            ignored_nonexistent_fields_by_model[model_label][name] += 1

    return (
        original_record_count,
        filtered,
        ignored_counts,
        ignored_records_by_model,
        user_permission_links_removed,
        user_records_touched,
        model_path_replacements,
        converted_field_records,
        ignored_nonexistent_fields_records,
        ignored_nonexistent_fields_by_model,
    )


def main() -> int:
    backup = os.environ["BACKUP_PATH"]
    project_dir = Path(os.environ["PROJECT_DIR"])
    settings_module = os.environ["SETTINGS_MODULE"]
    filtered_path = Path(os.environ["FILTERED_FIXTURE"])
    load_log_path = Path(os.environ["LOAD_LOG"])
    migrate_log_path = Path(os.environ["MIGRATE_LOG"])
    ignored_log_path = Path(os.environ["IGNORED_LOG"])
    ignored_json_path = Path(os.environ["IGNORED_JSON"])
    ignored_records_dir = Path(os.environ["IGNORED_RECORDS_DIR"])
    ignored_nonexistent_fields_json_path = Path(os.environ["IGNORED_NONEXISTENT_FIELDS_JSON"])
    converted_fields_json_path = Path(os.environ["CONVERTED_FIELDS_JSON"])

    os.chdir(project_dir)
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", settings_module)
    django.setup()

    print("[1/6] Applying signal safety guards (raw fixture load)")
    patch_signal_handlers(project_dir)

    print("[2/6] Clearing datasets directory")
    clear_datasets_dir(project_dir)

    print(f"[3/6] Building filtered fixture from {backup}")
    
    # Exclude framework-managed permission/content-type data that tends to mismatch
    # across schema versions; Django will recreate the required rows.
    excluded_models = {
        "auth.permission",
        "contenttypes.contenttype",
        "guardian.userobjectpermission",
        "guardian.groupobjectpermission",
    }

    model_path_rename_from = "stories.storygraph.modelgroup"
    model_path_rename_to = "stories.storygraph.modelgroups"

    ignored_records_dir.mkdir(parents=True, exist_ok=True)

    (
        original_record_count,
        filtered,
        ignored_counts,
        ignored_records_by_model,
        user_permission_links_removed,
        user_records_touched,
        model_path_replacements,
        converted_field_records,
        ignored_nonexistent_fields_records,
        ignored_nonexistent_fields_by_model,
    ) = filter_fixture(backup, excluded_models, model_path_rename_from, model_path_rename_to)

    with filtered_path.open("w") as handle:
        json.dump(filtered, handle)

    ignored_total = sum(ignored_counts.values())
    generated_at = datetime.utcnow().isoformat() + "Z"

    report = {
        "generated_at_utc": generated_at,
        "backup_path": backup,
        "original_records": original_record_count,
        "filtered_records": len(filtered),
        "ignored_records_total": ignored_total,
        "ignored_records_by_model": dict(sorted(ignored_counts.items())),
        "renamed_model_path_from": model_path_rename_from,
        "renamed_model_path_to": model_path_rename_to,
        "renamed_model_path_replacements": model_path_replacements,
        "accounts_user_permission_links_removed": user_permission_links_removed,
        "accounts_user_records_touched": user_records_touched,
    }

    ignored_records_files = {}
    for model in sorted(excluded_models):
        model_filename = model.replace(".", "_") + ".json"
        model_path = ignored_records_dir / model_filename
        ignored_records_files[model] = str(model_path)
        model_dump = {
            "generated_at_utc": generated_at,
            "backup_path": backup,
            "model": model,
            "ignored_records_total": len(ignored_records_by_model[model]),
            "ignored_fixture_records": ignored_records_by_model[model],
        }
        with model_path.open("w") as handle:
            json.dump(model_dump, handle, indent=2)

    report["ignored_records_per_model_files"] = ignored_records_files
    report["ignored_nonexistent_fields_total_records"] = len(ignored_nonexistent_fields_records)
    report["converted_fields_json"] = str(converted_fields_json_path)
    report["converted_fields_total_records"] = len(converted_field_records)

    converted_fields_report = {
        "generated_at_utc": generated_at,
        "backup_path": backup,
        "conversion_from": model_path_rename_from,
        "conversion_to": model_path_rename_to,
        "replacement_count": model_path_replacements,
        "records_with_conversions": len(converted_field_records),
        "converted_records": converted_field_records,
    }
    with converted_fields_json_path.open("w") as handle:
        json.dump(converted_fields_report, handle, indent=2)

    ignored_nonexistent_fields_report = {
        "generated_at_utc": generated_at,
        "backup_path": backup,
        "analyzed_fixture_records": len(filtered),
        "records_with_ignored_nonexistent_fields": len(ignored_nonexistent_fields_records),
        "ignored_nonexistent_fields_by_model": {
            model: dict(sorted(field_counts.items()))
            for model, field_counts in sorted(ignored_nonexistent_fields_by_model.items())
        },
        "ignored_nonexistent_fields_records": ignored_nonexistent_fields_records,
    }
    with ignored_nonexistent_fields_json_path.open("w") as handle:
        json.dump(ignored_nonexistent_fields_report, handle, indent=2)

    with ignored_json_path.open("w") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)

    with ignored_log_path.open("w") as handle:
        handle.write("Restore ignored-data summary\n")
        handle.write(f"Generated (UTC): {generated_at}\n")
        handle.write(f"Backup fixture: {backup}\n")
        handle.write(f"Original records: {original_record_count}\n")
        handle.write(f"Filtered records: {len(filtered)}\n")
        handle.write(f"Ignored records total: {ignored_total}\n")
        handle.write(
            f"Renamed model path replacements ({model_path_rename_from} -> {model_path_rename_to}): {model_path_replacements}\n"
        )
        handle.write(f"Ignored records per-model JSON files: {ignored_records_dir}\n")
        handle.write("Ignored records by model:\n")
        for model, count in sorted(ignored_counts.items()):
            handle.write(f"  - {model}: {count}\n")
        handle.write(f"accounts.user records touched: {user_records_touched}\n")
        handle.write(f"accounts.user permission links removed: {user_permission_links_removed}\n")

    print(f"Original records: {original_record_count}")
    print(f"Filtered records: {len(filtered)}")
    print(f"Ignored data log: {ignored_log_path}")
    print(f"Ignored data JSON: {ignored_json_path}")
    print(f"Ignored records per-model JSON dir: {ignored_records_dir}")
    print(f"Ignored --ignorenonexistent fields JSON: {ignored_nonexistent_fields_json_path}")
    print(f"Converted fields JSON: {converted_fields_json_path}")


    print("[4/6] Flushing DB")
    # Flush so imported private keys and relationships are loaded onto an empty DB.
    run_manage_py(["flush", "--no-input"], project_dir, settings_module)

    print("[5/6] Loading fixture")
    # Ignore unknown fields to tolerate fixture/schema drift and disable emails during import.
    load_rc = run_loaddata_no_email(filtered_path, load_log_path)
    # Treat missing "Installed ..." lines as a failed import.
    installed_lines = [
        line for line in load_log_path.read_text().splitlines() if line.startswith("Installed ")
    ]
    if load_rc != 0 or not installed_lines:
        print(f"loaddata failed. Last lines from {load_log_path}:", file=sys.stderr)
        print_tail(load_log_path, 60)
        return 1

    for line in installed_lines:
        print(line)

    print("[6/6] Running migrate")
    # Ensure schema is fully current and post_migrate hooks run for regenerated metadata.
    migrate_rc = run_migrate_no_email(migrate_log_path)
    if migrate_rc != 0:
        print(f"migrate failed. Last lines from {migrate_log_path}:", file=sys.stderr)
        print_tail(migrate_log_path, 60)
        return 1

    print_tail(migrate_log_path, 8)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
