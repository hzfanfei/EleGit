import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/wenxiang_api.dart';
import '../copy/ask_engine.dart';
import '../models/diagnostics.dart';
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
  late AskEngineChoice _askEngine;
  bool _saving = false;
  bool _savingAskEngine = false;
  String? _saveError;
  String? _askEngineSaveError;
  bool _probing = false;
  DiagnosticsProbeResult? _probeResult;
  String? _probeError;

  @override
  void initState() {
    super.initState();
    _memory = widget.memory;
    _voiceId = _memory?.ttsVoice() ?? kDefaultVolcTtsVoice;
    _askEngine = _memory?.askEngine() ?? kDefaultAskEngine;
    if (_memory == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadMemory());
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_alignAskEngineWithServer());
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
        _askEngine = _memory!.askEngine();
      });
      unawaited(_alignAskEngineWithServer());
    } catch (_) {}
  }

  Future<void> _alignAskEngineWithServer() async {
    if (widget.api == null || _memory == null) return;
    try {
      final status = await widget.api!.status();
      final remote = parseAskEngineChoice(status.askEnginePreference);
      final local = _memory!.askEngine();
      if (remote == local) return;
      await widget.api!.setAskEngine(askEngineChoiceId(local));
    } catch (_) {}
  }

  Future<void> _selectAskEngine(AskEngineChoice choice) async {
    setState(() {
      _askEngine = choice;
      _askEngineSaveError = null;
      _savingAskEngine = true;
    });
    await _memory?.saveAskEngine(choice);
    try {
      await widget.api?.setAskEngine(askEngineChoiceId(choice));
    } catch (err) {
      if (mounted) {
        setState(() => _askEngineSaveError = err.toString());
      }
    } finally {
      if (mounted) setState(() => _savingAskEngine = false);
    }
  }

  Future<void> _runProbe() async {
    if (widget.api == null) {
      setState(() => _probeError = '尚未连接本机问象服务');
      return;
    }
    setState(() {
      _probing = true;
      _probeError = null;
      _probeResult = null;
    });
    try {
      final result = await widget.api!.runDiagnosticsProbe(ttsVoice: _voiceId);
      if (!mounted) return;
      setState(() => _probeResult = result);
    } catch (err) {
      if (!mounted) return;
      setState(() => _probeError = err.toString());
    } finally {
      if (mounted) setState(() => _probing = false);
    }
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
            subtitle: '问答 · ${askEngineChoiceLabel(_askEngine)} · 语音 · ${current.name}',
            onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
            backTooltip: '返回',
          ),
          const WxHairline(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 18, Wx.inset, 32),
              children: [
                Text('智能问答', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  '问书与仓库进度由本机服务调用所选助手。默认 Claude Code。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
                ),
                if (_savingAskEngine) ...[
                  const SizedBox(height: 10),
                  Text('正在同步到本机服务…', style: Theme.of(context).textTheme.labelSmall),
                ],
                if (_askEngineSaveError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    '已记在手机上，但还没同步到本机服务。$_askEngineSaveError',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.danger),
                  ),
                ],
                const SizedBox(height: 12),
                Material(
                  color: Wx.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: Wx.hairline),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < AskEngineChoice.values.length; i++) ...[
                        if (i > 0) const WxHairline(),
                        _AskEngineTile(
                          choice: AskEngineChoice.values[i],
                          selected: AskEngineChoice.values[i] == _askEngine,
                          onTap: () => _selectAskEngine(AskEngineChoice.values[i]),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 28),
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
                const SizedBox(height: 28),
                Text('通路检测', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  '最低成本自检：助手连接、模型一字回复、语音合成与识别握手。约消耗一字 TTS 与一字模型输出。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: _probing || widget.api == null ? null : _runProbe,
                  child: Text(_probing ? '检测中…' : '运行检测'),
                ),
                if (_probeError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _probeError!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.danger),
                  ),
                ],
                if (_probeResult != null) ...[
                  const SizedBox(height: 14),
                  _ProbeResultCard(result: _probeResult!),
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

class _ProbeResultCard extends StatelessWidget {
  const _ProbeResultCard({required this.result});

  final DiagnosticsProbeResult result;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Wx.raised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Wx.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.ok ? '全部通过' : '部分未通过',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: result.ok ? Wx.ok : Wx.danger,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 10),
            _ProbeLine(
              label: '问答助手',
              ok: result.askCli?.ok == true,
              detail: _stepDetail(result.askCli),
            ),
            _ProbeLine(
              label: '模型回复',
              ok: result.askModel?.ok == true,
              detail: _modelDetail(result.askModel),
            ),
            _ProbeLine(
              label: '语音合成',
              ok: result.voiceTts?.ok == true,
              detail: _ttsDetail(result.voiceTts),
            ),
            _ProbeLine(
              label: '语音识别',
              ok: result.voiceStt?.ok == true,
              detail: _sttDetail(result.voiceStt),
            ),
          ],
        ),
      ),
    );
  }

  String _stepDetail(DiagnosticsStep? step) {
    if (step == null) return '未检测';
    if (!step.ok) return '${step.ms} ms · ${step.error ?? "失败"}';
    return '${step.ms} ms · 已连接';
  }

  String _modelDetail(DiagnosticsStep? step) {
    if (step == null) return '未检测';
    if (!step.ok) return '${step.ms} ms · ${step.error ?? "失败"}';
    final tail = (step.snippet ?? '').isEmpty ? '' : ' · 「${step.snippet}」';
    return '${step.ms} ms$tail';
  }

  String _ttsDetail(DiagnosticsVoiceTtsStep? step) {
    if (step == null) return '未检测';
    if (!step.ok) return '${step.ms} ms · ${step.error ?? "失败"}';
    return '${step.ms} ms · 已收到音频';
  }

  String _sttDetail(DiagnosticsVoiceSttStep? step) {
    if (step == null) return '未检测';
    if (!step.ok) return '${step.ms} ms · ${step.error ?? "失败"}';
    return '${step.ms} ms · 连接正常';
  }
}

class _ProbeLine extends StatelessWidget {
  const _ProbeLine({
    required this.label,
    required this.ok,
    required this.detail,
  });

  final String label;
  final bool ok;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            size: 18,
            color: ok ? Wx.ok : Wx.danger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.titleSmall?.copyWith(color: Wx.text, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.bodySmall?.copyWith(
                    color: ok ? Wx.muted : Wx.text,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AskEngineTile extends StatelessWidget {
  const _AskEngineTile({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final AskEngineChoice choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDefault = choice == kDefaultAskEngine;
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
                  Text(askEngineChoiceLabel(choice), style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    isDefault ? '默认 · ${askEngineChoiceBlurb(choice)}' : askEngineChoiceBlurb(choice),
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
