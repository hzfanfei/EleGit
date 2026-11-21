import 'package:flutter/material.dart';
import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../utils/wx_markdown_styles.dart';
import 'wx_unified_markdown.dart';

/// Explicit presentation markers only; never executes HTML or tag contents.
class WxAnswerBlock extends StatelessWidget {
  const WxAnswerBlock(
      {super.key,
      required this.source,
      required this.mdStyle,
      this.api,
      this.streaming = false,
      this.onTapLink});

  final String source;
  final WxMarkdownStyle mdStyle;
  final WenxiangApi? api;
  final bool streaming;
  final void Function(String href, String text)? onTapLink;

  Widget _markdown(String text) => WxUnifiedMarkdownBody(
        data: text,
        mdStyle: mdStyle,
        api: api,
        streaming: streaming,
        onTapLink: (label, href, _) {
          if (href != null && href.trim().isNotEmpty) {
            onTapLink?.call(href, label);
          }
        },
      );

  @override
  Widget build(BuildContext context) {
    final text = source.trim();
    final details = RegExp(
            r'^<details( open)?>\s*<summary>([^<\n]+)</summary>([\s\S]*)$',
            caseSensitive: false)
        .firstMatch(text);
    if (details != null) {
      final tail = details.group(3)!;
      final closed = tail.toLowerCase().endsWith('</details>');
      final body =
          closed ? tail.substring(0, tail.length - 10).trim() : tail.trim();
      return Material(
        color: Wx.surface,
        shape: RoundedRectangleBorder(
            side: const BorderSide(color: Wx.hairline),
            borderRadius: BorderRadius.circular(8)),
        child: ExpansionTile(
          initiallyExpanded: details.group(1) != null || (!closed && !streaming),
          title: Text(details.group(2)!,
              style: mdStyle.body.copyWith(fontWeight: FontWeight.w600)),
          subtitle: closed
              ? null
              : Text(
                  streaming ? '内容接收中…' : '折叠段语法未闭合',
                  style: const TextStyle(fontSize: 12),
                ),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [_markdown(body)],
        ),
      );
    }

    final alert = RegExp(
            r'^>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(?:\n|$)',
            caseSensitive: false)
        .firstMatch(text);
    if (alert != null) {
      final kind = alert.group(1)!.toUpperCase();
      const labels = {
        'NOTE': '说明',
        'TIP': '提示',
        'IMPORTANT': '重要',
        'WARNING': '注意',
        'CAUTION': '警告'
      };
      final caution = kind == 'WARNING' || kind == 'CAUTION';
      final color = caution
          ? Wx.danger
          : kind == 'TIP'
              ? Wx.ok
              : Wx.accent;
      final body = text
          .substring(alert.end)
          .split('\n')
          .map((line) => line.replaceFirst(RegExp(r'^> ?'), ''))
          .join('\n');
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            border: Border(left: BorderSide(color: color, width: 3))),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(caution ? Icons.info_outline : Icons.lightbulb_outline,
                color: color, size: 18),
            const SizedBox(width: 6),
            Text(labels[kind]!,
                style: TextStyle(color: color, fontWeight: FontWeight.w600))
          ]),
          if (body.isNotEmpty) ...[const SizedBox(height: 6), _markdown(body)],
        ]),
      );
    }

    // Only a standalone Markdown link to a known downloadable file becomes a card.
    // Keep its exact href (including query parameters) and existing link routing.
    final link =
        RegExp(r'^\[([^\]\n]+)\]\((https?://[^\s]+)\)$').firstMatch(text);
    final uri = link == null ? null : Uri.tryParse(link.group(2)!);
    final extension = uri == null
        ? null
        : RegExp(r'\.(apk|pdf|zip|docx?|xlsx?|pptx?|csv|epub|png|jpe?g|webp)$',
                caseSensitive: false)
            .firstMatch(uri.path)
            ?.group(1)
            ?.toUpperCase();
    if (!streaming &&
        link != null &&
        uri != null &&
        uri.host.isNotEmpty &&
        extension != null) {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.all(12),
            alignment: Alignment.centerLeft,
            minimumSize: const Size(48, 56)),
        onPressed: onTapLink == null
            ? null
            : () => onTapLink!(link.group(2)!, link.group(1)!),
        child: Row(children: [
          const Icon(Icons.download_outlined, size: 22),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(link.group(1)!,
                    style: mdStyle.body.copyWith(color: Wx.accent)),
                Text('$extension · ${uri.host}',
                    style: const TextStyle(color: Wx.muted, fontSize: 12)),
              ])),
        ]),
      );
    }
    return _markdown(source);
  }
}
