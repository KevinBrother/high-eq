import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/contacts/purpose.dart';
import 'package:high_eq/features/contacts/scene.dart';

Future<String> createFixtureContact(
  MobileEndpoints wire,
  AccountScope scope,
) async {
  // A fresh account has no chat-import decision. The UI grants it for
  // the first time, and the service requires an existing grant to withdraw it.
  await ContactDecisions(wire, scope).grant(ContactPurpose.contacts);
  final created = await wire.createContact(
    scope: scope,
    body: {'nickname': '合成关系人', 'scene': Scene.work.name},
  );
  return created['id'] as String;
}
