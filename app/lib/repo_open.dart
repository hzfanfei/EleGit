import 'api/wenxiang_api.dart';
import 'models.dart';
import 'widgets/wx_clone_scrim.dart';

bool _useLocalCheckout(String syncState) {
  return syncState == 'local' || syncState == 'auth_required';
}

/// Opens a repo: skip checkout when already up to date; pull when behind; clone when missing.
Future<void> openRepoWithSync({
  required WenxiangApi api,
  required RepoItem repo,
  required void Function(WxCloneMode mode)? onScrim,
  required void Function(String path)? onPath,
  required Future<void> Function() onReady,
}) async {
  onScrim?.call(WxCloneMode.open);
  CheckoutSyncStatus status;
  try {
    status = await api.checkoutStatus(repo.owner, repo.name);
    if (status.path.isNotEmpty) onPath?.call(status.path);
  } catch (_) {
    onScrim?.call(WxCloneMode.clone);
    await api.checkout(repo.owner, repo.name);
    api.warmChatSession(repo.owner, repo.name).catchError((_) {});
    await onReady();
    return;
  }

  if (status.present && (status.upToDate || _useLocalCheckout(status.syncState))) {
    api.warmChatSession(repo.owner, repo.name).catchError((_) {});
    await onReady();
    return;
  }

  if (status.present && status.behind > 0) {
    onScrim?.call(WxCloneMode.sync);
    await api.checkout(repo.owner, repo.name);
    api.warmChatSession(repo.owner, repo.name).catchError((_) {});
    await onReady();
    return;
  }

  onScrim?.call(WxCloneMode.clone);
  await api.checkout(repo.owner, repo.name);
  api.warmChatSession(repo.owner, repo.name).catchError((_) {});
  await onReady();
}
