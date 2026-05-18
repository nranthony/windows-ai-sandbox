#!/usr/bin/env bash
# =============================================================================
# audit.sh — comprehensive sandbox audit, structured JSON output
# =============================================================================
# Run INSIDE the agent container. Emits one JSON document with every finding
# tagged OK / DRIFT / WEAK / UNKNOWN / N/A / INFO. Drives the agent-side
# report generation under the `audit-sandbox` skill.
#
# Usage (inside container):
#   bash /workspace/temp_audit_package/scripts/audit/audit.sh
#   bash /workspace/temp_audit_package/scripts/audit/audit.sh > /tmp/audit.json
#   bash /workspace/temp_audit_package/scripts/audit/audit.sh --compact
#
# Usage (from host via profile.sh):
#   scripts/profile.sh <p> audit                # stages + runs + saves JSON
#   scripts/profile.sh <p> audit --stage-only   # just stage, don't run
#
# Probes live in probes/. Each is a stdlib-only Python module exporting a
# run() function that returns a list of finding dicts. aggregate.py imports
# them in turn, merges, prints one JSON. See README.md for the full contract
# and verdict semantics.
# =============================================================================
set -uo pipefail

AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$AUDIT_DIR/aggregate.py" "$@"
