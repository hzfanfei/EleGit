import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../api/wenxiang_api.dart';
import '../utils/markdown_syntax.dart';
import '../utils/text_fit.dart';
import '../utils/wx_markdown_styles.dart';
import '../utils/wx_mermaid_fence.dart';
import 'wx_mermaid_svg_block.dart';
import 'wx_rich_text.dart';

class WxMarkdownImageConfig {
  const WxMarkdownImageConfig({
    required this.uri,
    this.alt,
    this.title,
    this.width,
    this.height,
  });

  final Uri uri;
  final String? alt;
  final String? title;
  final double? width;
  final double? height;
}

typedef WxMarkdownImageBuilder = Widget Function(WxMarkdownImageConfig config);

bool _bareUrlLabel(String label) {
  final plain = label.replaceAll('\u200b', '');
  return plain.contains('://') ||
      RegExp(r'^www\.', caseSensitive: false).hasMatch(plain);
}

/// One markdown pipeline for chat and book reader ([GptMarkdown]).
class WxUnifiedMarkdownBody extends StatelessWidget {
  const WxUnifiedMarkdownBody({
    super.key,
    required this.data,
    required this.mdStyle,
    this.api,
    this.onTapLink,
    this.sizedImageBuilder,
    this.prepareChatSource = true,
    this.streaming = false,
  });

  final String data;
  final WxMarkdownStyle mdStyle;
  final WenxiangApi? api;
  final void Function(String text, String? href, String? title)? onTapLink;
  final WxMarkdownImageBuilder? sizedImageBuilder;
  final bool prepareChatSource;
  final bool streaming;

  String _prepareProse(String prose) {
    if (!prepareChatSource) return prose;
    return normalizeMarkdownDisplayMath(
      prepareChatMarkdownForDisplay(prose, isTableLine: isMarkdownTableLine),
    );
  }

  TextStyle get _monoStyle => mdStyle.body.copyWith(
        fontFamily: 'ui-monospace',
        fontFamilyFallback: const ['SF Mono', 'Menlo', 'Consolas', 'monospace'],
        fontSize:
            mdStyle.body.fontSize != null ? mdStyle.body.fontSize! * 0.88 : 14,
        height: 1.45,
      );

  @override
  Widget build(BuildContext context) {
    final segments = splitMarkdownFences(data, includeCode: prepareChatSource);
    if (segments.isEmpty) return const SizedBox.shrink();
    if (segments.length == 1) return _segment(context, segments.single);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final segment in segments) _segment(context, segment),
      ],
    );
  }

  Widget _segment(BuildContext context, WxMarkdownSegment segment) {
    if (segment.prose case final prose?) {
      return _gptMarkdown(context, _prepareProse(prose));
    }
    final code = segment.code!;
    return segment.isMermaid
        ? _mermaid(code, closed: segment.closed)
        : _fencedCode(code, segment.language);
  }

  Widget _mermaid(String code, {required bool closed}) => WxMermaidSvgBlock(
        code: code,
        closed: closed,
        streaming: streaming,
        api: api,
        serverTheme: mdStyle.mermaidServerTheme,
        backgroundColor: mdStyle.mermaidBackground,
        shellColor: mdStyle.mermaidShellColor,
        monoStyle: _monoStyle,
      );

  Widget _fencedCode(String code, String language) => WxFencedCode(
        code: code,
        language: language,
        blockKey: const Key('wx-md-code'),
        style: _monoStyle,
      );

  Widget _gptMarkdown(BuildContext context, String prepared) {
    return GptMarkdownTheme(
      gptThemeData: mdStyle.gptTheme,
      child: GptMarkdown(
        prepared,
        style: mdStyle.body,
        styleSheet: mdStyle.styleSheet,
        isStreaming: false,
        animation: GptMarkdownAnimation.none,
        onLinkTap: (url, title) {
          final href = url.trim();
          if (href.isEmpty) return;
          final label = title.trim().isNotEmpty ? title.trim() : href;
          onTapLink?.call(label, href, title);
        },
        inlineLinkBuilder: (link) {
          final bare = link.isAutolink || _bareUrlLabel(link.label);
          if (!bare) return link.defaultSpan();
          final shown = link.isAutolink ? link.label : link.url;
          return link.defaultSpan(
            children: [
              TextSpan(text: breakLongRuns(shown), style: link.style),
            ],
          );
        },
        imageBuilder: sizedImageBuilder == null
            ? null
            : (context, imageUrl, width, height) {
                final uri = Uri.tryParse(imageUrl) ?? Uri(path: imageUrl);
                return sizedImageBuilder!(
                  WxMarkdownImageConfig(
                    uri: uri,
                    title: '',
                    alt: '',
                    width: width,
                    height: height,
                  ),
                );
              },
        codeBuilder: (context, name, code, closed) {
          final lang = name.trim();
          if (isMermaidFenceLang(lang) ||
              (lang.isEmpty && looksLikeMermaidSource(code))) {
            return _mermaid(
              normalizeMermaidFenceSource(lang, code),
              closed: closed,
            );
          }
          return _fencedCode(code, name);
        },
        checkboxBuilder: (context, checked, content, style) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WxTaskBox(checked: checked),
              const SizedBox(width: 8),
              Expanded(child: content),
            ],
          );
        },
        hrBuilder: (context, style) => const WxMarkdownRule(),
      ),
    );
  }
}
