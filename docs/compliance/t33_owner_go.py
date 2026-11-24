"""Read the Go syntax needed by the T33 owner checks using only Python.

Parse named function bodies, including their nested callbacks, and split
direct calls into argument tokens. This is a structural reader for these
contracts, without Go type checking or data-flow analysis.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from dataclasses import dataclass, field
from itertools import pairwise


_TOKEN = re.compile(
    r"""(?P<trivia>\s+|//[^\n]*|/\*[\s\S]*?\*/)"""
    r"""|`[^`]*`|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"""
    r"""|[^\W\d]\w*|\d+|<<=|>>=|&\^=|[+\-*/%&|^]=|:=|==|!=|<=|>=|\|\||&&|\+\+|--|\.\.\.|[^\s]"""
)
_IDENTIFIER = re.compile(r"[^\W\d]\w*\Z")
_CLOSE = {"(": ")", "[": "]", "{": "}"}
_KEYWORDS = frozenset(
    "break case chan const continue default defer else fallthrough for func go goto if "
    "import interface map package range return select struct switch type var".split()
)
_ASSIGNMENTS = frozenset("= := += -= *= /= %= &= |= ^= <<= >>= &^= ++ --".split())
_LHS_BOUNDARIES = frozenset(
    ("{", "(", "[", ";", ":", "if", "for", "switch", "case", "var", "const", "type")
)


@dataclass(frozen=True)
class GoCall:
    function: str
    line: int
    arguments: tuple[tuple[str, ...], ...]
    position: int = field(default=-1, compare=False, repr=False)


@dataclass(frozen=True)
class GoBindingChange:
    position: int
    line: int
    statement: tuple[str, ...]
    function_level: bool


@dataclass(frozen=True)
class _Function:
    name: str
    params: int
    body: int


class GoSource:
    def __init__(self, source: str) -> None:
        self.source = source
        tokens = list(match for match in _TOKEN.finditer(source) if not match["trivia"])
        self.tokens = tuple(match[0] for match in tokens)
        self.offsets = tuple(match.start() for match in tokens)
        self.ends: dict[int, int] = {}
        stack: list[int] = []
        for i, token in enumerate(self.tokens):
            if token in _CLOSE:
                stack.append(i)
            elif token in _CLOSE.values():
                if not stack or _CLOSE[self.tokens[stack[-1]]] != token:
                    raise AssertionError(f"unmatched Go {token!r} on line {self._line(i)}")
                self.ends[stack.pop()] = i
        if stack:
            raise AssertionError(f"unclosed Go group on line {self._line(stack[-1])}")
        self.starts = {end: start for start, end in self.ends.items()}
        self.functions = tuple(self._functions())

    def _line(self, index: int) -> int:
        return self.source.count("\n", 0, self.offsets[index]) + 1

    def _level(self, start: int, stop: int) -> Iterator[int]:
        """Yield sibling tokens, skipping over nested groups."""
        while start < stop:
            yield start
            start = self.ends.get(start, start) + 1

    def _functions(self) -> Iterator[_Function]:
        for i in self._level(0, len(self.tokens)):
            if self.tokens[i] != "func":
                continue
            name = i + 1
            if self.tokens[name] == "(":
                name = self.ends[name] + 1  # Method receiver.
            if name + 1 >= len(self.tokens) or not _IDENTIFIER.fullmatch(self.tokens[name]):
                continue
            params = name + 1
            if self.tokens[params] == "[":
                params = self.ends[params] + 1
            if self.tokens[params] != "(":
                continue
            body = self._declaration_body(params, self.tokens[name])
            yield _Function(self.tokens[name], params, body)

    def _declaration_body(self, params: int, name: str) -> int:
        """Find the body after a signature whose result may itself be a func type."""
        cursor = self.ends[params] + 1
        has_result = False
        while cursor < len(self.tokens):
            if (
                has_result
                and cursor > self.ends[params] + 1
                and self._statement_break(cursor - 1, cursor)
            ):
                break
            token = self.tokens[cursor]
            if token in (";", "}"):
                break
            if token == "{":
                return cursor

            # Anonymous result types contain braces that are not the function body.
            if token in ("struct", "interface") and self.tokens[cursor + 1] == "{":
                cursor = self.ends[cursor + 1] + 1
            # A function result type has its own parameter group before the body.
            elif token == "func" and self.tokens[cursor + 1] == "(":
                cursor = self.ends[cursor + 1] + 1
            else:
                cursor = self.ends.get(cursor, cursor) + 1
            has_result = True
        raise AssertionError(f"missing Go body for {name}")

    def body(self, name: str) -> str:
        function = self._named(name)
        return self.source[self.offsets[function.body] + 1 : self.offsets[self.ends[function.body]]]

    def body_tokens(self, name: str) -> tuple[str, ...]:
        block = self._named(name).body
        return self.tokens[block + 1:self.ends[block]]

    def _block_after(self, start: int, stop: int, prefix: tuple[str, ...]) -> int | None:
        block = start + len(prefix)
        if (
            block < stop and self.tokens[start:block] == prefix
            and self.tokens[block] == "{" and self.ends[block] + 1 == stop
        ):
            return block
        return None

    def _code(self, start: int, stop: int) -> tuple[str, ...]:
        return tuple(token for token in self.tokens[start:stop] if token != ";")

    def switch_case(
        self, function: str, subject: str, value: str,
    ) -> tuple[str, ...] | None:
        """Return the active case body from a direct switch on the given subject."""
        prefix = GoSource(f"switch {subject}").tokens
        label = GoSource(f"case {value}:").tokens
        cases = []
        for start, stop in self._statements(self._named(function).body):
            block = self._block_after(start, stop, prefix)
            if block is None:
                continue
            end = self.ends[block]
            labels = [
                i for i in self._level(block + 1, end)
                if self.tokens[i] in ("case", "default")
            ]
            for first, last in pairwise([*labels, end]):
                body = first + len(label)
                if body <= last and self.tokens[first:body] == label:
                    cases.append(self._code(body, last))
        return cases[0] if len(cases) == 1 else None

    def callback_returns_call(self, target: str, signature: str, call: GoCall) -> bool:
        """Require an assigned callback to return the parsed direct call."""
        assignment = GoSource(f"{target} =").tokens
        header = assignment + GoSource(signature).tokens
        assignments = [
            (start, stop)
            for start, stop in self._statements(self._named(call.function).body)
            if self.tokens[start:start + len(assignment)] == assignment
        ]
        if len(assignments) != 1:
            return False
        block = self._block_after(*assignments[0], header)
        return (
            block is not None
            and self.tokens[call.position - 1] == "return"
            and tuple(self._statements(block))
            == ((call.position - 1, self.ends[call.position + 1] + 1),)
        )

    def guards_calls(
        self,
        function: str,
        guard: str,
        calls: tuple[GoCall, ...],
        error_check: str = "if e != nil { return e }",
    ) -> bool:
        """Require the guard directly after the error check around all calls."""
        if not calls:
            return False
        error_tokens = GoSource(error_check).tokens
        expected = GoSource(guard).tokens

        def guarded(block: int) -> bool:
            for before, current in pairwise(self._statements(block)):
                if (
                    self._code(*before) == error_tokens
                    and self._code(*current) == expected
                    and all(current[1] <= call.position < self.ends[block] for call in calls)
                ):
                    return True
            return False

        scope = self._named(function)
        if guarded(scope.body):
            return True

        signature = GoSource("func(tx pgx.Tx) error").tokens
        for session in self.calls("session", function=function, reject_indirect=False):
            if len(session.arguments) != 2 or session.arguments[0] != ("ctx",):
                continue
            _, callback = self._argument_spans(session.position + 1)
            block = self._block_after(*callback, signature)
            if block is not None and guarded(block):
                return True
        return False

    def _named(self, name: str) -> _Function:
        functions = tuple(function for function in self.functions if function.name == name)
        if len(functions) != 1:
            raise AssertionError(f"expected one Go function named {name}")
        return functions[0]

    def _arguments(self, opening: int) -> tuple[tuple[str, ...], ...]:
        return tuple(self.tokens[start:stop] for start, stop in self._argument_spans(opening))

    def _argument_spans(self, opening: int) -> Iterator[tuple[int, int]]:
        closing = self.ends[opening]
        start = opening + 1
        for i in self._level(start, closing):
            if self.tokens[i] == ",":
                yield start, i
                start = i + 1
        if start < closing:
            yield start, closing

    def parameter_names(self, function: str) -> frozenset[str]:
        return self._parameter_names(self._named(function).params)

    def _parameter_names(self, opening: int) -> frozenset[str]:
        return frozenset(
            arg[0] for arg in self._arguments(opening)
            if arg and _IDENTIFIER.fullmatch(arg[0])
        )

    def _statement_break(self, left: int, right: int) -> bool:
        token = self.tokens[left]
        inserts_semicolon = (
            token in (")", "]", "}", "++", "--", "break", "continue", "fallthrough", "return")
            or self._identifier(token) or token.isdecimal() or token.startswith(("`", '"', "'"))
        )
        end = self.offsets[left] + len(token)
        return inserts_semicolon and "\n" in self.source[end:self.offsets[right]]

    @staticmethod
    def _identifier(token: str) -> bool:
        return token not in _KEYWORDS and bool(_IDENTIFIER.fullmatch(token))

    def _statement_end(self, start: int, stop: int) -> int:
        previous = None
        for i in self._level(start, stop):
            if self.tokens[i] in (";", ")", "]", "}") or (
                previous is not None and self._statement_break(previous, i)
            ):
                return i
            previous = self.ends.get(i, i)
        return stop

    def _statements(self, block: int) -> Iterator[tuple[int, int]]:
        start = block + 1
        stop = self.ends[block]
        while start < stop:
            if self.tokens[start] == ";":
                start += 1
                continue
            end = self._statement_end(start, stop)
            yield start, end
            start = end

    def _variable_specs(self, start: int, stop: int) -> Iterator[tuple[int, int]]:
        if self.tokens[start] != "(":
            yield start, self._statement_end(start, stop)
            return
        stop = self.ends[start]
        start += 1
        while start < stop:
            if self.tokens[start] == ";":
                start += 1
                continue
            end = self._statement_end(start, stop)
            yield start, end
            start = end

    def _assignment_targets(self, operator: int) -> Iterator[tuple[int, int]]:
        """Split LHS targets at sibling commas, leaving expression groups intact."""
        end = operator
        following = operator
        left = operator - 1
        while left >= 0:
            token = self.tokens[left]
            if token in _LHS_BOUNDARIES or self._statement_break(left, following):
                break
            if token == ",":
                yield left + 1, end
                end = left
            following = self.starts.get(left, left)
            left = following - 1
        if left + 1 < end:
            yield left + 1, end

    def _target_root(self, start: int, end: int) -> str | None:
        for token in self.tokens[start:end]:
            if token not in ("(", "*", "&"):
                return token if self._identifier(token) else None
        return None

    def binding_changes(self, function: str, name: str) -> Iterator[GoBindingChange]:
        """Flag explicit writes or shadows of a protected input in this function."""
        scope = self._named(function)
        tokens = self.tokens
        stop = self.ends[scope.body]
        function_statements = {
            i for i in self._level(scope.body + 1, stop)
            if i == scope.body + 1 or tokens[i - 1] == ";" or self._statement_break(i - 1, i)
        }
        for i in range(scope.body + 1, stop):
            token = tokens[i]
            if token in _ASSIGNMENTS:
                targets = tuple(self._assignment_targets(i))
                if any(self._target_root(start, end) == name for start, end in targets):
                    start = targets[-1][0]
                    end = i + 1 if token in ("++", "--") else self._statement_end(i + 1, stop)
                    yield GoBindingChange(
                        start, self._line(start), tokens[start:end], start in function_statements,
                    )
            elif token in ("var", "const"):
                for start, end in self._variable_specs(i + 1, stop):
                    identifier = start
                    while identifier < end and self._identifier(tokens[identifier]):
                        if tokens[identifier] == name:
                            yield GoBindingChange(
                                i, self._line(identifier), (token, *tokens[start:end]),
                                i in function_statements,
                            )
                            break
                        if tokens[identifier + 1] != ",":
                            break
                        identifier += 2
            elif token == "func" and tokens[i + 1] == "(":
                params = i + 1
                results = self.ends[params] + 1
                if name in self._parameter_names(params) or (
                    tokens[results] == "(" and name in self._parameter_names(results)
                ):
                    yield GoBindingChange(i, self._line(i), ("func", name), False)

    def calls(
        self, *callee: str, function: str | None = None, reject_indirect: bool = True,
    ) -> Iterator[GoCall]:
        functions = self.functions if function is None else (self._named(function),)
        for scope in functions:
            for i in range(scope.body + 1, self.ends[scope.body]):
                after = i + len(callee)
                if self.tokens[i:after] != callee:
                    continue
                direct = self.tokens[i - 1] != "." and self.tokens[after] == "("
                if direct:
                    yield GoCall(scope.name, self._line(i), self._arguments(after), i)
                elif reject_indirect and len(callee) == 1:
                    raise AssertionError(
                        f"{scope.name}:{self._line(i)} must call {callee[0]} directly"
                    )
