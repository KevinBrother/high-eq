"""Executable source gates for native microphone permission callbacks.

The contract intentionally stays inside the standard library.  It reads the
small Kotlin/Swift shapes used by ``MainActivity``, ``AppDelegate`` and the two
``VoiceCapture`` implementations, then exposes a synthetic state machine for
grant, denial, retry and wrong-request-code callbacks.  This is source-level
evidence, not a substitute for a signed device build or an OS permission test.
"""

from __future__ import annotations

import ast
import re
from dataclasses import dataclass
from typing import Mapping

try:
    from .t33_contract_support import ios_runner_source_files
except ImportError:  # pragma: no cover - direct discovery from docs/compliance.
    from t33_contract_support import ios_runner_source_files  # type: ignore[no-redef]

ANDROID_CAPTURE_PATH = (
    "app/android/app/src/main/kotlin/cn/higheq/high_eq/VoiceCapture.kt"
)
IOS_CAPTURE_PATH = "app/ios/Runner/VoiceCapture.swift"
APP_DELEGATE_SOURCE = "Runner/AppDelegate.swift"


@dataclass(frozen=True)
class PermissionFlow:
    """Source-derived facts used by the synthetic callback state machine."""

    platform: str
    request_code: int
    platform_request_code: int | None
    entry_delegates_matching_request: bool
    rejects_other_request_codes: bool
    saves_pending_result: bool
    clears_pending_result: bool
    result_for_granted: bool | None
    result_for_denied: bool | None
    channel_installed: bool
    sources_member: bool = True
    request_dispatched: bool = True
    capture_channel_installed: bool = True
    preserves_first_request: bool = True


class SyntheticPermissionFlow:
    """Drive a source-derived flow with platform callbacks, never real audio."""

    def __init__(self, evidence: PermissionFlow):
        self.evidence = evidence
        self._pending = False

    def request(self) -> None:
        self._pending = (
            self.evidence.preserves_first_request
            and self.evidence.request_dispatched
            and self.evidence.capture_channel_installed
            and self.evidence.saves_pending_result
        )

    def complete(self, request_code: int, granted: bool) -> bool | None:
        if not self._pending:
            return None
        matches_request = request_code == self.evidence.request_code
        if not matches_request and self.evidence.rejects_other_request_codes:
            return None
        if matches_request and not self.evidence.entry_delegates_matching_request:
            return None
        if self.evidence.clears_pending_result:
            self._pending = False
        return (
            self.evidence.result_for_granted
            if granted
            else self.evidence.result_for_denied
        )


def _strip_kotlin_comments(source: str) -> str:
    without_blocks = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", without_blocks)


def _strip_swift_comments(source: str) -> str:
    # Swift permits nested block comments.  The native files do not currently
    # nest them, but a small loop avoids accepting a commented-out gate merely
    # because it contains an inner closing marker.
    previous = None
    while source != previous:
        previous = source
        source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", source)


def _strip_dart_comments(source: str) -> str:
    without_blocks = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", without_blocks)


def _dart_control_channel_name(source: str) -> str | None:
    match = re.search(
        r"static\s+const\s+controlChannel\s*=\s*MethodChannel\s*\(\s*"
        r"['\"]([^'\"]+)['\"]",
        _strip_dart_comments(source),
    )
    return match.group(1) if match else None


def _kotlin_control_channel_name(source: str) -> str | None:
    match = re.search(
        r'\bconst\s+val\s+CONTROL_CHANNEL\s*=\s*"([^"]+)"',
        _strip_kotlin_comments(source),
    )
    return match.group(1) if match else None


def _swift_control_channel_name(source: str) -> str | None:
    match = re.search(
        r'\bstatic\s+let\s+controlChannelName\s*=\s*"([^"]+)"',
        _strip_swift_comments(source),
    )
    return match.group(1) if match else None


def _braced_body(source: str, declaration: re.Pattern[str]) -> str | None:
    match = declaration.search(source)
    if match is None:
        return None
    start = source.find("{", match.end() - 1)
    if start < 0:
        return None
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1 : index]
    return None


def _line_statement_spans(body: str, pattern: re.Pattern[str]) -> list[tuple[int, int]]:
    """Find reachable statements starting at brace depth zero."""
    spans: list[tuple[int, int]] = []
    depth = 0
    offset = 0
    for line in body.splitlines(keepends=True):
        stripped = line.strip()
        if depth == 0 and re.match(r"^(?:return|throw)\b", stripped):
            break
        if depth == 0 and stripped and pattern.search(stripped):
            spans.append((offset, offset + len(line)))
        depth = max(0, depth + line.count("{") - line.count("}"))
        offset += len(line)
    return spans


def _top_level_has(body: str, pattern: re.Pattern[str]) -> bool:
    return bool(_line_statement_spans(body, pattern))


def _has_literal_false_condition(source: str) -> bool:
    return bool(re.search(r"\bif\s*(?:\(\s*false\s*\)|false)\s*\{", source))


def _call_arguments(source: str, call: re.Pattern[str]) -> tuple[re.Match[str], str] | None:
    match = call.search(source)
    if match is None:
        return None
    start = source.find("(", match.start())
    if start < 0:
        return None
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                return match, source[start + 1 : index]
    return None


def _split_arguments(arguments: str) -> list[str]:
    pieces: list[str] = []
    depth = 0
    start = 0
    for index, character in enumerate(arguments):
        if character in "([{<":
            depth += 1
        elif character in ")]}>":
            depth = max(0, depth - 1)
        elif character == "," and depth == 0:
            pieces.append(arguments[start:index].strip())
            start = index + 1
    tail = arguments[start:].strip()
    if tail:
        pieces.append(tail)
    return pieces


def _resolve_request_code(value: str, constant: int | None) -> int | None:
    value = value.strip()
    if value.isdigit():
        return int(value)
    if value in ("PERMISSION_REQUEST", "VoiceCapture.PERMISSION_REQUEST"):
        return constant
    return None


def _condition_true_for_request_code(
    condition: str, request_code: int, expected_code: int
) -> bool:
    normalized = condition.replace(
        "VoiceCapture.PERMISSION_REQUEST", str(expected_code)
    ).replace("PERMISSION_REQUEST", str(expected_code))
    match = re.fullmatch(r"\s*requestCode\s*(==|!=)\s*(\d+)\s*", normalized)
    if match is None:
        # An unparsed request-code branch that exits is not safe evidence.
        return "requestCode" in normalized
    value = int(match.group(2))
    return request_code == value if match.group(1) == "==" else request_code != value


def _android_permission_code(capture: str) -> int | None:
    match = re.search(
        r"\bconst\s+val\s+PERMISSION_REQUEST\s*=\s*(\d+)\b",
        _strip_kotlin_comments(capture),
    )
    return int(match.group(1)) if match else None


def _android_entry_flow(
    entry: str, request_code: int
) -> tuple[bool, bool, bool]:
    clean = _strip_kotlin_comments(entry)
    callback = _braced_body(
        clean,
        re.compile(r"override\s+fun\s+onRequestPermissionsResult\s*\([^)]*\)"),
    )
    if callback is None:
        return False, False, False
    delegate = re.compile(
        r"voiceCapture\s*\.\s*handlePermissionResult\s*\(\s*requestCode\s*,"
        r"\s*permissions\s*,\s*grantResults\s*\)"
    )
    delegates = _top_level_has(callback, delegate)
    delegate_match = delegate.search(callback)
    early_return = False
    if delegate_match is not None:
        prefix = callback[: delegate_match.start()]
        pattern = re.compile(
            r"if\s*\(([^)]*requestCode[^)]*)\)\s*\{?\s*return\b", re.S
        )
        early_return = any(
            _condition_true_for_request_code(match.group(1), request_code, request_code)
            for match in pattern.finditer(prefix)
        )

    configure = _braced_body(
        clean,
        re.compile(r"override\s+fun\s+configureFlutterEngine\s*\([^)]*\)"),
    )
    channel_installed = False
    if configure is not None:
        channel_installed = (
            _top_level_has(configure, re.compile(r"VoiceCapture\s*\(\s*this\s*\)"))
            and _top_level_has(
                configure, re.compile(r"voiceCapture\s*\.\s*install\s*\(")
            )
        )
    return delegates and not early_return, early_return, channel_installed


def _android_grant_expression(
    handler: str,
) -> tuple[str | None, bool | None, bool | None]:
    result_call = _call_arguments(
        handler, re.compile(r"\bpending\s*\.\s*success\s*\(")
    )
    if result_call is None:
        return None, None, None
    expression = result_call[1].strip().rstrip(",")
    normalized = expression.replace(
        "PackageManager.PERMISSION_GRANTED", "0"
    ).replace("grantResults.isNotEmpty()", "bool(grantResults)")
    normalized = normalized.replace("&&", " and ").replace("||", " or ")
    try:
        tree = ast.parse(f"({normalized})", mode="eval")
    except SyntaxError:
        return expression, None, None
    allowed = (
        ast.Expression,
        ast.BoolOp,
        ast.And,
        ast.Or,
        ast.Compare,
        ast.Eq,
        ast.NotEq,
        ast.Subscript,
        ast.Name,
        ast.Call,
        ast.Load,
        ast.Constant,
    )
    if any(not isinstance(node, allowed) for node in ast.walk(tree)):
        return expression, None, None
    try:
        granted = bool(
            eval(  # noqa: S307 - AST shape is allow-listed above.
                compile(tree, "<android-grant-expression>", "eval"),
                {"__builtins__": {}, "bool": bool},
                {"grantResults": [0]},
            )
        )
        denied = bool(
            eval(  # noqa: S307 - AST shape is allow-listed above.
                compile(tree, "<android-grant-expression>", "eval"),
                {"__builtins__": {}, "bool": bool},
                {"grantResults": [1]},
            )
        )
    except (NameError, IndexError, TypeError):
        return expression, None, None
    return expression, granted, denied


def android_permission_flow(entry: str, capture: str) -> PermissionFlow:
    clean_capture = _strip_kotlin_comments(capture)
    request_code = _android_permission_code(clean_capture)
    entry_ok, early_return, channel_installed = _android_entry_flow(
        entry, request_code or -1
    )
    method_call = _braced_body(
        clean_capture,
        re.compile(r"override\s+fun\s+onMethodCall\s*\([^)]*\)"),
    ) or ""
    install_body = _braced_body(
        clean_capture, re.compile(r"fun\s+install\s*\([^)]*\)")
    ) or ""
    capture_channel_installed = _top_level_has(
        install_body,
        re.compile(
            r"MethodChannel\s*\([^)]*\)\s*\.\s*"
            r"setMethodCallHandler\s*\(\s*this\s*\)"
        ),
    )
    request_dispatched = bool(
        re.search(
            r'["\']requestPermission["\']\s*->\s*'
            r"requestPermission\s*\(\s*result\s*\)",
            method_call,
        )
        and not _has_literal_false_condition(method_call)
    )

    request_body = _braced_body(
        clean_capture, re.compile(r"fun\s+requestPermission\s*\([^)]*\)")
    ) or ""
    positive_pending_guard = re.compile(
        r"if\s*\(\s*pendingPermission\s*!=\s*null\s*\)\s*\{"
    )
    reversed_pending_guard = re.compile(
        r"if\s*\(\s*pendingPermission\s*==\s*null\s*\)\s*\{"
    )
    preserves_first_request = bool(
        _line_statement_spans(request_body, positive_pending_guard)
    ) and not bool(_line_statement_spans(request_body, reversed_pending_guard))
    save_spans = _line_statement_spans(
        request_body, re.compile(r"pendingPermission\s*=\s*result\b")
    )
    request_pattern = re.compile(r"activity\s*\.\s*requestPermissions\s*\(")
    request_call_spans = _line_statement_spans(request_body, request_pattern)
    request_call = _call_arguments(
        request_body, request_pattern
    ) if request_call_spans else None
    platform_request_code = None
    request_uses_audio_permission = False
    if request_call is not None:
        arguments = _split_arguments(request_call[1])
        request_uses_audio_permission = bool(
            arguments and "Manifest.permission.RECORD_AUDIO" in arguments[0]
        )
        if len(arguments) > 1:
            platform_request_code = _resolve_request_code(arguments[1], request_code)
    saves_pending = bool(
        save_spans
        and request_call is not None
        and save_spans[0][0] < request_call[0].start()
    )

    handler = _braced_body(
        clean_capture, re.compile(r"fun\s+handlePermissionResult\s*\([^)]*\)")
    ) or ""
    guard_pattern = re.compile(
        r"if\s*\(([^)]*requestCode[^)]*)\)\s*\{?\s*return\b", re.S
    )
    guard_spans = _line_statement_spans(handler, guard_pattern)
    guard_match = (
        guard_pattern.search(handler, *guard_spans[0]) if guard_spans else None
    )
    pending_pattern = re.compile(
        r"val\s+pending\s*=\s*pendingPermission\s*\?:\s*return"
    )
    pending_spans = _line_statement_spans(handler, pending_pattern)
    has_pending_result = bool(pending_spans)
    rejects_other = bool(
        guard_match
        and request_code is not None
        and pending_spans
        and guard_spans[0][0] < pending_spans[0][0]
        and _condition_true_for_request_code(
            guard_match.group(1), request_code + 1, request_code
        )
    )
    clear_spans = _line_statement_spans(
        handler, re.compile(r"pendingPermission\s*=\s*null\b")
    )
    result_spans = _line_statement_spans(
        handler, re.compile(r"pending\s*\.\s*success\s*\(")
    )
    clears_pending = bool(
        has_pending_result
        and clear_spans
        and result_spans
        and clear_spans[0][0] < result_spans[0][0]
    )
    _, granted, denied = _android_grant_expression(handler)

    return PermissionFlow(
        platform="android",
        request_code=request_code or -1,
        platform_request_code=platform_request_code,
        entry_delegates_matching_request=entry_ok
        and not early_return
        and request_uses_audio_permission,
        rejects_other_request_codes=rejects_other,
        saves_pending_result=saves_pending,
        clears_pending_result=clears_pending,
        result_for_granted=granted,
        result_for_denied=denied,
        channel_installed=channel_installed,
        request_dispatched=request_dispatched,
        capture_channel_installed=capture_channel_installed,
        preserves_first_request=preserves_first_request,
    )


def android_permission_behavior_errors(
    entry: str, capture: str, *, dart_platform: str = ""
) -> list[str]:
    flow = android_permission_flow(entry, capture)
    errors: list[str] = []
    if flow.request_code < 0:
        errors.append("Android VoiceCapture does not declare the microphone request code")
    if not flow.channel_installed:
        errors.append("Android MainActivity does not install the VoiceCapture channel")
    if not flow.capture_channel_installed:
        errors.append(
            "Android VoiceCapture does not attach the control channel handler"
        )
    if not flow.request_dispatched:
        errors.append(
            "Android VoiceCapture does not route requestPermission to the "
            "microphone permission request"
        )
    if not flow.entry_delegates_matching_request:
        if _android_entry_early_returns_for_matching_request(entry, capture):
            errors.append(
                "Android MainActivity can return before delegating the matching "
                "microphone permission request"
            )
        else:
            errors.append(
                "Android MainActivity does not delegate microphone permission results"
            )
    if flow.saves_pending_result is False:
        errors.append(
            "Android VoiceCapture does not save the pending Flutter permission result"
        )
    if not flow.preserves_first_request:
        errors.append(
            "Android VoiceCapture does not preserve the first microphone request"
        )
    if flow.platform_request_code != flow.request_code:
        errors.append(
            "Android VoiceCapture does not request microphone permission with the "
            "callback request code"
        )
    if not flow.rejects_other_request_codes:
        errors.append(
            "Android VoiceCapture does not reject unrelated permission callback "
            "codes before consuming the pending result"
        )
    if not flow.clears_pending_result:
        errors.append(
            "Android VoiceCapture does not consume and clear the pending Flutter "
            "permission result"
        )
    if flow.result_for_granted is not True or flow.result_for_denied is not False:
        errors.append(
            "Android VoiceCapture does not complete the pending Flutter result from "
            "the platform grant result"
        )
    if dart_platform:
        dart_channel = _dart_control_channel_name(dart_platform)
        if (
            dart_channel is None
            or _kotlin_control_channel_name(capture) != dart_channel
        ):
            errors.append(
                "Android VoiceCapture control channel name does not match "
                "Flutter platform.dart"
            )
    return errors


def _android_entry_early_returns_for_matching_request(entry: str, capture: str) -> bool:
    request_code = _android_permission_code(capture)
    if request_code is None:
        return False
    clean = _strip_kotlin_comments(entry)
    callback = _braced_body(
        clean,
        re.compile(r"override\s+fun\s+onRequestPermissionsResult\s*\([^)]*\)"),
    )
    if callback is None:
        return False
    delegate = re.search(r"voiceCapture\s*\.\s*handlePermissionResult\s*\(", callback)
    if delegate is None:
        return False
    prefix = callback[: delegate.start()]
    return any(
        _condition_true_for_request_code(match.group(1), request_code, request_code)
        for match in re.finditer(
            r"if\s*\(([^)]*requestCode[^)]*)\)\s*\{?\s*return\b", prefix, re.S
        )
    )


def _swift_function_body(source: str, name: str) -> str | None:
    return _braced_body(
        source, re.compile(rf"\bfunc\s+{re.escape(name)}\s*\([^)]*\)")
    )


def _ios_channel_installed(entry: str) -> bool:
    clean = _strip_swift_comments(entry)
    capture_property = re.search(
        r"\bprivate\s+let\s+voiceCapture\s*=\s*VoiceCapture\s*\(\s*\)", clean
    )
    launch = _braced_body(
        clean,
        re.compile(
            r"override\s+func\s+application\s*\([^)]*"
            r"didFinishLaunchingWithOptions[^)]*\)[^{]*"
        ),
    )
    if capture_property is None or launch is None:
        return False
    registrar_pattern = re.compile(
        r"if\s+let\s+registrar\s*=\s*registrar\s*\(\s*"
        r"forPlugin:\s*\"VoiceCapture\"\s*\)"
    )
    if not _line_statement_spans(launch, registrar_pattern):
        return False
    registrar = _braced_body(
        launch,
        registrar_pattern,
    )
    if registrar is None or not _top_level_has(
        registrar,
        re.compile(r"voiceCapture\s*\.\s*install\s*\(\s*messenger:"),
    ):
        return False
    return True


def _ios_capture_install(clean_capture: str) -> bool:
    install = _swift_function_body(clean_capture, "install") or ""
    return all(
        (
            _top_level_has(
                install,
                re.compile(r"let\s+control\s*=\s*FlutterMethodChannel\s*\("),
            ),
            "name: Self.controlChannelName" in install,
            _top_level_has(
                install, re.compile(r"control\s*\.\s*setMethodCallHandler\s*\(")
            ),
            _top_level_has(
                install,
                re.compile(r"let\s+events\s*=\s*FlutterEventChannel\s*\("),
            ),
            "name: Self.pcmChannelName" in install,
            _top_level_has(
                install, re.compile(r"events\s*\.\s*setStreamHandler\s*\(")
            ),
        )
    )


def ios_permission_flow(entry: str, capture: str, project: str) -> PermissionFlow:
    clean_capture = _strip_swift_comments(capture)
    channel_installed = _ios_channel_installed(entry) and _ios_capture_install(
        clean_capture
    )

    handle = _swift_function_body(clean_capture, "handle") or ""
    request_route = bool(
        re.search(
            r'case\s+"requestPermission"\s*:\s*requestRecordPermission\s*\(\s*result\s*\)',
            handle,
        )
    )
    request = _swift_function_body(clean_capture, "requestRecordPermission") or ""
    positive_pending_guard = re.compile(
        r"if\s+pendingPermission\s*!=\s*nil\s*\{"
    )
    reversed_pending_guard = re.compile(
        r"if\s+pendingPermission\s*==\s*nil\s*\{"
    )
    preserves_first_request = bool(
        _line_statement_spans(request, positive_pending_guard)
    ) and not bool(_line_statement_spans(request, reversed_pending_guard))
    save_spans = _line_statement_spans(
        request, re.compile(r"pendingPermission\s*=\s*result\b")
    )
    platform_requests = bool(
        re.search(r"AVAudioApplication\s*\.\s*requestRecordPermission\s*\{", request)
        and re.search(
            r"AVAudioSession\s*\.\s*sharedInstance\s*\(\s*\)\s*\.\s*"
            r"requestRecordPermission\s*\{",
            request,
        )
        and not _has_literal_false_condition(request)
    )
    saves_pending = bool(
        save_spans
        and platform_requests
        and save_spans[0][0] < request.find("requestRecordPermission", save_spans[0][1])
    )
    callback_paths = len(re.findall(r"finishPermission\s*\(\s*granted\s*\)", request))

    finish = _swift_function_body(clean_capture, "finishPermission") or ""
    clear_spans = _line_statement_spans(
        finish, re.compile(r"pendingPermission\s*=\s*nil\b")
    )
    result_spans = _line_statement_spans(
        finish, re.compile(r"result\s*\(\s*granted\s*\)")
    )
    clears_pending = bool(
        clear_spans and result_spans and clear_spans[0][0] < result_spans[0][0]
    )
    returns_granted = bool(result_spans)

    sources_member = APP_DELEGATE_SOURCE in ios_runner_source_files(project)

    return PermissionFlow(
        platform="ios",
        request_code=0,
        platform_request_code=0 if platform_requests else None,
        entry_delegates_matching_request=channel_installed
        and request_route
        and callback_paths == 2,
        rejects_other_request_codes=True,
        saves_pending_result=saves_pending,
        clears_pending_result=clears_pending,
        result_for_granted=True if returns_granted else None,
        result_for_denied=False if returns_granted else None,
        channel_installed=channel_installed,
        sources_member=sources_member,
        preserves_first_request=preserves_first_request,
    )


def ios_permission_behavior_errors(
    entry: str, capture: str, project: str, *, dart_platform: str = ""
) -> list[str]:
    flow = ios_permission_flow(entry, capture, project)
    clean_capture = _strip_swift_comments(capture)
    request = _swift_function_body(clean_capture, "requestRecordPermission") or ""
    finish = _swift_function_body(clean_capture, "finishPermission") or ""
    errors: list[str] = []
    if not flow.sources_member:
        errors.append("iOS Runner Sources does not compile AppDelegate.swift")
    if not flow.channel_installed:
        errors.append("iOS AppDelegate does not install the VoiceCapture channel")
    if not flow.saves_pending_result:
        errors.append(
            "iOS VoiceCapture does not save the pending Flutter permission result"
        )
    if not flow.preserves_first_request:
        errors.append(
            "iOS VoiceCapture does not preserve the first microphone request"
        )
    if flow.platform_request_code is None:
        errors.append(
            "iOS VoiceCapture does not request microphone permission through both "
            "platform callback paths"
        )
    if len(re.findall(r"finishPermission\s*\(\s*granted\s*\)", request)) != 2:
        errors.append(
            "iOS VoiceCapture does not route both record-permission callbacks to "
            "the Flutter result"
        )
    if not flow.clears_pending_result:
        errors.append(
            "iOS VoiceCapture does not consume and clear the pending Flutter result"
        )
    if flow.result_for_granted is not True or not re.search(
        r"result\s*\(\s*granted\s*\)", finish
    ):
        errors.append(
            "iOS VoiceCapture does not complete the pending Flutter result with "
            "result(granted)"
        )
    if dart_platform:
        dart_channel = _dart_control_channel_name(dart_platform)
        if (
            dart_channel is None
            or _swift_control_channel_name(capture) != dart_channel
        ):
            errors.append(
                "iOS VoiceCapture control channel name does not match "
                "Flutter platform.dart"
            )
    return errors


def native_permission_behavior_errors(
    *,
    android_entry: str,
    android_capture: str,
    ios_entry: str,
    ios_capture: str,
    ios_project: str,
    native_sources: Mapping[str, str],
    dart_platform: str = "",
) -> list[str]:
    """Combined gate used by the main T33 contract."""
    errors = android_permission_behavior_errors(
        android_entry,
        native_sources.get(ANDROID_CAPTURE_PATH, android_capture),
        dart_platform=dart_platform,
    )
    errors.extend(
        ios_permission_behavior_errors(
            ios_entry,
            native_sources.get(IOS_CAPTURE_PATH, ios_capture),
            ios_project,
            dart_platform=dart_platform,
        )
    )
    return errors
