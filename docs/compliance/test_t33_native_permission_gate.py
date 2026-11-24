#!/usr/bin/env python3
"""T33 executable source gates for the native microphone callback path."""

from __future__ import annotations

import unittest
from pathlib import Path

try:  # Supports `python -m unittest` and direct discovery from this directory.
    from .native_permission_gate import (
        PermissionFlow,
        SyntheticPermissionFlow,
        android_permission_behavior_errors,
        android_permission_flow,
        ios_permission_behavior_errors,
        ios_permission_flow,
    )
except ImportError:  # pragma: no cover - exercised by the documented CLI form.
    from native_permission_gate import (  # type: ignore[no-redef]
        PermissionFlow,
        SyntheticPermissionFlow,
        android_permission_behavior_errors,
        android_permission_flow,
        ios_permission_behavior_errors,
        ios_permission_flow,
    )

ROOT = Path(__file__).resolve().parents[2]

ANDROID_ENTRY = "app/android/app/src/main/kotlin/cn/higheq/high_eq/MainActivity.kt"
ANDROID_CAPTURE = (
    "app/android/app/src/main/kotlin/cn/higheq/high_eq/VoiceCapture.kt"
)
IOS_ENTRY = "app/ios/Runner/AppDelegate.swift"
IOS_CAPTURE = "app/ios/Runner/VoiceCapture.swift"
IOS_PROJECT = "app/ios/Runner.xcodeproj/project.pbxproj"
DART_PLATFORM = "app/lib/features/voice/platform.dart"


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class NativePermissionBehaviorGateContract(unittest.TestCase):
    def test_android_synthetic_callbacks_cover_denial_reprompt_and_wrong_code(self) -> None:
        flow = android_permission_flow(read(ANDROID_ENTRY), read(ANDROID_CAPTURE))
        self.assertIsInstance(flow, PermissionFlow)
        self.assertEqual(android_permission_behavior_errors(
            read(ANDROID_ENTRY), read(ANDROID_CAPTURE)
        ), [])

        synthetic = SyntheticPermissionFlow(flow)
        synthetic.request()
        self.assertIsNone(synthetic.complete(flow.request_code + 1, True))
        self.assertFalse(synthetic.complete(flow.request_code, False))
        self.assertIsNone(synthetic.complete(flow.request_code, True))

        synthetic.request()
        self.assertTrue(synthetic.complete(flow.request_code, True))

    def test_android_gate_rejects_early_return_for_matching_request_code(self) -> None:
        entry = read(ANDROID_ENTRY)
        delegate = (
            "        voiceCapture.handlePermissionResult(requestCode, permissions, grantResults)\n"
        )
        self.assertIn(delegate, entry)
        mutated = entry.replace(
            delegate,
            "        if (requestCode == VoiceCapture.PERMISSION_REQUEST) return\n" + delegate,
            1,
        )
        self.assertIn(
            "Android MainActivity can return before delegating the matching "
            "microphone permission request",
            android_permission_behavior_errors(mutated, read(ANDROID_CAPTURE)),
        )

    def test_android_gate_rejects_unreachable_permission_delegation(self) -> None:
        entry = read(ANDROID_ENTRY)
        delegate = (
            "        voiceCapture.handlePermissionResult(requestCode, permissions, grantResults)\n"
        )
        self.assertIn(delegate, entry)
        mutated = entry.replace(delegate, "        return\n" + delegate, 1)
        self.assertIn(
            "Android MainActivity does not delegate microphone permission results",
            android_permission_behavior_errors(mutated, read(ANDROID_CAPTURE)),
        )

    def test_android_gate_rejects_missing_pending_flutter_result(self) -> None:
        capture = read(ANDROID_CAPTURE)
        assignment = "        pendingPermission = result\n"
        self.assertIn(assignment, capture)
        mutated = capture.replace(assignment, "", 1)
        self.assertIn(
            "Android VoiceCapture does not save the pending Flutter permission result",
            android_permission_behavior_errors(read(ANDROID_ENTRY), mutated),
        )

    def test_android_gate_rejects_unreachable_pending_flutter_result(self) -> None:
        capture = read(ANDROID_CAPTURE)
        assignment = "        pendingPermission = result\n"
        self.assertIn(assignment, capture)
        mutated = capture.replace(
            assignment, "        return\n" + assignment, 1
        )
        self.assertIn(
            "Android VoiceCapture does not save the pending Flutter permission result",
            android_permission_behavior_errors(read(ANDROID_ENTRY), mutated),
        )

    def test_android_gate_rejects_reversed_pending_condition(self) -> None:
        capture = read(ANDROID_CAPTURE)
        guard = "        if (pendingPermission != null) {\n"
        self.assertIn(guard, capture)
        mutated = capture.replace(
            guard, "        if (pendingPermission == null) {\n", 1
        )
        errors = android_permission_behavior_errors(
            read(ANDROID_ENTRY), mutated
        )
        self.assertIn(
            "Android VoiceCapture does not preserve the first microphone request",
            errors,
        )
        synthetic = SyntheticPermissionFlow(
            android_permission_flow(read(ANDROID_ENTRY), mutated)
        )
        synthetic.request()
        self.assertIsNone(synthetic.complete(synthetic.evidence.request_code, True))

    def test_android_gate_rejects_control_channel_name_drift(self) -> None:
        capture = read(ANDROID_CAPTURE)
        channel = 'const val CONTROL_CHANNEL = "cn.higheq/voice-capture"\n'
        self.assertIn(channel, capture)
        mutated = capture.replace(
            channel,
            'const val CONTROL_CHANNEL = "cn.higheq/voice-capture-drift"\n',
            1,
        )
        self.assertIn(
            "Android VoiceCapture control channel name does not match "
            "Flutter platform.dart",
            android_permission_behavior_errors(
                read(ANDROID_ENTRY),
                mutated,
                dart_platform=read(DART_PLATFORM),
            ),
        )

    def test_android_gate_rejects_hidden_platform_permission_request(self) -> None:
        capture = read(ANDROID_CAPTURE)
        request = (
            "        activity.requestPermissions(\n"
            "            arrayOf(Manifest.permission.RECORD_AUDIO),\n"
            "            PERMISSION_REQUEST,\n"
            "        )\n"
        )
        self.assertIn(request, capture)
        mutated = capture.replace(
            request, "        if (false) {\n" + request + "        }\n", 1
        )
        self.assertIn(
            "Android VoiceCapture does not request microphone permission with the "
            "callback request code",
            android_permission_behavior_errors(read(ANDROID_ENTRY), mutated),
        )

    def test_android_gate_rejects_late_wrong_code_guard(self) -> None:
        capture = read(ANDROID_CAPTURE)
        guard = "        if (requestCode != PERMISSION_REQUEST) return\n"
        result = (
            "        pending.success(\n"
            "            grantResults.isNotEmpty() &&\n"
            "                grantResults[0] == PackageManager.PERMISSION_GRANTED,\n"
            "        )\n"
        )
        self.assertIn(guard, capture)
        self.assertIn(result, capture)
        mutated = capture.replace(guard, "", 1).replace(result, result + guard, 1)
        self.assertIn(
            "Android VoiceCapture does not reject unrelated permission callback "
            "codes before consuming the pending result",
            android_permission_behavior_errors(read(ANDROID_ENTRY), mutated),
        )

    def test_android_gate_rejects_missing_request_method_dispatch(self) -> None:
        capture = read(ANDROID_CAPTURE)
        dispatch = '            "requestPermission" -> requestPermission(result)\n'
        self.assertIn(dispatch, capture)
        mutated = capture.replace(dispatch, "", 1)
        self.assertIn(
            "Android VoiceCapture does not route requestPermission to the "
            "microphone permission request",
            android_permission_behavior_errors(read(ANDROID_ENTRY), mutated),
        )

    def test_android_gate_rejects_missing_control_channel_handler(self) -> None:
        capture = read(ANDROID_CAPTURE)
        handler = (
            "        MethodChannel(messenger, CONTROL_CHANNEL).setMethodCallHandler(this)\n"
        )
        self.assertIn(handler, capture)
        mutated = capture.replace(handler, "", 1)
        self.assertIn(
            "Android VoiceCapture does not attach the control channel handler",
            android_permission_behavior_errors(read(ANDROID_ENTRY), mutated),
        )

    def test_ios_synthetic_callbacks_cover_denial_reprompt_and_grant(self) -> None:
        flow = ios_permission_flow(
            read(IOS_ENTRY), read(IOS_CAPTURE), read(IOS_PROJECT)
        )
        self.assertIsInstance(flow, PermissionFlow)
        self.assertEqual(
            ios_permission_behavior_errors(
                read(IOS_ENTRY), read(IOS_CAPTURE), read(IOS_PROJECT)
            ),
            [],
        )

        synthetic = SyntheticPermissionFlow(flow)
        synthetic.request()
        self.assertIsNone(synthetic.complete(flow.request_code + 1, True))
        self.assertFalse(synthetic.complete(flow.request_code, False))
        self.assertIsNone(synthetic.complete(flow.request_code, True))

        synthetic.request()
        self.assertTrue(synthetic.complete(flow.request_code, True))

    def test_ios_gate_rejects_unreachable_channel_installation(self) -> None:
        entry = read(IOS_ENTRY)
        registrar = (
            '    if let registrar = registrar(forPlugin: "VoiceCapture") {\n'
        )
        self.assertIn(registrar, entry)
        mutated = entry.replace(registrar, "    return true\n" + registrar, 1)
        self.assertIn(
            "iOS AppDelegate does not install the VoiceCapture channel",
            ios_permission_behavior_errors(
                mutated, read(IOS_CAPTURE), read(IOS_PROJECT)
            ),
        )

    def test_ios_gate_rejects_control_channel_name_drift(self) -> None:
        capture = read(IOS_CAPTURE)
        channel = 'static let controlChannelName = "cn.higheq/voice-capture"\n'
        self.assertIn(channel, capture)
        mutated = capture.replace(
            channel,
            'static let controlChannelName = "cn.higheq/voice-capture-drift"\n',
            1,
        )
        self.assertIn(
            "iOS VoiceCapture control channel name does not match "
            "Flutter platform.dart",
            ios_permission_behavior_errors(
                read(IOS_ENTRY),
                mutated,
                read(IOS_PROJECT),
                dart_platform=read(DART_PLATFORM),
            ),
        )

    def test_ios_gate_rejects_reversed_pending_condition(self) -> None:
        capture = read(IOS_CAPTURE)
        guard = "    if pendingPermission != nil {\n"
        self.assertIn(guard, capture)
        mutated = capture.replace(
            guard, "    if pendingPermission == nil {\n", 1
        )
        errors = ios_permission_behavior_errors(
            read(IOS_ENTRY), mutated, read(IOS_PROJECT)
        )
        self.assertIn(
            "iOS VoiceCapture does not preserve the first microphone request",
            errors,
        )
        synthetic = SyntheticPermissionFlow(
            ios_permission_flow(
                read(IOS_ENTRY), mutated, read(IOS_PROJECT)
            )
        )
        synthetic.request()
        self.assertIsNone(synthetic.complete(synthetic.evidence.request_code, True))

    def test_ios_gate_rejects_hidden_platform_permission_request(self) -> None:
        capture = read(IOS_CAPTURE)
        request = (
            "    if #available(iOS 17.0, *) {\n"
            "      AVAudioApplication.requestRecordPermission { [weak self] granted in\n"
            "        DispatchQueue.main.async {\n"
            "          self?.finishPermission(granted)\n"
            "        }\n"
            "      }\n"
            "    } else {\n"
            "      AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in\n"
            "        DispatchQueue.main.async {\n"
            "          self?.finishPermission(granted)\n"
            "        }\n"
            "      }\n"
            "    }\n"
        )
        self.assertIn(request, capture)
        mutated = capture.replace(
            request, "    if false {\n" + request + "    }\n", 1
        )
        self.assertIn(
            "iOS VoiceCapture does not request microphone permission through both "
            "platform callback paths",
            ios_permission_behavior_errors(
                read(IOS_ENTRY), mutated, read(IOS_PROJECT)
            ),
        )

    def test_ios_gate_rejects_appdelegate_missing_from_runner_sources(self) -> None:
        project = read(IOS_PROJECT)
        build_entry = (
            "74858FAF1ED2DC5600515810 /* AppDelegate.swift in Sources */,"
        )
        self.assertIn(build_entry, project)
        mutated = project.replace(build_entry, "", 1)
        self.assertIn(
            "iOS Runner Sources does not compile AppDelegate.swift",
            ios_permission_behavior_errors(
                read(IOS_ENTRY), read(IOS_CAPTURE), mutated
            ),
        )

    def test_ios_gate_rejects_commented_channel_installation(self) -> None:
        entry = read(IOS_ENTRY)
        installation = "      voiceCapture.install(messenger: registrar.messenger())"
        self.assertIn(installation, entry)
        mutated = entry.replace(installation, "      // " + installation.strip(), 1)
        self.assertIn(
            "iOS AppDelegate does not install the VoiceCapture channel",
            ios_permission_behavior_errors(
                mutated, read(IOS_CAPTURE), read(IOS_PROJECT)
            ),
        )

    def test_ios_gate_rejects_missing_granted_flutter_result(self) -> None:
        capture = read(IOS_CAPTURE)
        result = "    result(granted)\n"
        self.assertIn(result, capture)
        mutated = capture.replace(result, "    // result(granted)\n", 1)
        self.assertIn(
            "iOS VoiceCapture does not complete the pending Flutter result "
            "with result(granted)",
            ios_permission_behavior_errors(
                read(IOS_ENTRY), mutated, read(IOS_PROJECT)
            ),
        )

    def test_ios_gate_rejects_unreachable_granted_flutter_result(self) -> None:
        capture = read(IOS_CAPTURE)
        finish = "  private func finishPermission(_ granted: Bool) {\n"
        self.assertIn(finish, capture)
        mutated = capture.replace(finish, finish + "    return\n", 1)
        errors = ios_permission_behavior_errors(
            read(IOS_ENTRY), mutated, read(IOS_PROJECT)
        )
        self.assertIn(
            "iOS VoiceCapture does not consume and clear the pending Flutter result",
            errors,
        )
        self.assertIn(
            "iOS VoiceCapture does not complete the pending Flutter result "
            "with result(granted)",
            errors,
        )


if __name__ == "__main__":
    unittest.main()
