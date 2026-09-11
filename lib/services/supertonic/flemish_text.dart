/// Eburon Flemish (nl-BE) adaptation layer: normalization, homophone
/// respellings, prosody shaping, and expression-tag handling.
///
/// Why homophones instead of lexicon files: sherpa-onnx's Piper/VITS path
/// phonemizes purely through espeak-ng and never consults a custom word
/// lexicon (verified in `piper-phonemize-lexicon.cc`), and Supertonic 3 has
/// no lexicon concept either (fixed unicode indexer). So Flemish fixes ship
/// as text the engines already pronounce correctly. Every homophone below
/// was verified with `espeak-ng -v nl --ipa` against the nl_BE-nathalie
/// voice's `tokens.txt` phone set.
///
/// Pure (unit-tested). Runs before both neural engines.
class FlemishText {
  /// Expression tags Supertonic 3 documents (<laugh>, <breath>, <sigh>).
  /// Verified present in its unicode indexer, so they pass through intact.
  static const supertonicExpressionTags = {'laugh', 'breath', 'sigh'};

  /// Flemish fixes: original (lowercase, whole-word) → respelling that
  /// espeak-nl renders with correct phones and stress. Longest first.
  static const homophones = <String, String>{
    'van-avermet': 'van aver maet',
    'vlaams-belang': 'vlaams belang',
    'eburonhub': 'eeburonhub',
    'tomorrowland': 'tomoro land',
    'chaudfontaine': 'sjo fonten',
    'superprestige': 'super prestiezje',
    'alderweireld': 'alder weireld',
    'deceuninck': 'de seuninck',
    'campenaerts': 'campe naerts',
    'batshuayi': 'batsjoeaji',
    'tielemans': 'tiele mans',
    'courtois': 'koert wa',
    'trossard': 'tros saar',
    'lampaert': 'lam paert',
    'trappist': 'trap pist',
    'terzake': 'ter zake',
    'slaapwel': 'slaap wel',
    'provincie': 'provinsie',
    'manneke': 'mannke',
    'speculoos': 'speku loos',
    'kasseien': 'kas seijen',
    'neufchateau': 'neufsjatoo',
    'bouillon': 'boeljon',
    'seraing': 'se reng',
    'malmedy': 'malmedie',
    'stavelot': 'staveloo',
    'aywaille': 'eewai',
    'ottignies': 'ottinjie',
    'ventoux': 'ventoe',
    'standard': 'stan daar',
    'awel': 'au wel',
    'voila': 'vo la',
    'cava': 'ka va',
    'jeanetten': 'zjanetten',
    'sante': 'santee',
    'proficiat': 'profisjaat',
    'streamz': 'striemz',
    'qmusic': 'kjoe mjoezik',
    'meunier': 'meunjee',
    'museeuw': 'mu zeeuw',
    'ceulemans': 'keule mans',
    'lukaku': 'loeka koe',
    'openda': 'op enda',
    'hazard': 'hazaar',
    'doku': 'do koe',
    'nonkel': 'non kel',
    'efkes': 'ef kes',
    'gentse': 'gent se',
    'binche': 'bensj',
    'herstal': 'her stal',
    'oupeye': 'oepee',
    'ciao': 'tsjao',
    'adieu': 'adjeu',
    'salut': 'sa lu',
    'eburon': 'eeburong',
    'merckx': 'merks',
    'scifo': 'sjifo',
    'ciney': 'sinee',
    'vise': 'viezee',
    'yves': 'ief',
    'allee': 'a lee',
    'gsm': 'geessem',
    'avermaet': 'aver maet',
  };

  /// Daily Flemish acronyms → spoken letters. Longest first.
  static const acronyms = <String, String>{
    'vrt nws': 'vee er tee nieuws',
    'vrt max': 'vee er tee max',
    'open vld': 'open vee el dee',
    'openvld': 'open vee el dee',
    'n-va': 'en vee aa',
    'cd&v': 'cee dee en vee',
    'vrt': 'vee er tee',
    'vtm': 'vee tee em',
    'mnm': 'em en em',
    'nmbs': 'en em bee es',
    'nws': 'nieuws',
    'stubru': 'stu bru',
    'pvda': 'pee vee dee aa',
    'pvv': 'pee vee vee',
    'bbb': 'bee bee bee',
    'nsc': 'en es cee',
    'cda': 'cee dee aa',
    'd66': 'dee zesenzestig',
    'fvd': 'ef vee dee',
    'bij1': 'bij een',
    'ja21': 'jaa eenentwintig',
  };

  static const _titles = <String, String>{
    'dhr.': 'de heer',
    'dhr': 'de heer',
    'mevr.': 'mevrouw',
    'mevr': 'mevrouw',
    'mr.': 'meneer',
    'dr.': 'dokter',
    'dr': 'dokter',
    'prof.': 'professor',
    'prof': 'professor',
    'ir.': 'ingenieur',
    'ir': 'ingenieur',
    'ing.': 'ingenieur',
    'ing': 'ingenieur',
    'mr': 'em er',
  };

  static const _abbreviations = <String, String>{
    'bv.': 'bijvoorbeeld',
    'bv': 'bijvoorbeeld',
    'bvb.': 'bijvoorbeeld',
    'bvb': 'bijvoorbeeld',
    'dwz.': 'dat wil zeggen',
    'dwz': 'dat wil zeggen',
    'ivm': 'in verband met',
    'i.v.m.': 'in verband met',
    'tav': 'ten aanzien van',
    't.a.v.': 'ten aanzien van',
    'o.a.': 'onder andere',
    'oa': 'onder andere',
    'e.a.': 'en andere',
    'aub': 'alstublieft',
    'svp': 'alstublieft',
    's.v.p.': 'alstublieft',
    'btw': 'trouwens',
    'idd': 'inderdaad',
    'wrs': 'waarschijnlijk',
    'mss': 'misschien',
    'ff': 'effe',
    'asap': 'zo snel mogelijk',
    'fyi': 'ter info',
    'omg': 'oh mijn god',
    'wtf': 'wee tee ef',
    'imo': 'naar mijn mening',
    'tbh': 'eerlijk gezegd',
    'dm': 'dee em',
    'sms': 'es em es',
    'tv': 'tee vee',
    'pc': 'pee cee',
    'ps': 'pee es',
    'sp': 'es pee',
    'nr.': 'nummer',
    'nr': 'nummer',
    'nrs.': 'nummers',
    'nrs': 'nummers',
    'tel.': 'telefoon',
    'tel': 'telefoon',
  };

  static const _emoticons = <String, String>{
    '<3': 'hartje',
    ':)': '',
    ':-)': '',
    ':(': '',
    ':-(': '',
    ';)': '',
    ';-)': '',
    ':D': '',
    ':-D': '',
    'xD': '',
    'XD': '',
    ':p': '',
    ':-p': '',
    ':P': '',
    ';p': '',
  };

  /// Full pipeline: URLs → homophones → acronyms → titles/abbrev → numbers
  /// and symbols → hyphens → emoticons → prosody shaping.
  static String normalize(String text) {
    var out = ' $text ';

    // URLs and e-mails first (before symbol rules eat them).
    out = out.replaceAllMapped(
        RegExp(r'https?://\S+|www\.\S+'), (_) => ' link ');
    out = out.replaceAllMapped(RegExp(r'(\S+)@(\S+)'), (m) {
      final domain = (m.group(2) ?? '').replaceAll('.', ' punt ');
      return ' ${m.group(1)} apenstaartje $domain ';
    });

    // Currency / units with digits.
    out = out.replaceAllMapped(
        RegExp(r'€\s?(\d[\d.,]*)'), (m) => ' ${m.group(1)} euro ');
    out = out.replaceAllMapped(
        RegExp(r'(\d[\d.,]*)\s?€'), (m) => ' ${m.group(1)} euro ');
    out = out.replaceAll('£', ' pond ');
    out = out.replaceAllMapped(
        RegExp(r'\$(\d)'), (m) => ' ${m.group(1)} dollar ');
    out = out.replaceAllMapped(
        RegExp(r'(\d[\d.,]*)\s?%'), (m) => ' ${m.group(1)} procent ');
    out = out.replaceAll('°C', ' graden ');
    out = out.replaceAll('°', ' graden ');
    out = out.replaceAllMapped(RegExp(r'(\d{1,2})[uh](\d{2})\b'),
        (m) => ' ${m.group(1)} uur ${m.group(2)} ');
    out = out.replaceAllMapped(RegExp(r'(\d{1,2}):(\d{2})\b'),
        (m) => ' ${m.group(1)} uur ${m.group(2)} ');
    for (final entry in {
      'km/u': 'kilometer per uur',
      'm2': 'vierkante meter',
      'm3': 'kubieke meter',
      'kcal': 'kilocalorieën',
      'km': 'kilometer',
      'cm': 'centimeter',
      'mm': 'millimeter',
      'ml': 'milliliter',
      'cl': 'centiliter',
      'kg': 'kilo',
    }.entries) {
      out = out.replaceAllMapped(
          RegExp('\\b${entry.key}\\b', caseSensitive: false),
          (_) => ' ${entry.value} ');
    }
    out = out.replaceAllMapped(RegExp(r'(\d+)\s+min\b'),
        (m) => ' ${m.group(1)} minuten ');
    out = out.replaceAllMapped(RegExp(r'(\d+)\s+sec\b'),
        (m) => ' ${m.group(1)} seconden ');
    out = out.replaceAllMapped(RegExp(r'(\d+)\s*x\b'),
        (m) => ' ${m.group(1)} keer ');

    // Homophones, acronyms, titles, abbreviations: longest keys first,
    // whole-word, case-insensitive.
    out = _replaceWholeWords(out, {...homophones, ...acronyms});
    out = _replaceWholeWords(out, _titles);
    out = _replaceWholeWords(out, _abbreviations);

    // Hyphens: acronyms already handled, so letter-letter joins can split.
    out = out.replaceAllMapped(
        RegExp(r'([A-Za-zÀ-ÿ])\-([A-Za-zÀ-ÿ])'), (m) => '${m.group(1)} ${m.group(2)}');
    out = out.replaceAllMapped(
        RegExp(r'(\d)\s?\-\s?(\d)'), (m) => '${m.group(1)} ${m.group(2)}');
    out = out.replaceAll(' - ', ', ');

    // Remaining symbols.
    out = out.replaceAll('&', ' en ');
    out = out.replaceAll('@', ' apenstaartje ');
    out = out.replaceAllMapped(
        RegExp(r'#(\w+)'), (m) => ' hashtag ${m.group(1)} ');
    for (final c in ['*', '~', '^', '`']) {
      out = out.replaceAll(c, ' ');
    }
    out = out.replaceAll('_', ' ');
    out = out.replaceAll('|', ', ');
    out = out.replaceAll(' / ', ' en ');
    out = out.replaceAll('/', ' ');
    out = out.replaceAll('=', ' is ');
    out = out.replaceAll('+', ' plus ');
    for (final c in ['→', '←', '↑', '↓']) {
      out = out.replaceAll(c, ', ');
    }
    for (final entry in _emoticons.entries) {
      out = out.replaceAll(entry.key, ' ${entry.value} ');
    }

    // Prosody shaping (meaning-preserving): calm shouting, map long
    // pauses to commas, keep ellipses (natural pause cue).
    out = out.replaceAll('?!', '?');
    out = out.replaceAll(RegExp(r'!{2,}'), '!');
    out = out.replaceAll(RegExp(r'\?{2,}'), '?');
    out = out.replaceAll(';', ',');
    out = out.replaceAll(':', ',');
    out = out.replaceAll('—', ',');
    out = out.replaceAll('–', ',');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (out.isNotEmpty && !RegExp(r'[.?!…]$').hasMatch(out)) {
      out += '.';
    }
    return out;
  }

  static String _replaceWholeWords(String text, Map<String, String> table) {
    var out = text;
    final keys = table.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final key in keys) {
      out = out.replaceAllMapped(
        RegExp('\\b${RegExp.escape(key)}\\b', caseSensitive: false),
        (_) => ' ${table[key]} ',
      );
    }
    return out;
  }

  /// Normalizes `<tag>` / `<tag attr="…">` markers. Tags in [keep] survive
  /// (attributes stripped); everything else becomes a space. Use [keep]
  /// = [supertonicExpressionTags] for EburonVoix-3, empty for Lite.
  static String filterTags(String text, Set<String> keep) {
    return text
        .replaceAllMapped(
          RegExp(r'<\s*/?\s*([a-zA-Z]+)(?:\s+[^<>]*)?\s*/?>'),
          (m) {
            final tag = (m.group(1) ?? '').toLowerCase();
            return keep.contains(tag) ? '<$tag>' : ' ';
          },
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
