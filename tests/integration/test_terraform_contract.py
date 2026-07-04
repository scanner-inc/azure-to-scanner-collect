"""
Terraform contract tests (T1-T2 from the plan). T3 (clean destroy) is
asserted by run.sh after `terraform destroy`.
"""
import json
import subprocess

import boto3
import pytest
import requests

from conftest import ENV_TFVARS, FIXTURE_DIR, az


def test_t1_outputs_consistent_with_reality(tf, blob_service, s3):
    """T1: outputs are non-empty and the resources they name actually exist,
    all inside the one run-suffixed resource group."""
    for key, value in tf.items():
        assert value not in ("", None, []), f"terraform output {key} is empty"

    # S3 buckets exist and are reachable with our credentials
    s3.head_bucket(Bucket=tf["al_s3_bucket"])
    s3.head_bucket(Bucket=tf["mirror_s3_bucket"])
    s3.head_bucket(Bucket=tf["mirror_ex_s3_bucket"])

    # The run's resource group exists and contains the storage accounts
    rg_accounts = json.loads(az([
        "storage", "account", "list", "--resource-group", tf["resource_group"],
        "--query", "[].name", "-o", "json",
    ]).stdout)
    for key in ("al_staging_account", "mirror_source_account", "mirror_ex_source_account",
                "mirror_dlq_account", "mirror_ex_dlq_account"):
        assert tf[key] in rg_accounts, \
            f"{key}={tf[key]} not found in resource group {tf['resource_group']}"

    # Run suffix embeds in created resource names, so everything is
    # attributable to this run
    suffix = tf["run_suffix"]
    for key in ("resource_group", "al_s3_bucket", "mirror_s3_bucket", "al_staging_account",
                "mirror_source_account", "al_function_app", "mirror_function_app"):
        assert suffix in tf[key], f"{key}={tf[key]} does not embed run suffix {suffix}"


def test_t1b_lifecycle_opt_in_applied(tf, s3):
    """Both created buckets were deployed with s3_expiration_days = 7; the
    lifecycle rule must exist and match. (The 'existing' bucket must have
    none - asserted in M9.)"""
    for bucket_key in ("al_s3_bucket", "mirror_s3_bucket"):
        config = s3.get_bucket_lifecycle_configuration(Bucket=tf[bucket_key])
        rules = [r for r in config["Rules"] if r["Status"] == "Enabled"]
        assert any(r.get("Expiration", {}).get("Days") == 7 for r in rules), \
            f"{bucket_key}: expected an enabled 7-day expiration lifecycle rule"


def test_t1c_dead_letter_and_retry_wiring(tf, blob_service):
    """The mirror event subscriptions must have a dead-letter destination and
    a retry policy, the DLQ container must exist, and the dead-letter metric
    alert must exist."""
    for sub_name in tf["mirror_event_subscriptions"]:
        sub = json.loads(az([
            "eventgrid", "system-topic", "event-subscription", "show",
            "--name", sub_name,
            "--system-topic-name", tf["mirror_system_topic"],
            "--resource-group", tf["resource_group"],
            "-o", "json",
        ]).stdout)
        assert sub.get("deadLetterDestination"), f"{sub_name}: no dead-letter destination"
        retry = sub.get("retryPolicy") or {}
        assert retry.get("maxDeliveryAttempts"), f"{sub_name}: no retry policy"
        assert retry.get("eventTimeToLiveInMinutes"), f"{sub_name}: no event TTL"

    # DLQ container exists
    containers = [c.name for c in
                  blob_service(tf["mirror_dlq_account"]).list_containers()]
    assert tf["mirror_dlq_container"] in containers, "DLQ container does not exist"

    # Dead-letter metric alert exists
    alert = json.loads(az([
        "monitor", "metrics", "alert", "show",
        "--name", tf["mirror_alert_name"], "--resource-group", tf["resource_group"],
        "-o", "json",
    ]).stdout)
    assert alert.get("enabled", False), "dead-letter alert exists but is disabled"


def test_t1d_cross_cloud_auth_wiring(tf):
    """The AWS roles' trust policies pin the Entra issuer, the fixed
    audience, and each pipeline's managed identity principal id."""
    iam = boto3.Session(profile_name=tf["aws_profile"],
                        region_name=tf["aws_region"]).client("iam")

    for role_key, principal_key in (
        ("al_aws_role_arn", "al_managed_identity_principal_id"),
        ("mirror_aws_role_arn", "mirror_managed_identity_principal_id"),
    ):
        role_name = tf[role_key].split("/")[-1]
        trust = iam.get_role(RoleName=role_name)["Role"]["AssumeRolePolicyDocument"]
        statement = trust["Statement"][0]
        assert statement["Action"] == "sts:AssumeRoleWithWebIdentity"
        conditions = statement["Condition"]["StringEquals"]
        sub_conditions = {k: v for k, v in conditions.items() if k.endswith(":sub")}
        assert sub_conditions, f"{role_name}: trust policy pins no sub claim"
        assert tf[principal_key] in sub_conditions.values(), \
            f"{role_name}: trust policy sub does not pin the managed identity principal"
        aud_conditions = {k: v for k, v in conditions.items() if k.endswith(":aud")}
        assert aud_conditions, f"{role_name}: trust policy pins no aud claim"
        # Both pipelines share one issuer; the condition keys embed it
        assert any("sts.windows.net" in k for k in conditions), \
            f"{role_name}: trust policy conditions do not reference the Entra issuer"


def test_t1e_function_apps_default_deny_except_eventgrid(tf):
    """T1e: every function app's runtime host default-denies inbound traffic,
    allowing only the AzureEventGrid service tag (delivery) and the test
    runner's IP (harness-only). The SCM site keeps its own credentialed
    access so zip deploys work."""
    for app_key in ("al_function_app", "mirror_function_app", "mirror_ex_function_app"):
        site_config_id = (
            f"/subscriptions/{tf['subscription_id']}"
            f"/resourceGroups/{tf['resource_group']}"
            f"/providers/Microsoft.Web/sites/{tf[app_key]}/config/web"
        )
        props = json.loads(az([
            "resource", "show", "--ids", site_config_id, "-o", "json",
        ]).stdout)["properties"]

        assert props.get("ipSecurityRestrictionsDefaultAction") == "Deny", \
            f"{tf[app_key]}: main site inbound is not default-deny"

        rules = props.get("ipSecurityRestrictions") or []
        eventgrid_rules = [r for r in rules
                           if r.get("tag") == "ServiceTag"
                           and r.get("ipAddress") == "AzureEventGrid"
                           and r.get("action") == "Allow"]
        assert eventgrid_rules, f"{tf[app_key]}: no Allow rule for the AzureEventGrid service tag"

        runner_rules = [r for r in rules
                        if r.get("ipAddress") == tf["runner_ip_cidr"]
                        and r.get("action") == "Allow"]
        assert runner_rules, f"{tf[app_key]}: test runner {tf['runner_ip_cidr']} is not allow-listed"

        # SCM must NOT inherit the deny (zip deploys go through it)
        assert props.get("scmIpSecurityRestrictionsDefaultAction") != "Deny", \
            f"{tf[app_key]}: SCM site is default-deny; zip deploys would break"


def test_auth1_eventgrid_endpoint_rejects_unauthenticated(tf):
    """AUTH1: the Event Grid delivery endpoint requires the per-function
    system key independently of the network layer. The runner is
    allow-listed (so this request passes the IP restrictions), yet a POST
    without a key must be rejected by the Functions host."""
    for app_key, function_name in (
        ("al_function_app", "transfer_staging_blob"),
        ("mirror_function_app", "mirror_blob"),
    ):
        url = (f"https://{tf[app_key]}.azurewebsites.net"
               f"/runtime/webhooks/eventgrid?functionName={function_name}")
        resp = requests.post(url, json=[{"eventType": "probe", "data": {}}],
                             timeout=120)  # generous: may wake a cold app
        assert resp.status_code in (401, 403), (
            f"{tf[app_key]}: unauthenticated POST to the Event Grid endpoint "
            f"returned HTTP {resp.status_code} (expected 401/403): {resp.text[:300]}"
        )


def test_t2_plan_is_idempotent(tf):
    """T2: a plan right after apply shows no drift (exit code 0)."""
    # Must match the variables run.sh applied with, including the test
    # principal (else the plan proposes removing its role assignment)
    principal = az(["ad", "signed-in-user", "show", "--query", "id", "-o", "tsv"],
                   check=False).stdout.strip()
    result = subprocess.run(
        [
            "terraform", f"-chdir={FIXTURE_DIR}", "plan",
            "-detailed-exitcode", "-input=false", "-lock=false",
            f"-var-file={ENV_TFVARS}", f"-var=run_suffix={tf['run_suffix']}",
            f"-var=test_principal_object_id={principal}",
            f"-var=runner_ip_cidr={tf['runner_ip_cidr']}",
        ],
        capture_output=True, text=True,
    )
    if result.returncode == 2:
        pytest.fail(f"plan is not idempotent - drift detected:\n{result.stdout[-20000:]}")
    assert result.returncode == 0, f"terraform plan errored:\n{result.stderr[-4000:]}"
