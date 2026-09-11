import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/controllers/chat_controller.dart';

void main() {
  group('ChatController.buildMemoryBlock', () {
    test('returns empty for no past chats', () {
      expect(ChatController.buildMemoryBlock([]), isEmpty);
    });

    test('formats past exchanges with titles and roles', () {
      final out = ChatController.buildMemoryBlock([
        (
          title: 'Vlaamse recepten',
          messages: [
            (role: 'user', content: 'Geef een stoofvlees recept'),
            (role: 'assistant', content: 'Hier is het recept...'),
          ],
        ),
      ]);
      expect(out, contains('Vlaamse recepten'));
      expect(out, contains('user: Geef een stoofvlees recept'));
      expect(out, contains('assistant: Hier is het recept...'));
    });

    test('hard-caps total length', () {
      final out = ChatController.buildMemoryBlock(
        [
          (
            title: 'Lang',
            messages: [
              (role: 'user', content: 'x' * 5000),
            ],
          ),
        ],
        maxChars: 100,
      );
      expect(out.length, lessThanOrEqualTo(101)); // cap + ellipsis
      expect(out.endsWith('…'), isTrue);
    });
  });

  group('ChatController.memoryMessageText', () {
    test('strips assistant thinking traces like live history does', () {
      final out = ChatController.memoryMessageText(
        'assistant',
        '<think>private reasoning here</think>Het antwoord.',
      );
      expect(out.contains('private reasoning'), isFalse);
      expect(out, contains('Het antwoord.'));
    });

    test('drops errors, images, and non-chat roles', () {
      expect(
          ChatController.memoryMessageText('assistant', '❌ Error: x'), isEmpty);
      expect(ChatController.memoryMessageText('assistant', '[IMAGE_BASE64]xx'),
          isEmpty);
      expect(ChatController.memoryMessageText('system', 'hello'), isEmpty);
      expect(ChatController.memoryMessageText('user', '  '), isEmpty);
    });

    test('keeps user text and trims long messages', () {
      expect(ChatController.memoryMessageText('user', '  hallo  '), 'hallo');
      final long = ChatController.memoryMessageText('user', 'y' * 5000);
      expect(long.endsWith('…'), isTrue);
      expect(long.length, lessThanOrEqualTo(301));
    });
  });
}
