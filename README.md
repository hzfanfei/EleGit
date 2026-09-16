# EleGit · 问象

手机 App「问象」+ 本机配套服务。打开即浏览器登录 GitHub，选仓库后克隆到 `~/问象`，流式问答。

配置说明（中文）：[配置说明.md](./配置说明.md)

用户计划 / PRD 在 Project store：

- `/cursor/stores/bc-d0755f26-a3ad-4de8-b86a-7c66b6eb5ff3/docs/wenxiang-plan.md`
- `/cursor/stores/bc-d0755f26-a3ad-4de8-b86a-7c66b6eb5ff3/docs/wenxiang-prd.md`

## 配置

```bat
copy .env.example .env
notepad .env
```

只填这一份根目录 `.env`。不要提交。不要把 Client Secret 写进仓库。

## 启动服务

```bat
cd server
npm install
npm start
```

## 启动 App

```bat
node scripts/sync-app-env.js
cd app
flutter pub get
flutter run --dart-define-from-file=../.env
```

手机不用填地址或 Key。对话页听筒可打电话：先在根目录 `.env` 填 `VOLC_APP_ID` / `VOLC_ACCESS_TOKEN`（或后备 `OPENAI_API_KEY`），见《配置说明.md》。

## 测试

```bat
cd server && npm test
cd app && flutter test
```
