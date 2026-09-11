import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Pure-Dart port of Supertonic's `UnicodeProcessor` text pipeline
/// (supertonic PyPI SDK `core.py`): NFKD → emoji strip → symbol normalize
/// → abbreviation expand → punctuation fixes → `<lang>` tokens → indexer ids.
/// No platform calls — fully unit-testable.
class SupertonicPreprocess {
  static final _emoji = RegExp(
    '[\u{1F600}-\u{1F64F}\u{1F300}-\u{1F5FF}\u{1F680}-\u{1F6FF}'
    '\u{1F700}-\u{1F77F}\u{1F780}-\u{1F7FF}\u{1F800}-\u{1F8FF}'
    '\u{1F900}-\u{1F9FF}\u{1FA00}-\u{1FA6F}\u{1FA70}-\u{1FAFF}'
    '\u2600-\u26FF\u2700-\u27BF\u{1F1E6}-\u{1F1FF}]+',
    unicode: true,
  );

  static const _symbolReplacements = {
    '–': '-',
    '‑': '-',
    '—': '-',
    '¯': ' ',
    '_': ' ',
    '“': '"',
    '”': '"',
    '‘': "'",
    '’': "'",
    '´': "'",
    '`': "'",
    '[': ' ',
    ']': ' ',
    '|': ' ',
    '/': ' ',
    '#': ' ',
    '→': ' ',
    '←': ' ',
  };

  static final _specialSymbols = RegExp(r'[♥☆♡©\\]');
  static final _punctSpacing = <RegExp, String>{
    RegExp(r' ,'): ',',
    RegExp(r' \.'): '.',
    RegExp(r' !'): '!',
    RegExp(r' \?'): '?',
    RegExp(r' ;'): ';',
    RegExp(r' :'): ':',
    RegExp(r" '"): "'",
  };
  static final _duplicateQuotes = RegExp('(["\'`])\\1+');
  static final _whitespace = RegExp(r'\s+');
  static final _endingPunct =
      RegExp('[.!?;:,\\\'"\\)\\]}…。」』】〉》›»]\$');

  /// Mirrors `UnicodeProcessor._preprocess_text`.
  static String preprocess(String text, String lang) {
    var out = unorm.nfkd(text);
    out = out.replaceAll(_emoji, '');
    _symbolReplacements.forEach((k, v) => out = out.replaceAll(k, v));
    out = out.replaceAll(_specialSymbols, '');
    out = out
        .replaceAll('@', ' at ')
        .replaceAll('e.g.,', 'for example, ')
        .replaceAll('i.e.,', 'that is, ');
    _punctSpacing.forEach((p, r) => out = out.replaceAll(p, r));
    out = out.replaceAllMapped(_duplicateQuotes, (m) => m.group(1)!);
    out = out.replaceAll(_whitespace, ' ').trim();
    if (!_endingPunct.hasMatch(out)) out += '.';
    return '<$lang>$out</$lang>';
  }

  /// Maps preprocessed text to indexer ids. Unknown code units become a
  /// space (the SDK would emit -1 and corrupt the run).
  static List<int> toIds(String preprocessed, List<int> indexer) {
    final spaceId = indexer[' '.codeUnitAt(0)];
    return preprocessed.codeUnits
        .map((u) => (u < indexer.length && indexer[u] != -1)
            ? indexer[u]
            : spaceId)
        .toList();
  }

  /// Float32 [1, 1, T] attention mask of ones.
  static List<List<List<double>>> textMask(int length) =>
      [
        [List<double>.filled(length, 1.0)]
      ];
}
