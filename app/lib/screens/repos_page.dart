import 'package:flutter/material.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';

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
  String _error = '';
  String _progress = '';
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final repos = await widget.api.repos(_query.text.trim());
      setState(() => _repos = repos);
    } catch (err) {
      setState(() => _error = err.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(RepoItem repo) async {
    setState(() {
      _busy = true;
      _error = '';
      _progress = '正在把 ${repo.fullName} 克隆到本机问象目录…';
    });
    try {
      final checkout = await widget.api.checkout(repo.owner, repo.name);
      if (!mounted) return;
      setState(() => _progress = '已检出 ${checkout.path}');
      widget.onOpen(repo);
    } catch (err) {
      setState(() => _error = err.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = '';
        });
      }
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
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: '搜索仓库名',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _search,
                ),
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_progress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(_progress),
            ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _repos.length,
              itemBuilder: (context, index) {
                final repo = _repos[index];
                return ListTile(
                  title: Text(repo.fullName),
                  subtitle: Text(
                    [
                      if (repo.privateRepo) '私有',
                      if (repo.language.isNotEmpty) repo.language,
                      if (repo.description.isNotEmpty) repo.description,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: _busy ? null : () => _open(repo),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
