// Only for the pinned Flutter SDK when the normal test runner cannot bind even
// a loopback socket. Same test declarations; no replacement widget assertions.
// ignore_for_file: implementation_imports, depend_on_referenced_packages
import 'dart:io';
import 'package:flutter_test/flutter_test.dart'
    show AutomatedTestWidgetsFlutterBinding;
import 'package:test_api/src/backend/declarer.dart';
import 'package:test_api/src/backend/runtime.dart';
import 'package:test_api/src/backend/suite.dart';
import 'package:test_api/src/backend/suite_platform.dart';
import 'package:test_api/src/backend/test.dart';
import '../../test/replies/entry_test.dart' as entry;
import '../../test/replies/page_test.dart' as page;
import '../../test/replies/result_test.dart' as result;
import '../../test/replies/share_test.dart' as share;
import '../../test/replies/wire_test.dart' as wire;

Future<void> main() async {
  AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  var failures = 0, count = 0;
  for (final register in [
    entry.main,
    page.main,
    result.main,
    share.main,
    wire.main,
  ]) {
    final declaration = Declarer()..declare(register);
    final suite = Suite(declaration.build(), SuitePlatform(Runtime.vm));
    for (final test in suite.group.entries.cast<Test>()) {
      final live = test.load(suite, groups: [suite.group]);
      live.onError.listen((error) {
        failures++;
        stderr.writeln(error);
      });
      await live.run();
      count++;
      stdout.writeln('${live.state.result}: ${test.name}');
      if (!live.state.result.isPassing) failures++;
      await live.close();
    }
  }
  stdout.writeln('T22: $count tests, $failures failures');
  exit(count > 0 && failures == 0 ? 0 : 1);
}
