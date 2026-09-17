import 'api/wenxiang_api.dart';
import 'models.dart';
import 'widgets/wx_clone_scrim.dart';

/// Opens a repo: skip checkout when already up to date; pull when behind; clone when missing.
Future<void> openRepoWithSync({
  required WenxiangApi api,
  required RepoItem repo,
  required void Function(WxCloneMode mode)? onScrim,
  required Future<void> Function() onReady,
}) async {
  CheckoutSyncStatus status;
  try {
    status = await api.checkoutStatus(repo.owner, repo.name);
  } catch (_) {
    onScrim?.call(WxCloneMode.clone);
    await api.checkout(repo.owner, repo.name);
    await onReady();
    return;
  }

  if (status.present && status.upToDate) {
    await onReady();
    return;
  }

  if (status.present && status.behind > 0) {
    onScrim?.call(WxCloneMode.sync);
    await api.checkout(repo.owner, repo.name);
    await onReady();
    return;
  }

  onScrim?.call(WxCloneMode.clone);
  await api.checkout(repo.owner, repo.name);
  await onReady();
}
