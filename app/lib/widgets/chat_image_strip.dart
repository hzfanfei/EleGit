import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/wenxiang_api.dart';
import '../chat/chat_image.dart';
import '../models.dart';
import '../theme.dart';

class ChatImageStrip extends StatelessWidget {
  const ChatImageStrip({
    super.key,
    required this.images,
    this.api,
    this.onRemove,
    this.draftBytes,
  });

  final List<ChatImageAttachment> images;
  final WenxiangApi? api;
  final ValueChanged<int>? onRemove;
  final List<Uint8List>? draftBytes;

  @override
  Widget build(BuildContext context) {
    final count = draftBytes?.length ?? images.length;
    if (count == 0) return const SizedBox.shrink();
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: count,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final bytes = draftBytes != null ? draftBytes![index] : null;
          final image = draftBytes == null ? images[index] : null;
          return _ChatThumb(
            bytes: bytes,
            image: image,
            api: api,
            onRemove: onRemove == null ? null : () => onRemove!(index),
          );
        },
      ),
    );
  }
}

class _ChatThumb extends StatelessWidget {
  const _ChatThumb({
    this.bytes,
    this.image,
    this.api,
    this.onRemove,
  });

  final Uint8List? bytes;
  final ChatImageAttachment? image;
  final WenxiangApi? api;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76,
      height: 76,
      child: Stack(
        children: [
          Positioned.fill(
            child: Material(
              color: Wx.surface,
              borderRadius: BorderRadius.circular(Wx.radius),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: image == null && bytes == null
                    ? null
                    : () => _open(context),
                child: _ChatImagePicture(
                  bytes: bytes,
                  image: image,
                  api: api,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: 2,
              right: 2,
              child: IconButton(
                tooltip: '移除',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                style: IconButton.styleFrom(backgroundColor: const Color(0xCC100E0C)),
                onPressed: onRemove,
                icon: const Icon(Icons.close, size: 16, color: Wx.text),
              ),
            ),
        ],
      ),
    );
  }

  void _open(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Wx.bg,
        insetPadding: const EdgeInsets.all(16),
        child: InteractiveViewer(
          child: _ChatImagePicture(
            bytes: bytes,
            image: image,
            api: api,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}

class _ChatImagePicture extends StatefulWidget {
  const _ChatImagePicture({
    this.bytes,
    this.image,
    this.api,
    required this.fit,
  });

  final Uint8List? bytes;
  final ChatImageAttachment? image;
  final WenxiangApi? api;
  final BoxFit fit;

  @override
  State<_ChatImagePicture> createState() => _ChatImagePictureState();
}

class _ChatImagePictureState extends State<_ChatImagePicture> {
  Future<Uint8List?>? _remote;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(covariant _ChatImagePicture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image?.id != widget.image?.id || oldWidget.bytes != widget.bytes) {
      _arm();
    }
  }

  void _arm() {
    final inline = widget.bytes;
    if (inline != null) {
      _remote = null;
      return;
    }
    final image = widget.image;
    final api = widget.api;
    if (image == null || api == null) {
      _remote = null;
      return;
    }
    final cached = ChatImageCache.get(image.id);
    if (cached != null) {
      _remote = Future.value(Uint8List.fromList(cached));
      return;
    }
    _remote = api.fetchChatImage(image.id);
  }

  @override
  Widget build(BuildContext context) {
    final inline = widget.bytes;
    if (inline != null) {
      return Image.memory(inline, fit: widget.fit, gaplessPlayback: true);
    }
    final future = _remote;
    if (future == null) return const _BrokenImage();
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Image.memory(bytes, fit: widget.fit, gaplessPlayback: true);
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return const _BrokenImage();
      },
    );
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Wx.surface,
      child: Center(child: Icon(Icons.broken_image_outlined, color: Wx.faint, size: 20)),
    );
  }
}
