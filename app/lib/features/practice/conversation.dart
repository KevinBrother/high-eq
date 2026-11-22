import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/api.dart';
import '../../core/sse.dart';
import '../../core/transport.dart';
import '../contacts/models.dart' show newRequestId;
import 'repository.dart';

/// A command is journalled before dispatch. History, never the temporary bubble,
/// decides whether to offer the command again. No retries run in the background.
class Conversation extends ChangeNotifier {
  Conversation(this.repo, this.snapshot);
  final PracticeRepository repo;
  Json snapshot;
  String get id => snapshot['session_id'];
  List<Json> get rows => (snapshot['messages'] as List).cast<Json>();
  String get status => snapshot['status'];
  bool get active => ['pending', 'active'].contains(status);
  bool get hasSavedReply => rows.lastOrNull?['role'] == 'assistant';
  bool get canSend => active && !busy && !needsRead && command == null;
  bool get canScore =>
      !busy &&
      !needsRead &&
      command == null &&
      (active || status == 'capped') &&
      hasSavedReply;
  bool get canRetry =>
      command != null &&
      !busy &&
      !needsRead &&
      (active ||
          status == 'moderation_unavailable' ||
          (status == 'capped' && command!['kind'] == 'finish'));
  bool get canExit =>
      active && (!needsRead || detailKnown) && (!busy || streaming);
  bool get canRecover => !busy && (needsRead || !ledgerKnown);
  Json? command;
  String fragment = '', notice = '';
  bool busy = false,
      streaming = false,
      needsRead = true,
      detailKnown = false,
      ledgerKnown = false;
  int _epoch = 0;
  void Function()? _stop;
  @override
  void dispose() {
    _epoch++;
    _stop?.call();
    super.dispose();
  }

  int _begin() {
    final e = ++_epoch;
    _stop?.call();
    _stop = null;
    busy = true;
    streaming = false;
    notice = '';
    fragment = '';
    notifyListeners();
    return e;
  }

  void _end(int e) {
    if (e == _epoch) {
      busy = false;
      streaming = false;
      notifyListeners();
    }
  }

  Future<void> recover() async {
    if (busy) return;
    final e = _begin();
    try {
      final op = await repo.read(id);
      if (e != _epoch) return;
      command = op;
      if (op?['terminal'] != null) {
        snapshot = {...snapshot, 'status': op!['terminal']};
      }
      await _read(e);
    } catch (err) {
      if (e == _epoch) {
        needsRead = true;
        notice = problem(err);
      }
    } finally {
      _end(e);
    }
  }

  Future<void> _read(int e) async {
    if (e != _epoch) return;
    final next = await repo.get(id);
    if (e != _epoch) return;
    if (next['session_id'] != id) throw const FormatException();
    final body = command?['body'];
    final saved =
        body != null &&
        (next['messages'] as List).any(
          (m) =>
              m['role'] == 'assistant' &&
              m['client_message_id'] == body['client_message_id'],
        );
    // A lagging history read must never revive a witnessed safety stop.
    if ((status == 'safety' && next['status'] != 'safety') ||
        (status == 'moderation_unavailable' &&
            !saved &&
            ['active', 'pending'].contains(next['status']))) {
      ledgerKnown = false;
      needsRead = status == 'safety';
      return;
    }
    snapshot = next;
    detailKnown = true;
    ledgerKnown = true;
    needsRead = false;
    final unfinishedScore = status == 'capped' && command?['kind'] == 'finish';
    if (saved ||
        (!active && status != 'moderation_unavailable' && !unfinishedScore)) {
      await _clear(e);
      if (e != _epoch) return;
    }
    await _restoreInterruptedSend(e);
    if (e != _epoch) return;
    // A server may persist a user row before its assistant reply.
    if (command == null &&
        (active || status == 'moderation_unavailable') &&
        rows.lastOrNull?['role'] == 'user') {
      final last = rows.last;
      command = {
        'kind': 'send',
        'body': {
          'client_message_id': last['client_message_id'],
          'text': last['text'],
        },
      };
    }
  }

  Future<void> _clear(int e) async {
    await repo.remember(id, null);
    if (e == _epoch) command = null;
  }

  Future<void> _restoreInterruptedSend(int e) async {
    final exit = command;
    final fallback = exit?['fallback'];
    if (status != 'moderation_unavailable' ||
        exit?['kind'] != 'exit' ||
        fallback is! Map<String, dynamic> ||
        fallback['kind'] != 'send') {
      return;
    }
    command = fallback;
    await repo.remember(id, fallback);
    if (e != _epoch) return;
  }

  Future<void> send(String text) async {
    if (!canSend || text.trim().isEmpty) return;
    await _run({
      'kind': 'send',
      'body': {'client_message_id': newRequestId(), 'text': text.trim()},
    });
  }

  Future<void> finish() async {
    if (canScore) await _run({'kind': 'finish'});
  }

  Future<void> exit() async {
    if (!canExit) return;
    final current = command;
    final Json? fallback;
    if (current?['kind'] == 'send') {
      fallback = current;
    } else if (current?['kind'] == 'exit' &&
        current?['fallback'] is Json &&
        current!['fallback']['kind'] == 'send') {
      // A failed exit can remain journalled while the session is still
      // writable. Reuse the earliest send instead of nesting another exit.
      fallback = current['fallback'] as Json;
    } else {
      fallback = null;
    }
    await _run({'kind': 'exit', 'fallback': ?fallback});
  }

  Future<void> retry() async {
    if (canRetry) await _run(command!);
  }

  Future<void> _terminal(String status) async {
    command = status == 'safety'
        ? {'terminal': status}
        : {...?command, 'terminal': status};
    snapshot = {...snapshot, 'status': status};
    fragment = '';
    streaming = false;
    ledgerKnown = false;
    needsRead = true;
    notifyListeners();
    await repo.remember(id, command);
  }

  Future<ReplyEvent> _receive(int epoch, Json body) async {
    final terminal = Completer<ReplyEvent>();
    void fail(Object err) {
      if (!terminal.isCompleted) terminal.completeError(err);
    }

    final sub = repo
        .send(id, body)
        .timeout(const Duration(seconds: 65))
        .listen(
          (event) {
            if (epoch != _epoch || terminal.isCompleted) return;
            if (event.kind == ReplyEventKind.fragment) {
              fragment += event.data['text'] as String;
              notifyListeners();
            } else {
              terminal.complete(event);
            }
          },
          onError: fail,
          onDone: () => fail(const FormatException('回复中断')),
        );
    _stop = () => fail(const FormatException('已离开对话'));
    try {
      return await terminal.future;
    } finally {
      unawaited(sub.cancel());
      if (epoch == _epoch) _stop = null;
    }
  }

  Future<void> _run(Json op) async {
    final e = _begin();
    command = op;
    try {
      await repo.remember(id, op);
      if (e != _epoch) return;
      switch (op['kind']) {
        case 'send':
          streaming = true;
          notifyListeners();
          final event = await _receive(e, op['body']);
          if (e != _epoch) return;
          fragment = '';
          streaming = false;
          switch (event.kind) {
            case ReplyEventKind.safety:
              await _terminal('safety');
            case ReplyEventKind.moderationUnavailable:
              await _terminal('moderation_unavailable');
            case ReplyEventKind.replySaved:
              snapshot = {
                ...snapshot,
                'status': 'active',
                'settlement': event.data['settlement'],
              };
              ledgerKnown = true;
            case ReplyEventKind.inProgress:
              notice = '原发言仍在处理中，请稍后恢复会话。';
            case ReplyEventKind.fragment:
              throw StateError('非终止帧');
          }
          if (e != _epoch) return;
          notifyListeners();
          await _read(e);
          if (e == _epoch &&
              event.kind == ReplyEventKind.inProgress &&
              active &&
              command != null) {
            needsRead = true;
          }
        case 'finish':
          final result = await repo.finish(id);
          if (e != _epoch) return;
          if (result['safety'] == true) {
            await _terminal('safety');
            await _read(e);
          } else {
            snapshot = {
              ...snapshot,
              'status': 'complete',
              'settlement': result['settlement'],
              'result': result,
            };
            ledgerKnown = true;
            await _clear(e);
          }
        case 'exit':
          final bill = await repo.exit(id);
          if (e != _epoch) return;
          snapshot = {...snapshot, 'status': 'exited', 'settlement': bill};
          ledgerKnown = true;
          await _clear(e);
      }
    } catch (err) {
      if (e != _epoch) return;
      fragment = '';
      streaming = false;
      needsRead = true;
      ledgerKnown = false;
      notice = err is ApiFailure ? problem(err) : '连接中断，请恢复原会话。';
      if (err is ApiFailure && err.code == 'moderation_unavailable') {
        await _terminal('moderation_unavailable');
      }
      if (op['kind'] == 'finish' ||
          (err is ApiFailure &&
              (err.status == 409 || err.code == 'moderation_unavailable'))) {
        try {
          await _read(e);
        } catch (_) {
          /* Keep the terminal and offer a read-only retry. */
        }
      }
    } finally {
      _end(e);
    }
  }
}
