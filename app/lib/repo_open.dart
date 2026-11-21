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
  required bool Function() isCancelled,
}) async {
  onScrim?.call(WxCloneMode.open);
  CheckoutSyncStatus? status;
  try {
    status = await api.checkoutStatus(repo.owner, repo.name);
  } catch (_) {}
  if (isCancelled()) return;

  if (status != null && status.path.isNotEmpty) onPath?.call(status.path);
  final ready = status != null &&
      status.present &&
      (status.upToDate || _useLocalCheckout(status.syncState));
  if (!ready) {
    final needsSync = status != null && status.present && status.behind > 0;
    onScrim?.call(needsSync ? WxCloneMode.sync : WxCloneMode.clone);
    await api.checkout(repo.owner, repo.name);
  }
  if (isCancelled()) return;
  api.warmChatSession(repo.owner, repo.name).catchError((_) {});
  await onReady();
}
