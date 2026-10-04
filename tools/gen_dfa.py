#!/usr/bin/env python3
"""Emit src/scanner_dfa.mojo from yaml_parser_fetch_next_token's dispatch.

libyaml upstream used to ship a re2c grammar (tools/scanners.re) whose generated
tables are not present in the 90a56d4 tree; the character classification lives in
explicit macros in src/yaml_private.h and the token dispatch is an if-chain in
scanner.c: yaml_parser_fetch_next_token.  This script is the re2c stand-in: it
transcribes that if-chain into a transition table indexed by (context bits,
symbol) and writes it out as data, exactly as the generated header used to be
shipped.  Re-run it after touching the rules below.

Every condition here is a literal transcription of the C, in C order.
"""

from __future__ import annotations

import pathlib

# Symbol codes.  Everything that is not an indicator collapses to OTHER; the
# scanner's multi-byte classes (NUL, blankz) are carried in the context word.
SYMBOLS = [
    "OTHER",
    "Z",
    "PERCENT",
    "DASH",
    "DOT",
    "LBRACKET",
    "LBRACE",
    "RBRACKET",
    "RBRACE",
    "COMMA",
    "QUESTION",
    "COLON",
    "STAR",
    "AMP",
    "BANG",
    "PIPE",
    "GT",
    "SQUOTE",
    "DQUOTE",
    "HASH",
    "AT",
    "BACKTICK",
    "DOC_START",
    "DOC_END",
]
S = {name: i for i, name in enumerate(SYMBOLS)}
SYMBOL_COUNT = len(SYMBOLS)

# Single-octet symbol table: byte -> symbol code.  NUL is Z; the blank classes
# reach the dispatch through the context word, not as symbols.
SYM = [S["OTHER"]] * 256
SYM[0x00] = S["Z"]
for octet, name in [
    (0x25, "PERCENT"),
    (0x2D, "DASH"),
    (0x2E, "DOT"),
    (0x5B, "LBRACKET"),
    (0x7B, "LBRACE"),
    (0x5D, "RBRACKET"),
    (0x7D, "RBRACE"),
    (0x2C, "COMMA"),
    (0x3F, "QUESTION"),
    (0x3A, "COLON"),
    (0x2A, "STAR"),
    (0x26, "AMP"),
    (0x21, "BANG"),
    (0x7C, "PIPE"),
    (0x3E, "GT"),
    (0x27, "SQUOTE"),
    (0x22, "DQUOTE"),
    (0x23, "HASH"),
    (0x40, "AT"),
    (0x60, "BACKTICK"),
]:
    SYM[octet] = S[name]

# Context bits.  These are the six predicates the C reads beside the octet.
CTX_COL0 = 1 << 0  # parser->mark.column == 0
CTX_FLOW = 1 << 1  # parser->flow_level
CTX_BLANKZ1 = 1 << 2  # IS_BLANKZ_AT(buffer, 1)
CTX_BLANK1 = 1 << 3  # IS_BLANK_AT(buffer, 1)
CTX_BLANKZ0 = 1 << 4  # IS_BLANKZ(buffer)
CTX_BLANKZ3 = 1 << 5  # IS_BLANKZ_AT(buffer, 3)
CTX_COUNT = 1 << 6

ACTIONS = [
    "NONE",
    "STREAM_END",
    "DIRECTIVE",
    "DOCUMENT_START",
    "DOCUMENT_END",
    "FLOW_SEQUENCE_START",
    "FLOW_MAPPING_START",
    "FLOW_SEQUENCE_END",
    "FLOW_MAPPING_END",
    "FLOW_ENTRY",
    "BLOCK_ENTRY",
    "KEY",
    "VALUE",
    "ALIAS",
    "ANCHOR",
    "TAG",
    "BLOCK_SCALAR_LITERAL",
    "BLOCK_SCALAR_FOLDED",
    "FLOW_SCALAR_SINGLE",
    "FLOW_SCALAR_DOUBLE",
    "PLAIN",
]
A = {name: i for i, name in enumerate(ACTIONS)}

# The set the C excludes from starting a plain scalar.
PLAIN_EXCLUDED = {
    S["DASH"],
    S["QUESTION"],
    S["COLON"],
    S["COMMA"],
    S["LBRACKET"],
    S["RBRACKET"],
    S["LBRACE"],
    S["RBRACE"],
    S["HASH"],
    S["AMP"],
    S["STAR"],
    S["BANG"],
    S["PIPE"],
    S["GT"],
    S["SQUOTE"],
    S["DQUOTE"],
    S["PERCENT"],
    S["AT"],
    S["BACKTICK"],
}


def dispatch(ctx: int, sym: int) -> int:
    """The C's dispatch order, one (context, symbol) pair at a time."""
    flow = ctx & CTX_FLOW
    blankz1 = ctx & CTX_BLANKZ1
    blank1 = ctx & CTX_BLANK1
    blankz0 = ctx & CTX_BLANKZ0
    col0 = ctx & CTX_COL0

    if sym == S["Z"]:
        return A["STREAM_END"]
    if col0 and sym == S["PERCENT"]:
        return A["DIRECTIVE"]
    if sym == S["DOC_START"]:
        return A["DOCUMENT_START"]
    if sym == S["DOC_END"]:
        return A["DOCUMENT_END"]
    if sym == S["LBRACKET"]:
        return A["FLOW_SEQUENCE_START"]
    if sym == S["LBRACE"]:
        return A["FLOW_MAPPING_START"]
    if sym == S["RBRACKET"]:
        return A["FLOW_SEQUENCE_END"]
    if sym == S["RBRACE"]:
        return A["FLOW_MAPPING_END"]
    if sym == S["COMMA"]:
        return A["FLOW_ENTRY"]
    if sym == S["DASH"] and blankz1:
        return A["BLOCK_ENTRY"]
    if sym == S["QUESTION"] and (flow or blankz1):
        return A["KEY"]
    if sym == S["COLON"] and (flow or blankz1):
        return A["VALUE"]
    if sym == S["STAR"]:
        return A["ALIAS"]
    if sym == S["AMP"]:
        return A["ANCHOR"]
    if sym == S["BANG"]:
        return A["TAG"]
    if sym == S["PIPE"] and not flow:
        return A["BLOCK_SCALAR_LITERAL"]
    if sym == S["GT"] and not flow:
        return A["BLOCK_SCALAR_FOLDED"]
    if sym == S["SQUOTE"]:
        return A["FLOW_SCALAR_SINGLE"]
    if sym == S["DQUOTE"]:
        return A["FLOW_SCALAR_DOUBLE"]
    if not (blankz0 or sym in PLAIN_EXCLUDED):
        return A["PLAIN"]
    if sym == S["DASH"] and not blank1:
        return A["PLAIN"]
    if not flow and sym in (S["QUESTION"], S["COLON"]) and not blankz1:
        return A["PLAIN"]
    return A["NONE"]


def build() -> list[int]:
    return [
        dispatch(ctx, sym)
        for ctx in range(CTX_COUNT)
        for sym in range(SYMBOL_COUNT)
    ]


def mojo_tuple(values: list[int], name: str, per_line: int = 24) -> str:
    rows = []
    for i in range(0, len(values), per_line):
        rows.append("    " + ", ".join(str(v) for v in values[i : i + per_line]))
    return f"comptime {name} = StaticTuple[Int, {len(values)}](\n" + ",\n".join(
        rows
    ) + ",\n)\n"


def main() -> None:
    root = pathlib.Path(__file__).resolve().parents[1]
    trans = build()

    out = ['"""Character-class and token-dispatch tables for the scanner.',
           "",
           "GENERATED by tools/gen_dfa.py -- do not edit by hand.",
           "",
           "The upstream re2c grammar (tools/scanners.re) is absent from the",
           "90a56d4 tree, so these tables are transcribed by hand from",
           "scanner.c: yaml_parser_fetch_next_token and src/yaml_private.h.  The",
           "scan still runs through the same predicates as the C; this module",
           "replaces the dispatch if-chain with a table walk over (context,",
           "symbol).",
           '"""',
           "",
           "from std.utils import StaticTuple",
           "",
           "# Context bits read beside the lead octet.",
    ]
    for name, value in [
        ("CTX_COL0", CTX_COL0),
        ("CTX_FLOW", CTX_FLOW),
        ("CTX_BLANKZ1", CTX_BLANKZ1),
        ("CTX_BLANK1", CTX_BLANK1),
        ("CTX_BLANKZ0", CTX_BLANKZ0),
        ("CTX_BLANKZ3", CTX_BLANKZ3),
    ]:
        out.append(f"comptime {name}: Int = {value}")
    out.append("")
    out.append("# Scanner dispatch actions.")
    for name in ACTIONS:
        out.append(f'comptime ACT_{name}: Int = {A[name]}')
    out.append("")
    out.append(f"comptime SYMBOL_COUNT: Int = {SYMBOL_COUNT}")
    out.append(f"comptime CONTEXT_COUNT: Int = {CTX_COUNT}")
    out.append(f"comptime TRANSITIONS: Int = {len(trans)}")
    out.append("")
    for name in SYMBOLS:
        out.append(f'comptime SYM_{name}: Int = {S[name]}')
    out.append("")
    out.append(mojo_tuple(SYM, "DFA_SYMBOL_TABLE", 32))
    out.append("")
    out.append(mojo_tuple(trans, "DFA_TRANSITION_TABLE", SYMBOL_COUNT))
    out.append("")
    out.append(
        """# yaml_private.h: the six predicates the C reads beside the lead octet.
def dfa_context(
    column: Int,
    flow_level: Int,
    blankz0: Bool,
    blank1: Bool,
    blankz1: Bool,
    blankz3: Bool,
) -> Int:
    var ctx = 0
    if column == 0:
        ctx |= CTX_COL0
    if flow_level > 0:
        ctx |= CTX_FLOW
    if blankz0:
        ctx |= CTX_BLANKZ0
    if blank1:
        ctx |= CTX_BLANK1
    if blankz1:
        ctx |= CTX_BLANKZ1
    if blankz3:
        ctx |= CTX_BLANKZ3
    return ctx


# scanner.c: yaml_parser_fetch_next_token, one table step.
def dfa_dispatch(ctx: Int, symbol: Int) -> Int:
    var table = DFA_TRANSITION_TABLE
    return table[ctx * SYMBOL_COUNT + symbol]


# scanner.c: the symbol a lead octet maps to; the four-octet document
# indicators and the leading-blank case are resolved here rather than in the
# table, which is what upstream does by spelling them out as separate tests.
def dfa_symbol(octet: Int, next1: Int, next2: Int, next3: Int, column: Int) -> Int:
    var table = DFA_SYMBOL_TABLE
    var sym = table[octet]
    if column == 0 and (sym == SYM_DASH or sym == SYM_DOT) and next1 == octet and next2 == octet:
        if is_blankz_octet(next3):
            if sym == SYM_DASH:
                return SYM_DOC_START
            return SYM_DOC_END
        return sym
    return sym


# yaml_private.h: IS_BLANKZ for a single octet.  The multi-byte forms are
# excluded here and reach the probe through the caller's BLANKZ0/BLANKZ3 bits.
def is_blankz_octet(octet: Int) -> Bool:
    return octet == 0x00 or octet == 0x09 or octet == 0x0A or octet == 0x0D or octet == 0x20


@export("mojo_yaml_dfa_dispatch")
def mojo_yaml_dfa_dispatch(ctx: Int, symbol: Int) abi("C") -> Int64:
    return Int64(dfa_dispatch(ctx, symbol))


@export("mojo_yaml_dfa_symbol")
def mojo_yaml_dfa_symbol(octet: Int, next1: Int, next2: Int, next3: Int, column: Int) abi("C") -> Int64:
    return Int64(dfa_symbol(octet, next1, next2, next3, column))
        """
    )

    (root / "src" / "scanner_dfa.mojo").write_text("\n".join(out))
    print(f"wrote src/scanner_dfa.mojo: {len(trans)} transitions, {len(SYM)} symbols")


if __name__ == "__main__":
    main()