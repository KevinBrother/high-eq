import 'dart:convert';
import 'dart:io';

const _proxyResponse =
    'HTTP/1.1 502 Bad Gateway\r\n'
    'Content-Length: 0\r\n'
    'Connection: close\r\n\r\n';

/// A synthetic proxy that records only whether any client connected.
///
/// It never reads or logs request data, headers, paths or payloads. The wrapper
/// starts it on an ephemeral IPv4 loopback port and counts connections. One
/// connection is expected from the default-client positive control; controlled
/// T29 clients must not create another.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('usage: proxy_sentinel.dart <ready-file> <hit-file>');
    exitCode = 64;
    return;
  }

  final readyFile = File(arguments[0]);
  final hitFile = File(arguments[1]);
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final response = ascii.encode(_proxyResponse);

  try {
    await readyFile.writeAsString('${server.port}\n', flush: true);
    await for (final socket in server) {
      try {
        await hitFile.writeAsString(
          'hit\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {
        // The marker is deliberately the only data this process writes.
      }
      try {
        socket.add(response);
        await socket.close();
      } catch (_) {
        // The marker is sufficient evidence; never surface request bytes.
      }
    }
  } finally {
    await server.close();
  }
}
