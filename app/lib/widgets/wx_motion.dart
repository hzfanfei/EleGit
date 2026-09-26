import 'package:flutter/material.dart';

import '../theme.dart';

/// One-shot entrance: fade in and rise [Wx.motionRise].
class WxAppear extends StatefulWidget {
  const WxAppear({super.key, required this.child});

  final Widget child;

  @override
  State<WxAppear> createState() => _WxAppearState();
}

class _WxAppearState extends State<WxAppear> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: Wx.motion,
  )..forward();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _anim, curve: Wx.motionCurve);
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) {
        return Opacity(
          opacity: curved.value,
          child: Transform.translate(
            offset: Offset(0, (1 - curved.value) * Wx.motionRise),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// In-app page change. Settings keeps the platform push.
class WxFadePage<T> extends Page<T> {
  const WxFadePage({required this.child, super.key, super.name});

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) {
    return PageRouteBuilder<T>(
      settings: this,
      transitionDuration: Wx.motion,
      reverseTransitionDuration: Wx.motion,
      pageBuilder: (context, animation, secondaryAnimation) => child,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Wx.motionCurve,
          reverseCurve: Wx.motionCurve,
        );
        return FadeTransition(
          opacity: curved,
          child: AnimatedBuilder(
            animation: curved,
            builder: (context, child) {
              return Transform.translate(
                offset: Offset(0, (1 - curved.value) * Wx.motionRise),
                child: child,
              );
            },
            child: child,
          ),
        );
      },
    );
  }
}
