import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

class AgentDecisionCard extends StatefulWidget {
  const AgentDecisionCard({
    super.key,
    required this.event,
    required this.onSubmit,
  });

  final ChatStreamEvent event;
  final Future<void> Function({
    required String kind,
    required bool skip,
    required bool accept,
    required List<Map<String, dynamic>> answers,
  }) onSubmit;

  @override
  State<AgentDecisionCard> createState() => _AgentDecisionCardState();
}

class _AgentDecisionCardState extends State<AgentDecisionCard> {
  final Map<String, Set<String>> _picked = {};
  bool _sending = false;
  bool _open = false;
  String? _error;

  Map<String, dynamic> get _payload => widget.event.payload ?? const {};

  @override
  void didUpdateWidget(covariant AgentDecisionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prev = oldWidget.event.payload?['requestId'];
    final next = widget.event.payload?['requestId'];
    if (prev != next) {
      _picked.clear();
      _error = null;
      _open = false;
    }
  }

  void _toggle() => setState(() => _open = !_open);

  Future<void> _send({
    required bool skip,
    required bool accept,
    List<Map<String, dynamic>> answers = const [],
  }) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onSubmit(
        kind: widget.event.type == 'plan' ? 'plan' : 'ask',
        skip: skip,
        accept: accept,
        answers: answers,
      );
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = '没发出去，再点一次';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.event.type == 'plan') {
      final title = (_payload['title'] ?? '计划').toString();
      final overview = (_payload['overview'] ?? '').toString();
      final plan = (_payload['plan'] ?? '').toString();
      return _Shell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FoldHeader(title: title, open: _open, onToggle: _toggle),
            if (_open) ...[
              if (overview.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(overview, style: theme.textTheme.bodyMedium?.copyWith(color: Wx.muted, height: 1.4)),
              ],
              if (plan.isNotEmpty) ...[
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: Text(plan, style: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: Wx.danger)),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton(
                    onPressed: _sending ? null : () => _send(skip: true, accept: false),
                    child: const Text('先不用'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _sending ? null : () => _send(skip: false, accept: true),
                    child: Text(_sending ? '发送中…' : '按这个做'),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    }

    final title = (_payload['title'] ?? '').toString();
    final questions = (_payload['questions'] as List?) ?? const [];
    return _Shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FoldHeader(
            title: title.isEmpty ? '需要你选一下' : title,
            open: _open,
            onToggle: _toggle,
          ),
          if (_open) ...[
            for (final raw in questions)
              if (raw is Map)
                _QuestionBlock(
                  question: Map<String, dynamic>.from(raw),
                  picked: _picked,
                  enabled: !_sending,
                  onChanged: () => setState(() {}),
                ),
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: Wx.danger)),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton(
                  onPressed: _sending ? null : () => _send(skip: true, accept: false),
                  child: const Text('跳过'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _sending
                      ? null
                      : () {
                          final answers = <Map<String, dynamic>>[];
                          for (final raw in questions) {
                            if (raw is! Map) continue;
                            final id = (raw['id'] ?? '').toString();
                            final ids = _picked[id]?.toList() ?? const <String>[];
                            if (id.isEmpty || ids.isEmpty) continue;
                            answers.add({'questionId': id, 'selectedOptionIds': ids});
                          }
                          _send(skip: answers.isEmpty, accept: false, answers: answers);
                        },
                  child: Text(_sending ? '发送中…' : '确定'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _QuestionBlock extends StatelessWidget {
  const _QuestionBlock({
    required this.question,
    required this.picked,
    required this.enabled,
    required this.onChanged,
  });

  final Map<String, dynamic> question;
  final Map<String, Set<String>> picked;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final id = (question['id'] ?? '').toString();
    final prompt = (question['prompt'] ?? '').toString();
    final multi = question['allowMultiple'] == true;
    final options = (question['options'] as List?) ?? const [];
    final selected = picked.putIfAbsent(id, () => <String>{});
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (prompt.isNotEmpty)
            Text(prompt, style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final raw in options)
                if (raw is Map)
                  ChoiceChip(
                    label: Text((raw['label'] ?? raw['id'] ?? '').toString()),
                    selected: selected.contains((raw['id'] ?? '').toString()),
                    onSelected: !enabled
                        ? null
                        : (on) {
                            final optionId = (raw['id'] ?? '').toString();
                            if (optionId.isEmpty) return;
                            if (multi) {
                              if (on) {
                                selected.add(optionId);
                              } else {
                                selected.remove(optionId);
                              }
                            } else if (on) {
                              selected
                                ..clear()
                                ..add(optionId);
                            }
                            onChanged();
                          },
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FoldHeader extends StatelessWidget {
  const _FoldHeader({
    required this.title,
    required this.open,
    required this.onToggle,
  });

  final String title;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: const Key('wx-decision-toggle'),
      onTap: onToggle,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
            const SizedBox(width: 8),
            Text(
              open ? '收起' : '展开',
              style: theme.textTheme.labelSmall?.copyWith(color: Wx.accent),
            ),
            Icon(
              open ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: Wx.accent,
            ),
          ],
        ),
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Wx.inset, 10, Wx.inset, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Wx.surface,
          borderRadius: BorderRadius.circular(Wx.radius),
          border: Border.all(color: Wx.hairline),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: child,
        ),
      ),
    );
  }
}
