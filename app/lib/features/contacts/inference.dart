import '../../core/transport.dart';

const profileInferenceSafetyMessage =
    '听起来你现在可能正经历很难受的事。这里不适合继续练习，建议你马上联系专业的人：全国心理援助热线 12356；如果有人身危险，请立即拨打 110 或 120。';

sealed class ProfileInferenceResult {
  const ProfileInferenceResult();
}

final class ProfileInferenceProcessing extends ProfileInferenceResult {
  const ProfileInferenceProcessing();
}

final class ProfileInferenceCompleted extends ProfileInferenceResult {
  const ProfileInferenceCompleted(this.profile);
  final Json profile;
}

final class ProfileInferenceSafety extends ProfileInferenceResult {
  const ProfileInferenceSafety();
}

final class ProfileInferenceTerminal extends ProfileInferenceResult {
  const ProfileInferenceTerminal(this.status);
  final int status;
}

bool _exact(Map<dynamic, dynamic> value, List<String> keys) =>
    value.length == keys.length && keys.every(value.containsKey);

bool _trait(Object? value) {
  if (value is! Json ||
      !_exact(value, ['label', 'confidence']) ||
      value['label'] is! String ||
      (value['label'] as String).trim().isEmpty) {
    return false;
  }
  final confidence = value['confidence'];
  return confidence is num &&
      confidence.isFinite &&
      confidence >= 0 &&
      confidence <= 1;
}

bool _profile(Json value) {
  if (!_exact(value, ['summary', 'big_five', 'conflict_style', 'attachment']) ||
      value['summary'] is! String) {
    return false;
  }
  final bigFive = value['big_five'];
  if (bigFive is! List || !bigFive.every(_trait)) return false;
  if (!_trait(value['conflict_style'])) return false;
  final attachment = value['attachment'];
  return attachment == null || _trait(attachment);
}

/// Decodes only the exact reply shapes in the profile inference contract.
///
/// A valid [Profile] proves completion. A 202 receipt proves only that the
/// same request is still in progress; it never proves that a profile changed.
ProfileInferenceResult decodeProfileInferenceResult(
  int status,
  Json value,
  String requestId,
) {
  if (status == 202 &&
      _exact(value, ['request_id', 'status']) &&
      value['request_id'] == requestId &&
      value['status'] == 'in_progress') {
    return const ProfileInferenceProcessing();
  }
  if (status != 200) return ProfileInferenceTerminal(status);
  if (_exact(value, ['safety', 'message']) &&
      value['safety'] == true &&
      value['message'] == profileInferenceSafetyMessage) {
    return const ProfileInferenceSafety();
  }
  if (_profile(value)) return ProfileInferenceCompleted(value);
  return ProfileInferenceTerminal(status);
}
