import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/wenxiang_api.dart';
import '../copy/ask_engine.dart';
import '../models/diagnostics.dart';
import '../persist/app_memory.dart';
import '../theme.dart';
import '../utils/app_version.dart';
import '../utils/notification_center.dart';
import '../voice/cosyvoice_tts_voices.dart';
import '../voice/device_media.dart';
import '../voice/tts_voice_catalog.dart';
import '../voice/volc_tts_voices.dart';
import '../voice/xiaomi_tts_voices.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_edge_back.dart';
import '../widgets/wx_link_route.dart';

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
  late AskEngineChoice _askEngineBook;
  late AskEngineChoice _askEngineRepo;
  bool _saving = false;
  bool _savingAskEngineBook = false;
  bool _savingAskEngineRepo = false;
  bool _savingVoiceStack = false;
  String? _saveError;
  String? _askEngineBookSaveError;
  String? _askEngineRepoSaveError;
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

  @override
  void initState() {
    super.initState();
    _memory = widget.memory;
    _voiceId = _memory?.ttsVoice() ?? kDefaultVolcTtsVoice;
    _askEngineBook = _memory?.askEngineBook() ?? kDefaultAskEngine;
    _askEngineRepo = _memory?.askEngineRepo() ?? kDefaultAskEngine;
    if (_memory == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadMemory());
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_alignAskEngineWithServer());
          unawaited(_loadVoiceProfile());
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadAppVersion());
    });
    widget.api?.linkEpoch.addListener(_onLinkChanged);
  }

  void _onLinkChanged() {
    if (mounted) setState(() {});
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
      final preferred = adoptServerVoice ? profile.ttsVoice : (_memory?.ttsVoice() ?? profile.ttsVoice);
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
        _askEngineBook = _memory!.askEngineBook();
        _askEngineRepo = _memory!.askEngineRepo();
      });
      unawaited(_alignAskEngineWithServer());
      unawaited(_loadVoiceProfile());
    } catch (_) {}
  }

  Future<void> _alignAskEngineWithServer() async {
    if (widget.api == null || _memory == null) return;
    try {
      final status = await widget.api!.status();
      final bookRemote = parseAskEngineChoice(status.askEngineBookPreference);
      final repoRemote = parseAskEngineChoice(status.askEngineRepoPreference);
      final bookLocal = _memory!.askEngineBook();
      final repoLocal = _memory!.askEngineRepo();
      if (!_memory!.askEngineBookIsExplicit()) {
        if (bookRemote != bookLocal) {
          await _memory!.saveAskEngineFor(AskEngineScope.book, bookRemote);
          if (mounted) setState(() => _askEngineBook = bookRemote);
        }
      } else if (bookRemote != bookLocal) {
        await widget.api!.setAskEngine(
          askEngineChoiceId(bookLocal),
          scope: AskEngineScope.book,
        );
      }
      if (!_memory!.askEngineRepoIsExplicit()) {
        if (repoRemote != repoLocal) {
          await _memory!.saveAskEngineFor(AskEngineScope.repo, repoRemote);
          if (mounted) setState(() => _askEngineRepo = repoRemote);
        }
      } else if (repoRemote != repoLocal) {
        await widget.api!.setAskEngine(
          askEngineChoiceId(repoLocal),
          scope: AskEngineScope.repo,
        );
      }
    } catch (_) {}
  }

  Future<void> _selectAskEngine(AskEngineScope scope, AskEngineChoice choice) async {
    final savingBook = scope == AskEngineScope.book;
    setState(() {
      if (savingBook) {
        _askEngineBook = choice;
        _askEngineBookSaveError = null;
        _savingAskEngineBook = true;
      } else {
        _askEngineRepo = choice;
        _askEngineRepoSaveError = null;
        _savingAskEngineRepo = true;
      }
    });
    await _memory?.saveAskEngineFor(scope, choice);
    try {
      await widget.api?.setAskEngine(askEngineChoiceId(choice), scope: scope);
    } catch (err) {
      if (mounted) {
        setState(() {
          if (savingBook) {
            _askEngineBookSaveError = err.toString();
          } else {
            _askEngineRepoSaveError = err.toString();
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          if (savingBook) {
            _savingAskEngineBook = false;
          } else {
            _savingAskEngineRepo = false;
          }
        });
      }
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

  Future<void> _selectVoiceStack(VoiceStackChoice choice) async {
    final stack = voiceStackId(choice);
    if (stack == _voiceProfile.activeVoiceStack || _savingVoiceStack) return;
    setState(() {
      _savingVoiceStack = true;
      _voiceStackError = null;
    });
    try {
      await widget.api?.setVoiceStack(stack);
      await _loadVoiceProfile(adoptServerVoice: true);
    } catch (err) {
      if (mounted) setState(() => _voiceStackError = err.toString());
    } finally {
      if (mounted) setState(() => _savingVoiceStack = false);
    }
  }

  Future<void> _selectVoice(TtsVoiceOption voice) async {
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
        : _voiceProfile.usesXiaomiTts
            ? kDefaultXiaomiTtsVoice
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
          ),
          const WxHairline(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 18, Wx.inset, 32),
              children: [
                if (widget.api != null) ...[
                  Row(
                    children: [
                      WxLinkRouteMark(baseUrl: widget.api!.baseUrl),
                      const SizedBox(width: 8),
                      Text(
                        widget.api!.linkLabel,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                ],
                Text('智能问答', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  '问书与问象可分别选择 Claude Code 或 Cursor，由本机服务调用。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
                ),
                const SizedBox(height: 16),
                _SectionLabel(
                  title: askEngineScopeTitle(AskEngineScope.book),
                  value: askEngineChoiceLabel(_askEngineBook),
                ),
                if (_savingAskEngineBook) ...[
                  const SizedBox(height: 6),
                  Text('正在同步问书…', style: Theme.of(context).textTheme.labelSmall),
                ],
                if (_askEngineBookSaveError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '问书已记在手机上，但还没同步到本机服务。$_askEngineBookSaveError',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.danger),
                  ),
                ],
                const SizedBox(height: 8),
                _AskEnginePicker(
                  scope: AskEngineScope.book,
                  selected: _askEngineBook,
                  onSelect: (c) => _selectAskEngine(AskEngineScope.book, c),
                ),
                const SizedBox(height: 20),
                _SectionLabel(
                  title: askEngineScopeTitle(AskEngineScope.repo),
                  value: askEngineChoiceLabel(_askEngineRepo),
                ),
                if (_savingAskEngineRepo) ...[
                  const SizedBox(height: 6),
                  Text('正在同步问象…', style: Theme.of(context).textTheme.labelSmall),
                ],
                if (_askEngineRepoSaveError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '问象已记在手机上，但还没同步到本机服务。$_askEngineRepoSaveError',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.danger),
                  ),
                ],
                const SizedBox(height: 8),
                _AskEnginePicker(
                  scope: AskEngineScope.repo,
                  selected: _askEngineRepo,
                  onSelect: (c) => _selectAskEngine(AskEngineScope.repo, c),
                ),
                const SizedBox(height: 28),
                _SectionLabel(
                  title: '语音',
                  value: voiceEngineSummary(_voiceProfile),
                  prominent: true,
                ),
                const SizedBox(height: 6),
                Text(
                  '识别和合成一起切换。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
                ),
                if (_savingVoiceStack) ...[
                  const SizedBox(height: 10),
                  Text('正在同步到本机服务…', style: Theme.of(context).textTheme.labelSmall),
                ],
                if (_voiceStackError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    '还没换过去。$_voiceStackError',
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
                      for (var i = 0; i < VoiceStackChoice.values.length; i++) ...[
                        if (i > 0) const WxHairline(),
                        _VoiceStackTile(
                          choice: VoiceStackChoice.values[i],
                          selected: voiceStackId(VoiceStackChoice.values[i]) ==
                              _voiceProfile.activeVoiceStack,
                          onTap: () => _selectVoiceStack(VoiceStackChoice.values[i]),
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
                  _voiceProfile.usesXiaomiTts
                      ? '快问快答使用小米 MiMo 语音。'
                      : _voiceProfile.usesCosyvoiceTts
                          ? '快问快答使用本机 ${_voiceProfile.ttsEngine} 合成。'
                          : '快问快答使用火山引擎音色。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
                ),
                if (_voiceProfile.usesCosyvoiceTts) ...[
                  const SizedBox(height: 6),
                  Text(
                    '以下为 CosyVoice 中文 zero-shot 音色，companion 启动时会一并预载；切换后快问立即生效。',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint),
                  ),
                ],
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
                if (_previewError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    '试听失败：$_previewError',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.danger),
                  ),
                ],
                const SizedBox(height: 16),
                for (final group in voiceGroups) ...[
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
                            defaultVoiceId: defaultVoiceId,
                            onTap: () => _selectVoice(group.value[i]),
                            onPreview: widget.api == null
                                ? null
                                : () => unawaited(_previewVoice(group.value[i])),
                            previewLoading:
                                _previewLoading && _previewVoiceId == group.value[i].id,
                            previewDisabled: widget.api == null || _previewLoading,
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
                const SizedBox(height: 28),
                Text('通知中心', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  '问书后台任务完成时，通过本地系统通知提醒。无需服务器推送通道。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<bool>(
                  valueListenable: NotificationCenter.instance.enabled,
                  builder: (context, isEnabled, _) {
                    if (widget.api == null) {
                      return Material(
                        color: Wx.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: const BorderSide(color: Wx.hairline),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
                          child: Text('需要连接本机问象服务后才能开启通知。'),
                        ),
                      );
                    }
                    final status = isEnabled
                        ? '已开启：后台任务完成时弹出通知'
                        : '关闭';
                    return Material(
                      color: Wx.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: Wx.hairline),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: SwitchListTile(
                        value: isEnabled,
                        onChanged: (val) {
                          NotificationCenter.instance
                              .setEnabled(widget.api!, want: val)
                              .catchError((Object err) {
                            if (!mounted) return null;
                            setState(() => _saveError = err.toString());
                            return null;
                          });
                        },
                        title: const Text('开启本地通知'),
                        subtitle: Text(
                          status,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
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
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
                ),
                const SizedBox(height: 12),
                Material(
                  color: Wx.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
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
                                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          _appVersionLoading
                              ? '加载中…'
                              : _appVersion?.label ?? '版本不可用',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Wx.muted,
                                fontFeatures: const [FontFeature.tabularFigures()],
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
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
          ),
        ),
      ],
    );
  }
}

class _AskEnginePicker extends StatelessWidget {
  const _AskEnginePicker({
    required this.scope,
    required this.selected,
    required this.onSelect,
  });

  final AskEngineScope scope;
  final AskEngineChoice selected;
  final ValueChanged<AskEngineChoice> onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
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
              scope: scope,
              choice: AskEngineChoice.values[i],
              selected: AskEngineChoice.values[i] == selected,
              onTap: () => onSelect(AskEngineChoice.values[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _AskEngineTile extends StatelessWidget {
  const _AskEngineTile({
    required this.scope,
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final AskEngineScope scope;
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
                    isDefault
                        ? '默认 · ${askEngineChoiceBlurb(choice, scope)}'
                        : askEngineChoiceBlurb(choice, scope),
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

class _VoiceStackTile extends StatelessWidget {
  const _VoiceStackTile({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final VoiceStackChoice choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
                  Text(voiceStackLabel(choice), style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    voiceStackBlurb(choice),
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
    required this.defaultVoiceId,
    required this.onTap,
    this.onPreview,
    this.previewLoading = false,
    this.previewDisabled = false,
  });

  final TtsVoiceOption voice;
  final bool selected;
  final String defaultVoiceId;
  final VoidCallback onTap;
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
              splashFactory: NoSplash.splashFactory,
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              onTap: onTap,
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
          ),
          if (onPreview != null)
            IconButton(
              onPressed: previewDisabled && !previewLoading ? null : onPreview,
              tooltip: '试听',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              icon: previewLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.volume_up_rounded, size: 22, color: Wx.muted),
            ),
          if (selected) const Icon(Icons.check_rounded, color: Wx.accent, size: 20),
        ],
      ),
    );
  }
}
