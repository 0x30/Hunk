#!/usr/bin/env node
// 从 highlight.js 批量生成 languages.json 候选，用来扩充 Hunk 的词法高亮语言表。
//
// 理念：Hunk 的 LanguageDef 是「低维数据」——只要关键字 + 注释符 + 字符串符。
// 所以我们只借成熟项目的「数据」，不借它们的「引擎」（引擎仍是 Sources/HunkCore/
// Lexer.swift 自己的，可控、零运行时依赖、已加死循环防御）。
//
// 用法：
//   npm i highlight.js
//   node Scripts/gen-languages.mjs > Sources/HunkCore/Resources/languages.candidate.json
//   # 再人工 review/合并进 languages.json（核对扩展名、注释规则、剔除噪声关键字）
//
// 数据来源：
//   - keywords / aliases(扩展名)：highlight.js 的 language 定义
//   - lineComment / blockComment：从定义的 contains 里启发式提取（hljs.COMMENT）
// 更准的注释/字符串规则可改用 VS Code 各扩展的 language-configuration.json
// （comments.lineComment / comments.blockComment），结构化、微软维护、覆盖最广。

import hljs from 'highlight.js';

// keywords 可能是 "a b c" / { keyword, built_in, literal, type, $pattern }
function flattenKeywords(kw) {
  if (!kw) return [];
  if (typeof kw === 'string') return kw.split(/\s+/);
  const out = [];
  for (const [k, v] of Object.entries(kw)) {
    if (k === '$pattern') continue;
    if (typeof v === 'string') out.push(...v.split(/\s+/));
    else if (Array.isArray(v)) out.push(...v.map(String));
  }
  return out;
}

// 从 contains 树里启发式找注释规则（hljs.COMMENT(begin,end) 会留下 begin/end）
function extractComments(def) {
  const line = new Set();
  let block = null;
  const visit = (node) => {
    if (!node || typeof node !== 'object') return;
    const scope = node.scope || node.className;
    if (scope === 'comment' && node.begin) {
      const begin = String(node.begin).replace(/\\/g, '').trim();
      if (!node.end || node.end === '$') line.add(begin);
      else if (!block) block = [begin, String(node.end).replace(/\\/g, '').trim()];
    }
    (node.contains || []).forEach(visit);
  };
  (def.contains || []).forEach(visit);
  return { line: [...line], block };
}

const languages = [];
for (const name of hljs.listLanguages()) {
  const def = hljs.getLanguage(name);
  if (!def) continue;
  // 只保留像标识符的关键字，剔除正则/符号噪声
  const keywords = [...new Set(flattenKeywords(def.keywords))]
    .filter((k) => /^[A-Za-z_@][\w@]*$/.test(k))
    .sort();
  if (keywords.length === 0) continue;
  const { line, block } = extractComments(def);
  const extensions = [...new Set([name, ...(def.aliases || [])])].map((s) => s.toLowerCase());
  languages.push({
    name: def.name || name,
    extensions,
    lineComments: line,
    ...(block ? { blockComment: block } : {}),
    keywords,
  });
}

process.stdout.write(JSON.stringify({ version: 1, filenames: {}, languages }, null, 2) + '\n');
process.stderr.write(`生成 ${languages.length} 个语言候选；人工 review 后合并进 languages.json\n`);
