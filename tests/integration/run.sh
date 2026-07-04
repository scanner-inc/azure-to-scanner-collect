#!/usr/bin/env bash
# Integration test entrypoint: apply fixture -> pytest -> destroy.
# See ./run.sh --help for the full interface. Common invocations:
#
#   ./run.sh                                     # full cycle, fast tests only
#   ./run.sh --include-slow-tests                # everything (~20-30 min more)
#   ./run.sh --keep-fixture                      # skip destroy (debugging)
#   ./run.sh --destroy-only --run-suffix <sfx>   # tear down a kept run
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'USAGE'
Usage: ./run.sh [flags] [pytest args...]

Full cycle: terraform-apply the fixture, run pytest, terraform-destroy,
then sweep for leftovers.

Flags:
  --include-slow-tests   also run the slow opt-in tests (M12 Event Grid
                         redelivery, DL1 dead-letter, A-REAL diagnostic
                         path; adds ~20-30 min of platform waits)
  --only-slow-tests      run ONLY the slow tests (the settle canaries still
                         run first; apply/destroy still dominate wall-clock)
  --keep-fixture         skip destroy so the fixture can be inspected or
                         reused; tear down later with --destroy-only
  --destroy-only         destroy a kept run and exit; requires --run-suffix
  --run-suffix <sfx>     reuse a specific run suffix instead of generating a
                         fresh one (e.g. to rerun tests against a fixture
                         kept with --keep-fixture)
  --verbose              also stream Azure/AWS SDK logs (request/response
                         headers, retries, auth flows); default shows only
                         the harness's own progress lines
  -h, --help             show this help

Anything unrecognized is passed through to pytest, e.g.:
  ./run.sh -k mirror                     # only the mirror tests
  ./run.sh --only-slow-tests -k dead     # just the dead-letter slow test

Requires: env.tfvars (copy env.tfvars.example), terraform >= 1.9, python3,
an az login session, and a valid AWS SSO session for the profile in
env.tfvars.
USAGE
}

INCLUDE_SLOW=0
ONLY_SLOW=0
KEEP=0
DESTROY_ONLY=0
VERBOSE=0
RUN_SUFFIX=""
PYTEST_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-slow-tests) INCLUDE_SLOW=1 ;;
    --only-slow-tests) ONLY_SLOW=1 ;;
    --keep-fixture) KEEP=1 ;;
    --destroy-only) DESTROY_ONLY=1 ;;
    --run-suffix)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --run-suffix requires a value" >&2
        exit 1
      fi
      RUN_SUFFIX="$2"
      shift
      ;;
    --run-suffix=*) RUN_SUFFIX="${1#*=}" ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) PYTEST_ARGS+=("$1") ;;
  esac
  shift
done
export VERBOSE # read by conftest.py to unmute SDK loggers

if [[ "${INCLUDE_SLOW}" == "1" && "${ONLY_SLOW}" == "1" ]]; then
  echo "ERROR: --include-slow-tests and --only-slow-tests are mutually exclusive." >&2
  exit 1
fi
if [[ "${DESTROY_ONLY}" == "1" && -z "${RUN_SUFFIX}" ]]; then
  echo "ERROR: --destroy-only requires --run-suffix <sfx> (the suffix of the kept run)." >&2
  exit 1
fi

if [[ ! -f env.tfvars ]]; then
  echo "ERROR: env.tfvars not found. Copy env.tfvars.example and fill in your test environment." >&2
  exit 1
fi

# openssl (not tr|head over /dev/urandom): the pipe version dies with
# SIGPIPE/141 under `set -o pipefail` when head closes the pipe early.
# Lowercase hex only: the suffix embeds in storage account names (lowercase
# alphanumerics only). --run-suffix overrides.
RUN_SUFFIX="${RUN_SUFFIX:-$(openssl rand -hex 3)}"
AWS_PROFILE_VAL="$(sed -n 's/^aws_profile[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' env.tfvars)"
if [[ -z "${AWS_PROFILE_VAL}" ]]; then
  echo "ERROR: could not read aws_profile from env.tfvars (expected a line like: aws_profile = \"my-profile\")" >&2
  exit 1
fi
SUBSCRIPTION_VAL="$(sed -n 's/^subscription_id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' env.tfvars)"
if [[ -z "${SUBSCRIPTION_VAL}" ]]; then
  echo "ERROR: could not read subscription_id from env.tfvars (expected a line like: subscription_id = \"...\")" >&2
  exit 1
fi
echo "=== Integration test run: suffix=${RUN_SUFFIX} ==="

check_leftovers() {
  # T3: after destroy, nothing bearing our run suffix may remain. The fixture
  # lives in one run-suffixed resource group, so "RG gone" implies almost
  # everything is gone; storage accounts get a belt-and-braces check because
  # their names live in a global namespace.
  echo "--- Checking for leftover resources (suffix ${RUN_SUFFIX}) ---"
  local leftovers=0
  local rg_left sa_left aws_left
  rg_left="$(az group list --query "[?contains(name, '${RUN_SUFFIX}')].name" -o tsv 2>/dev/null || true)"
  sa_left="$(az storage account list --query "[?contains(name, '${RUN_SUFFIX}')].name" -o tsv 2>/dev/null || true)"
  aws_left="$(aws s3api list-buckets --profile "${AWS_PROFILE_VAL}" \
    --query "Buckets[?contains(Name, \`${RUN_SUFFIX}\`)].Name" --output text 2>/dev/null || true)"
  if [[ -n "${rg_left}" ]]; then echo "LEFTOVER resource groups: ${rg_left}"; leftovers=1; fi
  if [[ -n "${sa_left}" ]]; then echo "LEFTOVER storage accounts: ${sa_left}"; leftovers=1; fi
  if [[ -n "${aws_left}" ]]; then echo "LEFTOVER S3 buckets: ${aws_left}"; leftovers=1; fi
  if [[ "${leftovers}" == "1" ]]; then
    echo "ERROR: destroy left resources behind (see above)" >&2
    return 1
  fi
  echo "No leftovers."
}

destroy() {
  echo "--- Destroying fixture (suffix ${RUN_SUFFIX}; resource group deletion is slow, ~10 min) ---"
  terraform -chdir=fixture destroy -auto-approve -input=false "${VAR_FLAGS[@]}"
  check_leftovers
}

# The function apps default-deny inbound (only the AzureEventGrid service tag
# is allowed), so the runner's public IP must be allow-listed for the tests
# that hit the apps directly (L5 admin API, AUTH1 key-auth probe).
detect_runner_ip() {
  local url ip
  for url in https://api.ipify.org https://checkip.amazonaws.com; do
    ip="$(curl -fsS --max-time 10 "${url}" 2>/dev/null | tr -d '[:space:]')" || continue
    if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "${ip}"
      return 0
    fi
  done
  return 1
}
RUNNER_IP="$(detect_runner_ip || true)"
if [[ -z "${RUNNER_IP}" && "${DESTROY_ONLY}" != "1" ]]; then
  echo "ERROR: could not detect this machine's public IP (tried api.ipify.org and" >&2
  echo "       checkip.amazonaws.com). The function apps default-deny inbound traffic," >&2
  echo "       so tests need the runner allow-listed." >&2
  exit 1
fi
[[ -n "${RUNNER_IP}" ]] && echo "Runner public IP: ${RUNNER_IP} (allow-listed on the function apps)"

# The test principal gets blob data-plane access on the run's resource group
TEST_PRINCIPAL="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
VAR_FLAGS=(-var-file="$(pwd)/env.tfvars" -var "run_suffix=${RUN_SUFFIX}" -var "test_principal_object_id=${TEST_PRINCIPAL}" -var "runner_ip_cidr=${RUNNER_IP:+${RUNNER_IP}/32}")

if [[ "${DESTROY_ONLY}" == "1" ]]; then
  destroy
  exit 0
fi

cleanup() {
  local exit_code=$?
  if [[ "${KEEP}" == "1" ]]; then
    echo "--keep-fixture: leaving fixture deployed. Destroy later with:"
    echo "  ./run.sh --destroy-only --run-suffix ${RUN_SUFFIX}"
  else
    destroy || exit_code=1
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

# --- Python environment ---
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -r requirements.txt

# --- Preflight ---
echo "--- Preflight ---"
terraform version -json | python3 -c 'import json,sys; v=json.load(sys.stdin)["terraform_version"]; print(f"terraform {v}")'
az account show >/dev/null 2>&1 || { echo "Azure session invalid: run 'az login'"; exit 1; }
az account set --subscription "${SUBSCRIPTION_VAL}" || { echo "Cannot select subscription ${SUBSCRIPTION_VAL}"; exit 1; }
if [[ -z "${TEST_PRINCIPAL}" ]]; then
  echo "WARNING: could not resolve the signed-in principal (az ad signed-in-user show failed)."
  echo "         Blob data-plane role assignment will be skipped; tests will fail unless"
  echo "         your principal already has Storage Blob Data Contributor."
fi
aws sts get-caller-identity --profile "${AWS_PROFILE_VAL}" >/dev/null || { echo "AWS session invalid: run 'aws sso login --profile ${AWS_PROFILE_VAL}'"; exit 1; }

# First-time subscriptions fail apply cryptically if resource providers are
# unregistered; check up front with a clear fix-it message.
for provider in Microsoft.EventGrid Microsoft.EventHub Microsoft.Web Microsoft.Storage \
                Microsoft.ManagedIdentity Microsoft.OperationalInsights microsoft.insights; do
  state="$(az provider show -n "${provider}" --query registrationState -o tsv 2>/dev/null || echo NotFound)"
  if [[ "${state}" != "Registered" ]]; then
    echo "ERROR: resource provider ${provider} is not registered (state: ${state})." >&2
    echo "Fix:   az provider register -n ${provider} --wait" >&2
    exit 1
  fi
done

# --- Deploy ---
echo "--- terraform apply (this takes ~10-20 min; function app deploys dominate) ---"
terraform -chdir=fixture init -input=false -upgrade=false
terraform -chdir=fixture apply -auto-approve -input=false "${VAR_FLAGS[@]}"

# --- Test ---
echo "--- pytest ---"
# Slow tests (M12 redelivery, DL1 dead-letter, A-REAL diagnostic path) wait
# on platform clocks for many minutes; opt in with --include-slow-tests, or
# run just those three with --only-slow-tests
if [[ "${ONLY_SLOW}" == "1" ]]; then
  MARKER_EXPR="slow"
elif [[ "${INCLUDE_SLOW}" == "1" ]]; then
  MARKER_EXPR=""
else
  MARKER_EXPR="not slow"
fi
# ${arr[@]+...}: safe empty-array expansion under set -u on bash 3.2 (macOS)
pytest -v --tb=short -m "${MARKER_EXPR}" ${PYTEST_ARGS[@]+"${PYTEST_ARGS[@]}"}
