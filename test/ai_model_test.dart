import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/models/ai_model.dart';

void main() {
  group('AiModel.hasVisionMarker', () {
    test('does not classify text-only Gemma 4 bundles as vision models', () {
      expect(
        AiModel.hasVisionMarker('Gemma-4-E2B-Abliterated.litertlm'),
        isFalse,
      );
    });

    test('recognizes unambiguous vision model markers', () {
      expect(AiModel.hasVisionMarker('Qwen2-VL-Instruct.litertlm'), isTrue);
      expect(AiModel.hasVisionMarker('LLaVA-Next.litertlm'), isTrue);
      expect(AiModel.hasVisionMarker('mobile-vision-model.litertlm'), isTrue);
    });
  });

  group('AiModel.displayName', () {
    AiModel model(String name, String filename) => AiModel(
          name: name,
          filename: filename,
          url: '',
          size: '',
          description: '',
          template: 'chatml',
        );

    test('shows the Eburon alias for catalog models', () {
      final m = model('Qwen 3 0.6B (LiteRT-LM)', 'Qwen3-0.6B.litertlm');
      expect(m.displayName, 'Eburon-Stellar');
      expect(m.hasEburonAlias, isTrue);
    });

    test('covers vision and image catalog models', () {
      expect(
        model('Qwen2-VL-2B Instruct (Q4_K_M)',
                'qwen2-vl-2b-instruct-q4_k_m.gguf')
            .displayName,
        'Eburon-Lyra',
      );
      expect(
        model('DreamShaper 8 LCM (SD 1.5)', 'DreamShaper8_LCM.safetensors')
            .displayName,
        'Eburon-Nebula',
      );
      expect(
        model('DreamShaper 8 LCM Q8 (SD 1.5 · mobile)',
                'DreamShaper8_LCM_q8_0.gguf')
            .displayName,
        'Eburon-Nebula-Q8',
      );
    });

    test('falls back to the raw name for custom/imported models', () {
      final m = model('my-custom.gguf', 'my-custom.gguf');
      expect(m.displayName, 'my-custom.gguf');
      expect(m.hasEburonAlias, isFalse);
    });
  });
}
