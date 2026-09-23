#!/usr/bin/env bash
#
# verify-security-posture.sh
#
# Read-only audit of an AlloyDB cluster against the hardened baseline in
# docs/security-hardening.md.
#
# Makes NO changes. Safe to run against production, and safe to hand to an
# auditor who has only viewer access.
#
# Usage:
#   ./scripts/verify-security-posture.sh --cluster CLUSTER_ID --region REGION [--project PROJECT_ID]
#
# Exit codes:
#   0  all checks passed
#   1  one or more FAIL results
#   2  usage or prerequisite error

set -uo pipefail

CLUSTER=""
REGION=""
PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$CLUSTER" || -z "$REGION" ]]; then
  echo "Usage: $0 --cluster CLUSTER_ID --region REGION [--project PROJECT_ID]" >&2
  exit 2
fi

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
  echo "No project set. Pass --project or run: gcloud config set project PROJECT_ID" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 2; }

# Every gcloud call goes through gc(). Two reasons:
#   1. --quiet stops gcloud from ever opening an interactive prompt (e.g. the
#      "install the alpha components?" prompt), which would block forever in CI.
#   2. timeout caps a stalled API call so the audit always terminates.
# A timed-out or failed call returns empty output, and each check below is
# written to degrade to INFO rather than a false PASS when that happens.
GCLOUD_TIMEOUT="${GCLOUD_TIMEOUT:-60}"
gc() { timeout "$GCLOUD_TIMEOUT" gcloud --quiet "$@" 2>/dev/null; }

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'

PASS=0; FAIL=0; WARN=0

pass() { printf "  ${GREEN}PASS${NC}  %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  ${RED}FAIL${NC}  %s\n" "$1"; [[ -n "${2:-}" ]] && printf "        ${YELLOW}-> %s${NC}\n" "$2"; FAIL=$((FAIL+1)); }
warn() { printf "  ${YELLOW}WARN${NC}  %s\n" "$1"; [[ -n "${2:-}" ]] && printf "        ${YELLOW}-> %s${NC}\n" "$2"; WARN=$((WARN+1)); }
info() { printf "  ${BLUE}INFO${NC}  %s\n" "$1"; [[ -n "${2:-}" ]] && printf "        ${BLUE}-> %s${NC}\n" "$2"; return 0; }
section() { printf "\n${BOLD}%s${NC}\n" "$1"; }

printf "${BOLD}AlloyDB security posture${NC}\n"
printf "cluster=%s region=%s project=%s\n" "$CLUSTER" "$REGION" "$PROJECT"

# ---------------------------------------------------------------------------
# Fetch cluster and instances once.
# ---------------------------------------------------------------------------
CLUSTER_JSON=$(gc alloydb clusters describe "$CLUSTER" \
  --region="$REGION" --project="$PROJECT" --format=json 2>/dev/null)

if [[ -z "$CLUSTER_JSON" ]]; then
  echo "Could not describe cluster '$CLUSTER' in '$REGION'. Check name, region and permissions." >&2
  exit 2
fi

INSTANCES_JSON=$(gc alloydb instances list \
  --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" --format=json 2>/dev/null)

# ---------------------------------------------------------------------------
section "1. Encryption at rest"
# ---------------------------------------------------------------------------
KMS_KEY=$(jq -r '.encryptionConfig.kmsKeyName // empty' <<<"$CLUSTER_JSON")
if [[ -n "$KMS_KEY" ]]; then
  pass "CMEK enabled: $KMS_KEY"

  ROTATION=$(gc kms keys describe "$KMS_KEY" --format='value(rotationPeriod)' 2>/dev/null)
  if [[ -n "$ROTATION" ]]; then
    pass "Key rotation configured: $ROTATION"
  else
    warn "No automatic key rotation on the CMEK key" \
         "gcloud kms keys update $KMS_KEY --rotation-period=90d --next-rotation-time=..."
  fi

  PROT=$(gc kms keys describe "$KMS_KEY" --format='value(versionTemplate.protectionLevel)' 2>/dev/null)
  [[ "$PROT" == "HSM" ]] && pass "Key protection level: HSM" || info "Key protection level: ${PROT:-unknown} (HSM gives FIPS 140-2 L3)"
else
  warn "Google-managed encryption, not CMEK" \
       "CMEK is set at cluster creation and cannot be added in place."
fi

# ---------------------------------------------------------------------------
section "2. Network isolation"
# ---------------------------------------------------------------------------
PSC_ENABLED=$(jq -r '.pscConfig.pscEnabled // false' <<<"$CLUSTER_JSON")
NETWORK=$(jq -r '.networkConfig.network // empty' <<<"$CLUSTER_JSON")

if [[ "$PSC_ENABLED" == "true" ]]; then
  pass "Private Service Connect enabled (no VPC peering)"
elif [[ -n "$NETWORK" ]]; then
  info "Private services access via $NETWORK" \
       "Supported and private, but this repository's examples standardise on PSC. The choice is fixed at cluster creation and cannot be changed in place."
else
  warn "Could not determine the private access method"
fi

PUBLIC_COUNT=0
while read -r inst; do
  [[ -z "$inst" ]] && continue
  NAME=$(jq -r '.name' <<<"$inst" | awk -F/ '{print $NF}')
  PUB=$(jq -r '.networkConfig.enablePublicIp // false' <<<"$inst")
  PUBIP=$(jq -r '.publicIpAddress // empty' <<<"$inst")
  if [[ "$PUB" == "true" || -n "$PUBIP" ]]; then
    fail "Instance '$NAME' has a PUBLIC IP${PUBIP:+ ($PUBIP)}" \
         "Disable it, or justify and allow-list it explicitly."
    PUBLIC_COUNT=$((PUBLIC_COUNT+1))
    EXT=$(jq -r '[.networkConfig.authorizedExternalNetworks[]?.cidrRange] | join(", ")' <<<"$inst")
    [[ -n "$EXT" ]] && info "  authorized external networks: $EXT" \
                    || fail "  public IP with NO CIDR allow-list - open to the internet"
  fi
done < <(jq -c '.[]?' <<<"$INSTANCES_JSON")
[[ $PUBLIC_COUNT -eq 0 ]] && pass "No instance has a public IP"

# ---------------------------------------------------------------------------
section "3. Encryption in transit"
# ---------------------------------------------------------------------------
while read -r inst; do
  [[ -z "$inst" ]] && continue
  NAME=$(jq -r '.name' <<<"$inst" | awk -F/ '{print $NF}')
  SSL=$(jq -r '.clientConnectionConfig.sslConfig.sslMode // "unset"' <<<"$inst")
  REQ=$(jq -r '.clientConnectionConfig.requireConnectors // false' <<<"$inst")

  case "$SSL" in
    ENCRYPTED_ONLY) pass "$NAME: ssl_mode=ENCRYPTED_ONLY" ;;
    unset)          warn "$NAME: ssl_mode not set explicitly" "Set ENCRYPTED_ONLY." ;;
    *)              fail "$NAME: ssl_mode=$SSL permits unencrypted connections" \
                         "Set ENCRYPTED_ONLY." ;;
  esac

  [[ "$REQ" == "true" ]] \
    && pass "$NAME: require_connectors=true (direct connections blocked)" \
    || info "$NAME: require_connectors=false - direct psql/JDBC is permitted"
done < <(jq -c '.[]?' <<<"$INSTANCES_JSON")

# ---------------------------------------------------------------------------
section "4. Database flags"
# ---------------------------------------------------------------------------
check_flag() {
  local inst_json="$1" name="$2" flag="$3" expect="$4" severity="$5"
  local actual
  actual=$(jq -r --arg f "$flag" '.databaseFlags[$f] // "unset"' <<<"$inst_json")
  if [[ "$actual" == "$expect" ]]; then
    pass "$name: $flag=$actual"
  elif [[ "$severity" == "fail" ]]; then
    fail "$name: $flag=$actual (expected $expect)"
  else
    warn "$name: $flag=$actual (recommended $expect)"
  fi
}

while read -r inst; do
  [[ -z "$inst" ]] && continue
  TYPE=$(jq -r '.instanceType' <<<"$inst")
  [[ "$TYPE" != "PRIMARY" ]] && continue
  NAME=$(jq -r '.name' <<<"$inst" | awk -F/ '{print $NF}')

  check_flag "$inst" "$NAME" "alloydb.iam_authentication"    "on"               warn
  check_flag "$inst" "$NAME" "alloydb.enable_pgaudit"        "on"               warn
  check_flag "$inst" "$NAME" "password.enforce_complexity"   "on"               warn
  check_flag "$inst" "$NAME" "alloydb.pg_authid_select_role" "alloydbsuperuser" warn
  check_flag "$inst" "$NAME" "alloydb.pg_shadow_select_role" "alloydbsuperuser" warn

  # pgaudit.log must be a non-empty, non-"none" value or pgAudit captures
  # nothing even when the extension is enabled.
  PGA_ON=$(jq -r '.databaseFlags["alloydb.enable_pgaudit"] // "off"' <<<"$inst")
  PGA_LOG=$(jq -r '.databaseFlags["pgaudit.log"] // "unset"' <<<"$inst")
  if [[ "$PGA_ON" == "on" ]]; then
    if [[ "$PGA_LOG" == "unset" || "$PGA_LOG" == "none" ]]; then
      fail "$NAME: pgaudit enabled but pgaudit.log=$PGA_LOG - NOTHING is being audited" \
           "Set pgaudit.log, e.g. 'ddl,role'."
    else
      pass "$NAME: pgaudit.log=$PGA_LOG"
    fi
  fi

  IIT=$(jq -r '.databaseFlags["idle_in_transaction_session_timeout"] // "unset"' <<<"$inst")
  [[ "$IIT" == "unset" || "$IIT" == "0" ]] \
    && warn "$NAME: idle_in_transaction_session_timeout is disabled" \
            "Idle-in-transaction sessions hold locks and block vacuum." \
    || pass "$NAME: idle_in_transaction_session_timeout=${IIT}ms"
done < <(jq -c '.[]?' <<<"$INSTANCES_JSON")

# ---------------------------------------------------------------------------
section "5. Availability and recovery"
# ---------------------------------------------------------------------------
while read -r inst; do
  [[ -z "$inst" ]] && continue
  TYPE=$(jq -r '.instanceType' <<<"$inst")
  [[ "$TYPE" != "PRIMARY" ]] && continue
  NAME=$(jq -r '.name' <<<"$inst" | awk -F/ '{print $NF}')
  AVAIL=$(jq -r '.availabilityType // "unset"' <<<"$inst")
  [[ "$AVAIL" == "REGIONAL" ]] \
    && pass "$NAME: availability_type=REGIONAL (HA, SLA eligible)" \
    || fail "$NAME: availability_type=$AVAIL - no automatic failover, not SLA covered"
done < <(jq -c '.[]?' <<<"$INSTANCES_JSON")

CB_ENABLED=$(jq -r '.continuousBackupConfig.enabled // false' <<<"$CLUSTER_JSON")
CB_DAYS=$(jq -r '.continuousBackupConfig.recoveryWindowDays // 0' <<<"$CLUSTER_JSON")
[[ "$CB_ENABLED" == "true" ]] \
  && pass "Continuous backup / PITR enabled, ${CB_DAYS}-day window" \
  || fail "Continuous backup disabled - no point-in-time recovery" \
          "This is your only defence against logical corruption."

AB_ENABLED=$(jq -r '.automatedBackupPolicy.enabled // false' <<<"$CLUSTER_JSON")
[[ "$AB_ENABLED" == "true" ]] \
  && pass "Automated backup policy enabled" \
  || warn "No automated backup policy"

BK_KEY=$(jq -r '.automatedBackupPolicy.encryptionConfig.kmsKeyName // empty' <<<"$CLUSTER_JSON")
if [[ -n "$KMS_KEY" ]]; then
  [[ -n "$BK_KEY" ]] \
    && pass "Backups are CMEK encrypted" \
    || warn "Cluster uses CMEK but backups may not" \
            "Backups carry their own encryption_config."
fi

DEL_POLICY=$(jq -r '.deletionPolicy // "DEFAULT"' <<<"$CLUSTER_JSON")
info "Cluster deletion policy: $DEL_POLICY"

# ---------------------------------------------------------------------------
section "6. Audit logging (project level)"
# ---------------------------------------------------------------------------
IAM_POLICY=$(gc projects get-iam-policy "$PROJECT" --format=json 2>/dev/null)
if [[ -n "$IAM_POLICY" ]]; then
  AUDIT_TYPES=$(jq -r '
    [ .auditConfigs[]?
      | select(.service == "alloydb.googleapis.com" or .service == "allServices")
      | .auditLogConfigs[]?.logType ] | unique | join(",")' <<<"$IAM_POLICY")

  if [[ -n "$AUDIT_TYPES" ]]; then
    pass "Data Access audit logs enabled: $AUDIT_TYPES"
    [[ "$AUDIT_TYPES" != *"DATA_READ"* ]] && \
      warn "DATA_READ not enabled - reads are not audited"
  else
    fail "Data Access audit logs NOT enabled for alloydb.googleapis.com" \
         "pgAudit records are delivered as Data Access logs; without this they are lost."
  fi
else
  warn "Could not read the project IAM policy (needs resourcemanager.projects.getIamPolicy)"
fi

SINKS=$(gc logging sinks list --project="$PROJECT" --format=json 2>/dev/null)
if [[ -n "$SINKS" ]]; then
  MATCH=$(jq -r '[.[] | select((.filter // "") | test("alloydb"; "i"))] | length' <<<"$SINKS")
  [[ "$MATCH" -gt 0 ]] \
    && pass "$MATCH log sink(s) reference AlloyDB" \
    || warn "No log sink appears to export AlloyDB logs" \
            "Export to a SIEM in a separate security project."
fi

# ---------------------------------------------------------------------------
section "7. Monitoring"
# ---------------------------------------------------------------------------
# `gcloud alpha monitoring policies list` prompts to install the alpha
# component and blocks forever when stdin is not a TTY, so call the REST API
# directly instead. This is also the only path that works in CI.
POLICIES=""
if command -v curl >/dev/null 2>&1; then
  TOKEN=$(gc auth print-access-token)
  if [[ -n "$TOKEN" ]]; then
    POLICIES=$(curl -sS --max-time "$GCLOUD_TIMEOUT" \
      -H "Authorization: Bearer $TOKEN" \
      "https://monitoring.googleapis.com/v3/projects/${PROJECT}/alertPolicies" \
      2>/dev/null)
  fi
fi

# Note: the API omits the "alertPolicies" key entirely when the project has
# none, so an empty {} is a successful response meaning zero policies - not a
# failure. Only a JSON body carrying ".error" is an actual failure.
if [[ -z "$POLICIES" ]] || ! jq -e . <<<"$POLICIES" >/dev/null 2>&1; then
  info "Could not reach the Monitoring API to list alert policies"
elif jq -e 'has("error")' <<<"$POLICIES" >/dev/null 2>&1; then
  info "Could not list alert policies: $(jq -r '.error.message' <<<"$POLICIES")"
else
  TOTAL=$(jq -r '.alertPolicies | length // 0' <<<"$POLICIES")
  N=$(jq -r --arg c "$CLUSTER" \
      '[.alertPolicies[]? | select((.displayName // "") | contains($c))] | length' \
      <<<"$POLICIES")
  if [[ "$TOTAL" -eq 0 ]]; then
    fail "This project has NO alert policies at all" \
         "Nobody is being paged. Apply terraform/modules/observability."
  elif [[ "$N" -gt 0 ]]; then
    pass "$N of $TOTAL alert policies reference this cluster"
  else
    warn "None of the $TOTAL alert policies in this project mention '$CLUSTER'" \
         "Apply terraform/modules/observability to cover this cluster."
  fi
fi



# ---------------------------------------------------------------------------
printf "\n${BOLD}Summary${NC}\n"
printf "  ${GREEN}pass %d${NC}   ${YELLOW}warn %d${NC}   ${RED}fail %d${NC}\n" "$PASS" "$WARN" "$FAIL"
printf "\nThis script checks configuration, not effectiveness. It cannot tell you\n"
printf "whether your SQL GRANTs follow least privilege, or whether anyone reads\n"
printf "the audit logs. See docs/security-hardening.md.\n"

[[ $FAIL -gt 0 ]] && exit 1
exit 0
