---
name: mermaid-diagrams
description: >-
  Write Mermaid diagrams as multiline fenced blocks that 问象 can render.
  Use when the user asks for a diagram, 图, 流程图, 时序图, 类图, 关系图,
  状态图, 饼图, 思维导图, or when an answer should show structure visually.
---

# 问象里画 Mermaid

回答里要画图时，只写多行围栏。问象把围栏正文交给 Mermaid 渲染。换行是语法的一部分，不能省。

## 围栏

开头单独一行是 `` ```mermaid ``。下一行是图类型。每条语句单独一行。结尾单独一行是 `` ``` ``。

不要写成 `` ```mermaidclassDiagram ``，也不要把整张图粘成一行。箭头必须在同一条语句里写完整，例如 `<|--`、`*--`、`o--`、`-->`、`||--o{`。不要加主题 frontmatter。不要叫用户自己去跑渲染命令。

## 按类型

- `flowchart` / `graph`：方向 `TD` 或 `LR` 写在类型后面。一个节点或一条边一行。
- `sequenceDiagram`：每个 `participant` 一行，一条消息一行。
- `classDiagram`：每个 `class` 一块。每个成员一行。关系箭头一行写完。
- `erDiagram`：一条关系一行。实体块里每个属性一行。注释和类型之间留空格，例如 `string name "姓名"`。
- `stateDiagram-v2`：一条迁移一行。
- `mindmap`：用缩进表示层级，每项一行。
- `pie`：需要显示数字时第一行写 `pie showData`。`title` 单独一行。每个 `"名称" : 数字` 单独一行。

## 不要画的时候

这一轮要求口语、禁止 Markdown（问书朗读、语音通话）时，不要输出围栏，用一两句话讲结构。
