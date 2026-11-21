import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'api.dart';

final sessionProvider = NotifierProvider<SessionState, Session?>(
  SessionState.new,
);

class SessionState extends Notifier<Session?> {
  Timer? _expiry;
  @override
  Session? build() {
    ref.onDispose(() => _expiry?.cancel());
    return null;
  }

  void enter(Session s) {
    _expiry?.cancel();
    _expiry = Timer(s.expires.difference(DateTime.now()), clear);
    state = s;
  }

  void clear() {
    _expiry?.cancel();
    state = null;
  }
}
