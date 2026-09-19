import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/wenxiang_api.dart';
import '../persist/app_memory.dart';
import '../theme.dart';
import '../voice/volc_tts_voices.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_edge_back.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.api, this.memory, this.onBack});

  final WenxiangApi? api;
  final AppMemory? memory;
  final VoidCallback? onBack;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppMemory? _memory;
  late String _voiceId;
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _memory = widget.memory;
    _voiceId = _memory?.ttsVoice() ?? kDefaultVolcTtsVoice;
    if (_memory == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadMemory());
      });
    }
  }

  Future<void> _loadMemory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _memory = AppMemory(prefs);
        _voiceId = _memory!.ttsVoice();
      });
    } catch (_) {}
  }

  Future<void> _select(VolcTtsVoice voice) async {
    setState(() {
      _voiceId = voice.id;
      _saveError = null;
      _saving = true;
    });
    await _memory?.saveTtsVoice(voice.id);
    try {
      await widget.api?.setTtsVoice(voice.id);
    } catch (err) {
      if (mounted) {
        setState(() => _saveError = err.toString());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = resolveVolcTtsVoice(_voiceId);
    return WxEdgeBack(
      onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
      child: Scaffold(
      body: Column(
        children: [
          WxPageHeader(
            title: '设置',
            subtitle: '语音朗读 · ${current.name}',
            onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
            backTooltip: '返回',
          ),
          const WxHairline(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 18, Wx.inset, 32),
              children: [
                Text('语音音色', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  '快问快答立刻用这个音色。当前 ${current.name}。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
                ),
                if (_saving) ...[
                  const SizedBox(height: 10),
                  Text('正在同步到本机服务…', style: Theme.of(context).textTheme.labelSmall),
                ],
                if (_saveError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    '已记在手机上，但还没同步到本机服务。$_saveError',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.danger),
                  ),
                ],
                const SizedBox(height: 16),
                for (final group in volcTtsVoiceGroups) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    child: Text(
                      group.key,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint),
                    ),
                  ),
                  Material(
                    color: Wx.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: Wx.hairline),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < group.value.length; i++) ...[
                          if (i > 0) const WxHairline(),
                          _VoiceTile(
                            voice: group.value[i],
                            selected: group.value[i].id == _voiceId,
                            onTap: () => _select(group.value[i]),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
    );
  }
}

class _VoiceTile extends StatelessWidget {
  const _VoiceTile({
    required this.voice,
    required this.selected,
    required this.onTap,
  });

  final VolcTtsVoice voice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDefault = voice.id == kDefaultVolcTtsVoice;
    return InkWell(
      splashFactory: NoSplash.splashFactory,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(voice.name, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    isDefault ? '默认' : voice.scene,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint),
                  ),
                ],
              ),
            ),
            if (selected) const Icon(Icons.check_rounded, color: Wx.accent, size: 20),
          ],
        ),
      ),
    );
  }
}
