import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/supertonic/supertonic_engine.dart';
import 'package:privatelm/services/supertonic/flemish_text.dart';
import 'package:privatelm/services/supertonic/supertonic_preprocess.dart';
import 'package:privatelm/services/supertonic/supertonic_wav.dart';
import 'package:privatelm/services/tts_service.dart';

void main() {
  group('TtsService.splitIntoChunks', () {
    test('packs short sentences into bounded chunks', () {
      final chunks = TtsService.splitIntoChunks(
          'Hallo. Ik ben Eburon. Ik spreek vloeiend Vlaams.', 30);
      expect(chunks.isNotEmpty, isTrue);
      expect(chunks.every((c) => c.length <= 30), isTrue);
      expect(chunks.join(' '),
          'Hallo. Ik ben Eburon. Ik spreek vloeiend Vlaams.');
    });

    test('hard-splits overlong sentences', () {
      final long = List.filled(20, 'woord').join(' ');
      final chunks = TtsService.splitIntoChunks(long, 30);
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((c) => c.length <= 30), isTrue);
    });

    test('returns empty for blank input', () {
      expect(TtsService.splitIntoChunks('   '), isEmpty);
    });
  });

  group('TtsService.speakableText', () {
    test('strips reasoning traces and markdown', () {
      const raw = '<think>private plan</think>\n'
          '# Titel\n'
          '**bold** and `code` and [link](https://x.io)\n'
          '```dart\nprint(1);\n```';
      final out = TtsService.speakableText(raw);
      expect(out.contains('private plan'), isFalse);
      expect(out.contains('**'), isFalse);
      expect(out.contains('```'), isFalse);
      expect(out.contains('Titel'), isTrue);
      expect(out.contains('link'), isTrue);
    });

    test('converts ellipsis and roleplay markers to expression tags', () {
      final out =
          TtsService.speakableText('Wacht... *sigh* ik kom eraan.');
      expect(out, contains('<breath>'));
      expect(out, contains('<sigh>'));
      expect(out.contains('*'), isFalse);
    });

    test('leaves non-expression markers as plain words', () {
      final out = TtsService.speakableText('Dit is *bold* tekst.');
      expect(out, contains('bold'));
      expect(out.contains('*'), isFalse);
      expect(out.contains('<'), isFalse);
    });

    test('maps Dutch markers to laugh and breath', () {
      final out =
          TtsService.speakableText('*lacht* Dat is grappig. *ademt* Oké.');
      expect(out, contains('<laugh>'));
      expect(out, contains('<breath>'));
    });
  });

  group('Supertonic languages', () {
    test('covers all 31 languages including Dutch', () {
      expect(AppConstants.supertonicLanguages.length, 31);
      expect(AppConstants.supertonicLanguages['nl'], 'Dutch (Flemish)');
      expect(AppConstants.supertonicLanguages['en'], 'English');
    });
  });

  group('SupertonicPreprocess', () {
    test('wraps text in language tokens', () {
      expect(SupertonicPreprocess.preprocess('Hallo!', 'nl'),
          '<nl>Hallo!</nl>');
    });

    test('adds a period when missing', () {
      expect(SupertonicPreprocess.preprocess('Hallo', 'nl'),
          '<nl>Hallo.</nl>');
    });

    test('expands abbreviations and symbols like the SDK', () {
      final out = SupertonicPreprocess.preprocess('mail @ home #1', 'en');
      expect(out.contains(' at '), isTrue);
      expect(out.contains('@'), isFalse);
      expect(out.contains('#'), isFalse);
    });

    test('toIds maps chars and falls back to space', () {
      // tiny fake indexer: only 'a' and ' ' known
      final indexer = List<int>.filled(1024, -1);
      indexer['a'.codeUnitAt(0)] = 7;
      indexer[' '.codeUnitAt(0)] = 3;
      expect(SupertonicPreprocess.toIds('aΩb', indexer), [7, 3, 3]);
    });

    test('matches the official Python SDK output (parity)', () {
      expect(
        SupertonicPreprocess.preprocess(
            'Hallo! Ik ben Eburon, je Vlaamse assistent. Café naïef één.',
            'nl'),
        '<nl>Hallo! Ik ben Eburon, je Vlaamse assistent. '
        'Café naïef één.</nl>',
      );
      expect(
        SupertonicPreprocess.preprocess(
            'mail me @ home, e.g., now!!  “quoted” — dash', 'en'),
        '<en>mail me at home, for example, now!! "quoted" - dash.</en>',
      );
      expect(
        SupertonicPreprocess.preprocess(
            'Wat kost het? €45 voor 3 stuks... 1) eerst 2) dan', 'nl'),
        '<nl>Wat kost het? €45 voor 3 stuks... 1) eerst 2) dan.</nl>',
      );
    });
  });

  group('SupertonicEngine.loadStyle', () {
    test('flattens nested style data (real F1 layout)', () async {
      final dir = await Directory.systemTemp.createTemp('st_style');
      final vs = Directory('${dir.path}/voice_styles');
      await vs.create();
      // Mirrors voice_styles/F1.json: dims [1, 50, 256]-style nesting.
      final nested = List.generate(
          1, (_) => List.generate(2, (_) => List.generate(3, (k) => k * 0.5)));
      await File('${vs.path}/F9.json').writeAsString(jsonEncode({
        'style_ttl': {'dims': [1, 2, 3], 'data': nested},
        'style_dp': {
          'dims': [1, 1, 2],
          'data': [
            [0.25, -0.5]
          ]
        },
      }));
      final style =
          await SupertonicEngine.loadStyle(dir.path, 'F9');
      expect(style.ttlShape, [1, 2, 3]);
      expect(style.ttl, [0.0, 0.5, 1.0, 0.0, 0.5, 1.0]);
      expect(style.dpShape, [1, 1, 2]);
      expect(style.dp, [0.25, -0.5]);
      await dir.delete(recursive: true);
    });
  });

  group('FlemishText.normalize', () {
    test('expands homophones for correct stress', () {
      expect(FlemishText.normalize('Courtois en Lukaku'),
          contains('koert wa'));
      expect(FlemishText.normalize('Courtois en Lukaku'),
          contains('loeka koe'));
    });

    test('expands Flemish acronyms longest-first', () {
      expect(FlemishText.normalize('VRT NWS om 8 uur'),
          contains('vee er tee nieuws'));
      expect(FlemishText.normalize('N-VA en CD&V'), contains('en vee aa'));
      expect(FlemishText.normalize('N-VA en CD&V'),
          contains('cee dee en vee'));
    });

    test('expands titles, abbreviations, units, currency', () {
      expect(FlemishText.normalize('dhr Jansen, bv 45 euro'),
          contains('de heer'));
      expect(FlemishText.normalize('dhr Jansen, bv 45 euro'),
          contains('bijvoorbeeld'));
      expect(FlemishText.normalize('€45 en 100%'), contains('45 euro'));
      expect(FlemishText.normalize('€45 en 100%'), contains('100 procent'));
      expect(FlemishText.normalize('om 14u30'), contains('14 uur 30'));
      expect(FlemishText.normalize('5 km'), contains('5 kilometer'));
    });

    test('handles links, mail, symbols, emoticons', () {
      expect(FlemishText.normalize('zie https://x.be/y :)'),
          contains('link'));
      expect(FlemishText.normalize('mail jan@vrt.be'),
          contains('apenstaartje'));
      expect(FlemishText.normalize('a & b'), contains('a en b'));
    });

    test('shapes prosody without changing meaning', () {
      expect(FlemishText.normalize('Echt?! Ongelooflijk!!'),
          'Echt? Ongelooflijk!');
      expect(FlemishText.normalize('hij zei: kom'), contains('zei, kom'));
      expect(FlemishText.normalize('van-avermet'),
          contains('van aver maet'));
    });

    test('is idempotent on plain sentences', () {
      const s = 'Hallo, hoe gaat het met u vandaag?';
      expect(FlemishText.normalize(s), s);
    });
  });

  group('FlemishText.filterTags', () {
    test('keeps official tags for Supertonic, drops attributes', () {
      expect(
          FlemishText.filterTags(
              'Goh <sigh> dat is <laugh intensity="0.3"> grappig.',
              FlemishText.supertonicExpressionTags),
          'Goh <sigh> dat is <laugh> grappig.');
    });

    test('strips unknown tags everywhere and all tags for Lite', () {
      expect(
          FlemishText.filterTags('Hij <cough> hoest.',
              FlemishText.supertonicExpressionTags),
          'Hij hoest.');
      expect(FlemishText.filterTags('Goh <sigh> ja.', const {}),
          'Goh ja.');
    });
  });

  group('SupertonicEngine.blendStyles', () {
    test('lerps with normalized weights', () {
      final a = Float32List.fromList([0.0, 2.0]);
      final b = Float32List.fromList([4.0, 6.0]);
      final out = SupertonicEngine.blendStyles([a, b], [0.25, 0.25]);
      expect(out[0], closeTo(2.0, 1e-6));
      expect(out[1], closeTo(4.0, 1e-6));
    });
  });

  group('TtsService.supertonicAssetProblems', () {
    test('flags missing, truncated, and corrupt assets', () async {
      final dir = await Directory.systemTemp.createTemp('st_assets');
      try {
        // Empty dir: everything missing.
        var problems = await TtsService.supertonicAssetProblems(dir.path);
        expect(problems.length, TtsService().supertonicTotalFiles);

        // Truncated ONNX (1 KB of a 200 MB file) still counts as missing.
        final vec = File('${dir.path}/onnx/vector_estimator.onnx');
        await vec.parent.create(recursive: true);
        await vec.writeAsBytes(List.filled(1024, 0));
        problems = await TtsService.supertonicAssetProblems(dir.path);
        expect(problems, contains('onnx/vector_estimator.onnx'));

        // Corrupt JSON counts as missing.
        final cfg = File('${dir.path}/onnx/tts.json');
        await cfg.writeAsString('not json{{{');
        problems = await TtsService.supertonicAssetProblems(dir.path);
        expect(problems, contains('onnx/tts.json'));

        // Valid JSON passes (size + parse).
        await cfg.writeAsString('{"ae": {"sample_rate": 44100}}'
            '${' ' * 2048}');
        problems = await TtsService.supertonicAssetProblems(dir.path);
        expect(problems, isNot(contains('onnx/tts.json')));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('TtsService live streaming slices', () {
    test('holds partial sentences until a boundary arrives', () {
      var s = TtsService.takeLiveSlice('Hallo wereld', '');
      expect(s.ready, isEmpty);
      expect(s.consumed, isEmpty);

      s = TtsService.takeLiveSlice('Hallo wereld. Dit is', '');
      expect(s.ready, ['Hallo wereld.']);

      s = TtsService.takeLiveSlice(
          'Hallo wereld. Dit is Eburon. ', s.consumed);
      expect(s.ready, ['Dit is Eburon.']);
    });

    test('never repeats on non-monotonic input', () {
      final s = TtsService.takeLiveSlice('Helemaal anders', 'Hallo wereld. ');
      expect(s.ready, isEmpty);
      expect(s.consumed, 'Hallo wereld. ');
    });

    test('force-flushes long boundary-less tails', () {
      final long = List.filled(130, 'woord').join(' ');
      final s = TtsService.takeLiveSlice(long, '');
      expect(s.ready.length, 1);
      expect(s.consumed.isNotEmpty, isTrue);
      // Short follow-ups stay held, never repeated.
      final next = TtsService.takeLiveSlice('${s.consumed} en meer', s.consumed);
      expect(next.ready, isEmpty);
      expect(next.consumed, s.consumed);
    });

    test('finalLiveChunks flushes the partial tail once', () {
      expect(
          TtsService.finalLiveChunks('Een. Twee drie', 'Een. '), ['Twee drie']);
      expect(TtsService.finalLiveChunks('Een. ', 'Een. '), isEmpty);
    });

    test('streamCleanText drops unclosed fences and think blocks', () {
      expect(TtsService.streamCleanText('Lees dit ```dart\nprint(1);'),
          'Lees dit ');
      expect(TtsService.streamCleanText('Hi <think>geheim plan'), 'Hi ');
      expect(TtsService.streamCleanText('Hi <thought>x</thought> ok'),
          contains('ok'));
      expect(TtsService.streamCleanText('Gewone zin. Klaar. '),
          'Gewone zin. Klaar. ');
    });
  });

  group('TtsService.liveReadyChunks', () {
    test('normalizes segments and keeps tags per engine', () {
      const seg = 'Het kost 5 kg. <breath> Mooi.';
      final neural = TtsService.liveReadyChunks(
          seg, FlemishText.supertonicExpressionTags);
      expect(neural.join(' '), contains('kilo'));
      expect(neural.join(' '), contains('<breath>'));
      final lite = TtsService.liveReadyChunks(seg, const {});
      expect(lite.join(' '), contains('kilo'));
      expect(lite.join(' ').contains('<breath>'), isFalse);
    });

    test('handles empty segments', () {
      expect(TtsService.liveReadyChunks('   ', const {}), isEmpty);
    });
  });

  group('encodeWav16', () {
    test('fades chunk edges to prevent joint clicks', () {
      final samples = Float32List.fromList(List.filled(4410, 0.5));
      final bytes = encodeWav16(samples, 44100, fadeMs: 10.0);
      final data = ByteData.sublistView(bytes);
      // 10 ms @ 44.1 kHz = 441 faded frames per side.
      expect(data.getInt16(44, Endian.little).abs(), lessThan(100));
      expect(
          data.getInt16(44 + (4410 - 1) * 2, Endian.little).abs(),
          lessThan(100));
      expect(data.getInt16(44 + 2205 * 2, Endian.little), 16384);
    });
    test('writes a valid mono 16-bit WAV', () {
      final samples = Float32List.fromList([0.0, 0.5, -0.5, 1.0]);
      final bytes = encodeWav16(samples, 44100, fadeMs: 0);
      expect(bytes.length, 44 + 8);
      final header = String.fromCharCodes(bytes.sublist(0, 4));
      final format = String.fromCharCodes(bytes.sublist(8, 12));
      expect(header, 'RIFF');
      expect(format, 'WAVE');
      final rate = ByteData.sublistView(bytes).getUint32(24, Endian.little);
      expect(rate, 44100);
      final peak =
          ByteData.sublistView(bytes).getInt16(44 + 3 * 2, Endian.little);
      expect(peak, 32767);
    });
  });
}
