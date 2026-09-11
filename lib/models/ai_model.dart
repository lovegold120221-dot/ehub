class AiModel {
  static const runtimeLlama = 'llama';
  static const runtimeLiteRt = 'litert';
  static const runtimeSd = 'sd';

  /// Eburon display aliases keyed by catalog filename.
  /// Shown on the Models page; everything else (downloads, loading,
  /// Hive keys) keeps using [filename]/[name].
  static const eburonAliases = <String, String>{
    'Qwen3-0.6B.litertlm': 'Eburon-Stellar',
    'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm':
        'Eburon-Nova',
    'DeepSeek-R1-Distill-Qwen-1.5B_multi-prefill-seq_q8_ekv4096.litertlm':
        'Eburon-Quasar',
    'gemma-4-E2B-it.litertlm': 'Eburon-Vega',
    'gemma-4-E4B-it.litertlm': 'Eburon-Sirius',
    'moonlight-16b-a3b-instruct-q3_k_s.gguf': 'Eburon-Polaris',
    'qwen2.5-3b-instruct-q4_k_m.gguf': 'Eburon-Rigel',
    'qwen2-vl-2b-instruct-q4_k_m.gguf': 'Eburon-Lyra',
    'phi-3.5-mini-instruct-q4_k_m.gguf': 'Eburon-Pulsar',
    'gemma-2-2b-it-q4_k_m.gguf': 'Eburon-Altair',
    'gemma-2-2b-it-abliterated-q4_k_m.gguf': 'Eburon-Antares',
    'smollm2-360m-instruct-q4_k_m.gguf': 'Eburon-Edge',
    'dolphin-3.0-qwen2.5-1.5b-q4_k_m.gguf': 'Eburon-Orion',
    'llama-3.2-3b-instruct-uncensored-q4_k_m.gguf': 'Eburon-Betelgeuse',
    'llama-3.2-1b-instruct-q4_k_m.gguf': 'Eburon-Proxima',
    'DreamShaper8_LCM.safetensors': 'Eburon-Nebula',
    'DreamShaper8_LCM_q8_0.gguf': 'Eburon-Nebula-Q8',
    'CyberRealistic_V8_FP16.safetensors': 'Eburon-Supernova',
    'Realistic_Vision_V5.1_fp16-no-ema.safetensors': 'Eburon-Mira',
    'AbsoluteReality_1.8.1_pruned.safetensors': 'Eburon-Atlas',
    'AnyLoRA_noVae_fp16-pruned.safetensors': 'Eburon-Aster',
  };

  static bool hasVisionMarker(String value) {
    final lower = value.toLowerCase();
    return lower.contains('vl-') ||
        lower.contains('-vl') ||
        lower.contains('llava') ||
        lower.contains('vision');
  }

  final String name;
  final String filename;  final String url;
  final String size;
  final String description;
  final String template;
  final String runtime;
  final bool isVision;
  final bool isImported;
  final bool isCustom;

  AiModel({
    required this.name,
    required this.filename,
    required this.url,
    required this.size,
    required this.description,
    required this.template,
    String? runtime,
    this.isVision = false,
    this.isImported = false,
    this.isCustom = false,
  }) : runtime = runtime ?? runtimeFromFilename(filename, template: template);

  /// Frontend display name for the Models page: the `Eburon-<Star>` alias
  /// when [filename] is in [eburonAliases], otherwise the raw [name].
  String get displayName => eburonAliases[filename] ?? name;

  /// True when this model shows an Eburon alias instead of [name].
  bool get hasEburonAlias =>
      eburonAliases.containsKey(filename) && eburonAliases[filename] != name;

  factory AiModel.fromMap(Map<String, String> map) => AiModel(
        name: map['name'] ?? '',
        filename: map['filename'] ?? '',
        url: map['url'] ?? '',
        size: map['size'] ?? '',
        description: map['description'] ?? '',
        template: map['template'] ?? 'chatml',
        runtime: map['runtime'],
        isVision: map['vision'] == 'true',
        isImported: map['imported'] == 'true',
        isCustom: map['custom'] == 'true',
      );

  Map<String, String> toMap() => {
        'name': name,
        'filename': filename,
        'url': url,
        'size': size,
        'description': description,
        'template': template,
        'runtime': runtime,
        if (isVision) 'vision': 'true',
        if (isImported) 'imported': 'true',
        if (isCustom) 'custom': 'true',
      };

  static String runtimeFromFilename(String filename, {String? template}) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.litertlm')) return runtimeLiteRt;
    if (lower.endsWith('.safetensors') || template == runtimeSd) {
      return runtimeSd;
    }
    return runtimeLlama;
  }

  AiModel copyWith({
    String? name,
    String? filename,
    String? url,
    String? size,
    String? description,
    String? template,
    String? runtime,
    bool? isVision,
    bool? isImported,
    bool? isCustom,
  }) {
    return AiModel(
      name: name ?? this.name,
      filename: filename ?? this.filename,
      url: url ?? this.url,
      size: size ?? this.size,
      description: description ?? this.description,
      template: template ?? this.template,
      runtime: runtime ?? this.runtime,
      isVision: isVision ?? this.isVision,
      isImported: isImported ?? this.isImported,
      isCustom: isCustom ?? this.isCustom,
    );
  }
}
