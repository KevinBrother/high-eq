#!/usr/bin/env python3
"""T33 static contract checks for the correction archive.

These tests intentionally use only local files. They separate fixed-baseline
facts from candidate evidence and keep unverified product goals marked as such.
"""

from __future__ import annotations

import copy
import re
import subprocess
import unittest
from collections.abc import Mapping
from pathlib import Path

try:  # Supports both `python -m unittest` and direct script execution.
    from .t33_contract_support import (
        WorkflowJob,
        android_permission_callback_errors,
        command_execution_issues,
        ios_runner_source_files,
        load_historical_evidence,
        practice_consent_contract_errors,
        parse_workflow_jobs,
        uses_ignored_build_path,
        workflow_event_names,
        workflow_has_path_filters,
        workflow_path_is_triggered,
        workflow_trigger_paths,
    )
except ImportError:  # pragma: no cover - exercised by the documented CLI form.
    from t33_contract_support import (  # type: ignore[no-redef]
        WorkflowJob,
        android_permission_callback_errors,
        command_execution_issues,
        ios_runner_source_files,
        load_historical_evidence,
        practice_consent_contract_errors,
        parse_workflow_jobs,
        uses_ignored_build_path,
        workflow_event_names,
        workflow_has_path_filters,
        workflow_path_is_triggered,
        workflow_trigger_paths,
    )

ROOT = Path(__file__).resolve().parents[2]
COMPLIANCE = ROOT / "docs" / "compliance"
BASELINE = "f60ace3"
CANDIDATE = "ce479034bcba174475fa8fbc156be66a3b22ba5371b5344602f29394185d638a"
OLD_BASELINE = "bd6e34e0ce8f3b96da61f7eea2e391a40cdcf70c"

PRACTICE_LOBBY_CONTRACT_FIXTURE = """
class PracticeLobby {
  Future<bool> ensurePracticeConsent({bool Function()? stillCurrent}) async {
    final granted = await widget.repo.practiceConsent();
    if (granted) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(),
    );
    if (ok != true) return false;
    await widget.repo.grantPracticeConsent();
    final confirmed = await widget.repo.practiceConsent();
    if (!confirmed) {
      throw const ApiFailure(403, 'forbidden', '练习授权未生效，请重试。', true);
    }
    return true;
  }

  Future<void> create(Json intent, {required bool Function() stillCurrent}) async {
    final isCurrent = stillCurrent;
    if (!await ensurePracticeConsent(stillCurrent: isCurrent)) return;
    final body = intent['input'] as Json;
    final s = await repo.create(body);
  }

  Future<void> start(Json input, {required bool Function() stillCurrent}) async {
    await create({'input': input}, stillCurrent: stillCurrent);
  }

  Future<void> open(Json input, {required bool Function() stillCurrent}) async {
    await start(input, stillCurrent: stillCurrent);
  }

  Future<void> _resumePending(Json intent, bool Function() isCurrent) async {
    await create(intent, stillCurrent: isCurrent);
  }

  Future<void> _openTargetLevel(Json target, bool Function() isCurrent) async {
    await start(target, stillCurrent: isCurrent);
  }
}
"""


def read(path: str | Path) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def insert_workflow_path(workflow: str, event: str, anchor: str, path: str) -> str:
    """Insert one path rule inside a named trigger without touching the other event."""
    lines = workflow.splitlines(keepends=True)
    start = lines.index(f"  {event}:\n")
    end = next(
        (
            index
            for index in range(start + 1, len(lines))
            if re.match(r"^  [A-Za-z_][A-Za-z0-9_-]*:\s*$", lines[index])
        ),
        len(lines),
    )
    rule = f"      - '{path}'\n"
    insert_at = lines.index(anchor, start, end) + 1
    lines.insert(insert_at, rule)
    return "".join(lines)


def git_show(path: str) -> str:
    return subprocess.run(
        ["git", "show", f"{BASELINE}:{path}"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def compliance_corpus() -> str:
    return "\n".join(
        p.read_text(encoding="utf-8") for p in sorted(COMPLIANCE.glob("*.md"))
    )


VOICE_REQUIRED_BEHAVIORS = {
    "app/test/voice/features_test.dart": (
        "transcription is explicitly unavailable and never cloud-backed",
        "window wire body is a strict statistics whitelist",
    ),
    "app/test/voice/aggregator_test.dart": (
        "aligns capture to UTC 30 second windows and carries overflow",
        "drops leading fragments and starts at the next UTC boundary",
        "drops an incomplete window instead of uploading a false 30 seconds",
    ),
    "app/test/voice/controller_test.dart": (
        "cancelling the final gate never starts native capture",
        "disposing during native start stops the late recorder",
        "only a strict 30-second statistics object reaches the uploader",
        "revoke persists the gate before stop and local purge",
        "failed revoke stays fail-closed and purges stale data on restart",
        "membership expiry immediately stops and clears pending windows",
        "revocation before upload never marks or sends the queued window",
    ),
    "app/test/voice/page_test.dart": (
        "voice route waits on the shared consent provider and fails closed",
        "capture banner stays visible and lifecycle pause stops capture",
        "lifecycle pause cancels a start still awaiting consent",
        "revocation from page leaves an empty queue and no upload path",
    ),
    "app/test/voice/platform_test.dart": (
        "parses PCM together with its UTC sample capture time",
        "rejects a PCM event without a native capture timestamp",
    ),
    "app/test/voice/store_test.dart": (
        "queue is encrypted and clears before revoke sync",
        "switching accounts invalidates the old scope and hides all data",
        "recordings expire after three days and are not readable",
    ),
}

VOICE_CI_REQUIRED = (
    "pull_request:",
    "runs-on: ubuntu-24.04",
    "fetch-depth: 0",
    "subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2",
    "flutter-version: '3.38.10'",
    "cache: false",
    "python3 -B -m unittest discover -s docs/compliance",
    "working-directory: app",
    "flutter pub get --enforce-lockfile",
    "flutter test --no-pub test/voice",
)

T29_LIVE_LOG = "build/t29/live-published.ToeY3h/t30-live.log"
T29_LIVE_RUN_TREE = "33149cab1d768881c2b6d9b24c62e294fafa0811"
T29_LIVE_FROZEN_TREE = "2825621d921f40b44248f9c1a7ef79c24b5a91de"
T29_HISTORICAL_EVIDENCE = "docs/compliance/t29-historical-evidence.json"

T29_WIRE_STEPS_REQUIRED = (
    "fetch-depth: 0",
    "bash app/tool/t29/live.sh",
)

VERIFY_REQUIRED_COMMANDS = (
    ("python3 -B -m unittest discover -s docs/compliance", ""),
    ("flutter pub get --enforce-lockfile", "app"),
    ("flutter test --no-pub test/voice", "app"),
)

T29_WIRE_REQUIRED_COMMANDS = (
    ("flutter pub get --enforce-lockfile", "app"),
    (
        "dart format --output=none --set-exit-if-changed "
        "lib/features/voice test/voice tool/t29",
        "app",
    ),
    ("dart analyze lib/features/voice tool/t29", "app"),
    (
        "./tool/t29/with_sentinel_proxy.sh flutter --no-version-check "
        "--suppress-analytics test --no-pub -r expanded "
        "tool/t29/proxy_isolation_test.dart",
        "app",
    ),
    ("bash app/tool/t29/live.sh", ""),
)

T29_WIRE_TRIGGER_PATHS = (
    "app/pubspec.yaml",
    "app/pubspec.lock",
    "app/lib/main.dart",
    "app/lib/core/api.dart",
    "app/lib/core/consent.dart",
    "app/lib/core/sse.dart",
    "app/lib/features/voice/**",
    "app/test/voice/**",
    "app/tool/t29/**",
    "app/android/app/src/main/AndroidManifest.xml",
    "app/android/app/src/main/kotlin/cn/higheq/high_eq/MainActivity.kt",
    "app/android/app/src/main/kotlin/cn/higheq/high_eq/VoiceCapture.kt",
    "app/ios/Runner/AppDelegate.swift",
    "app/ios/Runner/Info.plist",
    "app/ios/Runner/VoiceCapture.swift",
    "app/ios/Runner/VoicePCMConverter.swift",
    "app/ios/Runner/VoicePCMCaptureSession.swift",
    "app/ios/Runner.xcodeproj/project.pbxproj",
    "server/Dockerfile",
    "server/go.mod",
    "server/go.sum",
    "server/cmd/api/main.go",
    "server/internal/api/app/routes.gen.go",
    "server/internal/fieldcrypt/cipher.go",
    "server/internal/membership/collection.go",
    "server/internal/service/entitlements_http.go",
    "docker-compose.yml",
    ".github/workflows/t29-t30-wire.yml",
)

T29_WIRE_FORBIDDEN_TRIGGER_PATHS = (
    "docs/compliance/README.md",
    "docs/api/events.md",
    "docs/tasks/T29.md",
    "docs/tasks/T33.md",
    ".github/workflows/verify.yml",
)

HISTORICAL_SCOPE_OVERCLAIM_PATTERNS = (
    re.compile(
        r"(?:旧日志|历史日志|历史证据|历史记录)(?:已)?"
        r"(?:证明|显示|确认|表明|意味着).{0,40}当前.{0,40}"
        r"(?:CI|Actions|流水线|生产|线上).{0,40}(?:通过|成功|已核验|已验证)"
    ),
    re.compile(
        r"(?:旧日志|历史日志|历史证据|历史记录)(?:已)?"
        r"(?:证明|显示|确认|表明|意味着).{0,60}"
        r"(?:CI|Actions|流水线|生产|线上)(?:已经|均已|已)?"
        r"(?:通过|成功|核验|验证)"
    ),
)

T29_WIRE_DUPLICATE_COMMANDS = (
    (
        "python3 -B -m unittest discover -s docs/compliance",
        "T29 wire workflow must not duplicate Verify's compliance job",
    ),
    (
        "flutter test --no-pub test/voice",
        "T29 wire workflow must not duplicate Verify's voice unit-test job",
    ),
)


def voice_static_and_behavior_errors(
    *,
    manifest: str,
    plist: str,
    ios_project: str,
    android_entry: str,
    ios_entry: str,
    native_sources: Mapping[str, str],
    behavior_sources: Mapping[str, str],
) -> list[str]:
    errors: list[str] = []
    if 'android:name="android.permission.RECORD_AUDIO"' not in manifest:
        errors.append("Android Manifest is missing RECORD_AUDIO")
    if "NSMicrophoneUsageDescription" not in plist:
        errors.append("iOS Info.plist is missing NSMicrophoneUsageDescription")

    for needle in ("VoiceCapture(this)", "voiceCapture.install"):
        if needle not in android_entry:
            errors.append(f"Android entry is missing {needle}")
    for needle in ("VoiceCapture()", "voiceCapture.install"):
        if needle not in ios_entry:
            errors.append(f"iOS entry is missing {needle}")

    ios_source_root = ROOT / "app" / "ios"
    runner_sources = ios_runner_source_files(ios_project)
    for source_path in (
        "Runner/VoiceCapture.swift",
        "Runner/VoicePCMConverter.swift",
        "Runner/VoicePCMCaptureSession.swift",
    ):
        if (
            source_path not in runner_sources
            or not (ios_source_root / source_path).is_file()
        ):
            errors.append(
                f"iOS Xcode Sources is missing {source_path.rsplit('/', 1)[-1]}"
            )

    errors.extend(android_permission_callback_errors(android_entry, native_sources))

    for path, source in native_sources.items():
        for forbidden in ("URLSession", "SpeechRecognizer", "SFSpeech"):
            if forbidden in source:
                errors.append(f"{path} contains forbidden native path {forbidden}")

    for path, tests in VOICE_REQUIRED_BEHAVIORS.items():
        source = behavior_sources.get(path)
        if source is None:
            errors.append(f"missing voice behavior source {path}")
            continue
        for test_name in tests:
            if test_name not in source:
                errors.append(f"{path} is missing behavior gate {test_name!r}")
    return errors


def required_command_errors(
    job: WorkflowJob,
    command: str,
    *,
    workflow_name: str,
    missing_message: str,
    working_directory: str = "",
) -> list[str]:
    """Require one executable command to participate in step failure propagation."""
    matching = [step for step in job.steps if step.run_has(command)]
    if not matching:
        return [missing_message]

    errors: list[str] = []
    if any(step.if_condition for step in matching):
        errors.append(f"{workflow_name} step {command!r} must not be conditional")
    if any(
        step.continue_on_error.strip().lower() not in ("", "false")
        for step in matching
    ):
        errors.append(f"{workflow_name} step {command!r} must not allow failure")
    if working_directory and not any(
        step.working_directory == working_directory for step in matching
    ):
        errors.append(
            f"{workflow_name} step {command!r} must run in "
            f"working-directory: {working_directory}"
        )

    issues = {
        issue
        for step in matching
        for issue in command_execution_issues(step.run, command)
    }
    if "conditional" in issues:
        errors.append(
            f"{workflow_name} command {command!r} must run as an unconditional "
            "top-level command"
        )
    if "early-exit" in issues:
        errors.append(
            f"{workflow_name} command {command!r} must not be preceded by a shell "
            "early exit"
        )
    if "failure-swallowed" in issues:
        errors.append(
            f"{workflow_name} command {command!r} must propagate shell failure"
        )
    return errors


def required_command_order_errors(
    job: WorkflowJob,
    commands: tuple[tuple[str, str], ...],
    *,
    workflow_name: str,
) -> list[str]:
    positions: list[int] = []
    for command, _ in commands:
        position = next(
            (index for index, step in enumerate(job.steps) if step.run_has(command)),
            None,
        )
        if position is not None:
            positions.append(position)
    if positions == sorted(positions):
        return []
    return [f"{workflow_name} required commands must execute in order"]


def voice_ci_errors(workflow: str) -> list[str]:
    errors: list[str] = []
    events = workflow_event_names(workflow)
    if not {"push", "pull_request"}.issubset(events):
        errors.append(
            "hosted Verify workflow must trigger on both push and pull_request"
        )
    for event in ("push", "pull_request"):
        if workflow_has_path_filters(workflow, event):
            errors.append(
                f"hosted Verify workflow {event} must not use path filters"
            )

    jobs = parse_workflow_jobs(workflow)
    job = jobs.get("compliance")
    if job is None:
        return ["hosted Verify workflow is missing the compliance job"]

    if job.runs_on != "ubuntu-24.04":
        errors.append("hosted Verify workflow is missing 'runs-on: ubuntu-24.04'")
    if any("self-hosted" in item.runs_on.lower() for item in jobs.values()):
        errors.append("hosted Verify workflow must not use a self-hosted runner")
    if job.if_condition:
        errors.append("hosted Verify compliance job must not be conditional")
    if job.continue_on_error.strip().lower() not in ("", "false"):
        errors.append("hosted Verify compliance job must not allow failure")

    checkout = next(
        (step for step in job.steps if step.uses.startswith("actions/checkout@")), None
    )
    if checkout is None:
        errors.append("hosted Verify workflow is missing actions/checkout")
    else:
        checkout_with = checkout.with_values or {}
        if checkout_with.get("fetch-depth") != "0":
            errors.append("hosted Verify checkout is missing fetch-depth: 0")
        if checkout_with.get("persist-credentials") != "false":
            errors.append("hosted Verify checkout must not persist credentials")

    flutter_action = next(
        (step for step in job.steps if step.uses.startswith("subosito/flutter-action@")),
        None,
    )
    if flutter_action is None:
        errors.append("hosted Verify workflow is missing subosito/flutter-action")
    else:
        action_with = flutter_action.with_values or {}
        if action_with.get("flutter-version") != "3.38.10":
            errors.append("hosted Verify workflow is missing Flutter 3.38.10")
        if action_with.get("cache") != "false":
            errors.append("hosted Verify Flutter action must disable cache")

    for command, working_directory in VERIFY_REQUIRED_COMMANDS:
        errors.extend(
            required_command_errors(
                job,
                command,
                workflow_name="hosted Verify workflow",
                missing_message=(
                    f"hosted Verify workflow is missing executable {command!r}"
                ),
                working_directory=working_directory,
            )
        )
    errors.extend(
        required_command_order_errors(
            job,
            VERIFY_REQUIRED_COMMANDS,
            workflow_name="hosted Verify workflow",
        )
    )

    if any(
        _run_uses_ignored_build(step.run)
        or uses_ignored_build_path(step.working_directory)
        for step in job.steps
    ):
        errors.append("hosted Verify workflow must not consume ignored build/ evidence")
    return errors


def _run_uses_ignored_build(run: str) -> bool:
    return uses_ignored_build_path(run)


def t29_wire_workflow_errors(workflow: str) -> list[str]:
    errors: list[str] = []
    events = workflow_event_names(workflow)
    if not {"push", "pull_request"}.issubset(events):
        errors.append(
            "T29 wire workflow must trigger on both push and pull_request"
        )

    jobs = parse_workflow_jobs(workflow)
    job = jobs.get("voice-wire")
    if job is None:
        return ["T29 wire workflow is missing the voice-wire job"]

    if job.runs_on != "ubuntu-24.04":
        errors.append("T29 wire workflow must use a GitHub-hosted runner")
    if any("self-hosted" in item.runs_on.lower() for item in jobs.values()):
        errors.append("T29 wire workflow must use a GitHub-hosted runner")
    if job.if_condition:
        errors.append("T29 wire workflow voice-wire job must not be conditional")
    if job.continue_on_error.strip().lower() not in ("", "false"):
        errors.append("T29 wire workflow voice-wire job must not allow failure")

    if any(_run_uses_ignored_build(step.run) for step in job.steps):
        errors.append("T29 wire workflow must not consume ignored build/ evidence")

    checkout = next(
        (step for step in job.steps if step.uses.startswith("actions/checkout@")), None
    )
    if checkout is None:
        errors.append("T29 wire workflow is missing actions/checkout")
    else:
        checkout_with = checkout.with_values or {}
        if checkout_with.get("fetch-depth") != "0":
            errors.append("T29 wire workflow is missing 'fetch-depth: 0'")
        if checkout_with.get("persist-credentials") != "false":
            errors.append("T29 wire workflow must not persist checkout credentials")

    for command, working_directory in T29_WIRE_REQUIRED_COMMANDS:
        errors.extend(
            required_command_errors(
                job,
                command,
                workflow_name="T29 wire workflow",
                missing_message=f"T29 wire workflow is missing {command!r}",
                working_directory=working_directory,
            )
        )
    errors.extend(
        required_command_order_errors(
            job,
            T29_WIRE_REQUIRED_COMMANDS,
            workflow_name="T29 wire workflow",
        )
    )

    for command, duplicate_error in T29_WIRE_DUPLICATE_COMMANDS:
        if any(step.run_has(command) for step in job.steps):
            errors.append(duplicate_error)

    for event in ("push", "pull_request"):
        if not workflow_trigger_paths(workflow, event):
            errors.append(f"T29 wire workflow has no {event} path filter")
            continue
        for path in T29_WIRE_TRIGGER_PATHS:
            if not workflow_path_is_triggered(workflow, event, path):
                errors.append(
                    f"T29 wire workflow {event} paths do not trigger {path!r}"
                )
        for path in T29_WIRE_FORBIDDEN_TRIGGER_PATHS:
            if workflow_path_is_triggered(workflow, event, path):
                errors.append(
                    f"T29 wire workflow {event} must not trigger documentation-only "
                    f"input {path!r}"
                )
    return errors


def t29_live_evidence_errors(
    *,
    t29: str,
    t33: str,
    evidence: Mapping[str, object] | None = None,
) -> list[str]:
    """Validate the historical record structurally, not through prose patterns."""
    errors: list[str] = []
    for name, text in (("T29", t29), ("T33", t33)):
        if "../real-grant.log" in text:
            errors.append(f"{name} references the retired real-grant log")
        if T29_HISTORICAL_EVIDENCE not in text:
            errors.append(f"{name} must reference {T29_HISTORICAL_EVIDENCE}")

    record = evidence if evidence is not None else load_historical_evidence(
        ROOT / T29_HISTORICAL_EVIDENCE
    )
    if record is None:
        errors.append("structured T29 historical evidence record is missing or invalid")
        return errors

    expected_fields = (
        (("schema_version",), 1),
        (("kind",), "recorded-host-execution"),
        (("artifact", "path"), T29_LIVE_LOG),
        (("artifact", "in_archive"), False),
        (("versions", "run_tree"), T29_LIVE_RUN_TREE),
        (("versions", "frozen_tree"), T29_LIVE_FROZEN_TREE),
        (("versions", "components_match"), True),
        (("versions", "workflow_path"), ".github/workflows/t29-t30-wire.yml"),
        (("versions", "workflow_status"), "different"),
        (("execution", "environment"), "host-isolated-compose"),
        (("execution", "host_status"), "passed"),
        (("execution", "ci_status"), "unverified"),
        (("input", "pcm"), "synthetic"),
        (("scope", "current_tree"), False),
        (("scope", "real_device"), False),
        (("scope", "production"), False),
    )
    for path, expected in expected_fields:
        actual: object = record
        for key in path:
            actual = actual.get(key) if isinstance(actual, Mapping) else None
        if actual != expected:
            errors.append(
                "structured T29 historical evidence field "
                f"{'.'.join(path)} must be {expected!r}"
            )

    for name, text in (("T29", t29), ("T33", t33)):
        for line in text.splitlines():
            if any(
                pattern.search(line) for pattern in HISTORICAL_SCOPE_OVERCLAIM_PATTERNS
            ):
                errors.append(
                    f"{name} historical evidence must not extend the recorded scope "
                    "to a current CI or production pass"
                )

    if "CI 未核验" not in t33:
        errors.append(
            "T33 historical evidence must retain the recorded CI-unverified scope"
        )

    expected_components = ["app/", "server/", "docker-compose.yml"]
    versions = record.get("versions")
    components = versions.get("unchanged_components") if isinstance(versions, Mapping) else None
    if components != expected_components:
        errors.append(
            "structured T29 historical evidence field "
            "versions.unchanged_components must be ['app/', 'server/', "
            "'docker-compose.yml']"
        )

    history_rows = [
        line
        for line in t29.splitlines()
        if "历史证据" in line and T29_LIVE_LOG in line
    ]
    if len(history_rows) != 1:
        errors.append("T29 must bind the archived run to an explicit historical-evidence row")
    return errors


class BaselineAndScopeContract(unittest.TestCase):
    def test_fixed_baseline_and_candidate_evidence_are_separate(self) -> None:
        docs = [ROOT / "docs/tasks/T33.md", *sorted(COMPLIANCE.glob("*.md"))]
        for path in docs:
            text = path.read_text(encoding="utf-8")
            self.assertIn(BASELINE, text, f"{path}: missing fixed baseline")
            self.assertNotIn(OLD_BASELINE, text, f"{path}: stale baseline remains")

        t33 = read("docs/tasks/T33.md")
        self.assertIn(CANDIDATE, t33)
        self.assertRegex(t33, r"候选(?:实现|证据).*ce479034bcba")
        self.assertNotIn("11 个文件", t33)
        self.assertRegex(t33, r"主会话.*(?:提取|生成).*补丁")
        self.assertRegex(t33, r"本轮.*不.*(?:生成|创建).*补丁")

    def test_t33_does_not_freeze_static_contract_count(self) -> None:
        t33 = read("docs/tasks/T33.md")
        self.assertNotIn("29 项", t33)
        self.assertNotRegex(t33, r"当前 T33 已扩展为 \d+ 项")
        self.assertIn("实际总数以命令输出为准", t33)
        self.assertIn("不在交接中重复抄写", t33)

    def test_cross_card_changes_are_appended_not_denied(self) -> None:
        t33 = read("docs/tasks/T33.md")
        changes = read("docs/CHANGES.md")
        self.assertRegex(t33, r"CHANGES\.md.*(?:仅)?追加")
        self.assertRegex(changes, r"T33")
        for needle in ("/v1/me/export", "/v1/me/data", "1 天", "健康权限"):
            self.assertIn(needle, changes)


class BaselineSourceFactsContract(unittest.TestCase):
    def test_android_and_ios_permissions_are_not_inflated(self) -> None:
        baseline_manifest = git_show("app/android/app/src/main/AndroidManifest.xml")
        baseline_permissions = re.findall(
            r'android:name="android\.permission\.([^"]+)"', baseline_manifest
        )
        self.assertEqual(baseline_permissions, ["INTERNET"])

        baseline_plist = git_show("app/ios/Runner/Info.plist")
        baseline_entitlements = git_show("app/ios/Runner/Runner.entitlements")
        self.assertNotIn("NSHealthShareUsageDescription", baseline_plist)
        self.assertNotIn("NSMicrophoneUsageDescription", baseline_plist)
        self.assertNotIn("com.apple.developer.healthkit", baseline_entitlements)

        manifest = read("app/android/app/src/main/AndroidManifest.xml")
        current_permissions = re.findall(
            r'android:name="android\.permission\.([^"]+)"', manifest
        )
        for required in (
            "INTERNET",
            "RECORD_AUDIO",
            "ACTIVITY_RECOGNITION",
            "health.READ_HEART_RATE",
            "health.READ_HEART_RATE_VARIABILITY",
            "health.READ_STEPS",
            "health.READ_EXERCISE",
        ):
            self.assertIn(required, current_permissions)
        for forbidden in (
            "health.WRITE_HEART_RATE",
            "health.WRITE_STEPS",
            "health.WRITE_EXERCISE",
        ):
            self.assertNotIn(forbidden, current_permissions)

        plist = read("app/ios/Runner/Info.plist")
        entitlements = read("app/ios/Runner/Runner.entitlements")
        self.assertIn("NSHealthShareUsageDescription", plist)
        self.assertIn("NSMicrophoneUsageDescription", plist)
        self.assertNotIn("NSHealthUpdateUsageDescription", plist)
        self.assertIn("<key>com.apple.developer.healthkit</key><true/>", entitlements)

        corpus = compliance_corpus()
        self.assertRegex(
            corpus,
            r"固定基线[^\n]*Manifest[^\n]*仅[^\n]*INTERNET",
        )
        self.assertRegex(
            corpus,
            r"当前 T28 归档[^\n]*(?:ACTIVITY_RECOGNITION|Health Connect)",
        )
        self.assertRegex(
            corpus,
            r"iOS[^\n]*(?:NSMicrophoneUsageDescription|麦克风用途说明)",
        )
        self.assertRegex(
            corpus,
            r"当前 T28 归档[^\n]*(?:NSHealthShareUsageDescription|HealthKit)",
        )

    def test_incremental_modules_are_not_counted_as_baseline(self) -> None:
        profile_files = {
            path.name for path in (ROOT / "server/internal/profile").glob("*.go")
        }
        for name in ("contacts.go", "feedback.go", "infer.go", "inference_request.go"):
            self.assertIn(name, profile_files, "T25 profile implementation is present")

        reply_requests = read("server/migrations/20261123000021_reply_requests.up.sql")
        reply_keys = read("server/migrations/20261123000022_reply_request_keys.up.sql")
        receipts = read("server/migrations/20261123000023_reply_outcome_receipts.up.sql")
        migrations = "\n".join((reply_requests, reply_keys, receipts))
        for table in (
            "reply_requests",
            "reply_feedback",
            "reply_request_keys",
            "reply_outcome_receipts",
        ):
            self.assertIn(f"CREATE TABLE {table}", migrations)
        self.assertIn("chat_consent_id uuid NOT NULL REFERENCES consents", reply_requests)
        self.assertIn("contacts_consent_id uuid REFERENCES consents", reply_requests)
        self.assertIn("binding.chat", read("server/internal/replies/consent.go"))
        self.assertIn("QA-33 | T21", read("docs/compliance/qa.md"))
        inventory_rows = read("docs/compliance/data-inventory.md").splitlines()
        request_row = next(line for line in inventory_rows if line.startswith("| D11 |"))
        self.assertIn("不重查原用途授权、不重读画像、不外发、不再次扣次", request_row)
        self.assertIn("每条新反馈", next(line for line in inventory_rows if line.startswith("| D12 |")))
        self.assertIn("CREATE TRIGGER reply_import_guard", reply_requests)
        self.assertIn("BEFORE INSERT OR UPDATE ON chat_imports", reply_requests)
        self.assertIn(
            "DELETE FROM chat_imports c USING activities a WHERE a.id=c.activity_id AND a.kind='reply'",
            reply_requests,
        )
        self.assertEqual(reply_requests.count("CHECK(octet_length(input_mac)=32)"), 2)
        self.assertIn("outcome_enc bytea NOT NULL", reply_requests)
        self.assertIn(
            "activity_id uuid UNIQUE REFERENCES activities ON DELETE SET NULL",
            reply_keys,
        )

        request_sql = re.search(
            r"CREATE TABLE reply_requests \((.*?)\n\);", reply_requests, re.S
        )
        feedback_sql = re.search(
            r"CREATE TABLE reply_feedback \((.*?)\n\);", reply_requests, re.S
        )
        receipt_sql = re.search(
            r"CREATE TABLE reply_outcome_receipts \((.*?)\n\);", receipts, re.S
        )
        self.assertIsNotNone(request_sql)
        self.assertIsNotNone(feedback_sql)
        self.assertIsNotNone(receipt_sql)
        for body in (request_sql.group(1), feedback_sql.group(1)):
            self.assertNotRegex(body, r"chat_text|goal|destination|input_text")
        for forbidden in (
            "outcome_enc",
            "chat_text",
            "goal",
            "destination",
            "suggestion_text",
            "effect_text",
        ):
            self.assertNotIn(forbidden, receipt_sql.group(1))

        service = read("server/internal/replies/service.go")
        feedback = read("server/internal/replies/feedback.go")
        reply_privacy = read("server/internal/replies/privacy.go")
        profile_outcome = read("server/internal/profile/outcome.go")
        http = read("server/internal/service/http.go")
        self.assertIn('"POST /v1/replies": false', http)
        self.assertIn('"POST /v1/replies/:id/feedback": false', http)
        self.assertIn('in.ChatText, in.Goal, summary', service)
        self.assertIn('s.cipher.Seal(b, aad(p.User, fid, "outcome"))', feedback)
        self.assertIn('s.cipher.Open(encrypted, aad(v.UserID, v.FeedbackID, "outcome"))', feedback)
        self.assertIn("insert into reply_outcome_receipts", profile_outcome)
        self.assertIn("does not create a profile observation", profile_outcome)
        self.assertNotIn("reply_outcome_receipts", reply_privacy)

        self_reports = feedback.split('select a.source_id,a.contact_id,f.occurred_at,f.outcome_enc', 1)
        self.assertEqual(len(self_reports), 2)
        self.assertIn("f.pending and f.self_report", self_reports[1])
        self.assertIn("s.recorder.RecordActivity", self_reports[1])
        outcome_delivery = feedback.split("func (s *Service) deliverOutcome", 1)[1]
        self.assertNotIn("RecordActivity", outcome_delivery)

        inventory = read("docs/compliance/data-inventory.md")
        for needle in (
            "T21 后端增量",
            "reply_request_keys",
            "reply_outcome_receipts",
            "服务端不持久化源文本与目的",
            "ON DELETE SET NULL",
            "32 字节带密钥 HMAC",
            "普通效果不写本人画像",
            "只有显式 `self_report`",
            "不计入 `f60ace3` 的 42 项",
        ):
            self.assertIn(needle, inventory)

        corpus = compliance_corpus()
        self.assertNotRegex(corpus, r"reply_requests[^\n]*(?:候选|待对表|不存在)")
        self.assertNotIn("T21 服务端仍未合入", corpus)
        self.assertIn("T25 后端增量", corpus)
        self.assertIn("回复类导入触发器", corpus)
        self.assertRegex(corpus, r"回复.*触发器.*禁止.*chat_imports")
        self.assertIn("notice.v1` 不能代替服务端同意", read("docs/compliance/separate-consents.md"))

    def test_practice_consent_precedes_creation_and_rechecks_after_grant(self) -> None:
        published_lobby = read("app/lib/features/practice/lobby.dart")
        self.assertEqual(practice_consent_contract_errors(published_lobby), [])

        lobby = PRACTICE_LOBBY_CONTRACT_FIXTURE
        self.assertEqual(practice_consent_contract_errors(lobby), [])

        create_guard = (
            "    if (!await ensurePracticeConsent(stillCurrent: isCurrent)) return;\n"
        )
        create_request = "    final s = await repo.create(body);\n"
        altered = lobby.replace(create_guard, "", 1)
        altered = altered.replace(
            create_request, create_request + create_guard, 1
        )
        self.assertNotEqual(altered, lobby)
        self.assertIn(
            "practice create must follow the consent gate",
            practice_consent_contract_errors(altered),
        )

        reread = (
            "    final confirmed = await widget.repo.practiceConsent();\n"
        )
        altered = lobby.replace(reread, "    final confirmed = granted;\n", 1)
        self.assertNotEqual(altered, lobby)
        self.assertIn(
            "practice consent re-read must occur exactly once",
            practice_consent_contract_errors(altered),
        )

        cases = (
            (
                "create gate",
                create_guard,
                "    // if (!await ensurePracticeConsent(stillCurrent: isCurrent)) return;\n",
                "practice consent gate must occur exactly once",
            ),
            (
                "declined grant guard",
                "    if (ok != true) return false;\n",
                "    // if (ok != true) return false;\n",
                "declined practice consent guard must occur exactly once",
            ),
            (
                "false re-read rejection",
                "    if (!confirmed) {\n"
                "      throw const ApiFailure(403, 'forbidden', '练习授权未生效，请重试。', true);\n"
                "    }\n",
                "    /* if (!confirmed) {\n"
                "      throw const ApiFailure(403, 'forbidden', '练习授权未生效，请重试。', true);\n"
                "    } */\n",
                "practice consent confirmation must occur exactly once",
            ),
        )
        for name, executable, commented, expected in cases:
            with self.subTest(name=name):
                self.assertIn(executable, lobby)
                altered = lobby.replace(executable, commented, 1)
                self.assertNotEqual(altered, lobby)
                self.assertIn(expected, practice_consent_contract_errors(altered))

        formatted_gate = (
            "    if (!await ensurePracticeConsent(\n"
            "      stillCurrent: isCurrent,\n"
            "    )) return;\n"
        )
        formatted_create = (
            "    final decoy = 'final s = await repo.create(body);';\n"
            "    final s = await repo\n"
            "        .create(\n"
            "          body,\n"
            "        );\n"
        )
        formatted = lobby.replace(create_guard, formatted_gate, 1).replace(
            create_request, formatted_create, 1
        )
        self.assertNotEqual(formatted, lobby)
        self.assertEqual(practice_consent_contract_errors(formatted), [])

        repo = read("app/lib/features/practice/repository.dart")
        self.assertIn("purpose: 'practice'", repo)
        self.assertIn("'version': 'v1', 'granted': true", repo)

    def test_practice_consent_recheck_requires_executable_throw(self) -> None:
        throw = (
            "      throw const ApiFailure(403, 'forbidden', "
            "'练习授权未生效，请重试。', true);\n"
        )
        variants = {
            "removed": "",
            "commented": "      // throw const ApiFailure(403, 'forbidden');\n",
            "string": "      final hint = 'throw const ApiFailure(403)';",
        }
        self.assertIn(throw, PRACTICE_LOBBY_CONTRACT_FIXTURE)
        for name, replacement in variants.items():
            with self.subTest(name=name):
                altered = PRACTICE_LOBBY_CONTRACT_FIXTURE.replace(
                    throw, replacement, 1
                )
                self.assertNotEqual(altered, PRACTICE_LOBBY_CONTRACT_FIXTURE)
                self.assertIn(
                    "practice consent confirmation must throw when re-read remains false",
                    practice_consent_contract_errors(altered),
                )

    def test_t19_practice_contract_is_substantive(self) -> None:
        migration = read("server/migrations/20261122003019_practice_work.up.sql")
        down = read("server/migrations/20261122003019_practice_work.down.sql")
        for needle in (
            "REFERENCES activities ON DELETE CASCADE",
            "used_tokens integer NOT NULL DEFAULT 0 CHECK(used_tokens BETWEEN 0 AND 30000)",
            "worker uuid, valid_until timestamptz",
            "settlement_pending boolean NOT NULL DEFAULT false",
            "settlement_outcome text CHECK(settlement_outcome IN ('safety','moderation_unavailable','failed'))",
            "CHECK ((worker IS NULL) = (valid_until IS NULL))",
            "'capped'",
            "19000000-1000-4000-8000-000000000001",
        ):
            self.assertIn(needle, migration)
        self.assertIn("UPDATE activities SET state='failed' WHERE state='capped'", down)

        store = read("server/internal/training/store.go")
        self.assertIn('accounts.Granted(ctx, tx, u, "practice")', store)
        allowed = store.split("func (s *Service) allowed(", 1)[1].split("\nfunc ", 1)[0]
        self.assertRegex(allowed, re.compile(
            r'if in\.Contact != nil \{\s+if s\.Summary != nil \{.*?'
            r'accounts\.Granted\(ctx, tx, u, "contacts"\).*?return membership\.ErrForbidden'
            r'\s+\}\s+\}\s+return s\.Rights\.RequireContact\(ctx, tx, u, in\.Contact\)', re.S))
        for doc in ("data-inventory.md", "privacy-policy-draft.md", "separate-consents.md"):
            self.assertIn("T19 已接入 T25 画像摘要，选用关系人时额外检查 `contacts`", read("docs/compliance/" + doc))

        work = read("server/internal/training/work.go")
        self.assertIn(
            "worker=$3 and valid_until>clock_timestamp()",
            work,
        )
        self.assertIn("type guardedRunner struct", work)
        self.assertIn("c.Guard = r.guard", work)
        self.assertIn("return s.Accounts.WithSession(ctx, p, false", work)
        self.assertIn("return s.allowed(ctx, tx, j.user, j.input)", work)
        self.assertIn("update activities set state='capped'", work)
        self.assertIn("delete from practice_messages", work)

        privacy = read("server/internal/training/privacy.go")
        self.assertIn('case "account", "contacts", "sessions"', privacy)
        self.assertIn("join practice_work on activity_id=id", privacy)
        self.assertIn("limit 50", privacy)
        self.assertIn('json:"setup"', privacy)
        self.assertIn('json:"source_id"', privacy)

        delivery = read("server/internal/training/delivery.go")
        self.assertIn("interval '95 seconds'", read("server/internal/training/work.go"))
        self.assertIn("interval '720 hours'", delivery)

        http = read("server/internal/service/http.go")
        routes = re.search(r"var accountRoutes = map\[string\]bool\{(.*?)\n\}", http, re.S)
        self.assertIsNotNone(routes)
        route_block = routes.group(1)
        for route in (
            "GET /v1/levels",
            "GET /v1/sessions",
            "POST /v1/sessions",
            "GET /v1/sessions/:session_id",
            "POST /v1/sessions/:session_id/messages",
            "POST /v1/sessions/:session_id/exit",
            "POST /v1/sessions/:session_id/finish",
        ):
            self.assertIn(route, route_block)
        self.assertNotIn("GET /v1/me/export", route_block)
        self.assertNotIn("DELETE /v1/me/data/:kind/:id", route_block)

        inventory = read("docs/compliance/data-inventory.md")
        d38 = re.search(r"^\| D38 \|.*$", inventory, re.M)
        self.assertIsNotNone(d38, "data-inventory.md must have a D38 practice_work row")
        for phrase in (
            "practice_work",
            "used_tokens",
            "worker",
            "valid_until",
            "settlement_pending",
            "settlement_outcome",
            "capped",
            "ON DELETE CASCADE",
            "不含正文",
            "501 not_implemented",
            "42",
            "T35",
            "T19 后端增量",
        ):
            self.assertIn(phrase, d38.group(0), phrase)

        self.assertIn("TestPracticeWire", read("docs/compliance/qa.md"))

    def test_practice_setup_is_authorized_detail_only_and_contact_deletion_is_scoped(self) -> None:
        lobby = read("app/lib/features/practice/lobby.dart")
        demo = read("app/lib/features/practice/demo.dart")
        store = read("server/internal/training/store.go")
        api = read("docs/api/app.yaml")
        conversation = read("app/lib/features/practice/conversation.dart")
        inventory = read("docs/compliance/data-inventory.md")

        self.assertNotIn("started.", lobby)
        self.assertIn("_pruneDeletedContacts", demo)
        self.assertIn("..remove('setup')", demo)
        self.assertIn("contact is String && !ids.contains(contact)", demo)

        summary = store.split("type SessionSummary struct {", 1)[1].split("type Session struct {", 1)[0]
        session = store.split("type Session struct {", 1)[1].split("func (r record) summary()", 1)[0]
        self.assertNotIn("Setup", summary)
        self.assertIn("Setup *Input", session)
        self.assertIn("Items []SessionSummary `json:\"items\"`", store)
        listing = store.split("func (s *Service) List(", 1)[1]
        self.assertIn("r.summary()", listing)
        self.assertNotIn("r.Session", listing)

        summary_schema = api.split("    SessionSummary:", 1)[1].split("    Level:", 1)[0]
        detail_schema = api.split("    Session:", 1)[1].split("    SessionSummary:", 1)[0]
        list_schema = api.split("    ListSessionsResult:", 1)[1].split("    Reply:", 1)[0]
        create_endpoint = api.split("  /v1/sessions:", 1)[1].split("  /v1/sessions/{session_id}:", 1)[0]
        self.assertIn("setup:", detail_schema)
        for forbidden in ("setup:", "contact_id", "previous_id", "scenario"):
            self.assertNotIn(forbidden, summary_schema)
        self.assertIn("$ref: '#/components/schemas/SessionSummary'", create_endpoint)
        self.assertNotIn("$ref: '#/components/schemas/Session'", create_endpoint)
        self.assertIn("$ref: '#/components/schemas/SessionSummary'", list_schema)
        detail_endpoint = api.split("  /v1/sessions/{session_id}:", 1)[1].split("  /v1/sessions/{session_id}/exit:", 1)[0]
        self.assertIn("$ref: '#/components/schemas/Session'", detail_endpoint)

        create = store.split("func (s *Service) Create(", 1)[1].split("func (s *Service) Get(", 1)[0]
        self.assertIn("(out SessionSummary, e error)", create)
        self.assertIn("out = r.summary()", create)
        self.assertNotIn("out = Session{", create)

        exit_method = conversation.split("Future<void> exit() async {", 1)[1].split("Future<void> retry()", 1)[0]
        self.assertIn("current?['kind'] == 'exit'", exit_method)
        self.assertIn("current['fallback'] as Json", exit_method)
        self.assertIn("不形成嵌套退出", read("app/test/practice/finish_exit_test.dart"))

        d10 = re.search(r"^\| D10 \|.*$", inventory, re.M)
        self.assertIsNotNone(d10, "data-inventory.md must have a D10 practice row")
        for phrase in (
            "activities.content_enc",
            "SessionSummary",
            "有效登录会话",
            "归属",
            "不要求仍有有效的 `practice` 同意",
            "重练创建才复核",
            "creating",
            "practice.started",
            "外键级联",
            "跨设备",
        ):
            self.assertIn(phrase, d10.group(0), phrase)

    def test_candidate_evidence_uses_archive_hash_not_working_tree(self) -> None:
        corpus = compliance_corpus()
        self.assertNotRegex(corpus, r"工作区中[^\n]*(?:未提交|未提交实现)")
        self.assertNotRegex(corpus, r"未提交实现[^\n]*(?:已实现|静态通过)")

        for path in (
            "docs/compliance/banned-words-and-examples.md",
            "docs/compliance/sdk-model-review-checklist.md",
        ):
            text = read(path)
            self.assertIn(CANDIDATE, text, path)
            self.assertRegex(text, r"候选[^\n]*(?:待对表|不等于|不证明)", path)

    def test_generic_export_and_delete_routes_return_not_implemented(self) -> None:
        http = read("server/internal/service/http.go")
        routes = re.search(r"var accountRoutes = map\[string\]bool\{(.*?)\n\}", http, re.S)
        self.assertIsNotNone(routes)
        route_block = routes.group(1)
        self.assertNotIn("GET /v1/me/export", route_block)
        self.assertNotIn("DELETE /v1/me/data/:kind/:id", route_block)
        self.assertIn('problem(c, 501, "not_implemented"', http)

        for path in (
            "docs/compliance/README.md",
            "docs/compliance/data-inventory.md",
            "docs/compliance/qa.md",
            "docs/compliance/privacy-policy-draft.md",
            "docs/tasks/T33.md",
        ):
            text = read(path)
            self.assertIn("/v1/me/export", text, path)
            self.assertIn("/v1/me/data/:kind/:id", text, path)
            self.assertIn("501 not_implemented", text, path)

    def test_drafts_do_not_claim_unmerged_rights_or_permissions(self) -> None:
        privacy = read("docs/compliance/privacy-policy-draft.md")
        filings = read("docs/compliance/filings-and-authorizations.md")
        separate = read("docs/compliance/separate-consents.md")

        self.assertIn("20261123000021_reply_requests.up.sql", privacy)
        self.assertIn("T21 后端增量", privacy)
        self.assertNotRegex(privacy, r"服务端存在导出能力|存在单条删除")
        self.assertRegex(privacy, r"/v1/me/export[^\n]*501 not_implemented")
        self.assertRegex(privacy, r"/v1/me/data/:kind/:id[^\n]*501 not_implemented")

        baseline_plist = git_show("app/ios/Runner/Info.plist")
        baseline_entitlements = git_show("app/ios/Runner/Runner.entitlements")
        self.assertNotIn("NSHealthShareUsageDescription", baseline_plist)
        self.assertNotIn("com.apple.developer.healthkit", baseline_entitlements)

        self.assertRegex(filings, r"固定基线[^\n]*Manifest[^\n]*仅[^\n]*INTERNET")
        self.assertRegex(
            filings,
            r"当前 T28 归档[^\n]*(?:ACTIVITY_RECOGNITION|Health Connect)",
        )
        self.assertRegex(
            filings,
            r"当前 T28 归档[^\n]*(?:NSHealthShareUsageDescription|HealthKit)",
        )
        self.assertRegex(filings, r"iOS[^\n]*(?:NSMicrophoneUsageDescription|麦克风用途说明)")
        self.assertRegex(filings, r"f60ace3[^\n]*仅声明[^\n]*INTERNET")
        self.assertNotRegex(
            filings,
            r"固定基线[^\n]*ACTIVITY_RECOGNITION[^\n]*(?:已声明|已启用)",
        )
        self.assertNotRegex(filings, r"HealthKit[^\n]*entitlement 和[^\n]*存在")
        self.assertNotRegex(filings, r"(?:9 个|九个).*(?:DNS|HTTP|不可达|未取得)")

        self.assertNotRegex(separate, r"服务端仅检查有效未撤回记录")

    def test_security_and_deletion_boundaries_remain_explicit(self) -> None:
        corpus = compliance_corpus() + "\n" + read("docs/tasks/T33.md")
        for phrase in (
            "注销冻结",
            "撤销注销",
            "健康窗口专用删除",
            "AES-GCM",
            "删除协调器",
        ):
            self.assertIn(phrase, corpus)
        self.assertRegex(corpus, r"通用.*(?:导出|删除).*(?:未接线|未接通|501 not_implemented)")


class DataLineageContract(unittest.TestCase):
    def test_source_score_growth_and_call_chain_is_complete(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        required = (
            "scores.id = activities.source_id",
            "detail_enc",
            "growth_scores",
            "ai_calls.operation_id",
            "ai_calls.id",
            "score_id",
            "LinkScoreTx",
        )
        for needle in required:
            self.assertIn(needle, inventory)
        self.assertRegex(
            inventory,
            r"(?:失败|审核).*(?:score_id|关联).*(?:空|未补|不补)|(?:空|未补).*(?:失败|审核)",
        )

    def test_daily_plans_and_drill_progress_have_distinct_delete_scopes(self) -> None:
        migration = read("server/migrations/20261121000200_training.up.sql")
        daily = re.search(r"CREATE TABLE daily_plans \((.*?)\n\);", migration, re.S)
        drill = re.search(r"CREATE TABLE drill_progress \((.*?)\n\);", migration, re.S)
        self.assertIsNotNone(daily)
        self.assertIsNotNone(drill)
        self.assertIn("REFERENCES users ON DELETE CASCADE", daily.group(1))
        self.assertNotIn("REFERENCES activities", daily.group(1))
        self.assertIn("REFERENCES activities(id,kind) ON DELETE CASCADE", drill.group(1))

        inventory = read("docs/compliance/data-inventory.md")
        self.assertRegex(inventory, r"daily_plans[^\n]*随账号删除")
        self.assertRegex(inventory, r"drill_progress[^\n]*随单项活动删除")
        self.assertNotRegex(inventory, r"daily_plans[^\n]*随账号或相关活动删除")

    def test_one_day_provider_admission_is_not_proof_of_actual_retention(self) -> None:
        admission = read("server/migrations/20261121000600_gateway_admission.up.sql")
        self.assertIn("max_retention_days >= 0", admission)
        self.assertNotRegex(admission, r"max_retention_days\s*<=\s*1")

        checklist = read("docs/compliance/sdk-model-review-checklist.md")
        qa = read("docs/compliance/qa.md")
        t33 = read("docs/tasks/T33.md")
        routing = read("server/internal/gateway/store.go")
        self.assertIn("c.Task == ProfileInference && a.retention > 1", routing)
        self.assertIn("b.retention > a.retention", routing)
        for doc in [checklist, qa]:
            self.assertIn("不证明供应商实际留存或删除", doc)
            self.assertIn("1 天", doc)
        self.assertIn("1 天", t33)


class T26GrowthContract(unittest.TestCase):
    def test_t26_growth_projection_and_drill_schedule_boundaries(self) -> None:
        migration = read("server/migrations/20261123010026_growth_plan_delivery.up.sql")
        self.assertIn(
            "ALTER TABLE daily_plans\n"
            "  ADD COLUMN assessment_id uuid REFERENCES assessments(id) ON DELETE CASCADE;",
            migration,
        )

        schedule = re.search(
            r"CREATE TABLE growth_drill_schedules \((.*?)\n\);", migration, re.S
        )
        self.assertIsNotNone(schedule)
        schedule_block = schedule.group(1)
        for column in (
            "activity_id",
            "target_item",
            "level_id",
            "schedule_enc",
            "occurred_at",
            "retry_at",
            "closed_at",
            "created_at",
        ):
            self.assertRegex(schedule_block, rf"(?m)^\s*{column}\s", f"missing {column}")
        self.assertIn(
            "activity_id uuid PRIMARY KEY REFERENCES activities ON DELETE CASCADE",
            schedule_block,
        )
        self.assertNotRegex(schedule_block, r"(?m)^\s*(?:score|band)\s")
        self.assertIn("schedule_enc bytea NOT NULL", schedule_block)

        projection = read("server/internal/growth/projection.go")
        consume = projection.split("func (s *Service) Consume(", 1)[1].split(
            "// Reference", 1
        )[0]
        self.assertIn('v.Kind != "practice" && v.Kind != "review"', consume)
        self.assertIn(
            "insert into growth_scores(score_id,kind,nvc_enc,emotion_enc)",
            consume,
        )
        self.assertNotIn("insert into growth_scores(score_id,kind,nvc_enc,emotion_enc,user_id", consume)

        delivery = read("server/internal/growth/planning_delivery.go")
        self.assertIn("insert into growth_drill_schedules", delivery)
        for forbidden in (
            "insert into drill_progress",
            "update drill_progress",
            "delete from drill_progress",
        ):
            self.assertNotIn(forbidden, delivery.lower())
        self.assertIn("occurredAt.Add(72 * time.Hour)", delivery)
        self.assertIn("closed_at", delivery)
        self.assertIn("ReviewThreeDays", delivery)

        schedule_rules = read("server/internal/growth/schedule.go")
        self.assertIn("case score >= 25:", schedule_rules)
        self.assertIn("case score >= 10:", schedule_rules)

        inventory = read("docs/compliance/data-inventory.md")
        baseline_training = read("server/migrations/20261121000200_training.up.sql")
        self.assertIn("CREATE TABLE growth_scores", baseline_training)

        d16 = re.search(r"^\| D16 \|.*$", inventory, re.M)
        self.assertIsNotNone(d16)
        for phrase in (
            "数值副本（固定基线表 + T26 投影消费）",
            "`growth_scores` 表属于固定基线 `f60ace3`",
            "T26 新增的是投影消费",
            "内部 `growth.json` 包含数值评分记录、计划和单项调度",
            "其中评分记录只导出数值投影",
        ):
            self.assertIn(phrase, d16.group(0))

        baseline_encrypted = inventory.split(
            "在固定基线迁移中可定位的密文信封列", 1
        )[1].split("T25 后端增量", 1)[0]
        self.assertIn("growth_scores.nvc_enc", baseline_encrypted)
        self.assertNotIn("schedule_enc", baseline_encrypted)

        d43 = re.search(r"^\| D43 \|.*$", inventory, re.M)
        self.assertIsNotNone(d43)
        for phrase in (
            "growth_drill_schedules",
            "schedule_enc",
            "REFERENCES activities ON DELETE CASCADE",
            "closed_at",
            "72h",
            "不计入 `f60ace3` 的 42 项",
            "T19",
            "drill_progress",
            "T26 后端增量",
        ):
            self.assertIn(phrase, d43.group(0))

        schema = read("docs/schema.md")
        self.assertIn("assessments |o--o{ daily_plans : informs", schema)
        daily_plan_row = next(
            line for line in schema.splitlines() if line.startswith("| `daily_plans` |")
        )
        for phrase in (
            "可空 `assessment_id`",
            "ON DELETE CASCADE",
            "`plan_enc` 内保存条目完成标志",
            "独立可空 `completed_at`",
        ):
            self.assertIn(phrase, daily_plan_row)
        growth_score_row = next(
            line for line in schema.splitlines() if line.startswith("| `growth_scores` |")
        )
        self.assertIn("固定基线表", growth_score_row)
        self.assertIn("T26 只新增投影消费与导出", growth_score_row)

    def test_t26_reference_and_plan_scene_recompute_from_authorized_sources(self) -> None:
        projection = read("server/internal/growth/projection.go")
        self.assertIn("const behaviorWindow = 720 * time.Hour", projection)
        reference = projection.split("func (s *Service) Reference(", 1)[1].split(
            "func (s *Service) export(", 1
        )[0]
        self.assertIn("now.Add(-behaviorWindow)", reference)
        self.assertIn("s.occurred_at>$2 and s.occurred_at<=$3", reference)
        self.assertIn("sum += BehaviorScore", reference)
        self.assertIn("TrainingReference(out.WLEISPercent, &average)", reference)
        self.assertIn("out.ValidBehaviorCount++", reference)

        planning = read("server/internal/growth/planning.go")
        plan_scene = planning.split("func (s *PlanService) planScene(", 1)[1].split(
            "func (s *PlanService) dueReview(", 1
        )[0]
        self.assertIn("scene := sceneFor(user, day, focus)", plan_scene)
        membership_pos = plan_scene.index("s.Membership.Require")
        profiles_pos = plan_scene.index("s.Profiles.AuthorizedScene")
        self.assertLess(membership_pos, profiles_pos)

        outer_membership = plan_scene[membership_pos:profiles_pos]
        self.assertIn("errors.Is(err, membership.ErrForbidden)", outer_membership)
        self.assertIn("return scene, false, nil", outer_membership)
        self.assertIn('return "", false, err', outer_membership)

        adoption = plan_scene[profiles_pos:]
        self.assertIn("if err != nil || !ok || !validScene(authorized)", adoption)
        self.assertIn("return scene, false, nil", adoption)
        self.assertIn("return authorized, true, nil", adoption)

        contacts = read("server/internal/profile/contacts.go")
        authorized_scene = contacts.split(
            "func (s *Service) AuthorizedScene(", 1
        )[1].split("func (s *Service) ForModel(", 1)[0]
        rights_pos = authorized_scene.index("s.Rights.Require")
        consent_pos = authorized_scene.index('consent(ctx, tx, u, "contacts")')
        contact_query_pos = authorized_scene.index("select id from contacts")
        contact_read_pos = authorized_scene.index("s.read(ctx, tx, u, id)")
        self.assertLess(rights_pos, consent_pos)
        self.assertLess(consent_pos, contact_query_pos)
        self.assertLess(contact_query_pos, contact_read_pos)

        inventory = read("docs/compliance/data-inventory.md")
        for phrase in (
            "720 小时（30 天）",
            "新增或删除有效来源后计数和参考值即时重算",
            "删除低分有效来源时参考值可以上升",
        ):
            self.assertIn(phrase, inventory)

        scene_phrases = (
            "默认场景由账号、计划日和训练重点推导",
            "通过后调用 `Profiles.AuthorizedScene`",
            "该方法再复核会员权益和有效 `contacts` 同意",
            "通过后查询并读取最近使用的关系人",
            "只有返回可用且合法的场景时才采用，否则走默认场景",
            "外层会员检查只有 `ErrForbidden` 回退，其他错误直接返回",
            "生成仍读取到期单项调度和近期已用题卡",
        )
        for document in (inventory, read("docs/tasks/T33.md")):
            for phrase in scene_phrases:
                self.assertIn(phrase, document)

        generate_plan = planning.split(
            "func (s *PlanService) generatePlan(", 1
        )[1].split("func (s *PlanService) planScene(", 1)[0]
        self.assertIn("s.dueReview(ctx, tx, user, at)", generate_plan)
        self.assertIn("s.usedContent(ctx, tx, user, day)", generate_plan)

    def test_t26_exports_are_numeric_and_hide_internal_review_links(self) -> None:
        projection = read("server/internal/growth/projection.go")
        export_record = projection.split("type ExportRecord struct {", 1)[1].split(
            "type PlanItemExportRecord struct {", 1
        )[0]
        self.assertEqual(
            set(re.findall(r"^\s+(\w+)\s+", export_record, re.M)),
            {"RecordType", "SourceID", "Kind", "OccurredAt", "NVC", "Emotion"},
        )

        plan_item = projection.split("type PlanItemExportRecord struct {", 1)[1].split(
            "type PlanExportRecord struct {", 1
        )[0]
        self.assertEqual(
            set(re.findall(r"^\s+(\w+)\s+", plan_item, re.M)),
            {"ID", "Kind", "Title", "ContentID", "Completed"},
        )
        self.assertNotIn("ReviewActivityID", plan_item)
        self.assertNotIn("review_activity_id", plan_item)

        plan_export = projection.split("type PlanExportRecord struct {", 1)[1].split(
            "type DrillExportRecord struct {", 1
        )[0]
        self.assertNotIn("ReviewActivityID", plan_export)
        self.assertNotIn("review_activity_id", plan_export)

        planning = read("server/internal/growth/planning.go")
        export_plans = planning.split("func (s *PlanService) exportPlans(", 1)[1].split(
            "func (s *PlanService) exportDrills(", 1
        )[0]
        self.assertIn("PlanItemExportRecord{", export_plans)
        self.assertIn(
            "ID: item.ID, Kind: item.Kind, Title: item.Title, ContentID: item.ContentID, Completed: item.Completed",
            export_plans,
        )
        self.assertNotIn("ReviewActivityID:", export_plans)
        export_drills = planning.split("func (s *PlanService) exportDrills(", 1)[1].split(
            "func utcTimePointer(", 1
        )[0]
        self.assertIn('RecordType: "drill"', export_drills)
        self.assertIn("Score:      score", export_drills)
        self.assertIn("Band:       band", export_drills)

        http = read("server/internal/service/http.go")
        routes = re.search(r"var accountRoutes = map\[string\]bool\{(.*?)\n\}", http, re.S)
        self.assertIsNotNone(routes)
        self.assertNotIn("GET /v1/me/export", routes.group(1))
        self.assertNotIn("DELETE /v1/me/data/:kind/:id", routes.group(1))
        self.assertIn('problem(c, 501, "not_implemented"', http)

        inventory = read("docs/compliance/data-inventory.md")
        for phrase in (
            "内部 `growth.json` 包含数值评分记录、计划和单项调度",
            "其中评分记录只导出数值投影",
            "不输出 `review_activity_id`",
            "通用 `GET /v1/me/export` 与 `DELETE /v1/me/data/:kind/:id` 仍为 `501 not_implemented`",
        ):
            self.assertIn(phrase, inventory)

    def test_t26_compliance_evidence_and_nonclaims_are_registered(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        qa = read("docs/compliance/qa.md")
        t33 = read("docs/tasks/T33.md")

        qa34 = re.search(r"^\| QA-34 \|.*$", qa, re.M)
        self.assertIsNotNone(qa34)
        for phrase in (
            "PG17",
            "普通 Redis",
            "独立 AOF Redis",
            "Flutter 实际 HTTP",
            "member-plan-http.log",
            "final-storage.log",
            "t04-server.log",
            "t27-latest/client.log",
            "首次 `GET` 前测评事件已生成计划",
            "免费、会员和撤回 `contacts` 后的路径",
            "正常账号",
            "可以幂等补生成",
            "冻结账号才被拒绝",
            "失败回滚",
            "删除后重算",
            "乱序原日补记",
            "原日已有匹配关卡",
            "不补建历史计划",
            "不给今天打卡",
            "不复活已关闭排期",
            "手动完成接口不是历史补打卡入口",
            "不是前两类服务端断言的客户端证据",
            "冻结账号",
            "GET",
            "NVC 20",
            "情绪 2/3/2",
            "行为分 24",
            "0→1",
            "(WLEIS 百分制分 + 24)/2",
            "恢复 0",
            "无训练参考",
            "导出没有该分数",
            "T34",
            "50 道题",
            "20 张卡",
            "未人工审校",
        ):
            self.assertIn(phrase, qa34.group(0))

        t26_section = re.search(r"### 4\.10 T26.*?(?=\n## 5\.)", t33, re.S)
        self.assertIsNotNone(t26_section)
        self.assertIn("不计入", t26_section.group(0))
        self.assertIn("42 项", t26_section.group(0))
        self.assertIn("T34 恢复后重删", t26_section.group(0))
        self.assertIn("50 道读人题", t26_section.group(0))
        self.assertIn("20 张知识卡片", t26_section.group(0))
        self.assertRegex(t26_section.group(0), r"合成材料.*未.*人工审")
        for phrase in (
            "首次 `GET` 前测评事件已生成计划",
            "免费、会员和撤回 `contacts` 后的路径",
            "正常账号",
            "可以幂等补生成",
            "冻结账号才被拒绝",
            "失败回滚",
            "删除后重算",
            "乱序原日补记",
            "不补建历史计划",
            "不给今天打卡",
            "不复活已关闭排期",
            "手动完成接口不是历史补打卡入口",
        ):
            self.assertIn(phrase, t26_section.group(0))

        evidence = re.search(r"### T26 合装证据.*$", t33, re.S)
        self.assertIsNotNone(evidence)
        for phrase in (
            "PG17",
            "普通 Redis",
            "独立 AOF Redis",
            "Flutter 实际 HTTP",
            "member-plan-http.log",
            "final-storage.log",
            "t04-server.log",
            "t27-latest/client.log",
            "首次 `GET` 前测评事件已生成计划",
            "免费、会员和撤回 `contacts` 后的路径",
            "可以幂等补生成",
            "冻结账号才被拒绝",
            "失败回滚",
            "删除后重算",
            "原日已有匹配关卡",
            "不补建历史计划",
            "不给今天打卡",
            "不复活已关闭排期",
            "手动完成接口不是历史补打卡入口",
            "冻结账号",
            "NVC 20",
            "情绪 2/3/2",
            "行为分 24",
            "0→1",
            "(WLEIS 百分制分 + 24)/2",
            "恢复 0",
            "无训练参考",
            "导出没有该分数",
            "T34",
            "50 道读人题",
            "20 张知识卡片",
            "人工审校",
        ):
            self.assertIn(phrase, evidence.group(0))

        for doc in (inventory, qa, t33):
            self.assertIn("T26", doc)
            self.assertIn("42 项", doc)
            self.assertIn("501 not_implemented", doc)
        self.assertIn("D43", inventory)
        self.assertIn("QA-34", qa)


class ReviewInventoryContract(unittest.TestCase):
    def test_recovery_and_tombstone_have_separate_lifetimes(self) -> None:
        migration = read("server/migrations/20261122120023_review_requests.up.sql")
        self.assertIn("mark_id uuid REFERENCES manual_marks(id) ON DELETE SET NULL", migration)
        self.assertIn("CREATE TABLE review_tombstones", migration)
        self.assertIn("AFTER DELETE ON users", migration)
        checkpoint = read("server/internal/reviews/checkpoint.go")
        self.assertIn("generatedCheckpointTTL = 15 * time.Minute", checkpoint)
        self.assertIn("generated_at=null,generated_expired=true", checkpoint)
        self.assertIn("s.Reviews.ReplayPending(worker)", read("server/cmd/api/main.go"))
        fields = read("server/internal/reviews/privacy.go")
        self.assertIn('record["approved_repair_draft"]', fields)
        self.assertIn('record["result"]', fields)
        self.assertNotIn("generated_enc", fields)
        journal = read("server/internal/reviews/store.go")
        self.assertIn("journalInput.MarkId, journalInput.SignalEventId = nil, nil", journal)
        self.assertIn("v.Submitted.MarkId, v.Submitted.SignalEventId = r.mark, r.signal", journal)
        row = next(line for line in read("docs/compliance/data-inventory.md").splitlines() if line.startswith("| D23 |"))
        for field in ("review_tombstones", "deleted_at", "15 分钟", "后台定期清扫", "reviews.json", "501 not_implemented"):
            self.assertIn(field, row)
        self.assertIn("未审核输出不展示、不导出", read("docs/compliance/separate-consents.md"))
        self.assertIn("成功落库时起算", row)
        self.assertIn("单独的已审核短语", row)
        self.assertIn("真实 T26 订阅者写数值投影", read("docs/compliance/qa.md"))


class ProfileEvidenceContract(unittest.TestCase):
    PROMPT_ID = "b935fb60-5a85-4c12-82c0-401afd649325"

    def test_profile_evidence_schema_freezes_sources_and_binds_both_consents(self) -> None:
        migration = read("server/migrations/20261122010025_profile_evidence.up.sql")
        for needle in (
            "CREATE TABLE profile_observations",
            "subject text NOT NULL CHECK(subject IN ('contact','self'))",
            "fact_enc bytea NOT NULL",
            "FOREIGN KEY(user_id,event_id) REFERENCES signal_events(user_id,id) ON DELETE CASCADE",
            "FOREIGN KEY(user_id,activity_id) REFERENCES activities(user_id,id) ON DELETE CASCADE",
            "CREATE TABLE activity_profile_context",
            "context_enc bytea NOT NULL",
            "PRIMARY KEY(user_id,activity_id)",
            "CREATE TABLE profile_inference_requests",
            "chat_consent_id uuid NOT NULL REFERENCES consents ON DELETE CASCADE",
            "contacts_consent_id uuid NOT NULL REFERENCES consents ON DELETE CASCADE",
            "CHECK(octet_length(input_digest)=32)",
            "CHECK(state IN ('processing','complete','invalidated'))",
            "FOREIGN KEY(user_id,contact_id) REFERENCES contacts(user_id,id) ON DELETE CASCADE",
        ):
            self.assertIn(needle, migration)
        self.assertIn("digest avoids", migration)
        self.assertIn("persisting chat text", migration)
        self.assertNotRegex(migration, r"(?:chat_text|input_text|message_text)")
        self.assertIn(self.PROMPT_ID, migration)
        self.assertIn("'profile_inference'", migration)
        self.assertIn("七个整数", migration)
        self.assertIn("不复述原文", migration)

        feedback = read("server/internal/profile/feedback.go")
        self.assertIn("Direction comes from the user's explicit judgment", feedback)
        self.assertIn("func (s *Service) bindActivityContext", feedback)
        self.assertIn("freezes the source scene, including a verified null", feedback)
        self.assertIn("insert into activity_profile_context", feedback)
        self.assertIn("return \"\", membership.ErrConflict", feedback)

    def test_profile_inference_revalidates_exact_consents_and_fails_closed(self) -> None:
        contacts = read("server/internal/profile/contacts.go")
        write = contacts.split("func (s *Service) write(", 1)[1].split("\nfunc ", 1)[0]
        self.assertLess(
            write.index('consent(ctx, tx, u, "contacts")'),
            write.index("RequireContact(ctx, tx, u, id)"),
        )
        for_model = contacts.split("func (s *Service) ForModel(", 1)[1].split("\nfunc ", 1)[0]
        self.assertIn("s.write(ctx, tx, u, &id)", for_model)

        infer = read("server/internal/profile/infer.go")
        request = read("server/internal/profile/inference_request.go")
        for needle in (
            'activeConsent(ctx, tx, u, "chat_import")',
            'activeConsent(ctx, tx, u, "contacts")',
            "reserveInference(ctx, tx, u, id, in.RequestId, chatConsent, contactsConsent, digest)",
            "call.BeforeAttempt = func(attemptCtx context.Context) error",
            "checkInferenceAttempt(attemptCtx, session, u, id, in.RequestId, reserved.chatConsent, reserved.contactsConsent, digest",
            "chatConsent != reserved.chatConsent",
            "contactsConsent != reserved.contactsConsent",
            "stored.state != \"processing\"",
            "invalidateInference(ctx, tx, u, in.RequestId)",
            "if reserved.state == \"complete\"",
            "len(x.Choices) != len(axes)",
            'i == 6 && sc != "partner"',
        ):
            self.assertIn(needle, infer)
        for needle in (
            "func inputDigest(text string) []byte",
            "sha256.Sum256([]byte(text))",
            "case \"invalidated\":",
            "return inferenceReservation{}, membership.ErrConflict",
            "a later regrant must not revive it",
            "set state='invalidated'",
        ):
            self.assertIn(needle, request)

        runtime = read("server/internal/service/training_runtime.go")
        self.assertIn("Summary: s.Profiles.ForModel", runtime)
        store = read("server/internal/training/store.go")
        allowed = store.split("func (s *Service) allowed(", 1)[1].split("\nfunc ", 1)[0]
        self.assertRegex(
            allowed,
            re.compile(
                r'if s\.Summary != nil \{.*?'
                r'accounts\.Granted\(ctx, tx, u, "contacts"\).*?'
                r'membership\.ErrForbidden.*?\}\s*\}'
                r'\s+return s\.Rights\.RequireContact\(ctx, tx, u, in\.Contact\)',
                re.S,
            ),
        )

    def test_profile_inventory_docs_distinguish_feedback_from_model_material(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        d14 = re.search(r"^\| D14 \|.*$", inventory, re.M)
        d39 = re.search(r"^\| D39 \|.*$", inventory, re.M)
        d40 = re.search(r"^\| D40 \|.*$", inventory, re.M)
        self.assertIsNotNone(d14, "data-inventory.md must have D14")
        self.assertIsNotNone(d39, "data-inventory.md must have D39")
        self.assertIsNotNone(d40, "data-inventory.md must have D40")

        d14_text = d14.group(0)
        for phrase in (
            "profile_observations.fact_enc",
            "用户明确反馈",
            "不是模型推断",
            "contacts.profile_enc",
            "七个有界选项",
            "随活动、信号事件或账号",
        ):
            self.assertIn(phrase, d14_text)

        self.assertIn("关联关系人时检查 `contacts`", d14_text)
        self.assertIn("`health` 与 `voice`", d14_text)
        self.assertIn("仅导入聊天做推断时另需 `chat_import`", inventory)
        d39_text = d39.group(0)
        self.assertIn("仅回复或复盘的本人反馈", d39_text)
        self.assertIn("不单列 D39", d39_text)
        for phrase in (
            "activity_profile_context.context_enc",
            "冻结来源活动场景",
            "已验证的 null",
            "ON DELETE CASCADE",
            "42",
            "T25 后端增量",
        ):
            self.assertIn(phrase, d39_text)

        d40_text = d40.group(0)
        self.assertIn("不输出 D40 请求、同意 ID 或输入摘要", d40_text)
        self.assertIn("不改写原记录", d40_text)
        for phrase in (
            "profile_inference_requests",
            "chat_consent_id",
            "contacts_consent_id",
            "32 字节 SHA-256",
            "processing",
            "complete",
            "invalidated",
            "撤回/重授权",
            "不复活",
            "ON DELETE CASCADE",
            "501 not_implemented",
            "T35",
            "42",
        ):
            self.assertIn(phrase, d40_text)

        # The supplier register identifies the prompt/evidence, while user-facing
        # material explains consent and retention without copying internal IDs.
        self.assertIn(self.PROMPT_ID, read("docs/compliance/sdk-model-review-checklist.md"))
        self.assertIn("供应商", read("docs/compliance/privacy-policy-draft.md"))
        self.assertIn("T25", read("docs/compliance/qa.md"))

    def test_profile_delete_is_internal_and_public_rights_stay_not_implemented(self) -> None:
        profile_http = read("server/internal/service/profile_http.go")
        self.assertIn('Scope: "contacts"', profile_http)
        self.assertIn("a.profiles.Data.Delete", profile_http)

        http = read("server/internal/service/http.go")
        routes = re.search(r"var accountRoutes = map\[string\]bool\{(.*?)\n\}", http, re.S)
        self.assertIsNotNone(routes)
        route_block = routes.group(1)
        self.assertIn('"DELETE /v1/contacts/:id": false', route_block)
        self.assertNotIn("GET /v1/me/export", route_block)
        self.assertNotIn("DELETE /v1/me/data/:kind/:id", route_block)
        self.assertIn('problem(c, 501, "not_implemented"', http)

        inventory = read("docs/compliance/data-inventory.md")
        self.assertIn("D01–D45", inventory)
        self.assertRegex(inventory, r"模块内部导出/删除[^\n]*不等于[^\n]*T35")
        self.assertRegex(
            inventory,
            r"D37[^\n]*D39[^\n]*D40[^\n]*D41[^\n]*D42[^\n]*D43[^\n]*D44[^\n]*不计入",
        )
        self.assertIn("chat_imports", inventory)
        self.assertRegex(inventory, r"chat_imports[^\n]*24 小时[^\n]*(?:待实现/验收|待验收)")

        qa = read("docs/compliance/qa.md")
        t33 = read("docs/tasks/T33.md")
        evidence = qa + "\n" + t33
        for needle in (
            "TestProfileLifecycle",
            "TestProfileInferenceReviewRegressions",
            "TestPracticeWire",
            "TestProfileReviewSourceLifecycle",
            "work",
            "null_scene",
            "build/t25/with-practice/live.log",
            "build/t25/joint-review-live.log",
            "本批后端实现不等于生产上线。",
        ):
            self.assertIn(needle, evidence)
        self.assertRegex(evidence, r"真实模型[^\n]*(?:不替代|不代表|仍待)")


class SharingHandoffContract(unittest.TestCase):
    def test_share_claim_does_not_imply_permission_to_show_text(self) -> None:
        for name in ("data-inventory.md", "privacy-policy-draft.md", "separate-consents.md"):
            text = (Path(__file__).resolve().parent / name).read_text()
            with self.subTest(name=name):
                self.assertIn("领取不要求已登录", text)
                self.assertIn("未登录时不显示正文", text)
                self.assertIn("登录后才可查看或编辑", text)
                self.assertNotIn("登录后打开「对话手记」", text)
                self.assertNotIn("登录并打开「对话手记」领取", text)

    def test_t22_share_handoff_platform_storage_is_not_flattened(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        privacy = read("docs/compliance/privacy-policy-draft.md")
        separate = read("docs/compliance/separate-consents.md")

        d37 = re.search(r"^\| D37 \|.*$", inventory, re.M)
        privacy_section = re.search(r"## 7\. 回复助手和聊天导入.*?(?=\n## 8\.)", privacy, re.S)
        c08 = re.search(r"### C08 回复助手聊天导入.*?(?=\n### C09)", separate, re.S)
        self.assertIsNotNone(d37, "data-inventory.md must have a D37 sharing-handoff row")
        self.assertIsNotNone(privacy_section, "privacy policy must describe sharing in section 7")
        self.assertIsNotNone(c08, "separate consent C08 must describe sharing handoff")

        sections = {
            "data-inventory.md D37": d37.group(0),
            "privacy-policy-draft.md section 7": privacy_section.group(0),
            "separate-consents.md C08": c08.group(0),
        }
        required = (
            "bc66e6e",
            "Android",
            "一次性内存",
            "iOS",
            "App Group",
            "Library/Caches/T22/incoming",
            "系统完整文件保护",
            "不是业务 AES-GCM",
            "写入",
            "替换",
            "领取",
            "清理",
            "10 分钟",
            "拒领",
            "不保证到点物理擦除",
            "开始分析",
            "未分析不上传",
            "提交前不上传",
            "T21",
            "后端增量",
            "服务端不持久化源文本与目的",
        )
        for name, section in sections.items():
            for phrase in required:
                self.assertIn(phrase, section, f"{name}: missing {phrase}")

        combined = "\n".join(sections.values())
        self.assertNotRegex(combined, r"(?:Android\s*(?:和|与|、)\s*iOS|两平台|均|都)[^\n]{0,80}不落盘")



class Pg17InventoryCoverageContract(unittest.TestCase):
    GAP_OBJECTS = (
        "admin_accounts",
        "admin_audit_logs",
        "admin_sessions",
        "erasure_roots_before_emotion",
        "gateway_revision",
        "prompt_releases",
        "quota_attempts",
    )

    def test_pg17_gap_objects_are_explicitly_inventoried(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        rows = [line for line in inventory.splitlines() if line.startswith("| D")]
        rows_by_name = {
            name: next((row for row in rows if name in row), None)
            for name in self.GAP_OBJECTS
        }
        missing = [name for name, row in rows_by_name.items() if row is None]
        self.assertEqual(missing, [], f"missing inventory rows: {missing}")

        admin_row = rows_by_name["admin_accounts"]
        self.assertIsNotNone(admin_row)
        for name in ("admin_accounts", "admin_audit_logs", "admin_sessions"):
            self.assertEqual(rows_by_name[name], admin_row, name)
            self.assertIn(name, admin_row)
        self.assertIn("覆盖 42/42", inventory)
        self.assertIn("后台员工数据", admin_row)
        self.assertRegex(admin_row, r"password_hash.*token_hash.*不进入 App 用户导出")
        for column in (
            "id",
            "login",
            "password_hash",
            "role",
            "token_hash",
            "admin_id",
            "expires_at",
            "occurred_at",
            "actor_id",
            "action",
            "target",
            "result",
        ):
            self.assertIn(column, admin_row)

        view_row = rows_by_name["erasure_roots_before_emotion"]
        self.assertIsNotNone(view_row)
        for phrase in (
            "查询视图",
            "不是物理副本",
            "不另存个人数据",
            "user_id",
            "scope",
            "root_id",
            "parent_id",
        ):
            self.assertIn(phrase, view_row)

        gateway_row = rows_by_name["gateway_revision"]
        self.assertIsNotNone(gateway_row)
        for phrase in ("平台配置", "不进入 App 用户导出", "singleton", "version"):
            self.assertIn(phrase, gateway_row)

        prompt_row = rows_by_name["prompt_releases"]
        self.assertIsNotNone(prompt_row)
        for phrase in (
            "平台配置",
            "不进入 App 用户导出",
            "task",
            "model_id",
            "model_kind",
            "primary_version_id",
            "experiment_version_id",
            "experiment_percent",
        ):
            self.assertIn(phrase, prompt_row)

        quota_row = rows_by_name["quota_attempts"]
        self.assertIsNotNone(quota_row)
        for phrase in (
            "原时区自然日",
            "valid_until",
            "重连/重试",
            "随活动/账号级联",
            "不导出内部令牌",
            "activity_id",
            "token",
            "state",
            "held_day",
            "metered",
        ):
            self.assertIn(phrase, quota_row)

        admin_sql = read("server/migrations/20261121193013_admin_security.up.sql")
        self.assertIn("REFERENCES admin_accounts ON DELETE CASCADE", admin_sql)
        roots_sql = read("server/migrations/20261121233030_emotion_roots.up.sql")
        self.assertIn(
            "ALTER VIEW erasure_roots RENAME TO erasure_roots_before_emotion",
            roots_sql,
        )
        self.assertIn("SELECT * FROM erasure_roots_before_emotion UNION ALL", roots_sql)
        gateway_sql = read("server/migrations/20261121000600_gateway_admission.up.sql")
        self.assertIn("CREATE TABLE gateway_revision", gateway_sql)
        route_sql = read("server/migrations/20261121200010_task_routing.up.sql")
        self.assertIn("ON model_routes", route_sql)
        prompts_sql = read("server/migrations/20261121210011_prompt_releases.up.sql")
        self.assertIn("CREATE TABLE prompt_releases", prompts_sql)
        self.assertIn("REFERENCES model_configs(id,kind)", prompts_sql)
        self.assertIn("REFERENCES prompt_versions(task,id)", prompts_sql)
        quota_sql = read("server/migrations/20261121203006_quota_attempts.up.sql")
        self.assertIn("REFERENCES activities ON DELETE CASCADE", quota_sql)


class T28HealthStaticContract(unittest.TestCase):
    def test_permissions_are_read_only_and_sources_are_history_only(self) -> None:
        manifest = read("app/android/app/src/main/AndroidManifest.xml")
        permissions = set(
            re.findall(r'android:name="android\.permission\.([^"]+)"', manifest)
        )
        self.assertTrue(
            {
                "INTERNET",
                "RECORD_AUDIO",
                "ACTIVITY_RECOGNITION",
                "health.READ_HEART_RATE",
                "health.READ_HEART_RATE_VARIABILITY",
                "health.READ_STEPS",
                "health.READ_EXERCISE",
            }.issubset(permissions)
        )
        self.assertFalse(any(permission.startswith("health.WRITE_") for permission in permissions))
        self.assertNotIn("WRITE_HEALTH_DATA", manifest)
        self.assertNotIn("insertRecords", read(
            "app/android/app/src/main/kotlin/cn/higheq/high_eq/HealthHistory.kt"
        ))

        plist = read("app/ios/Runner/Info.plist")
        entitlements = read("app/ios/Runner/Runner.entitlements")
        self.assertIn("NSHealthShareUsageDescription", plist)
        self.assertIn("NSMicrophoneUsageDescription", plist)
        self.assertNotIn("NSHealthUpdateUsageDescription", plist)
        self.assertIn("<key>com.apple.developer.healthkit</key><true/>", entitlements)
        swift = read("app/ios/Runner/HealthHistory.swift")
        self.assertIn(
            "Read-only, foreground history. No background delivery, writes or Watch bridge.",
            swift,
        )
        self.assertIn("store.requestAuthorization(toShare: [], read: types)", swift)
        self.assertNotIn("save(", swift)

        sync = read("app/lib/features/health/sync.dart")
        windows = read("app/lib/features/health/windows.dart")
        health_sources = sync + "\n" + windows
        self.assertIn(
            "_sources = {'apple_history', 'health_connect', 'huawei_history'}",
            sync,
        )
        self.assertIn(
            "{'apple_history', 'health_connect', 'huawei_history'}.contains(source)",
            windows,
        )
        self.assertNotIn("watch_live", health_sources)
        self.assertNotIn("background delivery", health_sources.lower())
        self.assertNotIn("insertRecords", health_sources)

    def test_huawei_is_restricted_and_windows_are_bounded(self) -> None:
        gradle = read("app/android/app/build.gradle.kts")
        self.assertIn(
            'providers.gradleProperty("t28Distribution").orElse("platform")', gradle
        )
        self.assertIn('historyDistribution == "huaweiRestricted"', gradle)
        self.assertIn('providers.gradleProperty("t28HuaweiAppId")', gradle)
        self.assertIn('huaweiAppId.matches(Regex("[0-9]+"))', gradle)
        self.assertIn('require(file("agconnect-services.json").isFile)', gradle)
        self.assertIn('apply(plugin = "com.huawei.agconnect")', gradle)
        plugin_branch = gradle.split("if (huaweiRestricted) {", 1)[1].split("android {", 1)[0]
        self.assertIn('apply(plugin = "com.huawei.agconnect")', plugin_branch)

        binding = read("app/lib/features/health/binding.dart")
        self.assertIn("defaultValue: false", binding)
        self.assertIn("source != 'huawei_history' || !huaweiApproved", binding)
        self.assertIn("_UnavailableHealthPort", binding)

        huawei = read("app/lib/features/health/huawei.dart")
        read_scopes = re.search(
            r"const huaweiReadScopes = <String>\{(.*?)\};", huawei, re.S
        )
        self.assertIsNotNone(read_scopes)
        scopes = read_scopes.group(1)
        for scope in (
            "huaweiHeartRateReadScope",
            "huaweiStepReadScope",
            "huaweiActivityReadScope",
        ):
            self.assertIn(scope, scopes)
        for scope in ("heartrate.read", "step.read", "activityrecord.read"):
            self.assertIn(scope, huawei)
        self.assertNotIn("heart_rate_variability", scopes)
        self.assertNotIn("hrv", scopes)
        self.assertIn("Read-only Huawei history adapter", huawei)

        windows = read("app/lib/features/health/windows.dart")
        sync = read("app/lib/features/health/sync.dart")
        for needle in (
            "const slotMs = 30000;",
            "to - from > 600000",
            "for (var slot = from; slot < to; slot += slotMs)",
            "'duration_seconds': 30",
        ):
            self.assertIn(needle, windows)
        for needle in (
            "floorSlot(clock() - 86400000)",
            "floorSlot(clock() - 300000)",
            "from + 600000",
            "s['pending_end'] = end;",
            "range of slots, NOT cached measurements",
        ):
            self.assertIn(needle, sync)

    def test_d45_withdrawal_and_evidence_boundaries_are_explicit(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        d45 = next(
            line for line in inventory.splitlines() if line.startswith("| D45 |")
        )
        for needle in (
            "t28.history.v1",
            "AES-GCM 256",
            "AAD 绑定账号",
            "`queue`",
            "队列键",
            "不缓存测量值",
            "显式撤回意图",
            "跨登出",
            "同一账号凭据",
            "普通登出不自动撤回线上同意",
            "health:false",
            "不因登出或撤回自动删除",
            "24 小时",
            "30 秒",
            "10 分钟",
            "pending_end",
            "不计入 `f60ace3` 的 42 项",
        ):
            self.assertIn(needle, d45)
        self.assertIn("D01–D45", inventory)
        self.assertIn("D37–D45", inventory)

        # Freeze only public, observable structure. Private cleanup helpers and
        # source comments are implementation details and may change freely.
        sessions = read("app/lib/core/session.dart")
        self.assertRegex(
            sessions, r"\benum\s+CacheKind\s*\{[^}]*\bqueue\b[^}]*\}"
        )
        self.assertRegex(
            sessions,
            r"\bstatic\s+const\s+healthQueueKey\s*=\s*'t28\.history\.v1'\s*;",
        )
        self.assertRegex(
            sessions,
            r"\benum\s+LogoutWithdrawalEvidence\s*\{[^}]*\bnone\b"
            r"[^}]*\bexplicit\b[^}]*\bunknown\b[^}]*\bunavailable\b[^}]*\}",
        )

        logout_tests = read("app/test/health/logout_regression_test.dart")
        self.assertIn("import 'package:flutter_test/flutter_test.dart';", logout_tests)
        self.assertIn("void main() {", logout_tests)
        registered_logout_tests = set(
            re.findall(r"(?m)^\s*test(?:Widgets)?\(\s*'([^']+)'", logout_tests)
        )
        for name in (
            "offline logout clears A queue; A reauth only withdraws and B cannot receive A",
            "setup tombstone is recovered after exhausted reads and never withdraws",
        ):
            self.assertIn(name, registered_logout_tests)

        sync_tests = read("app/test/health/sync_test.dart")
        self.assertIn("import 'package:flutter_test/flutter_test.dart';", sync_tests)
        self.assertIn("void main() {", sync_tests)
        registered_sync_tests = set(
            re.findall(r"(?m)^\s*test(?:Widgets)?\(\s*'([^']+)'", sync_tests)
        )
        for name in (
            "queue-only explicit withdrawal survives offline logout and retries for A only",
            "queue-only explicit withdrawal is flushed by online logout",
            "direct logout with no queue sends no health withdrawal",
            "failed withdrawal tombstone write cannot resume collection",
        ):
            self.assertIn(name, registered_sync_tests)

        qa = read("docs/compliance/qa.md")
        readme = read("docs/compliance/README.md")
        t33 = read("docs/tasks/T33.md")
        t28 = read("docs/tasks/T28.md")
        self.assertIn("docs/tasks/T28.md", t33)
        docs = qa + "\n" + readme + "\n" + t33 + "\n" + t28
        self.assertNotIn("../handoff.md", docs)
        self.assertRegex(
            t28,
            r"不冻结[^\n]*`Sessions`[^\n]*私有方法名[^\n]*注释[^\n]*实现细节",
        )
        self.assertRegex(
            t28,
            r"文档静态检查[^\n]*不能替代[^\n]*(?:Flutter|用例执行)",
        )
        # Receipt counts and elapsed times identify one host run; they are not
        # stable CI or documentation contracts. Freeze the evidence layers and
        # their claimed coverage instead.
        for needle in (
            "QA-36",
            "部分通过（静态 + 本次合装回归回执）",
            "固定基线静态",
            "当前 T28 归档静态",
            "本批宿主合装回执（非 CI 合同）",
            "旧阶段",
            "健康定向",
            "health+voice",
            "不能相加",
            "代理哨兵",
            "不构成文档静态契约",
            "真机",
            "Huawei",
            "固定 SHA CI",
            "未签收",
        ):
            self.assertIn(needle, docs)
        self.assertIn("旧阶段", readme)
        self.assertRegex(
            readme,
            r"旧阶段[^\n]*unknown-join",
        )
        for text in (qa, readme, t33):
            self.assertIn("D01–D45", text)
            self.assertIn("D37–D45", text)
        self.assertRegex(
            docs,
            r"T28[^\n]*(?:未合入固定基线|不写成固定基线|候选)",
        )
        self.assertNotRegex(
            docs,
            r"T28[^\n]*(?:CI 已[^\n]*通过|真机已[^\n]*通过|已合入固定基线)",
        )


class T29VoiceEvidenceContract(unittest.TestCase):
    def test_voice_capture_static_contract_and_inventory_are_explicit(self) -> None:
        errors = voice_static_and_behavior_errors(
            manifest=read("app/android/app/src/main/AndroidManifest.xml"),
            plist=read("app/ios/Runner/Info.plist"),
            ios_project=read("app/ios/Runner.xcodeproj/project.pbxproj"),
            android_entry=read(
                "app/android/app/src/main/kotlin/cn/higheq/high_eq/MainActivity.kt"
            ),
            ios_entry=read("app/ios/Runner/AppDelegate.swift"),
            native_sources={
                path: read(path)
                for path in (
                    "app/android/app/src/main/kotlin/cn/higheq/high_eq/VoiceCapture.kt",
                    "app/ios/Runner/VoiceCapture.swift",
                    "app/ios/Runner/VoicePCMConverter.swift",
                    "app/ios/Runner/VoicePCMCaptureSession.swift",
                )
            },
            behavior_sources={
                path: read(path) for path in VOICE_REQUIRED_BEHAVIORS
            },
        )
        self.assertEqual(errors, [])

        inventory = read("docs/compliance/data-inventory.md")
        d44 = next(
            line for line in inventory.splitlines() if line.startswith("| D44 |")
        )
        for needle in (
            "本机队列",
            "录音索引",
            "PCM",
            "完整 30 秒窗口",
            "AES-GCM 256",
            "账号",
            "kind",
            "id",
            "本机队列不含 PCM",
            "3 天",
            "不可读",
            "尽力删除",
            "janitor",
            "restore",
            "撤回",
            "不补传",
            "不计入旧 42 项",
        ):
            self.assertIn(needle, d44)
        self.assertIn("D01–D45", inventory)

        status = "T29 归档静态实现、未合入固定基线、真机待验"
        for path in (
            "docs/compliance/README.md",
            "docs/compliance/data-inventory.md",
            "docs/compliance/separate-consents.md",
            "docs/compliance/filings-and-authorizations.md",
            "docs/compliance/qa.md",
            "docs/compliance/privacy-policy-draft.md",
            "docs/compliance/banned-words-and-examples.md",
            "docs/compliance/terms-of-service-draft.md",
            "docs/tasks/T33.md",
        ):
            self.assertIn(status, read(path), path)

    def test_voice_behavior_runs_in_regular_hosted_ci(self) -> None:
        self.assertEqual(voice_ci_errors(read(".github/workflows/verify.yml")), [])

    def test_voice_evidence_rejects_synthetic_gate_removals(self) -> None:
        manifest = read("app/android/app/src/main/AndroidManifest.xml")
        plist = read("app/ios/Runner/Info.plist")
        ios_project = read("app/ios/Runner.xcodeproj/project.pbxproj")
        behavior_sources = {
            path: read(path) for path in VOICE_REQUIRED_BEHAVIORS
        }
        native_sources = {
            path: read(path)
            for path in (
                "app/android/app/src/main/kotlin/cn/higheq/high_eq/VoiceCapture.kt",
                "app/ios/Runner/VoiceCapture.swift",
                "app/ios/Runner/VoicePCMConverter.swift",
                "app/ios/Runner/VoicePCMCaptureSession.swift",
            )
        }
        workflow = read(".github/workflows/verify.yml")
        base = {
            "manifest": manifest,
            "plist": plist,
            "ios_project": ios_project,
            "android_entry": read(
                "app/android/app/src/main/kotlin/cn/higheq/high_eq/MainActivity.kt"
            ),
            "ios_entry": read("app/ios/Runner/AppDelegate.swift"),
            "native_sources": native_sources,
            "behavior_sources": behavior_sources,
        }
        self.assertEqual(voice_static_and_behavior_errors(**base), [])
        self.assertEqual(voice_ci_errors(workflow), [])

        no_permission = dict(base)
        no_permission["manifest"] = manifest.replace(
            'android:name="android.permission.RECORD_AUDIO"', ""
        )
        with self.subTest(gate="microphone permission"):
            self.assertIn(
                "Android Manifest is missing RECORD_AUDIO",
                voice_static_and_behavior_errors(**no_permission),
            )

        no_ios_permission = dict(base)
        no_ios_permission["plist"] = plist.replace(
            "NSMicrophoneUsageDescription", ""
        )
        with self.subTest(gate="iOS microphone permission declaration"):
            self.assertIn(
                "iOS Info.plist is missing NSMicrophoneUsageDescription",
                voice_static_and_behavior_errors(**no_ios_permission),
            )

        no_ios_pcm_source = dict(base)
        no_ios_pcm_source["ios_project"] = ios_project.replace(
            "VoicePCMConverter.swift", ""
        )
        with self.subTest(gate="iOS PCM source in Xcode target"):
            self.assertIn(
                "iOS Xcode Sources is missing VoicePCMConverter.swift",
                voice_static_and_behavior_errors(**no_ios_pcm_source),
            )

        no_native_network_guard = dict(base)
        no_native_network_guard["native_sources"] = dict(native_sources)
        ios_capture_path = "app/ios/Runner/VoiceCapture.swift"
        no_native_network_guard["native_sources"][ios_capture_path] += (
            "\nURLSession.shared\n"
        )
        with self.subTest(gate="native audio remains local"):
            self.assertTrue(
                any(
                    ios_capture_path in error and "URLSession" in error
                    for error in voice_static_and_behavior_errors(
                        **no_native_network_guard
                    )
                )
            )

        no_revoke_behavior = dict(base)
        no_revoke_behavior["behavior_sources"] = dict(behavior_sources)
        page_path = "app/test/voice/page_test.dart"
        no_revoke_behavior["behavior_sources"][page_path] = behavior_sources[
            page_path
        ].replace("revocation from page leaves an empty queue and no upload path", "")
        with self.subTest(gate="page revocation behavior"):
            self.assertTrue(
                any(
                    page_path in error and "revocation from page" in error
                    for error in voice_static_and_behavior_errors(
                        **no_revoke_behavior
                    )
                )
            )

        no_controller_revoke = dict(base)
        no_controller_revoke["behavior_sources"] = dict(behavior_sources)
        controller_path = "app/test/voice/controller_test.dart"
        no_controller_revoke["behavior_sources"][controller_path] = behavior_sources[
            controller_path
        ].replace("revoke persists the gate before stop and local purge", "")
        with self.subTest(gate="controller revoke ordering"):
            self.assertTrue(
                any(
                    controller_path in error and "revoke persists" in error
                    for error in voice_static_and_behavior_errors(
                        **no_controller_revoke
                    )
                )
            )

        no_flutter_test = workflow.replace(
            "flutter test --no-pub test/voice", ""
        )
        with self.subTest(gate="hosted Flutter voice test"):
            self.assertTrue(
                any(
                    "flutter test --no-pub test/voice" in error
                    for error in voice_ci_errors(no_flutter_test)
                )
            )

        self_hosted = workflow.replace(
            "runs-on: ubuntu-24.04", "runs-on: self-hosted"
        )
        with self.subTest(gate="ordinary GitHub-hosted runner"):
            errors = voice_ci_errors(self_hosted)
            self.assertIn(
                "hosted Verify workflow is missing 'runs-on: ubuntu-24.04'",
                errors,
            )
            self.assertIn(
                "hosted Verify workflow must not use a self-hosted runner",
                errors,
            )

    def test_voice_and_retention_revocation_docs_are_separate(self) -> None:
        text = read("docs/compliance/separate-consents.md")
        c05_row = next(
            line for line in text.splitlines() if line.startswith("| C05 |")
        )
        c06_row = next(
            line for line in text.splitlines() if line.startswith("| C06 |")
        )
        c05_section = re.search(r"### C05 .*?(?=\n### C06)", text, re.S)
        c06_section = re.search(r"### C06 .*?(?=\n### C07)", text, re.S)
        self.assertIsNotNone(c05_section)
        self.assertIsNotNone(c06_section)

        for prefix in ("| C04 |", "| C05 |", "| C06 |", "| C07 |"):
            row = next(
                line for line in text.splitlines() if line.startswith(prefix)
            )
            self.assertEqual(7, len(row.strip("|").split("|")), prefix)

        for needle in (
            "拒绝系统麦克风权限只停止本次采集",
            "不撤回同意",
            "不写撤回标记",
            "撤回 `voice`",
            "清空待传旧统计队列",
            "尝试删除本机录音和索引",
            "同步撤回 `voice` 与 `audio_retention`",
            "服务端既有按账号保存的 30 秒聚合统计（不含音频、PCM、逐秒数组或转写）不会因客户端撤回自动删除",
            "180 天",
            "专用时间删除",
            "删除后清除基线物化结果并从存活窗口重算",
        ):
            self.assertIn(needle, c05_row)
        self.assertNotIn("匿名", c05_row)
        self.assertNotIn("不补传旧窗口", c06_row)
        for needle in (
            "撤回 `audio_retention` 停止回听",
            "尝试删除本机录音和索引",
            "仅同步撤回该用途",
            "不清待传旧统计队列",
            "不撤回 `voice`",
            "旧待传窗口仍可按原授权发送",
            "服务端既有按账号保存的 30 秒聚合统计（不含音频、PCM、逐秒数组或转写）继续存在并参与基线",
            "不受录音保留撤回影响",
        ):
            self.assertIn(needle, c06_row)
        self.assertNotIn("匿名", c06_row)

        c05 = c05_section.group(0)
        c06 = c06_section.group(0)
        for needle in (
            "拒绝系统麦克风权限只关闭本次语音采集，不写撤回标记、不清待发统计队列",
            "清空待传旧统计队列、尝试删除本机录音和索引",
            "同步撤回 `voice` 与 `audio_retention`",
            "恢复联网也不会补传撤回前窗口",
            "服务端既有按账号保存的 30 秒聚合统计（不含音频、PCM、逐秒数组或转写）不会因客户端撤回 `voice` 自动删除",
            "DELETE /v1/signal-windows?starts_at=...&channel=voice",
            "`signal_baselines` 物化结果",
            "基线从存活窗口重算",
            "清理器逐项记录结果，失败时保持关闭并提示重试",
        ):
            self.assertIn(needle, c05)
        self.assertNotIn("匿名", c05)
        for needle in (
            "撤回或关闭录音保留只停止本机录音与回听",
            "尝试删除本机录音和索引并仅同步 `audio_retention` 撤回",
            "不清待传旧统计队列、不撤回 `voice`",
            "已授权的 30 秒统计特征分析仍可继续",
            "旧待传窗口仍可按原授权发送",
            "服务端既有按账号保存的 30 秒聚合统计（不含音频、PCM、逐秒数组或转写）继续存在并参与基线",
            "不受录音保留撤回影响",
            "删除失败时回听保持关闭并提示重试，不显示为已删除",
        ):
            self.assertIn(needle, c06)
        self.assertNotIn("匿名", c06)
        self.assertNotIn("不补传", c06)

        task = read("docs/tasks/T29.md")
        self.assertIn(
            "只有 `recordingsCleared` 等结果确认成功才显示“已删除”",
            task,
        )
        self.assertIn("删除失败时回听保持关闭并提示重试", task)

    def test_t29_live_evidence_uses_structured_record_without_inflating_scope(self) -> None:
        t29 = read("docs/tasks/T29.md")
        t33 = read("docs/tasks/T33.md")
        self.assertEqual(t29_live_evidence_errors(t29=t29, t33=t33), [])
        self.assertIn(T29_HISTORICAL_EVIDENCE, t29)
        self.assertIn(T29_HISTORICAL_EVIDENCE, t33)

    def test_t29_wire_workflow_covers_native_and_compliance_inputs(self) -> None:
        workflow = read(".github/workflows/t29-t30-wire.yml")
        self.assertEqual(t29_wire_workflow_errors(workflow), [])

        missing_native_path = workflow.replace(
            "      - 'app/**'\n",
            "",
            1,
        )
        self.assertNotEqual(missing_native_path, workflow)
        errors = t29_wire_workflow_errors(missing_native_path)
        self.assertTrue(any("VoiceCapture.swift" in error for error in errors))

        reads_temporary_evidence = workflow.replace(
            "      - name: Check T29 formatting",
            "      - name: Read temporary log\n        run: cat build/t29/live.log\n"
            "      - name: Check T29 formatting",
            1,
        )
        errors = t29_wire_workflow_errors(reads_temporary_evidence)
        self.assertIn("T29 wire workflow must not consume ignored build/ evidence", errors)

    def test_voice_static_gate_rejects_non_executable_permission_and_sources(self) -> None:
        base = {
            "manifest": read("app/android/app/src/main/AndroidManifest.xml"),
            "plist": read("app/ios/Runner/Info.plist"),
            "ios_project": read("app/ios/Runner.xcodeproj/project.pbxproj"),
            "android_entry": read(
                "app/android/app/src/main/kotlin/cn/higheq/high_eq/MainActivity.kt"
            ),
            "ios_entry": read("app/ios/Runner/AppDelegate.swift"),
            "native_sources": {
                path: read(path)
                for path in (
                    "app/android/app/src/main/kotlin/cn/higheq/high_eq/VoiceCapture.kt",
                    "app/ios/Runner/VoiceCapture.swift",
                    "app/ios/Runner/VoicePCMConverter.swift",
                    "app/ios/Runner/VoicePCMCaptureSession.swift",
                )
            },
            "behavior_sources": {
                path: read(path) for path in VOICE_REQUIRED_BEHAVIORS
            },
        }

        pcm_build_file = "E72900000000000000000003 /* VoicePCMConverter.swift in Sources */,"
        disabled_pcm = dict(base)
        disabled_pcm["ios_project"] = base["ios_project"].replace(pcm_build_file, "", 1)
        self.assertNotEqual(disabled_pcm["ios_project"], base["ios_project"])
        self.assertIn(
            "iOS Xcode Sources is missing VoicePCMConverter.swift",
            voice_static_and_behavior_errors(**disabled_pcm),
        )

        missing_pcm_path = dict(base)
        missing_pcm_path["ios_project"] = base["ios_project"].replace(
            "path = VoicePCMConverter.swift;",
            "path = Missing/VoicePCMConverter.swift;",
            1,
        )
        self.assertNotEqual(
            missing_pcm_path["ios_project"], base["ios_project"]
        )
        self.assertIn(
            "iOS Xcode Sources is missing VoicePCMConverter.swift",
            voice_static_and_behavior_errors(**missing_pcm_path),
        )

        permission_delegate = (
            "voiceCapture.handlePermissionResult(requestCode, permissions, grantResults)"
        )
        commented_delegate = dict(base)
        commented_delegate["android_entry"] = base["android_entry"].replace(
            permission_delegate,
            f"// {permission_delegate}",
            1,
        )
        self.assertNotEqual(
            commented_delegate["android_entry"], base["android_entry"]
        )
        self.assertIn(
            "Android MainActivity does not delegate microphone permission results",
            voice_static_and_behavior_errors(**commented_delegate),
        )

        conditional_delegate = dict(base)
        conditional_delegate["android_entry"] = base["android_entry"].replace(
            "        voiceCapture.handlePermissionResult(requestCode, permissions, grantResults)\n",
            "        if(false) {\n"
            "            voiceCapture.handlePermissionResult(requestCode, permissions, grantResults)\n"
            "        }\n",
            1,
        )
        self.assertNotEqual(
            conditional_delegate["android_entry"], base["android_entry"]
        )
        self.assertIn(
            "Android MainActivity does not delegate microphone permission results",
            voice_static_and_behavior_errors(**conditional_delegate),
        )

        unbraced_conditional_delegate = dict(base)
        unbraced_conditional_delegate["android_entry"] = base["android_entry"].replace(
            "        voiceCapture.handlePermissionResult(requestCode, permissions, grantResults)\n",
            "        if(false)\n\n"
            "            voiceCapture.handlePermissionResult(requestCode, permissions, grantResults)\n",
            1,
        )
        self.assertNotEqual(
            unbraced_conditional_delegate["android_entry"], base["android_entry"]
        )
        self.assertIn(
            "Android MainActivity does not delegate microphone permission results",
            voice_static_and_behavior_errors(**unbraced_conditional_delegate),
        )

        no_permission_result = dict(base)
        no_permission_result["native_sources"] = dict(base["native_sources"])
        voice_capture_path = (
            "app/android/app/src/main/kotlin/cn/higheq/high_eq/VoiceCapture.kt"
        )
        no_permission_result["native_sources"][voice_capture_path] = base[
            "native_sources"
        ][voice_capture_path].replace(
            "        pending.success(\n"
            "            grantResults.isNotEmpty() &&\n"
            "                grantResults[0] == PackageManager.PERMISSION_GRANTED,\n"
            "        )\n",
            "",
            1,
        )
        self.assertNotEqual(
            no_permission_result["native_sources"][voice_capture_path],
            base["native_sources"][voice_capture_path],
        )
        self.assertIn(
            "Android VoiceCapture does not handle microphone permission results",
            voice_static_and_behavior_errors(**no_permission_result),
        )

        conditional_permission_result = dict(base)
        conditional_permission_result["native_sources"] = dict(base["native_sources"])
        conditional_permission_result["native_sources"][voice_capture_path] = base[
            "native_sources"
        ][voice_capture_path].replace(
            "        pending.success(\n"
            "            grantResults.isNotEmpty() &&\n"
            "                grantResults[0] == PackageManager.PERMISSION_GRANTED,\n"
            "        )\n",
            "        if(false) {\n"
            "            pending.success(\n"
            "                grantResults.isNotEmpty() &&\n"
            "                    grantResults[0] == PackageManager.PERMISSION_GRANTED,\n"
            "            )\n"
            "        }\n",
            1,
        )
        self.assertNotEqual(
            conditional_permission_result["native_sources"][voice_capture_path],
            base["native_sources"][voice_capture_path],
        )
        self.assertIn(
            "Android VoiceCapture does not handle microphone permission results",
            voice_static_and_behavior_errors(**conditional_permission_result),
        )

        unbraced_permission_result = dict(base)
        unbraced_permission_result["native_sources"] = dict(base["native_sources"])
        unbraced_permission_result["native_sources"][voice_capture_path] = base[
            "native_sources"
        ][voice_capture_path].replace(
            "        pending.success(\n"
            "            grantResults.isNotEmpty() &&\n"
            "                grantResults[0] == PackageManager.PERMISSION_GRANTED,\n"
            "        )\n",
            "        if(false)\n\n"
            "            pending.success(\n"
            "                grantResults.isNotEmpty() &&\n"
            "                    grantResults[0] == PackageManager.PERMISSION_GRANTED,\n"
            "            )\n",
            1,
        )
        self.assertNotEqual(
            unbraced_permission_result["native_sources"][voice_capture_path],
            base["native_sources"][voice_capture_path],
        )
        self.assertIn(
            "Android VoiceCapture does not handle microphone permission results",
            voice_static_and_behavior_errors(**unbraced_permission_result),
        )

    def test_hosted_verify_requires_executable_commands_and_clean_inputs(self) -> None:
        workflow = read(".github/workflows/verify.yml")
        commented = workflow.replace(
            "        run: flutter test --no-pub test/voice",
            "        # run: flutter test --no-pub test/voice",
            1,
        )
        self.assertNotEqual(commented, workflow)
        self.assertIn(
            "hosted Verify workflow is missing executable 'flutter test --no-pub test/voice'",
            voice_ci_errors(commented),
        )

        ignored_input = workflow.replace(
            "      - name: Install locked Flutter dependencies",
            "      - name: Read ignored evidence\n"
            "        run: cat build/t29/live.log\n"
            "      - name: Install locked Flutter dependencies",
            1,
        )
        self.assertNotEqual(ignored_input, workflow)
        self.assertIn(
            "hosted Verify workflow must not consume ignored build/ evidence",
            voice_ci_errors(ignored_input),
        )

    def test_wire_workflow_tracks_direct_inputs_without_duplicate_unit_loops(self) -> None:
        workflow = read(".github/workflows/t29-t30-wire.yml")
        for event in ("push", "pull_request"):
            paths = workflow_trigger_paths(workflow, event)
            for path in (
                "app/**",
                "server/**",
                "docs/api/*.yaml",
            ):
                with self.subTest(event=event, path=path):
                    self.assertIn(path, paths)

            for path in (
                "app/pubspec.yaml",
                "app/pubspec.lock",
                "app/lib/main.dart",
                "app/android/app/src/main/AndroidManifest.xml",
                "app/ios/Runner/AppDelegate.swift",
                "server/Dockerfile",
                "server/go.mod",
                "server/go.sum",
                "server/migrations/20261122001532_manual_mark_tombstones.up.sql",
                "server/internal/service/entitlements_http.go",
                "app/lib/core/sse.dart",
                "app/lib/core/api.dart",
                "app/lib/core/consent.dart",
                "docs/api/app.yaml",
            ):
                with self.subTest(event=event, actual_input=path):
                    self.assertTrue(
                        workflow_path_is_triggered(workflow, event, path),
                        f"{event} must trigger the actual build or import input {path}",
                    )

        errors = t29_wire_workflow_errors(workflow)
        self.assertNotIn(
            "T29 wire workflow must not duplicate Verify's compliance job",
            errors,
        )
        self.assertNotIn(
            "T29 wire workflow must not duplicate Verify's voice unit-test job",
            errors,
        )

    def test_wire_covers_direct_go_packages_routes_and_entry_for_both_events(self) -> None:
        workflow = read(".github/workflows/t29-t30-wire.yml")
        for event in ("push", "pull_request"):
            for path in (
                "server/cmd/api/main.go",
                "server/internal/api/app/routes.gen.go",
                "server/internal/fieldcrypt/cipher.go",
            ):
                with self.subTest(event=event, path=path):
                    self.assertTrue(
                        workflow_path_is_triggered(workflow, event, path),
                        f"{event} must trigger the direct Go input {path}",
                    )

    def test_wire_rejects_missing_actual_live_dependencies(self) -> None:
        workflow = read(".github/workflows/t29-t30-wire.yml")
        mutations = (
            (
                "docker-compose.yml",
                workflow.replace(
                    "      - 'docker-compose.yml'\n",
                    "      - '!docker-compose.yml'\n",
                ),
            ),
            (
                "server/internal/membership/collection.go",
                workflow.replace(
                    "      - 'server/**'\n",
                    "      - 'server/**'\n"
                    "      - '!server/internal/membership/collection.go'\n",
                ),
            ),
        )
        for path, altered in mutations:
            self.assertNotEqual(altered, workflow, path)
            for event in ("push", "pull_request"):
                with self.subTest(event=event, path=path):
                    self.assertIn(
                        f"T29 wire workflow {event} paths do not trigger {path!r}",
                        t29_wire_workflow_errors(altered),
                    )

    def test_wire_path_negation_and_document_only_rules_are_effective(self) -> None:
        workflow = read(".github/workflows/t29-t30-wire.yml")
        for event in ("push", "pull_request"):
            anchor = "      - 'app/**'\n"
            negated_lock = insert_workflow_path(
                workflow,
                event,
                anchor,
                "!app/pubspec.lock",
            )
            with self.subTest(event=event, rule="lock negation"):
                self.assertIn(
                    f"T29 wire workflow {event} paths do not trigger 'app/pubspec.lock'",
                    t29_wire_workflow_errors(negated_lock),
                )

            negated_api = insert_workflow_path(
                workflow,
                event,
                anchor,
                "!app/lib/core/api.dart",
            )
            with self.subTest(event=event, rule="API import negation"):
                self.assertIn(
                    f"T29 wire workflow {event} paths do not trigger "
                    "'app/lib/core/api.dart'",
                    t29_wire_workflow_errors(negated_api),
                )

            docs_only = insert_workflow_path(
                workflow,
                event,
                anchor,
                "docs/**",
            )
            with self.subTest(event=event, rule="docs-only wildcard"):
                self.assertIn(
                    f"T29 wire workflow {event} must not trigger documentation-only "
                    "input 'docs/compliance/README.md'",
                    t29_wire_workflow_errors(docs_only),
                )

    def test_verify_rejects_both_github_path_filter_styles(self) -> None:
        workflow = read(".github/workflows/verify.yml")
        event = "pull_request"
        for filter_name in ("paths", "paths-ignore"):
            altered = workflow.replace(
                f"  {event}:\n",
                f"  {event}:\n    {filter_name}:\n      - 'docs/**'\n",
                1,
            )
            self.assertNotEqual(altered, workflow, filter_name)
            with self.subTest(filter=filter_name):
                self.assertIn(
                    f"hosted Verify workflow {event} must not use path filters",
                    voice_ci_errors(altered),
                )

    def test_verify_required_work_cannot_be_skipped_or_tolerate_failure(self) -> None:
        workflow = read(".github/workflows/verify.yml")
        step = "      - name: Test T29 voice consent, capture and revocation behavior\n"
        mutations = (
            (
                "step if false",
                workflow.replace(step, step + "        if: false\n", 1),
                "hosted Verify workflow step 'flutter test --no-pub test/voice' "
                "must not be conditional",
            ),
            (
                "step continue-on-error",
                workflow.replace(
                    step,
                    step + "        continue-on-error: true\n",
                    1,
                ),
                "hosted Verify workflow step 'flutter test --no-pub test/voice' "
                "must not allow failure",
            ),
        )
        for label, altered, expected in mutations:
            self.assertNotEqual(altered, workflow, label)
            with self.subTest(gate=label):
                self.assertIn(expected, voice_ci_errors(altered))

        job = "  compliance:\n    name: Privacy contracts and voice behavior\n"
        skipped_job = workflow.replace(job, job + "    if: false\n", 1)
        self.assertNotEqual(skipped_job, workflow)
        with self.subTest(gate="job if false"):
            self.assertIn(
                "hosted Verify compliance job must not be conditional",
                voice_ci_errors(skipped_job),
            )

        without_pull_request = workflow.replace("  pull_request:\n", "", 1)
        self.assertNotEqual(without_pull_request, workflow)
        with self.subTest(gate="pull request event"):
            self.assertIn(
                "hosted Verify workflow must trigger on both push and pull_request",
                voice_ci_errors(without_pull_request),
            )

        push_with_paths = workflow.replace(
            "  push:\n",
            "  push:\n    paths:\n      - 'docs/**'\n",
            1,
        )
        self.assertNotEqual(push_with_paths, workflow)
        with self.subTest(gate="push path filter"):
            self.assertIn(
                "hosted Verify workflow push must not use path filters",
                voice_ci_errors(push_with_paths),
            )

        python_command = "python3 -B -m unittest discover -s docs/compliance"
        early_exit = workflow.replace(
            f"        run: {python_command}\n",
            "        run: |\n"
            "          exit 0\n"
            f"          {python_command}\n",
            1,
        )
        self.assertNotEqual(early_exit, workflow)
        with self.subTest(gate="early exit"):
            self.assertIn(
                f"hosted Verify workflow command {python_command!r} must not be "
                "preceded by a shell early exit",
                voice_ci_errors(early_exit),
            )

        swallowed_python = workflow.replace(
            f"        run: {python_command}\n",
            f"        run: {python_command} || true\n",
            1,
        )
        self.assertNotEqual(swallowed_python, workflow)
        with self.subTest(gate="swallowed Python failure"):
            self.assertIn(
                f"hosted Verify workflow command {python_command!r} must propagate "
                "shell failure",
                voice_ci_errors(swallowed_python),
            )

        flutter_command = "flutter test --no-pub test/voice"
        swallowed_flutter = workflow.replace(
            f"        run: {flutter_command}\n",
            f"        run: {flutter_command} || true\n",
            1,
        )
        self.assertNotEqual(swallowed_flutter, workflow)
        with self.subTest(gate="swallowed Flutter failure"):
            self.assertIn(
                f"hosted Verify workflow command {flutter_command!r} must propagate "
                "shell failure",
                voice_ci_errors(swallowed_flutter),
            )

        reordered = workflow.replace(
            f"        run: {python_command}\n",
            "        run: __T29_REORDER__\n",
            1,
        ).replace(
            f"        run: {flutter_command}\n",
            f"        run: {python_command}\n",
            1,
        ).replace(
            "        run: __T29_REORDER__\n",
            f"        run: {flutter_command}\n",
            1,
        )
        self.assertNotEqual(reordered, workflow)
        with self.subTest(gate="command order"):
            self.assertIn(
                "hosted Verify workflow required commands must execute in order",
                voice_ci_errors(reordered),
            )

    def test_wire_events_and_required_steps_fail_closed(self) -> None:
        workflow = read(".github/workflows/t29-t30-wire.yml")

        without_pull_request = workflow.replace("  pull_request:\n", "", 1)
        self.assertNotEqual(without_pull_request, workflow)
        with self.subTest(gate="pull request event"):
            self.assertIn(
                "T29 wire workflow must trigger on both push and pull_request",
                t29_wire_workflow_errors(without_pull_request),
            )

        live_step = "      - name: Exercise T29 client against disposable T30 HTTP/PG/Redis\n"
        conditional_live = workflow.replace(
            live_step,
            live_step + "        if: false\n",
            1,
        )
        self.assertNotEqual(conditional_live, workflow)
        with self.subTest(gate="live step conditional"):
            self.assertIn(
                "T29 wire workflow step 'bash app/tool/t29/live.sh' must not be "
                "conditional",
                t29_wire_workflow_errors(conditional_live),
            )

        live_command = "bash app/tool/t29/live.sh"
        early_exit = workflow.replace(
            f"        run: {live_command}\n",
            "        run: |\n"
            "          exit 0\n"
            f"          {live_command}\n",
            1,
        )
        self.assertNotEqual(early_exit, workflow)
        with self.subTest(gate="live early exit"):
            self.assertIn(
                f"T29 wire workflow command {live_command!r} must not be preceded "
                "by a shell early exit",
                t29_wire_workflow_errors(early_exit),
            )

        swallowed_live = workflow.replace(
            f"        run: {live_command}\n",
            f"        run: {live_command} || true\n",
            1,
        )
        self.assertNotEqual(swallowed_live, workflow)
        with self.subTest(gate="swallowed live failure"):
            self.assertIn(
                f"T29 wire workflow command {live_command!r} must propagate shell "
                "failure",
                t29_wire_workflow_errors(swallowed_live),
            )

    def test_verify_cannot_read_or_escape_into_ignored_build_evidence(self) -> None:
        workflow = read(".github/workflows/verify.yml")
        ignored_from_app = workflow.replace(
            "      - name: Install locked Flutter dependencies",
            "      - name: Read ignored evidence\n"
            "        working-directory: app\n"
            "        run: cat ../build/t29/live.log\n"
            "      - name: Install locked Flutter dependencies",
            1,
        )
        self.assertNotEqual(ignored_from_app, workflow)
        with self.subTest(gate="run from app"):
            self.assertIn(
                "hosted Verify workflow must not consume ignored build/ evidence",
                voice_ci_errors(ignored_from_app),
            )

        escaped_directory = workflow.replace(
            "      - name: Test T29 voice consent, capture and revocation behavior\n"
            "        working-directory: app",
            "      - name: Test T29 voice consent, capture and revocation behavior\n"
            "        working-directory: app/../build/t29",
            1,
        )
        self.assertNotEqual(escaped_directory, workflow)
        with self.subTest(gate="working-directory"):
            self.assertIn(
                "hosted Verify workflow must not consume ignored build/ evidence",
                voice_ci_errors(escaped_directory),
            )

    def test_historical_attribution_uses_a_structured_evidence_record(self) -> None:
        evidence = ROOT / "docs/compliance/t29-historical-evidence.json"
        self.assertTrue(evidence.is_file(), evidence)
        record = load_historical_evidence(evidence)
        self.assertIsInstance(record, Mapping)
        assert record is not None

        t29 = read("docs/tasks/T29.md")
        t33 = read("docs/tasks/T33.md")
        mutations = (
            ("versions", "run_tree", "0" * 40, "versions.run_tree"),
            (
                "versions",
                "workflow_path",
                ".github/workflows/verify.yml",
                "versions.workflow_path",
            ),
            ("versions", "workflow_status", "same", "versions.workflow_status"),
            ("execution", "ci_status", "passed", "execution.ci_status"),
            ("scope", "current_tree", True, "scope.current_tree"),
        )
        for section, key, value, field in mutations:
            altered = copy.deepcopy(record)
            nested = altered[section]
            self.assertIsInstance(nested, dict)
            nested[key] = value
            errors = t29_live_evidence_errors(
                t29=t29,
                t33=t33,
                evidence=altered,
            )
            self.assertTrue(
                any(f"field {field} must be" in error for error in errors),
                (field, errors),
            )

    def test_t33_historical_claims_cannot_escape_the_recorded_scope(self) -> None:
        t29 = read("docs/tasks/T29.md")
        t33 = read("docs/tasks/T33.md")
        unsupported = t33 + "\n旧日志证明当前 CI／生产通过。\n"
        errors = t29_live_evidence_errors(t29=t29, t33=unsupported)
        self.assertTrue(
            any("historical evidence" in error for error in errors),
            errors,
        )

    def test_d18_inventory_records_server_voice_aggregation(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        row = next(
            line for line in inventory.splitlines() if line.startswith("| D18 |")
        )
        for prefix in ("| D17 |", "| D18 |", "| D19 |"):
            adjacent = next(
                line
                for line in inventory.splitlines()
                if line.startswith(prefix)
            )
            self.assertEqual(8, len(adjacent.strip("|").split("|")), prefix)
        cells = row.strip("|").split("|")
        self.assertIn("专用时间删除", cells[5])
        self.assertIn("`signal_baselines`", cells[5])
        self.assertNotIn("专用时间删除", cells[4])
        self.assertNotIn("专用时间删除", cells[6])
        for needle in (
            "健康/语音 30 秒聚合窗口",
            "`signal_windows.stats_enc`",
            "`channel` 为 `health` 或 `voice`",
            "服务端读取并解密",
            "`speech_rate`",
            "`volume`",
            "`pitch`",
            "基线与参考计算",
            "仅含统计值",
            "不含 PCM、录音、逐秒数组或转写",
            "180 天",
            "PurgeDue",
            "隐私删除协调器",
            "DELETE /v1/signal-windows",
            "`channel=health` 或 `channel=voice`",
            "精确 30 秒 `starts_at`",
            "专用时间删除",
            "当前账号",
            "不波及相邻窗口或其他账号",
            "`signal_baselines` 物化结果",
            "删除会使该账号的 `signal_baselines` 物化结果失效并清除",
            "由存活窗口重新计算",
            "客户端撤回 `voice` 或 `audio_retention` 不会自动删除全部既有服务端窗口",
            "该能力不等于通用删除入口已接线",
            "通用单条删除仍未接线",
            "本机录音 `3 天` 到期属 D44",
            "正式语音留存政策仍待确认",
            "不新增历史表计数",
        ):
            self.assertIn(needle, row)
        self.assertNotIn("健康窗口专用删除已接线", row)
        self.assertIn("D01–D45", inventory)


class ConsentAndSourceRegisterContract(unittest.TestCase):
    def test_c05_is_an_actionable_microphone_prompt_draft(self) -> None:
        text = read("docs/compliance/separate-consents.md")
        section = re.search(r"### C05 .*?(?=\n### C06)", text, re.S)
        self.assertIsNotNone(section)
        c05 = section.group(0)
        required = (
            r"必要性",
            r"(?:触发时机|申请.*前|开启.*前)",
            r"本机",
            r"30 秒聚合",
            r"(?:不上传|不会上传).*(?:音频|转写)",
            r"混入他人",
            r"(?:拒绝|撤回).*(?:后果|影响|停止)",
            re.escape("T29 归档静态实现、未合入固定基线、真机待验"),
        )
        for pattern in required:
            self.assertRegex(c05, pattern)

    def test_official_source_register_contains_verified_primary_evidence(self) -> None:
        register = read("docs/compliance/official-source-register.md")
        self.assertNotRegex(register, r"(?:9 个|九个).*(?:DNS|HTTP|不可达|未取得)")
        self.assertNotRegex(register, r"全部.*(?:DNS|未取得正文)")
        for url in (
            "https://www.cac.gov.cn/2021-08/20/c_1631050028355286.htm",
            "https://www.cac.gov.cn/2023-07/13/c_1690898327029107.htm",
            "https://developer.apple.com/app-store/review/guidelines/",
            "https://developer.android.com/health-and-fitness/health-connect/get-started",
            "https://www.gov.cn/zhengce/zhengceku/202308/content_6897341.htm",
        ):
            self.assertIn(url, register)
        self.assertIn(
            "50b62bb9868648fe0417d8757a8cff62641eba6d879403f363d771f8c6d3acff",
            register,
        )
        self.assertIn(
            "7fae988c064dde72c95e96e5727bf9abee4b3a5a1ea817606a9ca1f97ffac54b",
            register,
        )
        self.assertRegex(register, r"已读取官方正文")
        self.assertRegex(register, r"律师.*适用性")


if __name__ == "__main__":
    unittest.main(verbosity=2)
