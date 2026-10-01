import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  formatMermaidCliError,
  mermaidCacheId,
  normalizeMermaidSource,
  probeMermaidSources,
  renderMermaidSvg,
} from "../src/mermaid-render.js";

const diagramCases = [
  {
    name: "01 class 原文粘连",
    code: "classDiagramclass Answer {+文本+有图()}class Diagram {+类型+显示()}Answer --> Diagram:包含",
    parts: ["class Answer {", "+文本", "+有图()", "class Diagram {", "+类型", "Answer --> Diagram:包含"],
    marker: "包含",
  },
  {
    name: "02 class 继承",
    code: "classDiagramclass Animal {+int age+String gender+isMammal()}class Dog {+bark()}Animal <|-- Dog:是",
    parts: ["+int age", "+String gender", "+isMammal()", "+bark()", "Animal <|-- Dog:是"],
    marker: "是",
  },
  {
    name: "03 class 组合与聚合",
    code: "classDiagramclass Car {+start()}class Engine {+power}class Wheel {+size}Car *-- Engine:动力Car o-- Wheel:滚动",
    parts: ["+start()", "+power", "+size", "Car *-- Engine:动力", "Car o-- Wheel:滚动"],
    marker: "动力",
  },
  {
    name: "04 class 两条中文关系",
    code: "classDiagramclass A {+x}class B {+y}class C {+z}A --> B:包含B --> C:调用",
    parts: ["A --> B:包含", "B --> C:调用"],
    marker: "调用",
  },
  {
    name: "05 class 可见性",
    code: "classDiagramclass Account {-id#balance~cache+deposit(amount)+withdraw(amount) int}",
    parts: ["-id", "#balance", "~cache", "+deposit(amount)", "+withdraw(amount) int"],
    marker: "deposit",
  },
  {
    name: "06 class 依赖与实现",
    code: "classDiagramclass Service {+run()}class Repo {+save()}class Logger {+write()}Repo <|.. Service:实现Service ..> Logger:记录",
    parts: ["Repo <|.. Service:实现", "Service ..> Logger:记录"],
    marker: "实现",
  },
  {
    name: "07 class 泛型",
    code: "classDiagramclass Box~Item~ {+List~String~ items+int count}class Item {+name}Box --> Item:持有",
    parts: ["class Box~Item~ {", "+List~String~ items", "+int count", "Box --> Item:持有"],
    marker: "持有",
  },
  {
    name: "08 class 接口与基数",
    code: 'classDiagramclass Flyable {<<interface>>+fly()}class Duck {+quack()}class Pond {+water}Flyable <|.. Duck:实现Duck "1" --> "*" Pond:游',
    parts: ["<<interface>>", "+fly()", "Flyable <|.. Duck:实现", 'Duck "1" --> "*" Pond:游'],
    marker: "游",
  },
  {
    name: "09 class 方向样式备注",
    code: "classDiagram-v2 direction LR class Task {+name} class Done {+ok} classDef hot fill:#f6d6b8,stroke:#a67c52 cssClass \"Task\" hot Task --> Done:完成 note for Done \"结束\"",
    parts: [
      "classDiagram-v2",
      "direction LR",
      "+name",
      "+ok",
      "classDef hot fill:#f6d6b8,stroke:#a67c52",
      'cssClass "Task" hot',
      "Task --> Done:完成",
      'note for Done "结束"',
    ],
    marker: "完成",
  },
  {
    name: "10 er 原文粘连",
    code: "erDiagramANSWER ||--o{ DIAGRAM :包含ANSWER {string文本}DIAGRAM {string类型}",
    parts: ["ANSWER ||--o{ DIAGRAM :包含", "string 文本", "string 类型"],
    marker: "包含",
  },
  {
    name: "11 er 英文标签粘实体",
    code: "erDiagramCUSTOMER ||--o{ ORDER :placesCUSTOMER {string name string email PK}ORDER {int total float tax}",
    parts: ["ORDER :places", "CUSTOMER {", "string name", "string email PK", "int total", "float tax"],
    marker: "places",
  },
  {
    name: "12 er 多种基数",
    code: "erDiagramPARENT ||--|| CHILD :has TEACHER |o--o{ COURSE :teaches STUDENT }|--|{ COURSE :enrolls PARENT {string id}CHILD {string id}TEACHER {string name}COURSE {int credit}STUDENT {string sid}",
    parts: [
      "PARENT ||--|| CHILD :has",
      "TEACHER |o--o{ COURSE :teaches",
      "STUDENT }|--|{ COURSE :enrolls",
      "int credit",
      "string sid",
    ],
    marker: "enrolls",
  },
  {
    name: "13 er 键与注释",
    code: 'erDiagramUSER ||--o{ LOGIN :recordsUSER {string name "姓名" string email PK "邮箱" int orgId FK}LOGIN {datetime when string ip}',
    parts: [
      "USER ||--o{ LOGIN :records",
      'string name "姓名"',
      'string email PK "邮箱"',
      "int orgId FK",
      "datetime when",
      "string ip",
    ],
    marker: "姓名",
  },
  {
    name: "14 er 长类型名",
    code: "erDiagramSAMPLE {integer count booleanflag datetimecreated date day varcharcode charflag double ratio floatscore}",
    parts: [
      "integer count",
      "boolean flag",
      "datetime created",
      "date day",
      "varchar code",
      "char flag",
      "double ratio",
      "float score",
    ],
    marker: "integer",
  },
  {
    name: "15 er 带连字符的实体",
    code: "erDiagramORDER ||--|{ LINE-ITEM :containsORDER {int id PK}LINE-ITEM {string sku PK int qty}",
    parts: ["ORDER ||--|{ LINE-ITEM :contains", "int id PK", "LINE-ITEM {", "string sku PK", "int qty"],
    marker: "LINE-ITEM",
  },
  {
    name: "16 er 标识关系",
    code: "erDiagramPERSON ||..o{ PASSPORT :holdsPERSON {string id PK}PASSPORT {string no PK string personId FK}",
    parts: ["PERSON ||..o{ PASSPORT :holds", "string id PK", "string no PK", "string personId FK"],
    marker: "holds",
  },
  {
    name: "17 pie 中文标题粘连",
    code: 'pieshowDatatitle回答里的内容"文字" :70"流程图" :20"其他图" :10',
    parts: ["pie showData", "title 回答里的内容", '"文字" :70', '"流程图" :20', '"其他图" :10'],
    marker: "回答里的内容",
  },
  {
    name: "18 pie 小数",
    code: 'pieshowDatatitle营养成分"钙" :42.96"钾" :50.05"镁" :10.01"铁" :5',
    parts: ["title 营养成分", '"钙" :42.96', '"钾" :50.05', '"镁" :10.01', '"铁" :5'],
    marker: "42.96",
  },
  {
    name: "19 pie 单引号",
    code: "pietitle份额'甲' :60'乙' :40",
    parts: ["pie", "title 份额", "'甲' :60", "'乙' :40"],
    marker: "份额",
  },
  {
    name: "20 pie 零值小数与标题词",
    code: 'pieshowDatatitle分布"甲" :0"乙" :1"丙" :12.5"丁" :2.5"戊" :30"己" :8"title词" :4',
    parts: ["title 分布", '"甲" :0', '"丙" :12.5', '"丁" :2.5', '"title词" :4'],
    marker: "title词",
  },
];

function assertInOrder(source, parts) {
  let at = 0;
  for (const part of parts) {
    const found = source.indexOf(part, at);
    assert.notEqual(found, -1, `missing ${JSON.stringify(part)} in\n${source}`);
    at = found + part.length;
  }
}

describe("mermaid-render", () => {
  it("formatMermaidCliError surfaces parse errors", () => {
    const msg = formatMermaidCliError({
      message: "Command failed",
      stderr: "Error: Parse error on line 2:\n...",
    });
    assert.match(msg, /Parse error on line/i);
  });

  it("normalizeMermaidSource splits collapsed class, pie, and er diagrams", () => {
    const klass = normalizeMermaidSource(
      "classDiagram\nclass Answer { +文本 +有图() } class Diagram { +类型 +显示() } Answer --> Diagram: 包含",
    );
    assert.match(klass, /class Answer \{\n\+文本\n\+有图\(\)/);
    assert.match(klass, /Answer --> Diagram: 包含/);

    const pie = normalizeMermaidSource(
      'pie showData title 回答里的内容 "文字" : 70 "流程图" : 20 "其他图" : 10',
    );
    assert.match(pie, /^pie showData\n/);
    assert.match(pie, /\n"文字" : 70/);
    assert.match(pie, /\n"其他图" : 10/);

    const glued = normalizeMermaidSource(
      'pie showData\ntitle回答里的内容\n"文字" :70\n"流程图" :20\n"其他图" :10',
    );
    assert.match(glued, /^pie showData\ntitle 回答里的内容\n/);
    assert.match(glued, /\n"文字" :70/);
    assert.match(glued, /\n"其他图" :10/);

    const er = normalizeMermaidSource(
      "erDiagram ANSWER ||--o{ DIAGRAM : 包含 ANSWER { string文本 } DIAGRAM { string类型 }",
    );
    assert.match(er, /ANSWER \|\|--o\{ DIAGRAM : 包含/);
    assert.match(er, /ANSWER \{\nstring 文本\n\}/);
    assert.match(er, /DIAGRAM \{\nstring 类型\n\}/);

    const flow = "flowchart LR\n  A[开始] --> B[结束]";
    assert.equal(normalizeMermaidSource(flow), flow);

    const classGlued = normalizeMermaidSource(
      "classDiagramclass Answer {+文本+有图()}class Diagram {+类型+显示()}Answer --> Diagram:包含",
    );
    assert.match(classGlued, /\}\nclass Diagram \{\n\+类型/);
    assert.match(classGlued, /\}\nAnswer --> Diagram:包含/);

    const erGlued = normalizeMermaidSource(
      "erDiagramANSWER ||--o{ DIAGRAM :包含ANSWER {string文本}DIAGRAM {string类型}",
    );
    assert.match(erGlued, /\|\|--o\{ DIAGRAM :包含\nANSWER \{/);
    assert.match(erGlued, /string 文本/);
    assert.match(erGlued, /\}\nDIAGRAM \{\nstring 类型/);

    const pieGlued = normalizeMermaidSource(
      'pieshowDatatitle回答里的内容"文字" :70"流程图" :20"其他图" :10',
    );
    assert.match(pieGlued, /^pie showData\ntitle 回答里的内容\n"文字" :70\n"流程图" :20/);

    const inherited = normalizeMermaidSource(
      "classDiagramclass Animal {+int age+name}class Dog {+bark()}Animal <|-- Dog",
    );
    assert.match(inherited, /Animal <\|-- Dog/);
    assert.match(inherited, /\}\nAnimal <\|-- Dog/);

    const composed = normalizeMermaidSource(
      "classDiagramclass Car {+start()}class Engine {+power}Car *-- Engine Car o-- Wheel class Wheel {+size}",
    );
    assert.match(composed, /Car \*-- Engine\nCar o-- Wheel/);

    const twoRel = normalizeMermaidSource(
      "classDiagramclass A {+x}class B {+y}class C {+z}A --> B:包含B --> C:调用",
    );
    assert.match(twoRel, /A --> B:包含\nB --> C:调用/);

    const erEnglish = normalizeMermaidSource(
      "erDiagramCUSTOMER ||--o{ ORDER :placesCUSTOMER {string name string email PK}ORDER {int total float tax}",
    );
    assert.match(erEnglish, /ORDER :places\nCUSTOMER \{/);
    assert.match(erEnglish, /string email PK/);
    assert.match(erEnglish, /\}\nORDER \{\nint total\nfloat tax/);

    const erMany = normalizeMermaidSource(
      "erDiagramPARENT ||--|| CHILD :has TEACHER |o--o{ COURSE :teaches PARENT {string id}CHILD {string id}",
    );
    assert.match(erMany, /PARENT \|\|--\|\| CHILD :has\nTEACHER \|o--o\{ COURSE :teaches/);
    assert.match(erMany, /teaches\nPARENT \{/);
  });

  it("mermaidCacheId is stable", () => {
    const a = mermaidCacheId("graph TD\n  A-->B", "dark", "transparent");
    const b = mermaidCacheId("graph TD\n  A-->B", "dark", "transparent");
    assert.equal(a, b);
    assert.notEqual(a, mermaidCacheId("graph TD\n  A-->B", "default", "#FAF8F5"));
  });

  it("renders a flowchart to PNG and a flutter-safe SVG", async () => {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "wx-mmd-test-"));
    const { svg, png, id, cached } = await renderMermaidSvg({
      code: "flowchart LR\n  A[开始] --> B[结束]",
      theme: "dark",
      backgroundColor: "transparent",
      workspaceRoot,
    });
    assert.match(svg, /<svg[\s>]/i);
    assert.match(svg, /开始/);
    assert.doesNotMatch(svg, /foreignObject/i);
    assert.doesNotMatch(svg, /<style[\s>]/i);
    assert.match(svg, /font-family="WenxiangSerif"/);
    assert.equal(png[0], 0x89);
    assert.equal(png.subarray(1, 4).toString("ascii"), "PNG");
    assert.ok(id.length >= 16);
    assert.equal(cached, false);

    const again = await renderMermaidSvg({
      code: "flowchart LR\n  A[开始] --> B[结束]",
      theme: "dark",
      backgroundColor: "transparent",
      workspaceRoot,
    });
    assert.equal(again.cached, true);
    assert.equal(again.id, id);
  });

  it("normalizes twenty collapsed class, er, and pie diagrams", () => {
    assert.equal(diagramCases.length, 20);
    const failed = [];
    for (const sample of diagramCases) {
      try {
        assertInOrder(normalizeMermaidSource(sample.code), sample.parts);
      } catch (err) {
        failed.push(`${sample.name}: ${err.message}`);
      }
    }
    assert.equal(failed.length, 0, failed.join("\n\n"));
  });

  it("renders twenty collapsed class, er, and pie diagrams", { timeout: 180_000 }, async () => {
    const results = await probeMermaidSources(diagramCases.map((sample) => sample.code));
    const failed = [];
    for (let i = 0; i < diagramCases.length; i += 1) {
      const sample = diagramCases[i];
      const result = results[i];
      if (!result?.ok || !String(result.svg || "").includes(sample.marker)) {
        failed.push(
          `${sample.name}: ${result?.error || "rendered without marker"}\n${result?.source || ""}`,
        );
      }
    }
    assert.equal(failed.length, 0, failed.join("\n\n"));
  });

  it("rejects invalid diagram with a short message", async () => {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "wx-mmd-bad-"));
    await assert.rejects(
      () =>
        renderMermaidSvg({
          code: "flowchart LR\n  BAD-->",
          theme: "dark",
          workspaceRoot,
          useCache: false,
        }),
      (err) => {
        assert.equal(err.code, "mermaid_render_failed");
        assert.match(err.message, /Parse error on line/i);
        return true;
      },
    );
  });
});
