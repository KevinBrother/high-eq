import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

const privacyExportRootName = 'high-eq-privacy-exports';

/// Account namespaces are opaque, fixed-length directory names. The account
/// identifier is never copied into a path and the namespace cannot be listed by
/// another authenticated account.
Future<Directory> privacyExportAccountDirectory(
  Directory root,
  String account,
) async {
  if (account.isEmpty) {
    throw ArgumentError.value(account, 'account', '账号标识不能为空');
  }
  final digest = await Sha256().hash(utf8.encode(account));
  final tag = base64UrlEncode(digest.bytes).replaceAll('=', '');
  return Directory('${root.absolute.path}/$privacyExportRootName/v1_$tag');
}
