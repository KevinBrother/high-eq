/// Incremental raw-DEFLATE structure verifier.
///
/// Dart's raw zlib decoder can return the expected bytes and CRC without
/// requiring the stream to contain a final Huffman block. This verifier walks
/// the RFC 1951 block structure as bytes arrive, keeping only one byte of bit
/// look-ahead and the current Huffman tables. It rejects incomplete final
/// blocks and bytes beyond the declared compressed size.
class DeflateStreamVerifier {
  static final _fixedLiteral = _Huffman([
    for (var index = 0; index < 144; index++) 8,
    for (var index = 0; index < 112; index++) 9,
    for (var index = 0; index < 24; index++) 7,
    for (var index = 0; index < 8; index++) 8,
  ]);
  static final _fixedDistance = _Huffman(List<int>.filled(32, 5));
  static const _codeLengthOrder = [
    16,
    17,
    18,
    0,
    8,
    7,
    9,
    6,
    10,
    5,
    11,
    4,
    12,
    3,
    13,
    2,
    14,
    1,
    15,
  ];
  static const _lengthExtraBits = [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    1,
    1,
    1,
    2,
    2,
    2,
    2,
    3,
    3,
    3,
    3,
    4,
    4,
    4,
    4,
    5,
    5,
    5,
    5,
    0,
  ];
  static const _distanceExtraBits = [
    0,
    0,
    0,
    0,
    1,
    1,
    2,
    2,
    3,
    3,
    4,
    4,
    5,
    5,
    6,
    6,
    7,
    7,
    8,
    8,
    9,
    9,
    10,
    10,
    11,
    11,
    12,
    12,
    13,
    13,
  ];

  var _bitBuffer = 0;
  var _bitCount = 0;
  var _done = false;
  var _phase = _Phase.blockHeader;
  var _final = false;
  var _storedRemaining = 0;
  var _literalCount = 0;
  var _distanceCount = 0;
  var _codeLengthIndex = 0;
  var _codeLengthTarget = 0;
  final _codeLengthCodeLengths = List<int>.filled(19, 0);
  final _codeLengths = <int>[];
  _Huffman? _codeLengthTable;
  _Huffman? _literalTable;
  _Huffman? _distanceTable;
  var _repeatSymbol = 0;
  var _lengthExtra = 0;
  var _distanceExtra = 0;
  var _decodeCode = 0;
  var _decodeLength = 0;

  void add(List<int> bytes) {
    for (final value in bytes) {
      if (_done) throw const FormatException('导出文件压缩流含额外数据');
      _bitBuffer |= (value & 0xff) << _bitCount;
      _bitCount += 8;
      _pump();
      if (_done && _bitCount >= 8) {
        throw const FormatException('导出文件压缩流含额外数据');
      }
    }
  }

  void finish() {
    if (!_done || _bitCount >= 8) {
      throw const FormatException('导出文件压缩流未完整结束');
    }
  }

  void _pump() {
    while (!_done) {
      switch (_phase) {
        case _Phase.blockHeader:
          final header = _takeBits(3);
          if (header == null) return;
          _final = (header & 1) != 0;
          switch ((header >> 1) & 3) {
            case 0:
              _phase = _Phase.storedAlign;
            case 1:
              _literalTable = _fixedLiteral;
              _distanceTable = _fixedDistance;
              _resetSymbol();
              _phase = _Phase.data;
            case 2:
              _phase = _Phase.dynamicHeader;
            default:
              throw const FormatException('导出文件压缩块类型异常');
          }
        case _Phase.storedAlign:
          _bitBuffer = 0;
          _bitCount = 0;
          _phase = _Phase.storedLength;
        case _Phase.storedLength:
          final lengths = _takeBits(32);
          if (lengths == null) return;
          final length = lengths & 0xffff;
          final inverse = (lengths >> 16) & 0xffff;
          if ((length ^ inverse) != 0xffff) {
            throw const FormatException('导出文件存储块长度异常');
          }
          _storedRemaining = length;
          _phase = _Phase.storedData;
        case _Phase.storedData:
          if (_storedRemaining == 0) {
            _finishBlock();
            continue;
          }
          final available = _bitCount ~/ 8;
          if (available == 0) return;
          final consumed = available < _storedRemaining
              ? available
              : _storedRemaining;
          _dropBits(consumed * 8);
          _storedRemaining -= consumed;
        case _Phase.dynamicHeader:
          final values = _takeBits(14);
          if (values == null) return;
          _literalCount = (values & 0x1f) + 257;
          _distanceCount = ((values >> 5) & 0x1f) + 1;
          final codeLengthCount = ((values >> 10) & 0x0f) + 4;
          _codeLengthCodeLengths.fillRange(0, _codeLengthCodeLengths.length, 0);
          _codeLengthIndex = 0;
          _codeLengthTarget = codeLengthCount;
          _phase = _Phase.codeLengthCodeLengths;
        case _Phase.codeLengthCodeLengths:
          while (_codeLengthIndex < _codeLengthTarget) {
            final length = _takeBits(3);
            if (length == null) return;
            _codeLengthCodeLengths[_codeLengthOrder[_codeLengthIndex]] = length;
            _codeLengthIndex++;
          }
          _codeLengthTable = _Huffman(_codeLengthCodeLengths);
          _codeLengths.clear();
          _codeLengthTarget = _literalCount + _distanceCount;
          _resetSymbol();
          _phase = _Phase.dynamicCodeLengths;
        case _Phase.dynamicCodeLengths:
          final symbol = _decodeSymbol(_codeLengthTable!);
          if (symbol == null) return;
          if (symbol <= 15) {
            _codeLengths.add(symbol);
            if (_codeLengths.length > _codeLengthTarget) {
              throw const FormatException('导出文件压缩码表异常');
            }
            if (_codeLengths.length == _codeLengthTarget) {
              _finishDynamicCodeLengths();
            }
            continue;
          }
          if (symbol == 16 && _codeLengths.isEmpty) {
            throw const FormatException('导出文件压缩码表异常');
          }
          _repeatSymbol = symbol;
          _phase = _Phase.dynamicCodeRepeat;
        case _Phase.dynamicCodeRepeat:
          final extra = switch (_repeatSymbol) {
            16 => 2,
            17 => 3,
            18 => 7,
            _ => throw const FormatException('导出文件压缩码表异常'),
          };
          final value = _takeBits(extra);
          if (value == null) return;
          final repeat = switch (_repeatSymbol) {
            16 => value + 3,
            17 => value + 3,
            18 => value + 11,
            _ => 0,
          };
          final repeated = _repeatSymbol == 16 ? _codeLengths.last : 0;
          if (_codeLengths.length + repeat > _codeLengthTarget) {
            throw const FormatException('导出文件压缩码表异常');
          }
          _codeLengths.addAll(List<int>.filled(repeat, repeated));
          if (_codeLengths.length == _codeLengthTarget) {
            _finishDynamicCodeLengths();
          } else {
            _phase = _Phase.dynamicCodeLengths;
          }
        case _Phase.lengthExtra:
          if (_takeBits(_lengthExtra) == null) return;
          _distanceExtra = 0;
          _resetSymbol();
          _phase = _Phase.distanceSymbol;
        case _Phase.distanceSymbol:
          final symbol = _decodeSymbol(_distanceTable!);
          if (symbol == null) return;
          if (symbol >= _distanceExtraBits.length) {
            throw const FormatException('导出文件压缩距离码异常');
          }
          _distanceExtra = _distanceExtraBits[symbol];
          _phase = _Phase.distanceExtra;
        case _Phase.distanceExtra:
          if (_takeBits(_distanceExtra) == null) return;
          _resetSymbol();
          _phase = _Phase.data;
        case _Phase.data:
          final symbol = _decodeSymbol(_literalTable!);
          if (symbol == null) return;
          if (symbol == 256) {
            _finishBlock();
            continue;
          }
          if (symbol < 256) continue;
          final lengthIndex = symbol - 257;
          if (lengthIndex < 0 || lengthIndex >= _lengthExtraBits.length) {
            throw const FormatException('导出文件压缩长度码异常');
          }
          _lengthExtra = _lengthExtraBits[lengthIndex];
          _phase = _Phase.lengthExtra;
      }
    }
  }

  void _finishBlock() {
    _resetSymbol();
    if (_final) {
      _done = true;
      return;
    }
    _phase = _Phase.blockHeader;
  }

  void _finishDynamicCodeLengths() {
    _literalTable = _Huffman(_codeLengths.sublist(0, _literalCount));
    _distanceTable = _Huffman(_codeLengths.sublist(_literalCount));
    _resetSymbol();
    _phase = _Phase.data;
  }

  int? _decodeSymbol(_Huffman table) {
    if (table.maxBits == 0) {
      throw const FormatException('导出文件压缩码表异常');
    }
    while (_decodeLength < table.maxBits) {
      final bit = _takeBits(1);
      if (bit == null) return null;
      _decodeCode |= bit << _decodeLength;
      _decodeLength++;
      final symbol = table.symbols[_decodeLength][_decodeCode];
      if (symbol != null) {
        _resetSymbol();
        return symbol;
      }
    }
    throw const FormatException('导出文件压缩码异常');
  }

  void _resetSymbol() {
    _decodeCode = 0;
    _decodeLength = 0;
  }

  int? _takeBits(int count) {
    if (count == 0) return 0;
    if (_bitCount < count) return null;
    final mask = (1 << count) - 1;
    final value = _bitBuffer & mask;
    _dropBits(count);
    return value;
  }

  void _dropBits(int count) {
    _bitBuffer >>= count;
    _bitCount -= count;
  }
}

enum _Phase {
  blockHeader,
  storedAlign,
  storedLength,
  storedData,
  dynamicHeader,
  codeLengthCodeLengths,
  dynamicCodeLengths,
  dynamicCodeRepeat,
  data,
  lengthExtra,
  distanceSymbol,
  distanceExtra,
}

class _Huffman {
  _Huffman(List<int> lengths)
    : maxBits = lengths.fold(
        0,
        (value, length) => length > value ? length : value,
      ),
      symbols = List.generate(
        lengths.fold(0, (value, length) => length > value ? length : value) + 1,
        (_) => <int, int>{},
      ) {
    if (maxBits > 15) {
      throw const FormatException('导出文件压缩码表异常');
    }
    final counts = List<int>.filled(maxBits + 1, 0);
    for (final length in lengths) {
      if (length < 0 || length > maxBits) {
        throw const FormatException('导出文件压缩码表异常');
      }
      if (length > 0) counts[length]++;
    }
    var remaining = 1;
    for (var bits = 1; bits <= maxBits; bits++) {
      remaining = (remaining << 1) - counts[bits];
      if (remaining < 0) {
        throw const FormatException('导出文件压缩码表异常');
      }
    }
    final next = List<int>.filled(maxBits + 1, 0);
    var code = 0;
    for (var bits = 1; bits <= maxBits; bits++) {
      code = (code + counts[bits - 1]) << 1;
      next[bits] = code;
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length == 0) continue;
      final canonical = next[length]++;
      symbols[length][_reverse(canonical, length)] = symbol;
    }
  }

  final int maxBits;
  final List<Map<int, int>> symbols;

  static int _reverse(int value, int length) {
    var reversed = 0;
    for (var bit = 0; bit < length; bit++) {
      reversed = (reversed << 1) | ((value >> bit) & 1);
    }
    return reversed;
  }
}
