import 'package:flutter/material.dart';

import '../api/wenxiang_api.dart';
import '../copy/ask_engine.dart';

/// Repository model diagnostics, independent of the conversation's messages.
class AgentDetailsDialog extends StatefulWidget {
  const AgentDetailsDialog(
      {super.key,
      required this.api,
      required this.agentMode,
      this.initialUsage});

  final WenxiangApi api;
  final bool agentMode;
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

  @override
  void initState() {
    super.initState();
    _usage = widget.initialUsage;
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
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
    if (_testing) return;
    setState(() {
      _testing = true;
      _speed = null;
    });
    try {
      final result = await widget.api.measureModelSpeed(AskEngineScope.repo);
      final first = result['firstTokenMs'];
      final rate = result['tokensPerSecond'];
      final elapsed = result['elapsedMs'];
      final model = result['model'];
      final text = [
        if (model is String && model.isNotEmpty) '测速模型：$model',
        if (first is num) '首字 ${(first / 1000).toStringAsFixed(2)} 秒',
        if (rate is num)
          '生成速度 ${rate.toStringAsFixed(1)} token/秒'
        else
          '供应商未返回 token 用量，无法计算 token/秒',
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
    return '$period额度：已用 ${used.toStringAsFixed(0)}%，剩余 ${(100 - used).round()}%\n'
        '重置：${date == null ? '未知' : '${date.month}月${date.day}日 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}'}';
  }

  @override
  Widget build(BuildContext context) {
    final scope = (_config?['scopes'] as Map?)?['repo'] as Map?;
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
    final windows = [_usage?['primary'], _usage?['secondary']]
        .whereType<Map>()
        .where((w) => w['usedPercent'] is num);
    return AlertDialog(
      title: const Text('Agent 详情'),
      content: SingleChildScrollView(
          child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('当前权限：${widget.agentMode ? 'Agent · 可编辑' : '只读'}'),
          const SizedBox(height: 12),
          if (_loading) const LinearProgressIndicator(),
          if (_configError != null) Text(_configError!),
          if (_config != null) ...[
            Text('当前模型：${model?.isNotEmpty == true ? model : '跟随本机默认模型'}'),
            Text(
                '思考强度：${effort == null ? '跟随模型默认' : efforts[effort] ?? effort}'),
            Text('快速模式：${prefs?['fast'] == true ? '开启' : '关闭'}'),
          ],
          const SizedBox(height: 16),
          const Text('Codex 用量'),
          if (_usageError != null)
            Text(_usageError!)
          else if (windows.isEmpty)
            const Text('用量暂不可用，请稍后重试。')
          else
            for (final window in windows)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_usageText(window))),
          const SizedBox(height: 16),
          TextButton.icon(
            key: const Key('agent-model-speed'),
            onPressed:
                _testing || _loading || _config == null ? null : _testSpeed,
            icon: const Icon(Icons.speed),
            label: Text(_testing ? '正在测速…' : '模型测速'),
          ),
          const Text('测试当前仓库模型，会消耗少量模型额度；测试内容不进入对话。',
              style: TextStyle(fontSize: 12)),
          if (_speed != null)
            Padding(
                padding: const EdgeInsets.only(top: 8), child: Text(_speed!)),
        ],
      )),
      actions: [
        TextButton(
            onPressed: _loading || _testing ? null : _refresh,
            child: const Text('刷新')),
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }
}
