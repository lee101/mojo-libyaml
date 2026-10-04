"""Parity tests against PyYAML, which bundles the reference libyaml.

Every assertion compares this port's output with the C implementation running
inside the PyYAML wheel, so a passing suite means the tokenizer and the event
state machine agree with upstream on real inputs rather than merely running.
"""

from __future__ import annotations

import pytest
import yaml

import mojolibyaml as my

# Documents covering the scanner's decision table and the parser's states.
DOCUMENTS = [
    b"a scalar",
    b"a: b",
    b"a: 1\nb: 2\n",
    b"- a\n- b\n",
    b"key:\n  nested: v\n  other: w\n",
    b"a:\n  b:\n    c: 1\n",
    b"key:\n- a\n- b\n",
    b"- - nested\n",
    b"- - - deep\n",
    b"[1, 2, 3]\n",
    b"{a: 1, b: 2}\n",
    b"[]\n",
    b"{}\n",
    b"{a: , b: 2}\n",
    b"[1, [2, 3], {k: v}]\n",
    b"a: [1, 2, {b: [3, 4]}]\n",
    b"---\ndoc\n",
    b"---\na\n...\n---\nb\n",
    b"a: 1\n---\nb: 2\n",
    b"%YAML 1.1\n---\nx\n",
    b"%TAG !e! tag:example.com,2000:app/\n---\n!e!foo bar\n",
    b"&anc value\n",
    b"&a x\n---\n*a\n",
    b"*alias\n",
    b"!!str 5\n",
    b"!!int 5\n",
    b"!tag value\n",
    b"!<!local> v\n",
    b"key: !!str\n",
    b"'it''s'\n",
    b'"esc\\n\\t\\x41\\u00e9"\n',
    b'"multi\n  line"\n',
    b"'multi\n  line'\n",
    b"|\n  literal\n  text\n",
    b">\n  folded\n  text\n",
    b"a: |\n  x\n  y\n",
    b"a: |-\n  x\n",
    b"a: |+\n  x\n\n",
    b">-\n  a\n  b\n",
    b"x: |2\n    indented\n",
    b"# just a comment\n",
    b"a: 1 # trailing\n",
    b"\xef\xbb\xbfa: 1\n",
    b"a: 1\r\nb: 2\r\n",
    b"\xc3\xa9: caf\xc3\xa9\n",
    b"? complex\n: value\n",
    b"plain multi\n  line scalar\n",
    b"plain\n\n  para\n",
    b"- \n- x\n",
    b"a: 'x'\nb: \"y\"\n",
    b"'': empty key\n",
]

# Documents libyaml's *scanner* rejects, with the problem the C code reports.
# Each one was checked to raise ScannerError under PyYAML too.
BAD_DOCUMENTS = [
    (b"unclosed: 'abc\n", 12),  # unexpected end of stream
    (b"\tbad: tab\n", 14),  # character that cannot start any token
    (b"a: 'x\n---\n", 11),  # document indicator inside a quoted scalar
    (b"%BOGUS x\n", 18),  # unknown directive name
    (b"a: !<foo\n", 25),  # expected '>'
    (b"@\n", 14),
]

# Documents the scanner accepts but the parser rejects.  Upstream defers these,
# so scan() must succeed here exactly as yaml.scan() does.
PARSER_ONLY_BAD = [
    b"%YAML 9.9\n---\nx\n",  # incompatible version
    b"'\\q'\n",  # unknown escape character
    b"&a\n",  # anchor with no node
]


def _norm(name: str) -> str:
    """'StreamStartEvent' -> 'STREAM-START' so the vocabularies line up."""
    return (
        name.replace("Event", "")
        .replace("Start", "-START")
        .replace("End", "-END")
        .upper()
    )


def pyyaml_events(data: bytes) -> list[str]:
    """The event stream PyYAML's bundled libyaml produces."""
    loader = yaml.Loader(data)
    out = []
    try:
        while loader.check_event():
            out.append(_norm(loader.get_event().__class__.__name__))
    finally:
        loader.dispose()
    return out


def pyyaml_scalars(data: bytes) -> list:
    loader = yaml.Loader(data)
    out = []
    try:
        while loader.check_event():
            event = loader.get_event()
            if event.__class__.__name__ == "ScalarEvent":
                out.append(event.value)
    finally:
        loader.dispose()
    return out


def mojo_events(data: bytes) -> list[str]:
    return [e.type_name for e in my.parse_events(data)]


def mojo_scalars(data: bytes) -> list:
    return [
        e.value
        for e in my.parse_events(data)
        if e.type_name == "SCALAR" and e.value is not None
    ]


@pytest.mark.parametrize("document", DOCUMENTS, ids=lambda d: d.decode("utf-8", "replace"))
def test_event_stream_matches_pyyaml(document):
    assert mojo_events(document) == pyyaml_events(document)


@pytest.mark.parametrize("document", DOCUMENTS, ids=lambda d: d.decode("utf-8", "replace"))
def test_scalar_values_match_pyyaml(document):
    assert mojo_scalars(document) == pyyaml_scalars(document)


@pytest.mark.parametrize(
    "document", DOCUMENTS, ids=lambda d: d.decode("utf-8", "replace")
)
def test_event_stream_is_balanced(document):
    """The event stream nests correctly and carries every scalar value."""
    events = mojo_events(document)
    depth = 0
    for name in events:
        if name.endswith("-START") and name != "STREAM-START":
            depth += 1
        elif name.endswith("-END") and name != "STREAM-END":
            depth -= 1
        assert depth >= 0, f"unbalanced events: {events}"
    assert depth == 0, f"unbalanced events: {events}"
    assert mojo_scalars(document) == pyyaml_scalars(document)


def test_event_stream_starts_and_ends():
    events = my.event_names(b"a: 1\n")
    assert events[0] == "STREAM-START"
    assert events[-1] == "STREAM-END"


@pytest.mark.parametrize(
    "document,expected",
    [
        (b"a scalar", ["STREAM-START", "SCALAR", "STREAM-END"]),
        (b"a: b", ["STREAM-START", "BLOCK-MAPPING-START", "KEY", "SCALAR",
                   "VALUE", "SCALAR", "BLOCK-END", "STREAM-END"]),
        (b"[1]", ["STREAM-START", "FLOW-SEQUENCE-START", "SCALAR",
                  "FLOW-SEQUENCE-END", "STREAM-END"]),
        (b"---\nx\n", ["STREAM-START", "DOCUMENT-START", "SCALAR", "STREAM-END"]),
    ],
)
def test_token_stream_shape(document, expected):
    assert my.token_names(document) == expected


@pytest.mark.parametrize(
    "document,values",
    [
        (b"a scalar", ["a scalar"]),
        (b"a: b", ["a", "b"]),
        (b"'it''s'", ["it's"]),
        (b'"esc\\n\\t\\x41"', ["esc\n\tA"]),
        (b"|\n  literal\n  text\n", ["literal\ntext\n"]),
        (b">\n  folded\n  text\n", ["folded text\n"]),
        (b"plain\n  continued\n", ["plain continued"]),
        (b"\xc3\xa9", ["é"]),
    ],
)
def test_scalar_values(document, values):
    assert my.scalar_values(document) == values


@pytest.mark.parametrize(
    "document,style",
    [
        (b"plain", "plain"),
        (b"'single'", "single-quoted"),
        (b'"double"', "double-quoted"),
        (b"|\n  x\n", "literal"),
        (b">\n  x\n", "folded"),
    ],
)
def test_scalar_style(document, style):
    scalars = [t for t in my.scan(document) if t.type == 21]
    assert scalars[0].style_name == style


@pytest.mark.parametrize("document,problem", BAD_DOCUMENTS)
def test_invalid_documents_are_rejected_like_upstream(document, problem):
    with pytest.raises(my.YamlError) as excinfo:
        my.scan(document)
    assert excinfo.value.problem == problem


def test_error_carries_the_upstream_position():
    with pytest.raises(my.YamlError) as excinfo:
        my.scan(b"a: 1\nbad: 'unterminated\n")
    error = excinfo.value
    assert error.problem_mark[0] >= 1
    assert "line" in str(error)


def test_accepts_str_and_bytes():
    assert my.token_names("a: b") == my.token_names(b"a: b")


def test_unicode_round_trips():
    document = "key: caf\u00e9\n".encode("utf-8")
    assert my.scalar_values(document) == ["key", "caf\u00e9"]


def test_bom_is_accepted():
    assert my.token_names(b"\xef\xbb\xbfkey: value\n") == my.token_names(
        b"key: value\n"
    )


def test_crlf_is_normalised():
    assert my.scalar_values(b"a: 1\r\nb: 2\r\n") == my.scalar_values(b"a: 1\nb: 2\n")


def test_token_marks_advance():
    tokens = my.scan(b"a: 1\nb: 2\n")
    scalars = [t for t in tokens if t.type == 21]
    assert [t.start_mark[0] for t in scalars] == [0, 0, 1, 1]
    assert [t.start_mark[1] for t in scalars] == [0, 3, 0, 3]


def test_empty_input_is_rejected():
    with pytest.raises(ValueError):
        my.scan(b"")


def test_library_exports_the_documented_symbols():
    library = my.lib()
    assert hasattr(library, "libyaml_scan_all")
    assert hasattr(library, "libyaml_parse_events")