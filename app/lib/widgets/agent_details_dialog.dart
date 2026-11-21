import 'package:flutter/material.dart';

import '../api/wenxiang_api.dart';
import '../copy/ask_engine.dart';
import 'wx_chrome.dart';

class AgentModelButton extends StatelessWidget {
  const AgentModelButton({super.key, required this.api, required this.scope});
  final WenxiangApi api;
  final AskEngineScope scope;

  @override
  Widget build(BuildContext context) {
    void open() => showDialog<void>(
        context: context,
        builder: (_) =>
            AgentDetailsDialog(api: api, scope: scope, agentMode: false));
    return OutlinedButton(
      key: ValueKey('agent-model-button-${askEngineScopeId(scope)}'),
      onPressed: open,
      onLongPress: open,
      style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 32),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.compact),
      child: const Text('Agent'),
    );
  }
}

/// Model settings and diagnostics for the module that opened this dialog.
class AgentDetailsDialog extends StatefulWidget {
  const AgentDetailsDialog(
      {super.key,
      required this.api,
      required this.agentMode,
      required this.scope,
      this.initialUsage});

  final WenxiangApi api;
  final bool agentMode;
  final AskEngineScope scope;
  final Map<String, dynamic>? initialUsage;

  @override
  State<AgentDetailsDialog> createState() => _AgentDetailsDialogState();
}

class _AgentDetailsDialogState extends State<AgentDetailsDialog> {
  Map<String, dynamic>? _config;
  Map<String, dynamic>? _usage;
  String? _configError;
  String? _usageError;
  String? _speed;
  bool _loading = false;
  bool _testing = false;
  bool _saving = false;
  String? _saveMessage;

  String get _scopeId => askEngineScopeId(widget.scope);
  String get _scopeTitle => widget.scope == AskEngineScope.book ? '问书' : '问象';

  Future<void> _chooseModel() async {
    if (_loading || _testing || _saving || _config == null) return;
    final selected = (_config!['scopes'] as Map?)?[_scopeId]?['model'];
    final models =
        (_config!['models'] as List? ?? []).whereType<Map>().toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('$_scopeTitle · 选择模型',
            style: Theme.of(context).textTheme.titleMedium),
        Flexible(
            child: ListView(shrinkWrap: true, children: [
          for (final model in models)
            ListTile(
              key: ValueKey('agent-model-${model['id']}'),
              title: Text((model['label'] ?? model['id']).toString()),
              trailing: Icon(model['id'] == selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              onTap: () => Navigator.pop(context, model['id'].toString()),
            ),
        ])),
      ])),
    );
    if (!mounted || picked == null || picked == selected) return;
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    try {
      await widget.api.setCodexModel(picked, scope: widget.scope);
      if (!mounted) return;
      setState(() {
        final scopes = Map<String, dynamic>.from(_config!['scopes'] ?? {});
        scopes[_scopeId] = {
          ...Map<String, dynamic>.from(scopes[_scopeId] ?? {}),
          'model': picked
        };
        _config = {..._config!, 'scopes': scopes};
        _speed = null;
        _saveMessage = null;
      });
      await _loadConfig();
    } catch (err) {
      if (mounted) setState(() => _saveMessage = '切换失败：$err');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveTuning(String model, {String? effort, bool? fast}) async {
    if (_loading || _testing || _saving) return;
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    try {
      await widget.api.setCodexModel(model,
          scope: widget.scope, effort: effort, fast: fast, select: false);
      if (!mounted) return;
      setState(() {
        final scopes = Map<String, dynamic>.from(_config!['scopes'] ?? {});
        final scope = Map<String, dynamic>.from(scopes[_scopeId] ?? {});
        final preferences =
            Map<String, dynamic>.from(scope['preferences'] ?? {});
        preferences[model] = {
          ...Map<String, dynamic>.from(preferences[model] ?? {}),
          if (effort != null) 'effort': effort,
          if (fast != null) 'fast': fast,
        };
        scopes[_scopeId] = {...scope, 'preferences': preferences};
        _config = {..._config!, 'scopes': scopes};
        _speed = null;
        _saveMessage = null;
      });
    } catch (err) {
      if (mounted) setState(() => _saveMessage = '参数保存失败：$err');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _usage = widget.initialUsage;
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading || _testing || _saving) return;
    setState(() {
      _loading = true;
      _configError = null;
      _usageError = null;
    });
    await Future.wait([_loadConfig(), _loadUsage()]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadConfig() async {
    try {
      final config = await widget.api.codexModels();
      if (mounted) setState(() => _config = config);
    } catch (_) {
      if (mounted) {
        setState(() {
          _config = null;
          _configError = '模型信息获取失败，请刷新重试。';
        });
      }
    }
  }

  Future<void> _loadUsage() async {
    try {
      final usage = await widget.api.codexUsage();
      if (mounted) setState(() => _usage = usage);
    } catch (_) {
      if (mounted) {
        setState(() {
          _usage = null;
          _usageError = '用量获取失败，请刷新重试。';
        });
      }
    }
  }

  Future<void> _testSpeed() async {
    if (_testing || _loading || _saving) return;
    setState(() {
      _testing = true;
      _speed = null;
    });
    try {
      final result = await widget.api.measureModelSpeed(widget.scope);
      final first = result['firstTokenMs'];
      final rate = result['tokensPerSecond'];
      final elapsed = result['elapsedMs'];
      final text = [
        if (first is num) '首字 ${(first / 1000).toStringAsFixed(2)} 秒',
        if (rate is num)
          '生成速度 ${rate.toStringAsFixed(1)} token/秒'
        else
          '无法计算 token/秒',
        if (elapsed is num) '总耗时 ${(elapsed / 1000).toStringAsFixed(2)} 秒',
      ].join('\n');
      if (mounted) setState(() => _speed = text);
    } catch (err) {
      if (mounted) setState(() => _speed = '测速失败：$err');
    } finally {
      if (mounted) {
        setState(() => _testing = false);
        _loadUsage();
      }
    }
  }

  String _usageText(Map window) {
    final used = (window['usedPercent'] as num).clamp(0, 100);
    final minutes = window['windowDurationMins'];
    final period = minutes is num && minutes > 0
        ? (minutes % 1440 == 0
            ? '${minutes ~/ 1440}天'
            : minutes % 60 == 0
                ? '${minutes ~/ 60}小时'
                : '$minutes分钟')
        : '当前';
    final reset = window['resetsAt'];
    final date = reset is num && reset > 0
        ? DateTime.fromMillisecondsSinceEpoch((reset * 1000).round()).toLocal()
        : null;
    return '$period · 剩余 ${(100 - used).round()}%\n'
        '重置：${date == null ? '未知' : '${date.month}月${date.day}日 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}'}';
  }

  @override
  Widget build(BuildContext context) {
    final scope = (_config?['scopes'] as Map?)?[_scopeId] as Map?;
    final model = scope?['model'] as String?;
    final models = (_config?['models'] as List? ?? []).whereType<Map>();
    final matching = models.where((item) => item['id'] == model);
    final capability = matching.isEmpty ? null : matching.first;
    final prefs = (scope?['preferences'] as Map?)?[model] as Map?;
    final effort = prefs?['effort'] ?? capability?['defaultReasoningEffort'];
    const efforts = {
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
    final availableEfforts = (capability?['reasoningEfforts'] as List? ?? [])
        .whereType<String>()
        .toSet()
        .toList();
    final canEdit = !_loading && !_testing && !_saving && model != null;
    final windows = [_usage?['primary'], _usage?['secondary']]
        .whereType<Map>()
        .where((w) => w['usedPercent'] is num);
    return AlertDialog(
      title: Row(children: [
        Expanded(child: Text('$_scopeTitle · 模型')),
        IconButton(
            tooltip: '刷新',
            onPressed: _loading || _testing || _saving ? null : _refresh,
            icon: const Icon(Icons.refresh)),
        IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close)),
      ]),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      content: SingleChildScrollView(
          child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading) const WxInlineBusy('正在读取模型和用量…'),
          if (_saving) const WxInlineBusy('正在保存…'),
          if (_configError != null) Text(_configError!),
          if (_config != null) ...[
            ListTile(
              key: const Key('agent-change-model'),
              contentPadding: EdgeInsets.zero,
              title: Text((capability?['label'] ?? model ?? '默认模型').toString()),
              subtitle: Text(widget.agentMode ? 'Agent · 可编辑' : '只读'),
              trailing: const Icon(Icons.unfold_more),
              onTap: _loading || _testing || _saving || models.isEmpty
                  ? null
                  : _chooseModel,
            ),
            const Divider(height: 16),
            Row(children: [
              const Expanded(child: Text('思考')),
              if (availableEfforts.length > 1)
                DropdownButton<String>(
                  key: const Key('agent-change-effort'),
                  underline: const SizedBox.shrink(),
                  value: availableEfforts.contains(effort)
                      ? effort as String
                      : null,
                  hint: const Text('默认'),
                  items: [
                    for (final value in availableEfforts)
                      DropdownMenuItem(
                          value: value, child: Text(efforts[value] ?? value))
                  ],
                  onChanged: canEdit
                      ? (value) {
                          if (value != null) _saveTuning(model, effort: value);
                        }
                      : null,
                ),
              if (availableEfforts.length <= 1)
                Text(efforts[effort] ?? effort?.toString() ?? '默认'),
            ]),
            Row(children: [
              const Expanded(child: Text('快速模式')),
              if (capability?['supportsFast'] == true)
                Switch(
                  key: const Key('agent-change-fast'),
                  value: prefs?['fast'] == true,
                  onChanged: canEdit
                      ? (value) => _saveTuning(model, fast: value)
                      : null,
                ),
              if (capability?['supportsFast'] != true) const Text('不支持'),
            ]),
            Text(prefs?['fast'] == true ? '下次提问生效 · 快速模式用量更高' : '下次提问生效',
                style: Theme.of(context).textTheme.bodySmall),
          ],
          if (_saveMessage != null) Text(_saveMessage!),
          const Divider(height: 24),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 12),
            title: const Text('用量'),
            subtitle: Text(windows.isEmpty
                ? '暂不可用'
                : windows
                    .map((w) =>
                        '剩余 ${(100 - (w['usedPercent'] as num).clamp(0, 100)).round()}%')
                    .join(' / ')),
            children: [
              if (_usageError != null)
                Text(_usageError!)
              else if (windows.isEmpty)
                const Text('用量暂不可用，请稍后重试。')
              else
                for (final window in windows)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_usageText(window))),
            ],
          ),
          TextButton.icon(
            key: const Key('agent-model-speed'),
            onPressed: _testing || _loading || _saving || _config == null
                ? null
                : _testSpeed,
            icon:
                _testing ? const WxLoading(size: 18) : const Icon(Icons.speed),
            label: Text(_testing ? '正在测速…' : '模型测速'),
          ),
          if (_speed != null)
            Padding(
                padding: const EdgeInsets.only(top: 8), child: Text(_speed!)),
        ],
      )),
    );
  }
}
