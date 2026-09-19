import 'package:flutter/material.dart';

/// Left-edge swipe right or right-edge swipe left → [onBack].
/// Taps still reach children. Does not pop the route by itself.
class WxEdgeBack extends StatefulWidget {
  const WxEdgeBack({
    super.key,
    required this.onBack,
    required this.child,
    this.edgeWidth = 28,
    this.minDistance = 48,
  });

  final VoidCallback onBack;
  final Widget child;
  final double edgeWidth;
  final double minDistance;

  @override
  State<WxEdgeBack> createState() => _WxEdgeBackState();
}

class _WxEdgeBackState extends State<WxEdgeBack> {
  int? _pointer;
  double _startX = 0;
  double _startY = 0;
  bool _fromLeft = false;
  bool _fromRight = false;
  bool _fired = false;

  void _reset() {
    _pointer = null;
    _fromLeft = false;
    _fromRight = false;
    _fired = false;
  }

  void _maybeBack(Offset position) {
    if (_fired || (!_fromLeft && !_fromRight)) return;
    final dx = position.dx - _startX;
    final dy = position.dy - _startY;
    if (dx.abs() < widget.minDistance || dy.abs() > dx.abs()) return;
    if ((_fromLeft && dx > 0) || (_fromRight && dx < 0)) {
      _fired = true;
      widget.onBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        final width = MediaQuery.sizeOf(context).width;
        _pointer = e.pointer;
        _startX = e.position.dx;
        _startY = e.position.dy;
        _fromLeft = _startX <= widget.edgeWidth;
        _fromRight = _startX >= width - widget.edgeWidth;
        _fired = false;
      },
      onPointerMove: (e) {
        if (_pointer != e.pointer) return;
        _maybeBack(e.position);
      },
      onPointerUp: (e) {
        if (_pointer != e.pointer) return;
        _maybeBack(e.position);
        _reset();
      },
      onPointerCancel: (e) {
        if (_pointer == e.pointer) _reset();
      },
      child: widget.child,
    );
  }
}
