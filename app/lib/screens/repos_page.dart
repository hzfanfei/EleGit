import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';

class ReposPage extends StatefulWidget {
  const ReposPage({
    super.key,
    required this.api,
    required this.onOpen,
    required this.onBack,
  });

  final WenxiangApi api;
  final void Function(RepoItem repo) onOpen;
  final VoidCallback onBack;

  @override
  State<ReposPage> createState() => _ReposPageState();
}

class _ReposPageState extends State<ReposPage> {
  final _query = TextEditingController();
  List<RepoItem> _repos = [];
  Object? _error;
  RepoItem? _cloning;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search();
    });
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repos = await widget.api.repos(_query.text.trim());
      if (!mounted) return;
      setState(() => _repos = repos);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = err);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(RepoItem repo) async {
    if (_cloning != null) return;
    setState(() {
      _cloning = repo;
      _error = null;
    });
    try {
      await widget.api.checkout(repo.owner, repo.name);
      if (!mounted) return;
      HapticFeedback.lightImpact();
      widget.onOpen(repo);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = err);
    } finally {
      if (mounted) setState(() => _cloning = null);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择仓库'),
        leading: IconButton(
          tooltip: '返回登录',
          icon: const Icon(Icons.arrow_back),
          onPressed: _cloning == null ? widget.onBack : null,
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  enabled: _cloning == null,
                  decoration: InputDecoration(
                    hintText: '搜索仓库名',
                    prefixIcon: const Icon(Icons.search, size: 20, color: Wx.faint),
                    suffixIcon: IconButton(
                      tooltip: '搜索',
                      icon: const Icon(Icons.arrow_forward, size: 20),
                      onPressed: _search,
                    ),
                  ),
                ),
              ),
              const WxHairline(),
              if (_error != null && _cloning == null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: WxErrorPanel(error: _error!, onRetry: _search),
                ),
              Expanded(child: _body()),
            ],
          ),
          if (_cloning != null) _CloneScrim(repo: _cloning!),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _repos.isEmpty) {
      return const WxBusy(label: '正在读取仓库');
    }
    if (_error != null && _repos.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_repos.isEmpty) {
      return WxEmpty(
        title: '没有找到仓库',
        detail: '换个关键词，或清空搜索看看全部。',
        action: TextButton(onPressed: _search, child: const Text('重新加载')),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _repos.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final repo = _repos[index];
        return _RepoTile(
          repo: repo,
          enabled: _cloning == null,
          onTap: () => _open(repo),
        );
      },
    );
  }
}

class _RepoTile extends StatelessWidget {
  const _RepoTile({
    required this.repo,
    required this.enabled,
    required this.onTap,
  });

  final RepoItem repo;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final initial = repo.owner.isNotEmpty ? repo.owner.substring(0, 1).toUpperCase() : '?';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Wx.raised,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Wx.hairline),
                  ),
                  child: Text(
                    initial,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Wx.text,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              repo.fullName,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          if (repo.privateRepo)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                border: Border.all(color: Wx.hairline),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                '私有',
                                style: TextStyle(fontSize: 11, color: Wx.muted, height: 1.2),
                              ),
                            ),
                        ],
                      ),
                      if (repo.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          repo.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Wx.muted),
                        ),
                      ],
                      if (repo.language.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(repo.language, style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CloneScrim extends StatelessWidget {
  const _CloneScrim({required this.repo});
  final RepoItem repo;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xCC0C0D0F),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Wx.surface,
              borderRadius: BorderRadius.circular(Wx.radius),
              border: Border.all(color: Wx.hairline),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('正在检出', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    '正在把 ${repo.fullName} 克隆到本机问象目录…',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '~/问象/${repo.owner}/${repo.name}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 18),
                  const ClipRRect(
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
