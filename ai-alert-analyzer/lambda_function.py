"""
AI-powered CloudWatch alert analyzer.

Flow: CloudWatch Alarm -> SNS -> this Lambda -> Gemini API -> SNS -> Email

- No third-party packages needed (uses urllib + boto3 from the Lambda runtime).
- Gemini API key is read from SSM Parameter Store (SecureString), never from code.
- If Gemini is unreachable, the raw alert is still delivered (fail-safe).
"""
import json
import os
import urllib.error
import urllib.request

import boto3

ssm = boto3.client("ssm")
sns = boto3.client("sns")

GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
GEMINI_SECRET_PARAM = os.environ["GEMINI_SECRET_PARAM"]
NOTIFY_TOPIC_ARN = os.environ["NOTIFY_TOPIC_ARN"]
PROJECT_NAME = os.environ.get("PROJECT_NAME", "three-tier-app")

_api_key_cache = None


def get_api_key():
    global _api_key_cache
    if _api_key_cache is None:
        resp = ssm.get_parameter(Name=GEMINI_SECRET_PARAM, WithDecryption=True)
        _api_key_cache = resp["Parameter"]["Value"]
    return _api_key_cache


def build_prompt(alarm):
    trigger = alarm.get("Trigger", {})
    return f"""You are a senior AWS SRE helping on-call engineers.
Analyze this CloudWatch alarm from a highly available 3-tier AWS application
(Public ALB -> NGINX web ASG -> Internal ALB -> PHP app ASG -> RDS MySQL Multi-AZ).

Alarm name: {alarm.get('AlarmName')}
Description: {alarm.get('AlarmDescription')}
State: {alarm.get('OldStateValue')} -> {alarm.get('NewStateValue')}
Reason: {alarm.get('NewStateReason')}
Time: {alarm.get('StateChangeTime')}
Metric: {trigger.get('Namespace')} / {trigger.get('MetricName')}
Dimensions: {json.dumps(trigger.get('Dimensions', []))}
Threshold: {trigger.get('ComparisonOperator')} {trigger.get('Threshold')}
(period {trigger.get('Period')}s x {trigger.get('EvaluationPeriods')} evaluation periods)

Reply in plain text (no markdown), under 200 words, using exactly these sections:
SEVERITY: (Low / Medium / High / Critical) with one-line justification
SUMMARY: what happened in simple words
LIKELY CAUSES: 2-3 most probable causes for this tier
NEXT STEPS: 3-4 concrete actions (console checks or AWS CLI commands)
Only use the facts given above. If something is uncertain, say so instead of guessing."""


def call_gemini(prompt):
    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        f"{GEMINI_MODEL}:generateContent"
    )
    body = json.dumps({"contents": [{"parts": [{"text": prompt}]}]}).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json", "x-goog-api-key": get_api_key()},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.loads(resp.read())
    return data["candidates"][0]["content"]["parts"][0]["text"].strip()


def publish(subject, message):
    sns.publish(TopicArn=NOTIFY_TOPIC_ARN, Subject=subject[:100], Message=message)


def lambda_handler(event, context):
    for record in event.get("Records", []):
        alarm = json.loads(record["Sns"]["Message"])
        name = alarm.get("AlarmName", "unknown-alarm")
        state = alarm.get("NewStateValue", "UNKNOWN")

        # Recovery notices don't need AI analysis
        if state == "OK":
            publish(
                f"[{PROJECT_NAME}] RESOLVED: {name}",
                f"Alarm {name} returned to OK at {alarm.get('StateChangeTime')}.\n"
                f"Reason: {alarm.get('NewStateReason')}",
            )
            continue

        raw = (
            f"Alarm: {name}\nState: {state}\n"
            f"Reason: {alarm.get('NewStateReason')}\nTime: {alarm.get('StateChangeTime')}"
        )
        try:
            analysis = call_gemini(build_prompt(alarm))
            message = f"{raw}\n\n--- AI ANALYSIS (Gemini) ---\n{analysis}"
        except (urllib.error.URLError, KeyError, IndexError, TimeoutError, json.JSONDecodeError) as exc:
            print(f"Gemini analysis failed: {exc}")
            message = f"{raw}\n\n(AI analysis unavailable - raw alert only)"

        publish(f"[{PROJECT_NAME}] ALERT: {name}", message)

    return {"status": "ok"}
