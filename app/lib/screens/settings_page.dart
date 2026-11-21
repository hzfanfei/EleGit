import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/wenxiang_api.dart';
import '../widgets/codex_scope_settings.dart';
import '../models/diagnostics.dart';
import '../persist/app_memory.dart';
import '../theme.dart';
import '../utils/app_version.dart';
import '../utils/notification_center.dart';
import '../voice/cosyvoice_tts_voices.dart';
import '../voice/minimax_tts_voices.dart';
import '../voice/device_media.dart';
import '../voice/tts_voice_catalog.dart';
import '../voice/volc_tts_voices.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_edge_back.dart';
import 'log_center_page.dart';

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
  VoiceServiceProfile _voiceProfile = const VoiceServiceProfile();
  bool _saving = false;
  VoiceStackChoice? _pendingVoiceStack;
  String? _saveError;
  String? _voiceStackError;
  bool _probing = false;
  DiagnosticsProbeResult? _probeResult;
  String? _probeError;
  final DeviceVoiceMedia _previewMedia = DeviceVoiceMedia();
  String? _previewVoiceId;
  bool _previewLoading = false;
  String? _previewError;
  AppVersion? _appVersion;
  bool _appVersionLoading = false;
  bool _notificationSaving = false;
  String? _notificationError;

  @override
  void initState() {
    super.initState();
    _memory = widget.memory;
    _voiceId = _memory?.ttsVoice() ?? kDefaultVolcTtsVoice;
    if (_memory == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadMemory());
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_loadVoiceProfile());
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadAppVersion());
      }
    });
    widget.api?.linkEpoch.addListener(_onLinkChanged);
  }

  void _onLinkChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadAppVersion() async {
    if (_appVersionLoading) return;
    setState(() => _appVersionLoading = true);
    try {
      final v = await AppVersion.load();
      if (!mounted) return;
      setState(() {
        _appVersion = v;
      });
    } catch (_) {
      if (!mounted) return;
    } finally {
      if (mounted) setState(() => _appVersionLoading = false);
    }
  }

  Future<void> _loadVoiceProfile({bool adoptServerVoice = false}) async {
    if (widget.api == null) return;
    try {
      final status = await widget.api!.status();
      if (!mounted) return;
      final profile = status.voiceProfile;
      final preferred = adoptServerVoice
          ? profile.ttsVoice
          : (_memory?.ttsVoice() ?? profile.ttsVoice);
      final resolved = profile.resolveVoice(preferred);
      setState(() {
        _voiceProfile = profile;
        _voiceId = profile.voices.any((v) => v.id == resolved.id)
            ? resolved.id
            : profile.ttsVoice;
      });
      if (_memory != null && _voiceId != _memory!.ttsVoice()) {
        await _memory!.saveTtsVoice(_voiceId);
      }
    } catch (err) {
      if (adoptServerVoice) rethrow;
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
      unawaited(_loadVoiceProfile());
    } catch (_) {}
  }

  Future<void> _runProbe() async {
    if (_probing) return;
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

  Future<void> _selectVoiceStack(VoiceStackChoice choice) async {
    final stack = voiceStackId(choice);
    if (stack == _voiceProfile.activeVoiceStack ||
        _pendingVoiceStack != null ||
        _saving) {
      return;
    }
    setState(() {
      _pendingVoiceStack = choice;
      _voiceStackError = null;
    });
    try {
      await widget.api?.setVoiceStack(stack);
      await _loadVoiceProfile(adoptServerVoice: true);
    } catch (err) {
      if (mounted) setState(() => _voiceStackError = err.toString());
    } finally {
      if (mounted) setState(() => _pendingVoiceStack = null);
    }
  }

  Future<void> _selectVoice(TtsVoiceOption voice) async {
    if (_saving || _pendingVoiceStack != null) return;
    setState(() {
      _voiceId = voice.id;
      _saveError = null;
      _saving = true;
    });
    try {
      await _memory?.saveTtsVoice(voice.id);
      await widget.api?.setTtsVoice(voice.id);
    } catch (err) {
      if (mounted) {
        setState(() => _saveError = err.toString());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setNotifications(bool enabled) async {
    final api = widget.api;
    if (api == null || _notificationSaving) return;
    setState(() {
      _notificationSaving = true;
      _notificationError = null;
    });
    try {
      await NotificationCenter.instance.setEnabled(api, want: enabled);
    } catch (err) {
      if (mounted) setState(() => _notificationError = '通知设置保存失败：$err');
    } finally {
      if (mounted) setState(() => _notificationSaving = false);
    }
  }

  Future<void> _previewVoice(TtsVoiceOption voice) async {
    if (widget.api == null || _previewLoading) return;
    setState(() {
      _previewVoiceId = voice.id;
      _previewLoading = true;
      _previewError = null;
    });
    try {
      await _previewMedia.stopPlayback();
      final preview = await widget.api!.previewTtsVoice(voice.id);
      if (!mounted) return;
      await _previewMedia.playPcm(preview.pcm, sampleRate: preview.sampleRate);
    } catch (err) {
      if (mounted) setState(() => _previewError = err.toString());
    } finally {
      if (mounted) {
        setState(() {
          _previewLoading = false;
          _previewVoiceId = null;
        });
      }
    }
  }

  @override
  void dispose() {
    widget.api?.linkEpoch.removeListener(_onLinkChanged);
    _previewMedia.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _voiceProfile.resolveVoice(_voiceId);
    final voiceGroups = _voiceProfile.voiceGroups();
    final defaultVoiceId = _voiceProfile.usesCosyvoiceTts
        ? kDefaultCosyvoiceTtsVoice
        : _voiceProfile.usesMinimaxTts
            ? kDefaultMinimaxTtsVoice
            : kDefaultVolcTtsVoice;
    return WxEdgeBack(
      onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
      child: Scaffold(
        body: Column(
          children: [
            WxPageHeader(
              title: '设置',
              onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
              backTooltip: '返回',
              trailing: [
                IconButton(
                  key: const Key('wx-settings-log-center'),
                  tooltip: '日志中心',
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => LogCenterPage(api: widget.api),
                      ),
                    );
                  },
                  icon: const Icon(Icons.receipt_long_outlined),
                ),
              ],
            ),
            const WxHairline(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Wx.inset, 18, Wx.inset, 32),
                children: [
                  CodexScopeSettings(api: widget.api),
                  const SizedBox(height: 28),
                  _SectionLabel(
                    title: '语音',
                    value: voiceEngineSummary(_voiceProfile),
                    prominent: true,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '识别和合成一起切换。',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Wx.muted),
                  ),
                  if (_voiceStackError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      '还没换过去。$_voiceStackError',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Wx.danger),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Material(
                    color: Wx.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Wx.radius),
                      side: const BorderSide(color: Wx.hairline),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0;
                            i < VoiceStackChoice.values.length;
                            i++) ...[
                          if (i > 0) const WxHairline(),
                          _VoiceStackTile(
                            choice: VoiceStackChoice.values[i],
                            selected:
                                voiceStackId(VoiceStackChoice.values[i]) ==
                                    _voiceProfile.activeVoiceStack,
                            saving: _pendingVoiceStack ==
                                VoiceStackChoice.values[i],
                            onTap: _pendingVoiceStack != null || _saving
                                ? null
                                : () => _selectVoiceStack(
                                    VoiceStackChoice.values[i]),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  _SectionLabel(
                    title: '语音音色',
                    value: current.name,
                    prominent: true,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _voiceProfile.usesMinimaxTts
                        ? '快问快答使用 MiniMax 语音。'
                        : _voiceProfile.usesCosyvoiceTts
                            ? '快问快答使用本机 ${_voiceProfile.ttsEngine} 合成。'
                            : '快问快答使用火山引擎音色。',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Wx.muted),
                  ),
                  if (_voiceProfile.usesCosyvoiceTts) ...[
                    const SizedBox(height: 6),
                    Text(
                      '以下为 CosyVoice 中文 zero-shot 音色，companion 启动时会一并预载；切换后快问立即生效。',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: Wx.faint),
                    ),
                  ],
                  if (_saveError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      '已记在手机上，但还没同步到本机服务。$_saveError',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Wx.danger),
                    ),
                  ],
                  if (_previewError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      '试听失败：$_previewError',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Wx.danger),
                    ),
                  ],
                  const SizedBox(height: 16),
                  for (final group in voiceGroups) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: Text(
                        group.key,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: Wx.faint),
                      ),
                    ),
                    Material(
                      color: Wx.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Wx.radius),
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
                              defaultVoiceId: defaultVoiceId,
                              saving: _saving && group.value[i].id == _voiceId,
                              onTap: _saving || _pendingVoiceStack != null
                                  ? null
                                  : () => _selectVoice(group.value[i]),
                              onPreview: widget.api == null
                                  ? null
                                  : () =>
                                      unawaited(_previewVoice(group.value[i])),
                              previewLoading: _previewLoading &&
                                  _previewVoiceId == group.value[i].id,
                              previewDisabled:
                                  widget.api == null || _previewLoading,
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
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Wx.muted),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed:
                        _probing || widget.api == null ? null : _runProbe,
                    child: _probing
                        ? const WxInlineBusy('正在检测通路…')
                        : const Text('运行检测'),
                  ),
                  if (_probeError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _probeError!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Wx.danger),
                    ),
                  ],
                  if (_probeResult != null) ...[
                    const SizedBox(height: 14),
                    _ProbeResultCard(result: _probeResult!),
                  ],
                  const SizedBox(height: 28),
                  Text('通知中心', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    '问书后台任务完成时，通过本地系统通知提醒。无需服务器推送通道。',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Wx.muted),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<bool>(
                    valueListenable: NotificationCenter.instance.enabled,
                    builder: (context, isEnabled, _) {
                      if (widget.api == null) {
                        return Material(
                          color: Wx.surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(Wx.radius),
                            side: const BorderSide(color: Wx.hairline),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
                            child: Text('需要连接本机问象服务后才能开启通知。'),
                          ),
                        );
                      }
                      final status = isEnabled ? '已开启：后台任务完成时弹出通知' : '关闭';
                      return Material(
                        color: Wx.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(Wx.radius),
                          side: const BorderSide(color: Wx.hairline),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: SwitchListTile(
                          value: isEnabled,
                          onChanged:
                              _notificationSaving ? null : _setNotifications,
                          title: const Text('开启本地通知'),
                          subtitle: _notificationSaving
                              ? const WxInlineBusy('正在更新通知设置…')
                              : Text(
                                  _notificationError ?? status,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: _notificationError == null
                                            ? Wx.muted
                                            : Wx.danger,
                                      ),
                                ),
                          secondary: Icon(
                            isEnabled
                                ? Icons.notifications_active_rounded
                                : Icons.notifications_off_rounded,
                            color: isEnabled ? Wx.accent : Wx.faint,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 28),
                  Text('关于', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    '问象的本机客户端。版本号会随每次打包写入 APK 文件名。',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Wx.muted),
                  ),
                  const SizedBox(height: 12),
                  Material(
                    color: Wx.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Wx.radius),
                      side: const BorderSide(color: Wx.hairline),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '问象',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '打包自 hzfanfei/EleGit',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(color: Wx.faint),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            _appVersionLoading
                                ? '加载中…'
                                : _appVersion?.label ?? '版本不可用',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                              color: Wx.muted,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
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
        borderRadius: BorderRadius.circular(Wx.radius),
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
              label: '问书助手',
              ok: (result.askCliBook ?? result.askCli)?.ok == true,
              detail: _stepDetail(result.askCliBook ?? result.askCli),
            ),
            _ProbeLine(
              label: '问象助手',
              ok: (result.askCliRepo ?? result.askCli)?.ok == true,
              detail: _stepDetail(result.askCliRepo ?? result.askCli),
            ),
            _ProbeLine(
              label: '问书模型',
              ok: (result.askModelBook ?? result.askModel)?.ok == true,
              detail: _modelDetail(result.askModelBook ?? result.askModel),
            ),
            _ProbeLine(
              label: '问象模型',
              ok: (result.askModelRepo ?? result.askModel)?.ok == true,
              detail: _modelDetail(result.askModelRepo ?? result.askModel),
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
                  style: theme.titleSmall
                      ?.copyWith(color: Wx.text, fontWeight: FontWeight.w600),
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.title,
    required this.value,
    this.prominent = false,
  });

  final String title;
  final String value;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final titleStyle = prominent
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.titleSmall;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(title, style: titleStyle),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Wx.muted),
          ),
        ),
      ],
    );
  }
}

class _VoiceStackTile extends StatelessWidget {
  const _VoiceStackTile({
    required this.choice,
    required this.selected,
    required this.onTap,
    required this.saving,
  });

  final VoiceStackChoice choice;
  final bool selected;
  final VoidCallback? onTap;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(voiceStackLabel(choice),
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    voiceStackBlurb(choice),
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Wx.faint),
                  ),
                ],
              ),
            ),
            if (saving)
              const WxInlineBusy('同步中…')
            else if (selected)
              const Icon(Icons.check_rounded, color: Wx.accent, size: 20),
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
    required this.defaultVoiceId,
    required this.onTap,
    required this.saving,
    this.onPreview,
    this.previewLoading = false,
    this.previewDisabled = false,
  });

  final TtsVoiceOption voice;
  final bool selected;
  final String defaultVoiceId;
  final VoidCallback? onTap;
  final bool saving;
  final VoidCallback? onPreview;
  final bool previewLoading;
  final bool previewDisabled;

  @override
  Widget build(BuildContext context) {
    final isDefault = voice.id == defaultVoiceId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(voice.name,
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    isDefault ? '默认' : voice.scene,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Wx.faint),
                  ),
                ],
              ),
            ),
          ),
          if (onPreview != null)
            IconButton(
              onPressed: previewDisabled ? null : onPreview,
              tooltip: previewLoading ? '正在准备试听…' : '试听',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              icon: previewLoading
                  ? const WxLoading(size: 18)
                  : const Icon(Icons.volume_up_rounded,
                      size: 22, color: Wx.muted),
            ),
          if (saving)
            const WxInlineBusy('同步中…')
          else if (selected)
            const Icon(Icons.check_rounded, color: Wx.accent, size: 20),
        ],
      ),
    );
  }
}
