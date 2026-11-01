"""Validate the checked-in examples against schema/result.schema.json, and check that
documents missing a required field are rejected. Run: python3 -I tests/validate_schema.py"""
import copy
import json
import pathlib
import sys

from jsonschema import Draft202012Validator

root = pathlib.Path(__file__).resolve().parent.parent
schema = json.loads((root / "schema/result.schema.json").read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema, format_checker=Draft202012Validator.FORMAT_CHECKER)
failures = []

for name in ("result-ok.json", "result-failed-probe.json"):
    doc = json.loads((root / "examples" / name).read_text())
    errs = list(validator.iter_errors(doc))
    if errs:
        failures.append(f"{name} should validate: {errs[0].message}")

ok = json.loads((root / "examples/result-ok.json").read_text())
for field in schema["required"]:
    doc = copy.deepcopy(ok)
    del doc[field]
    if not list(validator.iter_errors(doc)):
        failures.append(f"document without {field} should be rejected")

extra = copy.deepcopy(ok)
extra["future_field"] = {"anything": 1}
extra["host"]["new_host_fact"] = "x"
if list(validator.iter_errors(extra)):
    failures.append("unknown extra fields must be allowed")

wrong_version = copy.deepcopy(ok)
wrong_version["schema_version"] = "99"
if not list(validator.iter_errors(wrong_version)):
    failures.append("unknown schema_version should be rejected")

if failures:
    print("\n".join("FAIL: " + f for f in failures), file=sys.stderr)
    sys.exit(1)
print("schema examples: ok")
