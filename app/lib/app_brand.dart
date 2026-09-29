/// Compile-time app label (main vs backup install).
class AppBrand {
  static const label = String.fromEnvironment(
    'WENXIANG_APP_LABEL',
    defaultValue: '问象',
  );

  static const isBackup = bool.fromEnvironment(
    'WENXIANG_BACKUP',
    defaultValue: false,
  );
}
