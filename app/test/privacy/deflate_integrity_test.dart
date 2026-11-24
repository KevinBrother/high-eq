import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/privacy/deflate_integrity.dart';

void main() {
  test(
    'accepts a dynamic stream whose code lengths end on a direct length',
    () {
      for (final width in [1, 97, 65536]) {
        final verifier = DeflateStreamVerifier();
        for (var offset = 0; offset < _dynamicStream.length; offset += width) {
          final end = (offset + width).clamp(0, _dynamicStream.length);
          verifier.add(_dynamicStream.sublist(offset, end));
        }

        verifier.finish();
      }
    },
  );
}

final _dynamicStream = base64Decode(
  '1de9SsNQGMbxWylnztDnpOlHbkVEDk2GYGrL8VSUUkhFXSyddPEG/BjiYkHFu7FJ9C4MuJ53FHzm9xn+2493oWY2OzHjs4P0dDa1TsXKhZEKlE3HU5scq3hvobJExd1AuczlaTuYmKO5yTsTYw873XaapM5keXvYvRZ1uW1uHnbvm2pz3Xw81ttVVa7r25e6uP9+Wn89r5q7i+rqsirfPovzv96rZfAbD388KOK1P15TxIf++JAivueP71HER/74iCK+74/vU8QP/PEDivihP35IET/yx48o4iEQCxJjJWQ5lIXALDichQAtOKSFQC04rIWALTi0hcAtOLyFAC44xIVALjjMhYAuONTVgrqaQ10tqKs51NXSc8uhrhbU1f9c3f3lDw==',
);
