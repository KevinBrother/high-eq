"""Structural parsers used by the T33 contract checks.

The contracts need to distinguish executable workflow commands, Xcode build
entries, and native permission callbacks from comments or unrelated text.  The
repository intentionally keeps these checks dependency-free, so this module
implements only the small YAML/Xcode/README-shaped subset it needs.
"""

from __future__ import annotations

import json
import posixpath
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping


@dataclass(frozen=True)
class WorkflowStep:
    name: str = ""
    uses: str = ""
    run: str = ""
    working_directory: str = ""
    if_condition: str = ""
    continue_on_error: str = ""
    with_values: Mapping[str, str] | None = None

    def run_has(self, command: str) -> bool:
        return any(
            line.strip() == command or line.strip().startswith(f"{command} ")
            for line in self.run.splitlines()
        )


@dataclass(frozen=True)
class WorkflowJob:
    name: str
    runs_on: str
    steps: tuple[WorkflowStep, ...]
    if_condition: str = ""
    continue_on_error: str = ""


@dataclass(frozen=True)
class WorkflowPathRule:
    pattern: str
    exclude: bool = False


def _without_yaml_comments(workflow: str) -> list[str]:
    return [
        line
        for line in workflow.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def _scalar(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    if value[0] in ("'", '"') and value[-1:] == value[0]:
        return value[1:-1]
    return value.split(" #", 1)[0].rstrip()


def _inline_mapping(value: str) -> dict[str, str]:
    value = value.strip()
    if not (value.startswith("{") and value.endswith("}")):
        return {}
    result: dict[str, str] = {}
    for item in value[1:-1].split(","):
        if ":" not in item:
            continue
        key, raw = item.split(":", 1)
        result[key.strip()] = _scalar(raw)
    return result


def parse_workflow_jobs(workflow: str) -> dict[str, WorkflowJob]:
    """Parse named jobs and their real step entries from a simple Actions file."""
    lines = _without_yaml_comments(workflow)
    try:
        jobs_start = lines.index("jobs:") + 1
    except ValueError:
        return {}

    job_starts: list[tuple[int, str]] = []
    for index in range(jobs_start, len(lines)):
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", lines[index])
        if match:
            job_starts.append((index, match.group(1)))

    jobs: dict[str, WorkflowJob] = {}
    for job_index, (start, job_name) in enumerate(job_starts):
        end = job_starts[job_index + 1][0] if job_index + 1 < len(job_starts) else len(lines)
        block = lines[start:end]
        runs_on = ""
        job_if = job_continue_on_error = ""
        for line in block:
            match = re.match(r"^    runs-on:\s*(.+?)\s*$", line)
            if match:
                runs_on = _scalar(match.group(1))
            condition = re.match(r"^    if:\s*(.*?)\s*$", line)
            if condition:
                job_if = _scalar(condition.group(1))
            tolerant = re.match(r"^    continue-on-error:\s*(.*?)\s*$", line)
            if tolerant:
                job_continue_on_error = _scalar(tolerant.group(1))

        step_starts = [
            index
            for index, line in enumerate(block)
            if re.match(r"^      - (?:name|uses|run):", line)
        ]
        steps: list[WorkflowStep] = []
        for step_index, step_start in enumerate(step_starts):
            step_end = (
                step_starts[step_index + 1]
                if step_index + 1 < len(step_starts)
                else len(block)
            )
            step_lines = block[step_start:step_end]
            name = uses = run = working_directory = ""
            if_condition = continue_on_error = ""
            with_values: dict[str, str] = {}
            index = 0
            while index < len(step_lines):
                line = step_lines[index]
                first = re.match(r"^      - (name|uses|run):\s*(.*)$", line)
                key = ""
                value = ""
                if first:
                    key, value = first.group(1), first.group(2)
                else:
                    rest = re.match(r"^        ([A-Za-z0-9_-]+):\s*(.*)$", line)
                    if rest:
                        key, value = rest.group(1), rest.group(2)

                if key == "name":
                    name = _scalar(value)
                elif key == "uses":
                    uses = _scalar(value)
                elif key == "working-directory":
                    working_directory = _scalar(value)
                elif key == "if":
                    if_condition = _scalar(value)
                elif key == "continue-on-error":
                    continue_on_error = _scalar(value)
                elif key == "with":
                    if value.strip().startswith("{"):
                        with_values.update(_inline_mapping(value))
                    else:
                        nested = index + 1
                        while nested < len(step_lines):
                            nested_line = step_lines[nested]
                            nested_match = re.match(
                                r"^          ([A-Za-z0-9_-]+):\s*(.*)$", nested_line
                            )
                            if not nested_match:
                                break
                            with_values[nested_match.group(1)] = _scalar(
                                nested_match.group(2)
                            )
                            nested += 1
                        index = nested - 1
                elif key == "run":
                    if value.strip() in ("|", ">"):
                        body: list[str] = []
                        nested = index + 1
                        while nested < len(step_lines):
                            body_line = step_lines[nested]
                            if body_line.startswith("          "):
                                body.append(body_line[10:])
                                nested += 1
                            else:
                                break
                        run = "\n".join(body)
                        index = nested - 1
                    else:
                        run = _scalar(value)
                index += 1

            steps.append(
                WorkflowStep(
                    name=name,
                    uses=uses,
                    run=run,
                    working_directory=working_directory,
                    if_condition=if_condition,
                    continue_on_error=continue_on_error,
                    with_values=with_values,
                )
            )
        jobs[job_name] = WorkflowJob(
            job_name,
            runs_on,
            tuple(steps),
            if_condition=job_if,
            continue_on_error=job_continue_on_error,
        )
    return jobs


def workflow_trigger_path_rules(workflow: str, event: str) -> tuple[WorkflowPathRule, ...]:
    """Return ordered, uncommented path include/exclude rules for one event."""
    lines = _without_yaml_comments(workflow)
    try:
        start = lines.index(f"  {event}:") + 1
    except ValueError:
        return ()

    rules: list[WorkflowPathRule] = []
    in_paths = False
    for line in lines[start:]:
        if re.match(r"^  [A-Za-z_][A-Za-z0-9_-]*:", line):
            break
        if line.strip() == "paths:":
            in_paths = True
            continue
        if not in_paths:
            continue
        match = re.match(r"^      -\s+['\"]?([^'\"]+)['\"]?\s*$", line)
        if match:
            raw = match.group(1).strip()
            rules.append(WorkflowPathRule(raw.lstrip("!"), raw.startswith("!")))
        elif line.strip():
            in_paths = False
    return tuple(rules)


def workflow_has_path_filters(workflow: str, event: str) -> bool:
    """Return whether one event declares either GitHub path-filter style."""
    lines = _without_yaml_comments(workflow)
    try:
        start = lines.index(f"  {event}:") + 1
    except ValueError:
        return False

    for line in lines[start:]:
        if re.match(r"^  [A-Za-z_][A-Za-z0-9_-]*:", line):
            break
        if re.match(r"^    (?:paths|paths-ignore)\s*:", line):
            return True
    return False


def workflow_event_names(workflow: str) -> set[str]:
    """Return the events declared by the workflow's top-level `on` trigger."""
    lines = _without_yaml_comments(workflow)
    try:
        start = lines.index("on:") + 1
    except ValueError:
        inline = next(
            (line for line in lines if re.match(r"^on:\s*\[.*\]\s*$", line)),
            "",
        )
        if not inline:
            return set()
        body = inline.split(":", 1)[1].strip()[1:-1]
        return {
            item.strip().strip("'\"")
            for item in body.split(",")
            if item.strip().strip("'\"")
        }

    events: set[str] = set()
    for line in lines[start:]:
        if re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:", line):
            break
        match = re.match(r"^  ([A-Za-z_][A-Za-z0-9_-]*):", line)
        if match:
            events.add(match.group(1))
    return events


def command_execution_issues(run: str, command: str) -> tuple[str, ...]:
    """Return structural reasons a required shell command may not fail the step.

    GitHub's Linux `run` steps execute under `bash -e`, so an earlier `exit 0`,
    a leading control-flow indent, a trailing `|| ...`, or `set +e` changes the
    observable result even though the command text is still present.
    """
    lines = [line.rstrip("\r\n") for line in run.splitlines()]
    matching = [
        index
        for index, line in enumerate(lines)
        if (stripped := line.strip()) == command
        or stripped.startswith(f"{command} ")
    ]
    if not matching:
        return ("missing",)

    issues: set[str] = set()
    for index in matching:
        raw = lines[index]
        if raw.startswith((" ", "\t")):
            issues.add("conditional")

        tail = raw.strip()[len(command) :]
        if re.search(r"(?<!\\)\|\|", tail):
            issues.add("failure-swallowed")
        if re.search(r"(?<!\\)(?<!\|)\|(?!\|)", tail):
            issues.add("failure-swallowed")
        if re.search(r"(?<!\\)&\s*$", tail):
            issues.add("failure-swallowed")

        for previous in lines[:index]:
            statement = previous.strip().split(" #", 1)[0].rstrip()
            if re.match(r"^(?:exit|return)(?:\s|$)", statement):
                issues.add("early-exit")
            if re.match(r"^set\s+\+(?:e|[a-z]*e[a-z]*)(?:\s|$)", statement):
                issues.add("failure-swallowed")
            if statement == "set +o errexit":
                issues.add("failure-swallowed")
    return tuple(sorted(issues))


def _glob_regex(pattern: str) -> re.Pattern[str]:
    """Translate GitHub's slash-aware path glob subset into a full-match regex."""
    pieces = ["^"]
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "*" and pattern[index : index + 2] == "**":
            pieces.append(".*")
            index += 2
        elif char == "*":
            pieces.append("[^/]*")
            index += 1
        elif char == "?":
            pieces.append("[^/]")
            index += 1
        else:
            pieces.append(re.escape(char))
            index += 1
    pieces.append("$")
    return re.compile("".join(pieces))


def _path_matches(pattern: str, path: str) -> bool:
    return bool(_glob_regex(pattern).fullmatch(path))


def workflow_path_is_triggered(workflow: str, event: str, path: str) -> bool:
    """Apply ordered include/exclude rules exactly as the workflow event would."""
    triggered = False
    for rule in workflow_trigger_path_rules(workflow, event):
        if _path_matches(rule.pattern, path):
            triggered = not rule.exclude
    return triggered


def workflow_trigger_paths(workflow: str, event: str) -> set[str]:
    """Return the include rules left effective after explicit exclusions."""
    effective: list[str] = []
    for rule in workflow_trigger_path_rules(workflow, event):
        if rule.exclude:
            effective = [path for path in effective if not _path_matches(rule.pattern, path)]
        else:
            effective.append(rule.pattern)
    return set(effective)


def uses_ignored_build_path(value: str) -> bool:
    """Detect direct, relative-parent, or working-directory references to build/."""
    if not value:
        return False
    normalized = value.replace("\\", "/")
    for token in re.findall(r"[^\s\"'`;|&()]+", normalized):
        candidate = posixpath.normpath(token)
        if "build" in candidate.split("/"):
            return True
    return False


def _strip_kotlin_comments(source: str) -> str:
    without_blocks = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", without_blocks)


def _braced_body(source: str, declaration: re.Pattern[str]) -> str | None:
    match = declaration.search(source)
    if match is None:
        return None
    start = source.find("{", match.end() - 1)
    if start < 0:
        return None
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1 : index]
    return None


def _has_top_level_statement(body: str, statement: re.Pattern[str]) -> bool:
    """Return whether a statement starts directly in the function body.

    Calls nested in a block are deliberately rejected even when that block is
    currently true.  Permission completion should be a direct callback action,
    not an implementation detail hidden behind control flow.
    """
    depth = 0
    controlled_body = False
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if depth == 0:
            if controlled_body:
                controlled_body = False
            else:
                if re.match(r"^(?:return|throw)\b", stripped):
                    return False
                if statement.match(stripped):
                    return True
                controlled_body = bool(
                    re.match(
                        r"^(?:(?:else\s+)?if|for|while|when|catch)\s*\(.*\)\s*$",
                        stripped,
                    )
                    or re.match(r"^(?:else|finally)\s*$", stripped)
                )
        depth += line.count("{") - line.count("}")
        if depth < 0:
            depth = 0
    return False


def _has_top_level_keyword_statement(body: str, keyword: str) -> bool:
    """Return whether a normalized body has a direct statement with keyword."""
    depth = 0
    statement_start = 0

    def starts_with_keyword(end: int) -> bool:
        statement = body[statement_start:end].lstrip()
        return bool(re.match(rf"{re.escape(keyword)}\b", statement))

    for index, char in enumerate(body):
        if char == "{":
            depth += 1
        elif char == "}":
            depth = max(0, depth - 1)
            if depth == 0:
                if starts_with_keyword(index + 1):
                    return True
                statement_start = index + 1
        elif char == ";" and depth == 0:
            if starts_with_keyword(index + 1):
                return True
            statement_start = index + 1
    return starts_with_keyword(len(body))


def android_permission_callback_errors(entry: str, native_sources: Mapping[str, str]) -> list[str]:
    """Require an executable MainActivity callback and a real VoiceCapture handler."""
    errors: list[str] = []
    delegate = re.compile(
        r"voiceCapture\s*\.\s*handlePermissionResult\s*\(\s*requestCode\s*,"
        r"\s*permissions\s*,\s*grantResults\s*\)"
    )
    entry_body = _braced_body(
        _strip_kotlin_comments(entry),
        re.compile(r"override\s+fun\s+onRequestPermissionsResult\s*\([^)]*\)"),
    )
    if entry_body is None or not _has_top_level_statement(entry_body, delegate):
        errors.append(
            "Android MainActivity does not delegate microphone permission results"
        )

    capture = native_sources.get(
        "app/android/app/src/main/kotlin/cn/higheq/high_eq/VoiceCapture.kt", ""
    )
    capture_body = _braced_body(
        _strip_kotlin_comments(capture),
        re.compile(r"fun\s+handlePermissionResult\s*\([^)]*\)"),
    )
    if (
        capture_body is None
        or "PERMISSION_REQUEST" not in capture_body
        or not _has_top_level_statement(
            capture_body, re.compile(r"pending\s*\.\s*success\s*\(")
        )
    ):
        errors.append("Android VoiceCapture does not handle microphone permission results")
    return errors


def _pbx_section(project: str, name: str) -> str:
    match = re.search(
        rf"/\* Begin {re.escape(name)} section \*/(.*?)/\* End {re.escape(name)} section \*/",
        project,
        re.S,
    )
    return match.group(1) if match else ""


def _pbx_objects(section: str) -> dict[str, str]:
    objects: dict[str, str] = {}
    lines = section.splitlines()
    index = 0
    while index < len(lines):
        match = re.match(
            r"^\s*([A-F0-9]{24})(?:\s*/\*.*?\*/)?\s*=\s*\{(.*)$",
            lines[index],
        )
        if match is None:
            index += 1
            continue
        object_id = match.group(1)
        remainder = match.group(2)
        if remainder.rstrip().endswith("};"):
            objects[object_id] = remainder.rstrip()[:-2]
            index += 1
            continue
        body: list[str] = [remainder]
        index += 1
        while index < len(lines):
            closing = re.match(r"^\s*\};", lines[index])
            if closing:
                break
            body.append(lines[index])
            index += 1
        objects[object_id] = "\n".join(body)
        index += 1
    return objects


def _pbx_value(body: str, key: str) -> str:
    match = re.search(rf"\b{re.escape(key)}\s*=\s*([^;]+)\s*;", body)
    return match.group(1).strip().strip('"') if match else ""


def _project_relative_path(*parts: str) -> str:
    present = tuple(part for part in parts if part)
    if not present:
        return ""
    joined = posixpath.join(*present)
    normalized = posixpath.normpath(joined) if joined else ""
    if normalized in ("", "."):
        return ""
    if normalized == ".." or normalized.startswith("../") or normalized.startswith("/"):
        return ""
    return normalized


def _pbx_group_paths(groups: Mapping[str, str]) -> tuple[dict[str, str], dict[str, str]]:
    parents: dict[str, str] = {}
    for group_id, body in groups.items():
        children = re.search(r"\bchildren\s*=\s*\((.*?)\);", body, re.S)
        if children is None:
            continue
        for child_id in re.findall(r"\b([A-F0-9]{24})\b", children.group(1)):
            parents[child_id] = group_id

    resolved: dict[str, str] = {}

    def resolve(group_id: str, active: set[str] | None = None) -> str:
        if group_id in resolved:
            return resolved[group_id]
        stack = active or set()
        if group_id in stack:
            return ""
        stack.add(group_id)
        body = groups.get(group_id, "")
        own_path = _pbx_value(body, "path")
        source_tree = _pbx_value(body, "sourceTree") or "<group>"
        parent = parents.get(group_id)
        if parent and source_tree == "<group>":
            base = resolve(parent, stack)
            path = _project_relative_path(base, own_path)
        elif source_tree in ("SOURCE_ROOT", "$(SRCROOT)", "$(PROJECT_DIR)"):
            path = _project_relative_path(own_path)
        else:
            path = ""
        stack.remove(group_id)
        resolved[group_id] = path
        return path

    for group_id in groups:
        resolve(group_id)
    return resolved, parents


def ios_runner_source_files(project: str) -> set[str]:
    """Resolve source paths in the Runner target's compile Sources phase."""
    build_files = _pbx_objects(_pbx_section(project, "PBXBuildFile"))
    file_refs = _pbx_objects(_pbx_section(project, "PBXFileReference"))
    groups = _pbx_objects(_pbx_section(project, "PBXGroup"))
    target_objects = _pbx_objects(_pbx_section(project, "PBXNativeTarget"))
    phase_objects = _pbx_objects(_pbx_section(project, "PBXSourcesBuildPhase"))
    group_paths, parents = _pbx_group_paths(groups)

    runner_target = next(
        (
            body
            for body in target_objects.values()
            if re.search(r"\bisa\s*=\s*PBXNativeTarget\s*;", body)
            and re.search(r"\bname\s*=\s*Runner\s*;", body)
        ),
        None,
    )
    if runner_target is None:
        return set()
    phases_match = re.search(r"\bbuildPhases\s*=\s*\((.*?)\);", runner_target, re.S)
    if phases_match is None:
        return set()
    phase_ids = re.findall(r"\b([A-F0-9]{24})\b", phases_match.group(1))

    source_paths: set[str] = set()
    for phase_id in phase_ids:
        phase = phase_objects.get(phase_id, "")
        if not re.search(r"\bisa\s*=\s*PBXSourcesBuildPhase\s*;", phase):
            continue
        files_match = re.search(r"\bfiles\s*=\s*\((.*?)\);", phase, re.S)
        if files_match is None:
            continue
        for build_file_id in re.findall(r"\b([A-F0-9]{24})\b", files_match.group(1)):
            build_file = build_files.get(build_file_id, "")
            file_ref_match = re.search(
                r"\bfileRef\s*=\s*([A-F0-9]{24})(?:\s*/\*.*?\*/)?\s*;",
                build_file,
            )
            if file_ref_match is None:
                continue
            file_ref_id = file_ref_match.group(1)
            file_ref = file_refs.get(file_ref_id, "")
            own_path = _pbx_value(file_ref, "path")
            if not own_path:
                continue
            source_tree = _pbx_value(file_ref, "sourceTree") or "<group>"
            if source_tree == "<group>":
                path = _project_relative_path(
                    group_paths.get(parents.get(file_ref_id, ""), ""), own_path
                )
            elif source_tree in ("SOURCE_ROOT", "$(SRCROOT)", "$(PROJECT_DIR)"):
                path = _project_relative_path(own_path)
            else:
                path = ""
            if path:
                source_paths.add(path)
    return source_paths


def load_historical_evidence(path: str | Path) -> Mapping[str, Any] | None:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def _mask_dart_noncode(source: str) -> str:
    """Blank Dart comments and string literals while preserving line breaks."""
    masked = list(source)

    def blank(start: int, end: int) -> None:
        for index in range(start, min(end, len(masked))):
            if masked[index] not in "\r\n":
                masked[index] = " "

    index = 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            blank(index, end)
            index = end
            continue
        if source.startswith("/*", index):
            depth = 1
            blank(index, index + 2)
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    blank(index, index + 2)
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    blank(index, index + 2)
                    index += 2
                else:
                    blank(index, index + 1)
                    index += 1
            continue

        quote = next(
            (value for value in ("'''", '"""', "'", '"') if source.startswith(value, index)),
            "",
        )
        if not quote:
            index += 1
            continue
        blank(index, index + len(quote))
        index += len(quote)
        while index < len(source):
            if source.startswith(quote, index):
                blank(index, index + len(quote))
                index += len(quote)
                break
            if source[index] == "\\" and index + 1 < len(source):
                blank(index, index + 2)
                index += 2
            else:
                blank(index, index + 1)
                index += 1
    return "".join(masked)


def _compact_dart_code(source: str) -> str:
    """Normalize formatting whitespace without joining distinct identifiers."""
    compact = re.sub(r"\s+", " ", source).strip()
    return re.sub(r"\s*([(){}\[\],:;.?!<>+*/=\-])\s*", r"\1", compact)


def dart_method_body(source: str, name: str) -> str:
    """Return a Future method body with comments and string literals blanked."""
    declaration = re.compile(
        rf"\bFuture<(?:void|bool)>\s+{re.escape(name)}\s*\(.*?\)\s+async\s*\{{",
        re.S,
    )
    body = _braced_body(_mask_dart_noncode(source), declaration)
    if body is None:
        raise ValueError(f"missing or unterminated Dart method {name}")
    return body


def practice_consent_contract_errors(source: str) -> list[str]:
    """Check practice consent ordering and every create/recovery funnel."""
    try:
        ensure = _compact_dart_code(dart_method_body(source, "ensurePracticeConsent"))
        create = _compact_dart_code(dart_method_body(source, "create"))
        start = _compact_dart_code(dart_method_body(source, "start"))
        open_session = _compact_dart_code(dart_method_body(source, "open"))
        resume = _compact_dart_code(dart_method_body(source, "_resumePending"))
        target = _compact_dart_code(dart_method_body(source, "_openTargetLevel"))
    except ValueError as error:
        return [str(error)]

    def without_trailing_commas(code: str) -> str:
        return code.replace(",)", ")")

    ensure = without_trailing_commas(ensure)
    create = without_trailing_commas(create)
    start = without_trailing_commas(start)
    open_session = without_trailing_commas(open_session)
    resume = without_trailing_commas(resume)
    target = without_trailing_commas(target)

    errors: list[str] = []

    def once(body: str, label: str, needle: str) -> int:
        compact_needle = without_trailing_commas(_compact_dart_code(needle))
        count = body.count(compact_needle)
        if count != 1:
            errors.append(f"{label} must occur exactly once")
            return -1
        return body.index(compact_needle)

    def before(label: str, earlier: int, later: int) -> None:
        if earlier >= 0 and later >= 0 and earlier >= later:
            errors.append(label)

    granted = once(
        ensure,
        "initial practice consent read",
        "final granted = await widget.repo.practiceConsent();",
    )
    shortcut = once(
        ensure, "existing grant shortcut", "if (granted) return true;"
    )
    dialog = once(
        ensure, "explicit practice consent dialog", "final ok = await showDialog<bool>("
    )
    declined = once(
        ensure, "declined practice consent guard", "if (ok != true) return false;"
    )
    grant = once(
        ensure, "practice consent grant", "await widget.repo.grantPracticeConsent();"
    )
    reread = once(
        ensure,
        "practice consent re-read",
        "final confirmed = await widget.repo.practiceConsent();",
    )
    confirmed = once(ensure, "practice consent confirmation", "if (!confirmed) {")
    before(
        "practice consent must be read before the existing-grant shortcut",
        granted,
        shortcut,
    )
    before(
        "the explicit practice consent dialog must follow the consent read",
        shortcut,
        dialog,
    )
    before(
        "the declined practice consent guard must follow the dialog",
        dialog,
        declined,
    )
    before(
        "practice consent must not be granted before explicit acceptance",
        declined,
        grant,
    )
    before(
        "practice consent must be re-read after grant",
        grant,
        reread,
    )
    before(
        "the re-read practice consent must be confirmed after grant",
        reread,
        confirmed,
    )
    confirmation_branch = _braced_body(
        ensure,
        re.compile(r"\bif\s*\(\s*!\s*confirmed\s*\)"),
    )
    if confirmation_branch is None or not _has_top_level_keyword_statement(
        confirmation_branch, "throw"
    ):
        errors.append(
            "practice consent confirmation must throw when re-read remains false"
        )

    consent_gate = once(
        create,
        "practice consent gate",
        "if (!await ensurePracticeConsent(stillCurrent: isCurrent)) return;",
    )
    create_request = once(
        create, "practice create request", "final s = await repo.create(body);"
    )
    before(
        "practice create must follow the consent gate",
        consent_gate,
        create_request,
    )

    compact_source = _compact_dart_code(_mask_dart_noncode(source))
    direct_create = re.compile(r"\b(?:widget\.)?repo\.create\(")
    direct_creates = direct_create.findall(compact_source)
    create_call_sites = direct_create.findall(create)
    if len(direct_creates) != 1 or len(create_call_sites) != 1:
        errors.append("practice repository create must be called only from create")

    if "start(" not in target:
        errors.append("planned practice target must enter the start funnel")
    if "await create({" not in start:
        errors.append("practice start must enter the create funnel")
    if "create(intent,stillCurrent:isCurrent)" not in resume:
        errors.append("practice recovery must enter the create funnel")
    if "start(input" not in open_session:
        errors.append("practice repeat must enter the start funnel")

    return errors
