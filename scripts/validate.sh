#!/usr/bin/env bash
#
# validate.sh - static validation for every Terraform module and example.
#
# This performs NO network calls against Google Cloud and creates NO resources.
# `terraform init -backend=false` only downloads providers so that `validate`
# can type-check the configuration against the real provider schema.
#
# Usage:
#   ./scripts/validate.sh          # check formatting, fail if unformatted
#   ./scripts/validate.sh --fix    # rewrite files to canonical format first

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
FAILURES=0

if ! command -v terraform >/dev/null 2>&1; then
  echo "${RED}terraform not found on PATH${NC}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Formatting
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--fix" ]]; then
  echo "==> terraform fmt -recursive (rewriting)"
  terraform fmt -recursive terraform/
else
  echo "==> terraform fmt -recursive -check"
  if ! terraform fmt -recursive -check -diff terraform/; then
    echo "${RED}FAIL${NC}: files are not canonically formatted. Run: ./scripts/validate.sh --fix"
    FAILURES=$((FAILURES + 1))
  else
    echo "${GREEN}OK${NC}: formatting clean"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Validation of every directory that declares a terraform{} block
# ---------------------------------------------------------------------------
# Modules are validated indirectly via the examples that call them, but we also
# validate them standalone to catch syntax errors in modules no example uses.
TARGETS=$(find terraform -name 'versions.tf' -exec dirname {} \; | sort)

for dir in ${TARGETS}; do
  echo ""
  echo "==> ${dir}"
  if ! terraform -chdir="${dir}" init -backend=false -input=false -no-color >/dev/null; then
    echo "${RED}FAIL${NC}: terraform init failed in ${dir}"
    FAILURES=$((FAILURES + 1))
    continue
  fi
  if terraform -chdir="${dir}" validate -no-color; then
    echo "${GREEN}OK${NC}"
  else
    echo "${RED}FAIL${NC}: terraform validate failed in ${dir}"
    FAILURES=$((FAILURES + 1))
  fi
done

# ---------------------------------------------------------------------------
# 3. Guard against committed secrets / state
# ---------------------------------------------------------------------------
echo ""
echo "==> secret & state guard"
STRAY=$(git ls-files | grep -E '\.tfstate|(^|/)terraform\.tfvars$|\.tfvars$' | grep -v '\.example$' || true)
if [[ -n "${STRAY}" ]]; then
  echo "${RED}FAIL${NC}: the following files must never be tracked by git:"
  echo "${STRAY}"
  FAILURES=$((FAILURES + 1))
else
  echo "${GREEN}OK${NC}: no state or tfvars files tracked"
fi

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${RED}${FAILURES} check(s) failed.${NC}"
  exit 1
fi
echo "${GREEN}All checks passed.${NC}"
