"""ctypes bindings for the Mojo libyaml tokenizer."""

from __future__ import annotations

import ctypes
import os
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
LIB = Path(os.environ.get("MOJO_LIBYAML_LIB", ROOT / "dist" / "libmojo-libyaml.so"))

I = ctypes.c_int64

# Records are a fixed stride, matching FIELDS_PER_TOKEN in capi.mojo.
FIELDS_PER_TOKEN = 16
FIELDS_PER_EVENT = 16

# Generous bounds; the native side stops when the stream ends.
_CAPACITY = 1 << 16
_PAYLOAD = 1 << 22

# include/yaml.h: yaml_token_type_e
TOKEN_NAMES = {
    0: "NO",
    1: "STREAM-START",
    2: "STREAM-END",
    3: "VERSION-DIRECTIVE",
    4: "TAG-DIRECTIVE",
    5: "DOCUMENT-START",
    6: "DOCUMENT-END",
    7: "BLOCK-SEQUENCE-START",
    8: "BLOCK-MAPPING-START",
    9: "BLOCK-END",
    10: "FLOW-SEQUENCE-START",
    11: "FLOW-SEQUENCE-END",
    12: "FLOW-MAPPING-START",
    13: "FLOW-MAPPING-END",
    14: "BLOCK-ENTRY",
    15: "FLOW-ENTRY",
    16: "KEY",
    17: "VALUE",
    18: "ALIAS",
    19: "ANCHOR",
    20: "TAG",
    21: "SCALAR",
}

# include/yaml.h: yaml_scalar_style_e
STYLE_NAMES = {
    0: "any",
    1: "plain",
    2: "single-quoted",
    3: "double-quoted",
    4: "literal",
    5: "folded",
}

# include/yaml.h: yaml_event_type_e
EVENT_NAMES = {
    0: "NO",
    1: "STREAM-START",
    2: "STREAM-END",
    3: "DOCUMENT-START",
    4: "DOCUMENT-END",
    5: "ALIAS",
    6: "SCALAR",
    7: "SEQUENCE-START",
    8: "SEQUENCE-END",
    9: "MAPPING-START",
    10: "MAPPING-END",
}

# yaml.h: yaml_sequence_style_e / yaml_mapping_style_e
STYLE_ANY = 0
STYLE_BLOCK = 1
STYLE_FLOW = 2

# scanner.mojo problem codes -> upstream's wording.
SCANNER_MESSAGES = {
    1: "could not read a character",
    2: "found a tab character where an indentation space is expected",
    3: "found a tab character that violates indentation",
    4: "mapping values are not allowed in this context",
    5: "mapping keys are not allowed in this context",
    6: "block sequence entries are not allowed in this context",
    7: "found unexpected ':'",
    8: "did not find expected key",
    9: "could not find expected ':'",
    10: "did not find expected '-' indicator",
    11: "found unexpected document indicator",
    12: "found unexpected end of stream",
    13: "did not find expected comment or line break",
    14: "found character that cannot start any token",
    15: "found an indentation indicator equal to 0",
    16: "could not find expected directive name",
    17: "found unexpected non-alphabetical character",
    18: "found unknown directive name",
    19: "did not find expected version number",
    20: "did not find expected digit or '.' character",
    21: "found extremely long version number",
    22: "did not find expected whitespace",
    23: "did not find expected tag URI",
    24: "did not find expected '!'",
    25: "did not find the expected '>'",
    26: "did not find URI escaped octet",
    27: "found an incorrect leading UTF-8 octet",
    28: "found an incorrect trailing UTF-8 octet",
    29: "did not find expected whitespace or line break",
    30: "did not find expected alphabetic or numeric character",
    31: "found unknown escape character",
    32: "did not find expected hexdecimal number",
    33: "found invalid Unicode character escape code",
    34: "found a tab character that violates indentation",
    35: "exceeded maximum nesting depth",
}

# parser.mojo problem codes.
PARSER_MESSAGES = {
    100: "did not find expected <stream-start>",
    101: "did not find expected <document start>",
    102: "found incompatible YAML document",
    103: "found duplicate %YAML directive",
    104: "found duplicate %TAG directive",
    105: "found undefined tag handle",
    106: "did not find expected node content",
    107: "did not find expected '-' indicator",
    108: "did not find expected key",
    109: "did not find expected ',' or ']'",
    110: "did not find expected ',' or '}'",
}

# yaml.h: YAML_*_ERROR
ERROR_NAMES = {0: None, 1: "reader error", 2: "scanner error", 3: "parser error"}

SIGNATURES = {
    "libyaml_scan_all": ([I] * 7, I),
    "libyaml_parse_events": ([I] * 7, I),
}

_library: ctypes.CDLL | None = None


def lib() -> ctypes.CDLL:
    global _library
    if _library is None:
        if not LIB.exists():
            raise RuntimeError(
                f"Mojo library not built at {LIB}; run `pixi run build`"
            )
        _library = ctypes.CDLL(str(LIB))
        for name, (argtypes, restype) in SIGNATURES.items():
            function = getattr(_library, name)
            function.argtypes = argtypes
            function.restype = restype
    return _library


class YamlError(ValueError):
    """Raised when the scanner or parser rejects a document, mirroring libyaml."""

    def __init__(self, problem: int, line: int, column: int, stage: str = "scanner"):
        kind = "scanner" if stage == "scanner" else "parser"
        table = SCANNER_MESSAGES if stage == "scanner" else PARSER_MESSAGES
        detail = table.get(problem, f"problem {problem}")
        self.problem = problem
        self.problem_mark = (line, column)
        super().__init__(
            f"{kind} error: {detail} at line {line + 1}, column {column + 1}"
        )


class Token:
    """One libyaml token, with the payload spans already resolved."""

    __slots__ = (
        "type",
        "start_mark",
        "end_mark",
        "value",
        "aux",
        "style",
        "major",
        "minor",
        "start_index",
        "end_index",
    )

    def __init__(self, **kwargs):
        for key in self.__slots__:
            setattr(self, key, kwargs.get(key))

    @property
    def type_name(self) -> str:
        return TOKEN_NAMES.get(self.type, str(self.type))

    @property
    def style_name(self) -> str | None:
        if self.type != 21:
            return None
        return STYLE_NAMES.get(self.style)

    def __repr__(self) -> str:
        return (
            f"Token({self.type_name}, value={self.value!r}, "
            f"style={self.style_name}, mark={self.start_mark})"
        )


class Event:
    """One libyaml parsing event."""

    __slots__ = (
        "type",
        "has_value",
        "implicit",
        "style",
        "value",
        "anchor",
        "tag",
        "plain_implicit",
        "quoted_implicit",
        "major",
        "minor",
    )

    def __init__(self, **kwargs):
        for key in self.__slots__:
            setattr(self, key, kwargs.get(key))

    @property
    def type_name(self) -> str:
        return EVENT_NAMES.get(self.type, str(self.type))

    def __repr__(self) -> str:
        return f"Event({self.type_name}, value={self.value!r})"


def _as_bytes(data: bytes | str) -> bytes:
    if isinstance(data, str):
        return data.encode("utf-8")
    return bytes(data)


def _run(function_name: str, data: bytes | str):
    raw = _as_bytes(data)
    if not raw:
        raise ValueError("input must be non-empty")
    # The reader expects the document followed by a terminator NUL, as
    # reader.c does at EOF.
    buffer = np.frombuffer(raw + b"\x00", dtype=np.uint8)
    records = np.zeros(_CAPACITY * FIELDS_PER_TOKEN, dtype=np.int64)
    payload = np.zeros(_PAYLOAD, dtype=np.uint8)
    status = np.zeros(8, dtype=np.int64)
    count = getattr(lib(), function_name)(
        buffer.ctypes.data,
        raw.__len__(),
        records.ctypes.data,
        _CAPACITY,
        payload.ctypes.data,
        _PAYLOAD,
        status.ctypes.data,
    )
    if count < 0:
        error = int(status[0])
        stage = "scanner" if error == 2 else "parser"
        raise YamlError(int(status[1]), int(status[2]), int(status[3]), stage)
    used = min(int(count) * FIELDS_PER_TOKEN, records.size)
    table = records[:used].reshape(-1, FIELDS_PER_TOKEN)
    arena = bytes(payload)
    return table, arena


def scan(data: bytes | str) -> list[Token]:
    """Tokenize ``data`` and return the full token stream.

    This is the Python surface of ``yaml_parser_initialize`` followed by
    ``yaml_parser_scan`` repeated until STREAM-END.
    """
    table, arena = _run("libyaml_scan_all", data)
    tokens = []
    for row in table:
        tokens.append(
            Token(
                type=int(row[0]),
                start_mark=(int(row[1]), int(row[2])),
                end_mark=(int(row[3]), int(row[4])),
                value=_span(arena, int(row[5]), int(row[6])),
                aux=_span(arena, int(row[7]), int(row[8])),
                style=int(row[9]),
                major=int(row[10]),
                minor=int(row[11]),
                start_index=int(row[12]),
                end_index=int(row[13]),
            )
        )
    return tokens

def parse_events(data: bytes | str) -> list[Event]:
    """Return the event stream, the Python surface of ``yaml_parser_parse``."""
    table, arena = _run("libyaml_parse_events", data)
    events = []
    for row in table:
        # An empty payload span is an empty string, not an absent one: upstream
        # hands back "" for the implicit null scalar of a missing key.
        value = _span(arena, int(row[3]), int(row[4]))
        events.append(
            Event(
                type=int(row[0]),
                implicit=bool(int(row[1])),
                style=int(row[2]),
                has_value=bool(int(row[14])),
                value="" if value is None else value,
                anchor=_span(arena, int(row[5]), int(row[6])),
                tag=_span(arena, int(row[7]), int(row[8])),
                plain_implicit=bool(int(row[9])),
                quoted_implicit=bool(int(row[10])),
                major=int(row[11]),
                minor=int(row[12]),
            )
        )
    return events


def _span(arena: bytes, start: int, end: int) -> str | None:
    if end <= start:
        return None
    return arena[start:end].decode("utf-8", errors="replace")


def token_names(data: bytes | str) -> list[str]:
    """Convenience: just the token type names, for parity assertions."""
    return [token.type_name for token in scan(data)]


def scalar_values(data: bytes | str) -> list[str]:
    """Every SCALAR token's value, in order."""
    return [t.value for t in scan(data) if t.type == 21]


def event_names(data: bytes | str) -> list[str]:
    """Just the event type names, for parity assertions."""
    return [event.type_name for event in parse_events(data)]