import 'package:flutter/material.dart';
import '../api/wenxiang_api.dart';
import '../copy/ask_engine.dart';
import '../theme.dart';
import 'wx_chrome.dart';

class CodexScopeSettings extends StatefulWidget {
  const CodexScopeSettings({super.key, this.api});
  final WenxiangApi? api;
  @override
  State<CodexScopeSettings> createState() => _CodexScopeSettingsState();
}

class _CodexScopeSettingsState extends State<CodexScopeSettings> {
  List<Map<String, dynamic>> _models = [];
  Map<String, dynamic> _scopes = {};
  bool _loading = false;
  final _saving = <AskEngineScope>{};
  final _selecting = <AskEngineScope>{};
  AskEngineScope? _saved;
  AskEngineScope? _failed;
  String? _error;
  AskEngineScope? _testing;
  final _speedResults = <String, String>{};
  Map<String, dynamic>? _usage;
  bool _usageLoading = false;
  bool _usageFailed = false;

  Future<void> _refreshUsage() async {
    final api = widget.api;
    if (api == null || _usageLoading) return;
    setState(() { _usageLoading = true; _usageFailed = false; });
    try {
      final usage = await api.codexUsage();
      if (mounted && widget.api == api) setState(() => _usage = usage);
    } catch (_) {
      if (mounted && widget.api == api) setState(() { _usage = null; _usageFailed = true; });
    } finally {
      if (mounted) setState(() => _usageLoading = false);
    }
  }

  String _usageText(Map window) {
    final used = window['usedPercent'];
    if (used is! num) return '额度数据暂不可用';
    final mins = window['windowDurationMins'];
    final duration = mins is num && mins > 0
        ? (mins % 1440 == 0 ? '${mins ~/ 1440}天' : mins % 60 == 0 ? '${mins ~/ 60}小时' : '$mins分钟')
        : '当前';
    final reset = window['resetsAt'];
    var resetText = '';
    if (reset is num && reset > 0) {
      final date = DateTime.fromMillisecondsSinceEpoch((reset * 1000).round()).toLocal();
      resetText = ' · ${date.month}月${date.day}日 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} 重置';
    }
    return '$duration额度剩余 ${(100 - used).clamp(0, 100).toStringAsFixed(used % 1 == 0 ? 0 : 1)}%$resetText';
  }

  Future<void> _testSpeed(AskEngineScope scope) async {
    if (_testing != null || _saving.isNotEmpty || widget.api == null) return;
    final key = askEngineScopeId(scope);
    setState(() {
      _testing = scope;
      _speedResults.remove(key);
    });
    try {
      final result = await widget.api!.measureModelSpeed(scope);
      if (!mounted) return;
      final rate = result['tokensPerSecond'] as num?;
      final first = (result['firstTokenMs'] as num) / 1000;
      setState(() => _speedResults[key] = rate == null
          ? '首字 ${first.toStringAsFixed(2)} 秒 · 供应商未返回 token 用量，无法计算 token/秒'
          : '${rate.toStringAsFixed(1)} token/秒 · 首字 ${first.toStringAsFixed(2)} 秒 · ${result['outputTokens']} 输出 token');
    } catch (err) {
      if (mounted) setState(() => _speedResults[key] = '测速失败：$err');
    } finally {
      if (mounted) setState(() => _testing = null);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.api?.linkEpoch.addListener(_refresh);
    widget.api?.linkEpoch.addListener(_refreshUsage);
    _refresh();
    _refreshUsage();
  }

  @override
  void didUpdateWidget(covariant CodexScopeSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      oldWidget.api?.linkEpoch.removeListener(_refresh);
      oldWidget.api?.linkEpoch.removeListener(_refreshUsage);
      widget.api?.linkEpoch.addListener(_refresh);
      widget.api?.linkEpoch.addListener(_refreshUsage);
      _refresh();
      _refreshUsage();
    }
  }

  @override
  void dispose() {
    widget.api?.linkEpoch.removeListener(_refresh);
    widget.api?.linkEpoch.removeListener(_refreshUsage);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading || _saving.isNotEmpty || widget.api == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _failed = null;
    });
    try {
      final result = await widget.api!.codexModels();
      if (!mounted) return;
      setState(() {
        _models = (result['models'] as List)
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        _scopes = Map<String, dynamic>.from(result['scopes'] ?? {});
      });
    } catch (err) {
      if (mounted) setState(() => _error = err.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _save(AskEngineScope scope, String model,
      {String? effort, bool? fast, bool select = true}) async {
    if (_saving.contains(scope) || widget.api == null) return false;
    setState(() {
      _saving.add(scope);
      if (select) _selecting.add(scope);
      _speedResults.remove(askEngineScopeId(scope));
      _saved = null;
      _failed = null;
      _error = null;
    });
    try {
      await widget.api!.setCodexModel(model,
          scope: scope, effort: effort, fast: fast, select: select);
      if (!mounted) return false;
      setState(() {
        final key = askEngineScopeId(scope);
        final config = Map<String, dynamic>.from(_scopes[key] ?? {});
        final preferences =
            Map<String, dynamic>.from(config['preferences'] ?? {});
        preferences[model] = {
          ...Map<String, dynamic>.from(preferences[model] ?? {}),
          if (effort != null) 'effort': effort,
          if (fast != null) 'fast': fast,
        };
        _scopes[key] = {
          ...config,
          if (select) 'model': model,
          'preferences': preferences
        };
        _saved = scope;
      });
      return true;
    } catch (err) {
      if (mounted) {
        setState(() {
          _failed = scope;
          _error = err.toString();
        });
      }
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _saving.remove(scope);
          _selecting.remove(scope);
        });
      }
    }
  }

  Future<void> _choose(AskEngineScope scope, String? selected) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
          child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .7),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${askEngineScopeTitle(scope)} · 选择模型',
              style: Theme.of(ctx).textTheme.titleMedium),
          const Padding(
              padding: EdgeInsets.all(12), child: Text('仅用于当前场景，下一次提问生效。')),
          Flexible(
              child: ListView(shrinkWrap: true, children: [
            for (final model in _models)
              ListTile(
                key: Key('codex-option-${model['id']}'),
                title: Text(model['label'] as String),
                subtitle: Text(model['id'] as String),
                trailing: Icon(
                    model['id'] == selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: model['id'] == selected ? Wx.accent : Wx.muted),
                onTap: () => Navigator.pop(ctx, model['id'] as String),
              ),
          ])),
        ]),
      )),
    );
    if (mounted && picked != null && picked != selected) {
      await _save(scope, picked);
    }
  }

  Widget _card(AskEngineScope scope) {
    final key = askEngineScopeId(scope);
    final config = Map<String, dynamic>.from(_scopes[key] ?? {});
    final selected = config['model'] as String?;
    final matches = _models.where((m) => m['id'] == selected);
    final model = matches.isEmpty ? null : matches.first;
    final preferences = Map<String, dynamic>.from(config['preferences'] ?? {});
    final prefs = Map<String, dynamic>.from(preferences[selected] ?? {});
    final enabled = !_loading && _testing == null && widget.api != null;
    final muted =
        Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted);
    return Material(
      key: Key('codex-$key'),
      color: Wx.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Wx.radius),
          side: const BorderSide(color: Wx.hairline)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(scope == AskEngineScope.book ? '问书' : '问象',
                        style: Theme.of(context).textTheme.titleSmall)),
                Text('Codex', style: muted),
              ]),
              const SizedBox(height: 4),
              Text(
                  scope == AskEngineScope.book ? '阅读理解与书中问答' : '仓库问答与 Agent 任务',
                  style: muted),
            ])),
        const WxHairline(),
        ListTile(
          key: Key('codex-$key-model'),
          title: const Text('模型'),
          subtitle: Text(model?['label'] as String? ??
              (selected?.isNotEmpty == true ? selected! : '跟随本机默认模型')),
          trailing: const Icon(Icons.chevron_right_rounded),
          enabled: enabled && _models.isNotEmpty,
          onTap:
              _saving.contains(scope) ? null : () => _choose(scope, selected),
        ),
        if (model != null &&
            (model['supportsFast'] == true ||
                (model['reasoningEfforts'] as List? ?? []).toSet().length > 1))
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _ModelTuning(
                key: ValueKey('$key-$selected'),
                efforts:
                    (model['reasoningEfforts'] as List? ?? []).cast<String>(),
                effort: (prefs['effort'] ?? model['defaultReasoningEffort'])
                    as String?,
                enabled: enabled && !_selecting.contains(scope),
                fast: prefs['fast'] == true,
                supportsFast: model['supportsFast'] == true,
                onSave: ({effort, fast}) => _save(scope, selected!,
                    effort: effort, fast: fast, select: false),
              )),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              TextButton.icon(
                onPressed: enabled ? () => _testSpeed(scope) : null,
                icon: const Icon(Icons.speed_rounded, size: 18),
                label: Text(_testing == scope ? '正在测速…' : '模型测速'),
              ),
              const Expanded(
                  child: Text('会生成一段测试文字，消耗模型额度',
                      style: TextStyle(fontSize: 11, color: Wx.muted))),
            ])),
        if (_speedResults[key] != null)
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(_speedResults[key]!, style: muted)),
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Text(
                _saving.contains(scope)
                    ? '正在保存…'
                    : _failed == scope
                        ? '保存失败，当前配置未更改。$_error'
                        : _saved == scope
                            ? '已保存，下一次提问生效'
                            : '独立设置，下一次提问生效',
                style: muted?.copyWith(
                    color: _failed == scope ? Wx.danger : Wx.muted))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('智能问答', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text('统一使用 Codex，问书与问象的模型和参数分别设置。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Wx.muted)),
        const SizedBox(height: 16),
        if (widget.api != null)
          Card(child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(child: Text('Codex 套餐用量')),
                TextButton(onPressed: _usageLoading ? null : _refreshUsage, child: const Text('刷新')),
              ]),
              if (_usageLoading) const Text('正在查询用量…')
              else if (_usageFailed) const Text('用量查询失败，请点击刷新重试')
              else if (_usage?['primary'] == null && _usage?['secondary'] == null)
                const Text('当前账号未返回额度信息')
              else ...[
                if (_usage?['primary'] is Map) Text(_usageText(_usage!['primary'] as Map)),
                if (_usage?['secondary'] is Map) Text(_usageText(_usage!['secondary'] as Map)),
              ],
            ]),
          )),
        if (widget.api != null) const SizedBox(height: 12),
        if (_loading)
          const Padding(
              padding: EdgeInsets.only(bottom: 12), child: Text('正在加载模型…')),
        if (widget.api == null) const Text('连接本机服务后可设置模型。'),
        if (_error != null && _failed == null)
          Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('模型列表加载失败，请重新进入设置。$_error',
                  style: const TextStyle(color: Wx.danger))),
        if (!_loading &&
            widget.api != null &&
            _models.isEmpty &&
            _error == null)
          const Text('暂无可用模型，请确认本机 Codex 已登录后重新进入设置。'),
        _card(AskEngineScope.book),
        const SizedBox(height: 12),
        _card(AskEngineScope.repo),
      ]);
}

/// Keeps edits visible and serializes saves while controls remain interactive.
class _ModelTuning extends StatefulWidget {
  const _ModelTuning(
      {super.key,
      required this.efforts,
      required this.effort,
      required this.fast,
      required this.supportsFast,
      required this.onSave,
      this.enabled = true});
  final List<String> efforts;
  final String? effort;
  final bool fast;
  final bool supportsFast;
  final bool enabled;
  final Future<bool> Function({String? effort, bool? fast}) onSave;

  @override
  State<_ModelTuning> createState() => _ModelTuningState();
}

class _ModelTuningState extends State<_ModelTuning> {
  double? _drag;
  String? _effort;
  bool? _fast;
  String? _pendingEffort;
  bool? _pendingFast;
  bool _saving = false;

  Future<void> _save({String? effort, bool? fast}) async {
    setState(() {
      if (effort != null) _pendingEffort = _effort = effort;
      if (fast != null) _pendingFast = _fast = fast;
      _drag = null;
    });
    if (_saving) return;
    _saving = true;
    while (mounted && (_pendingEffort != null || _pendingFast != null)) {
      final effort = _pendingEffort;
      final fast = _pendingFast;
      _pendingEffort = null;
      _pendingFast = null;
      final saved = await widget.onSave(effort: effort, fast: fast);
      if (!mounted) return;
      if (!saved) {
        setState(() {
          if (effort != null && _pendingEffort == null) _effort = null;
          if (fast != null && _pendingFast == null) _fast = null;
        });
      }
    }
    _saving = false;
  }

  static const _labels = {
    'none': '无',
    'minimal': '最低',
    'low': '低',
    'medium': '中',
    'high': '高',
    'xhigh': '极高',
    'max': '最大',
    'ultra': '超高',
    'auto': '自动'
  };
  String _label(String value) => _labels[value] ?? value;

  @override
  void didUpdateWidget(covariant _ModelTuning oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_saving) {
      _effort = null;
      _fast = null;
    }
    if (!widget.enabled) _drag = null;
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.efforts.toSet().toList();
    final adjustable = steps.length > 1;
    if (!adjustable && !widget.supportsFast) return const SizedBox.shrink();
    final index = steps.indexOf(_effort ?? widget.effort ?? '');
    final value = (_drag ?? (index < 0 ? 0 : index).toDouble())
        .clamp(0.0, adjustable ? (steps.length - 1).toDouble() : 0.0);
    final fast = _fast ?? widget.fast;
    final current = steps.isEmpty ? '自动' : _label(steps[value.round()]);
    final muted =
        Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.muted);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        if (adjustable) ...[
          Text('思考强度', style: muted),
          const SizedBox(width: 8),
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                  color: Wx.accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(current,
                  style: const TextStyle(fontSize: 12, color: Wx.accent))),
        ],
        if (widget.supportsFast) ...[
          if (adjustable) const Spacer(),
          Text('快速模式', style: muted),
          const SizedBox(width: 4),
          SizedBox(
              height: 36,
              child: Switch(
                value: fast,
                onChanged: widget.enabled ? (v) => _save(fast: v) : null,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )),
        ],
      ]),
      if (adjustable) ...[
        SliderTheme(
            data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: Wx.accent,
                thumbColor: Wx.accent,
                overlayColor: Wx.accent.withValues(alpha: 0.10),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16)),
            child: SizedBox(
                height: 36,
                child: Slider(
                  value: value,
                  min: 0,
                  max: (steps.length - 1).toDouble(),
                  divisions: steps.length - 1,
                  label: current,
                  semanticFormatterCallback: (v) => _label(steps[v.round()]),
                  onChanged:
                      widget.enabled ? (v) => setState(() => _drag = v) : null,
                  onChangeEnd: widget.enabled
                      ? (v) {
                          if (steps[v.round()] != (_effort ?? widget.effort)) {
                            _save(effort: steps[v.round()]);
                          } else {
                            setState(() => _drag = null);
                          }
                        }
                      : null,
                ))),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(_label(steps.first), style: muted),
          Text(_label(steps.last), style: muted),
        ]),
      ],
      if (fast && widget.supportsFast) Text('加速响应，用量更高', style: muted),
    ]);
  }
}
