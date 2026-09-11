import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/tts_service.dart';

void main() {
  group('TtsService low-latency live slicing', () {
    test('emits sentence immediately when punctuation reaches stream end', () {
      final slice = TtsService.takeLiveSlice('Hallo wereld.', '');

      expect(slice.ready, ['Hallo wereld.']);
      expect(slice.consumed, 'Hallo wereld.');
    });

    test('force-flushes punctuation-free text at the latency bound', () {
      final text = List.filled(30, 'woord').join(' ');
      final slice = TtsService.takeLiveSlice(text, '', 64);

      expect(slice.ready, isNotEmpty);
      expect(slice.consumed, isNotEmpty);
      expect(slice.consumed.length, lessThanOrEqualTo(64));
      expect(text.startsWith(slice.consumed), isTrue);
    });

    test('keeps short partial text buffered', () {
      final slice = TtsService.takeLiveSlice('Nog niet klaar', '');

      expect(slice.ready, isEmpty);
      expect(slice.consumed, isEmpty);
    });
  });
}
