#!/usr/bin/env python3
"""从 xcresult 里提取失败用例的断言文本。

为什么需要它：`xcodebuild test` 的 stdout 只列「哪个用例失败」，`#expect` 的期望值/实际值
以及用例里的诊断 `print` 都只在 xcresult 里。没有这一步，CI 上只能看到一串用例名
（本项目实测：统计格式的三个用例真的失败过一次，日志里却只有名字，得下载几百 MB 产物
才能看到原因）。

用法：
    python3 scripts/xcresult-failures.py <path/to.xcresult>

退出码恒为 0：它只负责打印，判据仍在 `scripts/gate.sh`（测试退出码 + xcresult 摘要）。
"""
import json
import subprocess
import sys


def _xcresult(*arguments: str, path: str) -> dict:
    command = [
        "xcrun", "xcresulttool", "get", "test-results", *arguments,
        "--path", path, "--format", "json",
    ]
    completed = subprocess.run(command, capture_output=True, text=True)
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return {}


def _collect_cases(node: dict, out: list) -> None:
    if node.get("nodeType") == "Test Case":
        out.append(node)
    for child in node.get("children", []) or []:
        _collect_cases(child, out)


def _failure_texts(detail: dict) -> list:
    """把失败节点的可读信息都捞出来。

    字段名随 Xcode 版本/结果格式变（`failureText`、`Issue` 节点的 `name`、表达式树里的
    `Test Value`），因此不按固定键取，而是把失败子树里所有 `name`/`details` 按顺序摊开：
    形如 `abs((a - b) - c) : 53.0` 与 `2 : 2.0`，足以看清「期望 vs 实际」。
    """
    texts: list = []

    def walk(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key in ("failureText", "message", "failureMessage") and isinstance(child, str):
                    texts.append(child.strip())
                elif key == "name" and isinstance(child, str):
                    texts.append(child.strip())
                elif key == "details" and isinstance(child, str) and child.strip():
                    texts.append(child.strip())
                else:
                    walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    for run in detail.get("testRuns", []) or []:
        walk(run)
    # 去重但保序：同一个表达式节点会在 children 与 results 里各出现一次
    seen: set = set()
    unique: list = []
    for text in texts:
        if text in seen:
            continue
        seen.add(text)
        unique.append(text)
    return unique


def main(path: str) -> int:
    tree = _xcresult("tests", path=path)
    cases: list = []
    for node in tree.get("testNodes", []) or []:
        _collect_cases(node, cases)

    failed = [case for case in cases if case.get("result") == "Failed"]
    if not failed:
        print("（xcresult 里没有标记为 Failed 的用例）")
        return 0

    for case in failed:
        identifier = case.get("nodeIdentifier", "?")
        print(f"✘ {identifier}")
        detail = _xcresult("test-details", "--test-id", identifier, path=path)
        texts = _failure_texts(detail)
        if texts:
            for text in texts:
                print(f"    {text}")
        else:
            # 取不到可读文本时退化成「原样打印失败节点」——宁可吵，也不要静默。
            runs = detail.get("testRuns", []) or []
            print(f"    （未解析到断言文本）testRuns={json.dumps(runs, ensure_ascii=False)[:400]}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))