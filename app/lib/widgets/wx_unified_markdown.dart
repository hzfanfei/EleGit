import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../api/wenxiang_api.dart';
import '../utils/text_fit.dart';
import '../utils/wx_mermaid_fence.dart';
import '../utils/wx_markdown_styles.dart';
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

/// One markdown pipeline for chat and book reader ([GptMarkdown]).
class WxUnifiedMarkdownBody extends StatelessWidget {
  const WxUnifiedMarkdownBody({
    super.key,
    required this.data,
    required this.mdStyle,
    this.api,
    this.onTapLink,
    this.sizedImageBuilder,
    this.softWrapProse = true,
  });

  final String data;
  final WxMarkdownStyle mdStyle;
  final WenxiangApi? api;
  final void Function(String text, String? href, String? title)? onTapLink;
  final WxMarkdownImageBuilder? sizedImageBuilder;
  final bool softWrapProse;

  String _prepareProse(String prose) {
    if (!softWrapProse) return prose;
    return prepareChatMarkdownForDisplay(prose, isTableLine: isMarkdownTableLine);
  }

  TextStyle get _monoStyle => mdStyle.body.copyWith(
        fontFamily: 'ui-monospace',
        fontFamilyFallback: const ['SF Mono', 'Menlo', 'Consolas', 'monospace'],
        fontSize: mdStyle.body.fontSize != null ? mdStyle.body.fontSize! * 0.88 : 14,
        height: 1.45,
      );

  @override
  Widget build(BuildContext context) {
    final segments = splitMarkdownByMermaidFences(data);
    final hasMermaid = segments.any((s) => s.isMermaid);
    if (!hasMermaid) {
      return _gptMarkdown(context, _prepareProse(data));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final seg in segments)
          if (seg.isMermaid)
            WxMermaidSvgBlock(
              code: seg.mermaidCode ?? '',
              closed: seg.mermaidClosed,
              api: api,
              serverTheme: mdStyle.mermaidServerTheme,
              backgroundColor: mdStyle.mermaidBackground,
              shellColor: mdStyle.mermaidShellColor,
              monoStyle: _monoStyle,
            )
          else if ((seg.prose ?? '').trim().isNotEmpty)
            _gptMarkdown(context, _prepareProse(seg.prose!)),
      ],
    );
  }

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
          if (isMermaidFenceLang(lang) || looksLikeMermaidSource(code)) {
            return WxMermaidSvgBlock(
              code: normalizeMermaidFenceSource(
                isMermaidFenceLang(lang) ? lang : 'mermaid',
                code,
              ),
              closed: closed,
              api: api,
              serverTheme: mdStyle.mermaidServerTheme,
              backgroundColor: mdStyle.mermaidBackground,
              shellColor: mdStyle.mermaidShellColor,
              monoStyle: _monoStyle,
            );
          }
          return WxFencedCode(
            code: code,
            language: name,
            blockKey: const Key('wx-md-code'),
            style: _monoStyle,
          );
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
