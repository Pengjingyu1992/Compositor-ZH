"""Audit keys without treating Swift interpolation as a format key.

This lexical scanner covers history forwarders, enum values and historyNames
providers. Unknown runtime history expressions fail --check. Dynamic UI labels
are reported separately because they may contain user text rather than keys.
"""
from pathlib import Path
from dataclasses import dataclass
import argparse
import json
import re


@dataclass
class Token:
    value: str
    start: int
    end: int
    kind: str = "code"
    dynamic: bool = False


def string_end(source, start):
    """Consume strings and nested interpolation, including raw strings."""
    opening = re.match(r'(#{0,})("""|")', source[start:])
    hashes, quote = opening.groups()
    position = start + len(opening.group())
    closing = quote + hashes
    interpolation = "\\" + hashes + "("
    dynamic = False
    while position < len(source):
        if source.startswith(interpolation, position):
            dynamic = True
            position = expression_end(source, position + len(interpolation), ")")
        elif source.startswith(closing, position):
            return position + len(closing), dynamic, hashes, quote
        elif not hashes and source[position] == "\\":
            position += 2
        else:
            position += 1
    raise ValueError(f"Unterminated Swift string at offset {start}")


def expression_end(source, position, closing):
    while position < len(source):
        if source.startswith("//", position):
            end = source.find("\n", position)
            position = len(source) if end < 0 else end
        elif source.startswith("/*", position):
            position = comment_end(source, position)
        elif re.match(r'#{0,}"', source[position:]):
            position = string_end(source, position)[0]
        elif source[position] in "([{":
            position = expression_end(source, position + 1, dict(zip("([{", ")]}"))[source[position]])
        elif source[position] == closing:
            return position + 1
        else:
            position += 1
    raise ValueError(f"Unterminated Swift expression, expected {closing}")


def comment_end(source, start):
    position, depth = start + 2, 1
    while position < len(source) and depth:
        if source.startswith("/*", position):
            depth += 1
            position += 2
        elif source.startswith("*/", position):
            depth -= 1
            position += 2
        else:
            position += 1
    return position


def tokenize(source):
    tokens, position = [], 0
    escapes = {'"': '"', "\\": "\\", "n": "\n", "r": "\r", "t": "\t", "0": "\0"}
    while position < len(source):
        start = position
        if source[position].isspace():
            position += 1
        elif source.startswith("//", position):
            end = source.find("\n", position)
            position = len(source) if end < 0 else end
        elif source.startswith("/*", position):
            position = comment_end(source, position)
        elif re.match(r'#{0,}"', source[position:]):
            position, dynamic, hashes, quote = string_end(source, position)
            content = source[start + len(hashes) + len(quote):position - len(hashes) - len(quote)]
            if not hashes and not dynamic:
                content = re.sub(r'\\(["\\nrt0])', lambda m: escapes[m.group(1)], content)
            tokens.append(Token(content, start, position, "string", dynamic))
        elif source[position].isalpha() or source[position] in "_$":
            position += 1
            while position < len(source) and (source[position].isalnum() or source[position] in "_$"):
                position += 1
            tokens.append(Token(source[start:position], start, position, "identifier"))
        else:
            position += 1
            tokens.append(Token(source[start:position], start, position))
    return tokens


def match_pairs(tokens):
    pairs, stack = {}, []
    for index, token in enumerate(tokens):
        if token.kind == "string":
            continue
        if token.value in ("(", "[", "{"):
            stack.append(index)
        elif token.value in (")", "]", "}"):
            if stack and tokens[stack[-1]].value == dict(zip(")]}", "([{"))[token.value]:
                pairs[stack.pop()] = index
    return pairs


def arguments(tokens, opening, pairs):
    closing = pairs.get(opening)
    if closing is None:
        return []
    result, start, index = [], opening + 1, opening + 1
    while index < closing:
        if index in pairs:
            index = pairs[index] + 1
        elif tokens[index].value == "," and tokens[index].kind != "string":
            result.append(tokens[start:index])
            start = index + 1
            index += 1
        else:
            index += 1
    result.append(tokens[start:closing])
    return result


HISTORY_ARGUMENTS = {
    "beginEdit": None, "addPixelLayer": "editName", "duplicateLayers": "editName",
    "setEffects": "name", "fillPixels": "name", "applyPixelEdit": "name", "commitRasterEdit": "name",
    "setSelection": "name", "applySelection": "name", "resizeSelection": "name",
    "applyDocumentSize": "actionName",
}
UI_CALLS = {
    "Text", "Button", "Toggle", "Picker", "TextField", "Label", "Section", "GroupBox", "Menu", "alert", "confirmationDialog",
    "help", "accessibilityLabel", "row", "number", "slider", "wheel", "control",
    "colorSlider", "defringeSlider", "entry", "field",
}
UI_HELPERS = {"row", "number", "slider", "wheel", "control", "colorSlider", "defringeSlider", "entry", "field"}
RAW_HISTORY_PROVIDERS = {
    "Filters.swift": {"edit.kind.rawValue"},
    "ShapeTool.swift": {"draft.kind.rawValue"},
    "LayerArrange.swift": {"operation.rawValue"},
}


def scan_source(root):
    occurrences, unresolved, dynamic_ui, forwarders = {}, [], [], []

    def add(token, path, source, category):
        if token.dynamic or len(token.value) <= 1:
            return
        occurrence = {"file": str(path.relative_to(root)), "line": source.count("\n", 0, token.start) + 1,
                      "category": category}
        if occurrence not in occurrences.setdefault(token.value, []):
            occurrences[token.value].append(occurrence)

    for path in sorted(root.rglob("*.swift")):
        source = path.read_text()
        tokens = tokenize(source)
        pairs = match_pairs(tokens)
        scopes, provider_ranges = [], []
        for index, token in enumerate(tokens[:-1]):
            if token.value == "func" and tokens[index + 1].kind == "identifier":
                opening = next((j for j in range(index + 2, len(tokens)) if tokens[j].value == "{"), None)
                if opening in pairs:
                    scopes.append((opening, pairs[opening], tokens[index + 1].value))
                    if tokens[index + 1].value == "mergePlan":
                        provider_ranges.append((opening, pairs[opening]))
            if token.value == "var" and tokens[index + 1].value == "historyNames":
                opening = next(j for j in range(index + 2, len(tokens)) if tokens[j].value == "{")
                provider_ranges.append((opening, pairs[opening]))
        for opening, closing in provider_ranges:
            provider_tokens = tokens[opening + 1:closing]
            if not any(t.kind == "string" for t in provider_tokens) or any(
                t.kind != "string" and t.value == "+" for t in provider_tokens
            ):
                unresolved.append({"file": str(path.relative_to(root)), "line": source.count("\n", 0, tokens[opening].start) + 1,
                                   "call": "history-provider", "expression": "Provider requires fixed literal keys."})
            for token in tokens[opening + 1:closing]:
                if token.kind == "string":
                    add(token, path, source, "history-provider")
                    if token.dynamic:
                        unresolved.append({"file": str(path.relative_to(root)), "line": source.count("\n", 0, token.start) + 1,
                                           "call": "history-provider", "expression": source[token.start:token.end]})

        if path.name == "EditorSession.swift":
            for index, token in enumerate(tokens[:-1]):
                if token.value == "var" and tokens[index + 1].value == "label":
                    opening = next(j for j in range(index + 2, len(tokens)) if tokens[j].value == "{")
                    for literal in tokens[opening + 1:pairs[opening]]:
                        if literal.kind == "string":
                            add(literal, path, source, "ui-provider")

        if path.name == "PSDText.swift":
            for index, token in enumerate(tokens[:-3]):
                if token.value == "let" and tokens[index + 1].value.endswith("Note") and tokens[index + 2].value == "=" and tokens[index + 3].kind == "string":
                    add(tokens[index + 3], path, source, "ui-provider")

        # Preserve the previous enum coverage, excluding commented-out code.
        by_start = {t.start: t for t in tokens if t.kind == "string"}
        for match in re.finditer(r'(?:case\s+|,\s*)\w+\s*=\s*(")', source):
            token = by_start.get(match.start(1))
            if token and any(c.isupper() for c in token.value):
                add(token, path, source, "enum")

        for index in range(len(tokens) - 1):
            name = tokens[index].value
            if tokens[index].kind != "identifier" or tokens[index + 1].value != "(":
                continue
            if index > 0 and tokens[index - 1].value == "func":
                for arg in arguments(tokens, index + 1, pairs):
                    label = HISTORY_ARGUMENTS.get(name)
                    if any(t.value == "editName" or label is not None and t.value == label for t in arg):
                        for token in arg:
                            if token.kind == "string":
                                add(token, path, source, "history-default")
                continue
            full_name = name
            if index >= 2 and tokens[index - 1].value == ".":
                full_name = tokens[index - 2].value + "." + name
            args = arguments(tokens, index + 1, pairs)
            target, category = None, "ui"
            if name in HISTORY_ARGUMENTS:
                label = HISTORY_ARGUMENTS[name]
                target = args[0] if args and label is None else next(
                    (arg[2:] for arg in args if len(arg) > 1 and arg[0].value == label and arg[1].value == ":"), None)
                category = "history"
            elif full_name in ("L10n.text", "L10n.format"):
                target = args[0] if args else None
                category = "runtime"
            elif name in UI_CALLS and (name not in UI_HELPERS or path.relative_to(root).parts[0] == "UI"):
                target = args[0] if args else None
            elif path.parent.name == "PSD" and name == "PSDConversion":
                target = next((arg[2:] for arg in args if len(arg) > 1 and arg[0].value == "message"), None)
            elif path.parent.name == "PSD" and full_name == "notes.append":
                target = args[0] if args else None
            elif name == "NSMenuItem":
                target = next((arg[2:] for arg in args if len(arg) > 1 and arg[0].value == "title"), None)
            if target:
                text = source[target[0].start:target[-1].end]
                strings = [t for t in target if t.kind == "string"]
                location = {"file": str(path.relative_to(root)), "line": source.count("\n", 0, target[0].start) + 1,
                            "call": full_name, "expression": text}
                concatenated = any(t.value == "+" and t.kind != "string" for t in target)
                if any(t.dynamic for t in strings) or concatenated:
                    (unresolved if category in ("history", "runtime") else dynamic_ui).append(location)
                else:
                    for token in strings:
                        add(token, path, source, category)
                    if category == "history" and not strings:
                        expression = re.sub(r"\s+", "", text)
                        scope = next((s[2] for s in reversed(scopes) if s[0] < index < s[1]), "")
                        known = (".historyNames." in expression or
                                 expression in RAW_HISTORY_PROVIDERS.get(path.name, set()) or
                                 expression in ("name", "editName", "actionName") and scope in HISTORY_ARGUMENTS or
                                 expression == "plan.action" and path.name == "LayerMerge.swift")
                        (forwarders if known else unresolved).append(location)
            for arg in args:
                if len(arg) > 1 and arg[0].value in ("editName", "help") and arg[1].value == ":":
                    for token in arg[2:]:
                        if token.kind == "string":
                            add(token, path, source, "history" if arg[0].value == "editName" else "ui")
        if path.name.startswith("CameraRaw") or path.name == "ColorRangeSheet.swift":
            for index, token in enumerate(tokens[:-1]):
                if token.value == "return" and tokens[index + 1].kind == "string":
                    add(tokens[index + 1], path, source, "ui-provider")
    return occurrences, unresolved, dynamic_ui, forwarders


def audit(root, catalog_path):
    occurrences, unresolved, dynamic_ui, forwarders = scan_source(root)
    catalog = json.loads(catalog_path.read_text())["strings"]
    missing = [{"key": key, "occurrences": occurrences[key]} for key in sorted(occurrences) if key not in catalog]
    untranslated = []
    for key in sorted(set(occurrences) & set(catalog)):
        unit = catalog[key].get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
        if not unit.get("value") or unit.get("state") != "translated":
            untranslated.append(key)
    return {"source": str(root), "catalog": str(catalog_path), "candidate_count": len(occurrences),
            "catalog_count": len(catalog), "missing": missing, "untranslated": untranslated,
            "unresolved_runtime_expressions": unresolved, "dynamic_ui_review": dynamic_ui,
            "history_forwarders": forwarders, "keys": dict(sorted(occurrences.items()))}


def main():
    base = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=base.parent / "Compositor")
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--report", type=Path, default=base.parent / "build/localization-audit.json")
    parser.add_argument("--check", action="store_true", help="Fail on missing keys, translations or unresolved runtime expressions.")
    args = parser.parse_args()
    root = args.source.resolve()
    result = audit(root, (args.catalog or root / "Localizable.xcstrings").resolve())
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    for item in result["missing"]:
        print("MISSING", item["key"])
    for item in result["unresolved_runtime_expressions"]:
        print(f'UNRESOLVED {item["file"]}:{item["line"]}: {item["expression"]}')
    print(f'{result["candidate_count"]} candidates; {len(result["missing"])} missing; '
          f'{len(result["untranslated"])} untranslated; {len(result["unresolved_runtime_expressions"])} unresolved runtime expressions.')
    return int(args.check and bool(result["missing"] or result["untranslated"] or result["unresolved_runtime_expressions"]))


if __name__ == "__main__":
    raise SystemExit(main())
