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
}
