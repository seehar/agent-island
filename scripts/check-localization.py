#!/usr/bin/env python3
"""本地化守卫。

界面文案的查表路径是本仓库自研的（按应用内选定的语言取 `.lproj`）。SwiftUI 的
`LocalizedStringKey`（`Text("…")` 字面量、`Label` 等）与 `NSLocalizedString` /
`String(localized:)` 走的是 `Bundle` 自己的解析，两条路径会得出不同的语言。
这里把「界面文案一律经过 `LocalizationManager.t(_:)`」这条不变量变成静态检查，
替代人肉纪律。

错误（退出码 1）：
  1. 代码里 `t("…")` 用到的键在 Localizable.xcstrings 里不存在
  2. 除 Core/Localization.swift 外出现非字面量键（无法审计），
     或绕过自研查表的 API（NSLocalizedString / String(localized:) / localizedString(forKey:))
  3. 键、en、zh-Hans 三方的格式符集合不一致（复数变化的每一档都参与比较）
  4. 复数变化结构：同一键在所有语言里要么都带变化要么都不带，且每种语言都必须有 other
  5. 面向用户的字面量入口直接写英文文案（Text/Label/Button/… 的纯字面量参数）
  6. 根视图没有注入环境 locale（LocalizedRoot + .environment(\\.locale)）

警告（默认退出码 0，`--strict` 时计入失败）：
  7. catalog 里存在代码不再引用的键（仅 `--strict` 下计为失败）

用法：python3 scripts/check-localization.py [--strict] [仓库根目录]
"""
import bisect
import json
import pathlib
import re
import sys

STRICT = "--strict" in sys.argv
_positional = [a for a in sys.argv[1:] if not a.startswith("--")]
ROOT = (
    pathlib.Path(_positional[0]).resolve()
    if _positional
    else pathlib.Path(__file__).resolve().parent.parent
)
CODE = ROOT / "AgentIsland"
CATALOG = CODE / "Resources/Localizable.xcstrings"
LOCALIZATION_CORE = "Core/Localization.swift"

KEY_LITERAL = re.compile(r'\bt\(\s*("(?:[^"\\]|\\.)*")')
KEY_CALL = re.compile(r"\bt\(")
BYPASS = re.compile(r"NSLocalizedString\s*\(|String\s*\(\s*localized:|\.localizedString\s*\(\s*forKey:")
LITERAL_API = re.compile(
    r"\b(Text|Label|Button|Toggle|TextField|SecureField|Picker|Link|Section|Menu|"
    r"help|accessibilityLabel|navigationTitle|alert|confirmationDialog)\s*\(\s*\"([^\"\\]*)\""
)
SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ #0]*[\d.]*(?:ll|l|h|z|q)?[@dfsuxXeEgGc]")

errors = []
warnings = []


def strip_comments(src):
    """去掉注释、保留字符串字面量：文档里示例的 `t("…")` 不该被当成真实调用。

    逐字符扫描而非正则替换——`//` 出现在 URL 这类字面量里时不能当作注释起点。
    """
    out = []
    i, n = 0, len(src)
    in_string = in_block = False
    while i < n:
        ch = src[i]
        pair = src[i : i + 2]
        if in_block:
            if pair == "*/":
                in_block = False
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if pair == "//":
            end = src.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
            continue
        if pair == "/*":
            in_block = True
            out.append("  ")
            i += 2
            continue
        if ch == '"':
            in_string = True
        out.append(ch)
        i += 1
    return "".join(out)


def report(bucket, rel, line, message):
    bucket.append((rel, line, message))


def specifiers(text):
    return sorted(SPECIFIER.findall(re.sub(r"%%", "", text)))


def values_of(entry):
    """返回 {语言: [各形态的文案]}，含复数变化的每一档。"""
    out = {}
    for lang, loc in entry.get("localizations", {}).items():
        if "stringUnit" in loc:
            out[lang] = [loc["stringUnit"]["value"]]
        elif "variations" in loc:
            plural = loc["variations"].get("plural", {})
            out[lang] = [v["stringUnit"]["value"] for v in plural.values() if "stringUnit" in v]
        else:
            out[lang] = []
    return out


def scan_code():
    """按整份源码扫描：`t(` 后面换行再跟键的写法很常见，逐行匹配会漏掉。"""
    used = set()
    sources = {}
    for path in sorted(CODE.rglob("*.swift")):
        sources[path] = strip_comments(path.read_text(encoding="utf-8"))
    for path, source in sources.items():
        rel = str(path.relative_to(CODE))
        lines = source.splitlines()
        starts = [0] + [m.end() for m in re.finditer(r"\n", source)]
        where = lambda offset: bisect.bisect_right(starts, offset)  # noqa: E731
        muted = lambda offset: "l10n-ok" in lines[where(offset) - 1]  # noqa: E731

        for match in KEY_LITERAL.finditer(source):
            if not muted(match.start()):
                used.add(json.loads(match.group(1)))

        for match in KEY_CALL.finditer(source):
            if muted(match.start()):
                continue
            rest = source[match.end() :]
            next_char = rest[re.match(r"\s*", rest).end() :][:1]
            if next_char != '"' and rel != LOCALIZATION_CORE:
                report(errors, rel, where(match.start()), "键必须是字面量，否则无法审计：t(<非字面量>)")

        if rel != LOCALIZATION_CORE:
            for match in BYPASS.finditer(source):
                if not muted(match.start()):
                    report(
                        errors,
                        rel,
                        where(match.start()),
                        "绕过自研查表的 API（读系统语言而非界面语言）",
                    )

        for match in LITERAL_API.finditer(source):
            if muted(match.start()):
                continue
            literal = match.group(2)
            if len(re.sub(r"[^A-Za-z]", "", literal)) >= 2:
                report(
                    errors,
                    rel,
                    where(match.start()),
                    f'{match.group(1)}("{literal}") 由平台按系统语言解析，请改走 t(_:)；'
                    "确属非文案可加 // l10n-ok",
                )

    text = "\n".join(sources.values())
    if ".environment(\\.locale" not in text:
        report(errors, str(CATALOG.relative_to(ROOT)), 0, "没有任何视图注入 .environment(\\.locale)")
    if "LocalizedRoot {" not in text:
        report(
            errors,
            str(CATALOG.relative_to(ROOT)),
            0,
            "窗口根视图没有用 LocalizedRoot 包住，环境 locale 未注入",
        )
    return used, len(sources)


def main():
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings = catalog["strings"]
    used, file_count = scan_code()

    for key in sorted(used - set(strings)):
        report(errors, str(CATALOG.relative_to(ROOT)), 0, f"代码引用了 catalog 里没有的键：{key!r}")

    for key, entry in sorted(strings.items()):
        langs = values_of(entry)
        if not langs:
            report(errors, str(CATALOG.relative_to(ROOT)), 0, f"{key!r} 没有任何语言条目")
            continue
        with_variations = [lang for lang, loc in entry["localizations"].items() if "variations" in loc]
        if with_variations and len(with_variations) != len(entry["localizations"]):
            missing = sorted(set(entry["localizations"]) - set(with_variations))
            report(errors, str(CATALOG.relative_to(ROOT)), 0, f"{key!r} 的复数变化缺少语言：{missing}")
        for lang, loc in entry["localizations"].items():
            if "variations" in loc and "other" not in loc["variations"].get("plural", {}):
                report(errors, str(CATALOG.relative_to(ROOT)), 0, f"{key!r} 的 {lang} 缺少 other 形态")
        want = specifiers(key)
        for lang, values in sorted(langs.items()):
            for value in values:
                if specifiers(value) != want:
                    report(
                        errors,
                        str(CATALOG.relative_to(ROOT)),
                        0,
                        f"{key!r} 的 {lang} 格式符不一致：{specifiers(value)} ≠ {want}",
                    )

    stale = sorted(set(strings) - used)
    if STRICT:
        for key in stale:
            report(warnings, str(CATALOG.relative_to(ROOT)), 0, f"catalog 里的键没有被代码引用：{key!r}")
    elif stale:
        print(f"提示：{len(stale)} 个键暂未被代码引用（--strict 下计为失败）：{', '.join(stale)}")

    for level, bucket in (("ERROR", errors), ("WARN", warnings)):
        for rel, line, message in bucket:
            print(f"{level}  {rel}:{line}  {message}" if line else f"{level}  {rel}  {message}")

    print(f"扫描 {file_count} 个 Swift 文件、{len(strings)} 个键：{len(errors)} 错误、{len(warnings)} 警告")
    return 1 if errors or (STRICT and warnings) else 0


if __name__ == "__main__":
    sys.exit(main())