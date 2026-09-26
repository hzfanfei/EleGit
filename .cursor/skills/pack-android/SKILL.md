---
name: pack-android
description: >-
  Build the 问象 Android release APK by running scripts/build-android.mjs only.
  Use when the user asks to 打包, 重新打包, 出包, build an APK, or put the
  install package in the static directory. Do not call flutter build apk directly.
---

# 打包 Android

每次打包只跑仓库根目录的打包脚本。不要自己执行 `flutter build apk`，不要手写 `--dart-define-from-file`，不要自己把 apk 复制到静态目录。

```bat
node scripts/build-android.mjs
```

工作目录是仓库根目录。脚本会：

- 读取根目录 `.env`，把 `WENXIANG_PUBLIC_URL` 和 `WENXIANG_API_KEY` 编进安装包
- 只打 arm64
- 把 `app/pubspec.yaml` 的 build 号加 1，再按新版本命名，例如 `问象-v0.1.0-2.apk`。打包失败时 build 号退回

`.env` 缺失或这两项为空时，脚本会失败。把失败原因告诉用户，不要改用裸的 `flutter build apk` 继续打。

不要打印 `.env` 里的密钥。不要提交 `.env`。这是客户端安装包，打完不用重启本机问象服务。

完成后报告脚本打印的输出路径、文件大小和修改时间。
