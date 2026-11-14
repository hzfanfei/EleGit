---
name: markdown-tables
description: >-
  Write GitHub-style pipe tables for 问象 chat, one row per line, with a blank
  line before the table. Use when the user asks for a table, 表格, or when an
  answer should show rows and columns.
---

# 表格

问象把管道表交给 Markdown 渲染。每一行单独一行。表和上面的文字之间空一行。

换行如果被收掉，行和行会粘成 `||`，整段会显示成纯文字，不再是表。

## 写法

- 表前空一行。标题不要和第一根 `|` 写在同一行。
- 表头一行，分隔行一行，每一条数据一行。
- 每行以 `|` 开头，以 `|` 结尾。
- 对齐写在分隔行：左 `:---`，中 `:---:`，右 `---:`。

不要写成 `| 水果 | 单价 || --- | --- || 苹果 | 6 |`。

这一轮要求口语、禁止 Markdown（问书朗读、语音通话）时，不要输出表格。

```markdown
**早市水果**

| 水果 | 单价 | 剩多少 |
| --- | ---: | ---: |
| 苹果 | 6.5 | 18 斤 |
| 香蕉 | 4 | 9 把 |
```
