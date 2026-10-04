"""YAML tokenizer ported from libyaml's scanner.c.

The character classification macros from yaml_private.h, the simple-key and
indent bookkeeping, and every token scanner follow upstream's structure and
order so the two files can be read side by side.

Two divergences from the C source, both forced by the Mojo dialect:

  * The input model.  Upstream streams through a reader callback into a
    refillable buffer; here the caller hands over the whole UTF-8 document with
    a terminator NUL appended, which is what yaml_parser_update_buffer
    effectively produces at EOF.
  * String payloads.  Token payloads live in one growable arena and a Token
    records an offset and length instead of holding a buffer, because a struct
    carrying a List loses implicit copyability and cannot then be passed to a
    helper by value.  Every scalar scanner writes through the same
    `emit_*` / `clear_*` pair that `STRING_EXTEND`, `CLEAR` and `JOIN` provide
    in yaml_private.h.
"""

from std.sys import simd_width_of
from scanner_dfa import (
    ACT_ALIAS,
    ACT_ANCHOR,
    ACT_BLOCK_ENTRY,
    ACT_BLOCK_SCALAR_FOLDED,
    ACT_BLOCK_SCALAR_LITERAL,
    ACT_DIRECTIVE,
    ACT_DOCUMENT_END,
    ACT_DOCUMENT_START,
    ACT_FLOW_ENTRY,
    ACT_FLOW_MAPPING_END,
    ACT_FLOW_MAPPING_START,
    ACT_FLOW_SCALAR_DOUBLE,
    ACT_FLOW_SCALAR_SINGLE,
    ACT_FLOW_SEQUENCE_END,
    ACT_FLOW_SEQUENCE_START,
    ACT_KEY,
    ACT_PLAIN,
    ACT_STREAM_END,
    ACT_TAG,
    ACT_VALUE,
    dfa_context,
    dfa_dispatch,
    dfa_symbol,
)

comptime U8Ptr = Pointer[UInt8, AnyOrigin[mut=True]]
comptime WIDTH = simd_width_of[DType.uint8]()

# parser.c: MAX_NESTING_LEVEL, also reachable through
# yaml_get_max_nest_level / yaml_set_max_nest_level.
comptime MAX_NESTING_LEVEL: Int = 1000

# yaml.h: YAML_NO_ERROR and friends (subset that the scanner sets).
comptime NO_ERROR: Int = 0
comptime SCANNER_ERROR: Int = 2

# yaml.h: yaml_token_type_e
comptime NO_TOKEN: Int = 0
comptime STREAM_START_TOKEN: Int = 1
comptime STREAM_END_TOKEN: Int = 2
comptime VERSION_DIRECTIVE_TOKEN: Int = 3
comptime TAG_DIRECTIVE_TOKEN: Int = 4
comptime DOCUMENT_START_TOKEN: Int = 5
comptime DOCUMENT_END_TOKEN: Int = 6
comptime BLOCK_SEQUENCE_START_TOKEN: Int = 7
comptime BLOCK_MAPPING_START_TOKEN: Int = 8
comptime BLOCK_END_TOKEN: Int = 9
comptime FLOW_SEQUENCE_START_TOKEN: Int = 10
comptime FLOW_SEQUENCE_END_TOKEN: Int = 11
comptime FLOW_MAPPING_START_TOKEN: Int = 12
comptime FLOW_MAPPING_END_TOKEN: Int = 13
comptime BLOCK_ENTRY_TOKEN: Int = 14
comptime FLOW_ENTRY_TOKEN: Int = 15
comptime KEY_TOKEN: Int = 16
comptime VALUE_TOKEN: Int = 17
comptime ALIAS_TOKEN: Int = 18
comptime ANCHOR_TOKEN: Int = 19
comptime TAG_TOKEN: Int = 20
comptime SCALAR_TOKEN: Int = 21

# yaml.h: yaml_scalar_style_e
comptime ANY_SCALAR_STYLE: Int = 0
comptime PLAIN_SCALAR_STYLE: Int = 1
comptime SINGLE_QUOTED_SCALAR_STYLE: Int = 2
comptime DOUBLE_QUOTED_SCALAR_STYLE: Int = 3
comptime LITERAL_SCALAR_STYLE: Int = 4
comptime FOLDED_SCALAR_STYLE: Int = 5

# scanner.c: MAX_NUMBER_LENGTH
comptime MAX_NUMBER_LENGTH: Int = 9

# Scanner problems.  The Python layer maps each code back to upstream's
# message text, so the wording stays with the API that reports it.
comptime PROBLEM_GENERIC: Int = 1
comptime PROBLEM_TAB_INDENT: Int = 2
comptime PROBLEM_FLOW_TAB_INDENT: Int = 3
comptime PROBLEM_MAP_VALUE: Int = 4
comptime PROBLEM_MAP_KEY: Int = 5
comptime PROBLEM_BLOCK_ENTRY: Int = 6
comptime PROBLEM_UNEXPECTED_COLON: Int = 7
comptime PROBLEM_EXPECTED_KEY: Int = 8
comptime PROBLEM_EXPECTED_COLON: Int = 9
comptime PROBLEM_EXPECTED_BLOCK_END: Int = 10
comptime PROBLEM_UNEXPECTED_DOC_INDICATOR: Int = 11
comptime PROBLEM_UNEXPECTED_STREAM_END: Int = 12
comptime PROBLEM_EXPECTED_COMMENT_OR_BREAK: Int = 13
comptime PROBLEM_UNEXPECTED_CHAR: Int = 14
comptime PROBLEM_ZERO_INDENT: Int = 15
comptime PROBLEM_EXPECTED_DIRECTIVE_NAME: Int = 16
comptime PROBLEM_BAD_DIRECTIVE_CHAR: Int = 17
comptime PROBLEM_UNKNOWN_DIRECTIVE: Int = 18
comptime PROBLEM_EXPECTED_VERSION_NUMBER: Int = 19
comptime PROBLEM_EXPECTED_DIGIT_OR_DOT: Int = 20
comptime PROBLEM_VERSION_TOO_LONG: Int = 21
comptime PROBLEM_EXPECTED_WHITESPACE: Int = 22
comptime PROBLEM_EXPECTED_TAG_URI: Int = 23
comptime PROBLEM_EXPECTED_BANG: Int = 24
comptime PROBLEM_EXPECTED_GT: Int = 25
comptime PROBLEM_BAD_URI_ESCAPE: Int = 26
comptime PROBLEM_BAD_LEADING_UTF8: Int = 27
comptime PROBLEM_BAD_TRAILING_UTF8: Int = 28
comptime PROBLEM_TAG_WHITESPACE: Int = 29
comptime PROBLEM_ANCHOR_CHAR: Int = 30
comptime PROBLEM_UNKNOWN_ESCAPE: Int = 31
comptime PROBLEM_EXPECTED_HEX: Int = 32
comptime PROBLEM_BAD_UNICODE_ESCAPE: Int = 33
comptime PROBLEM_TRAILING_TAB: Int = 34
comptime PROBLEM_MAX_NESTING: Int = 35


@extern("malloc")
def yaml_malloc(num: Int, size: Int) abi("c") -> Int:
    ...


@extern("free")
def yaml_free(addr: Int) abi("c"):
    ...


def u8p(addr: Int) -> U8Ptr:
    return U8Ptr(unsafe_from_address=addr)


# The document bytes as a Pointer.  A struct field may not hold one (it would
# expose AnyOrigin), so the raw address is stored and rebuilt on each use.
def src_of(parser: Parser) -> U8Ptr:
    return U8Ptr(unsafe_from_address=parser.src_addr)


# yaml.h: yaml_mark_t
struct Mark(Copyable):
    var index: Int
    var line: Int
    var column: Int

    def __init__(out self, index: Int, line: Int, column: Int):
        self.index = index
        self.line = line
        self.column = column


# yaml.h: yaml_simple_key_t, flattened.
struct SimpleKey(Copyable):
    var possible: Bool
    var required: Bool
    var token_number: Int
    var mark_index: Int
    var mark_line: Int
    var mark_column: Int

    def __init__(
        out self,
        possible: Bool,
        required: Bool,
        token_number: Int,
        mark_index: Int,
        mark_line: Int,
        mark_column: Int,
    ):
        self.possible = possible
        self.required = required
        self.token_number = token_number
        self.mark_index = mark_index
        self.mark_line = mark_line
        self.mark_column = mark_column


# yaml.h: yaml_token_t with the payload strings replaced by arena spans, so the
# whole record stays copyable and can be handed to helpers by value.
struct Token(Copyable):
    var type: Int
    var start_index: Int
    var start_line: Int
    var start_column: Int
    var end_index: Int
    var end_line: Int
    var end_column: Int
    var value_start: Int
    var value_end: Int
    var aux_start: Int
    var aux_end: Int
    var style: Int
    var major: Int
    var minor: Int

    def __init__(out self, type: Int, start_mark: Mark, end_mark: Mark):
        self.type = type
        self.start_index = start_mark.index
        self.start_line = start_mark.line
        self.start_column = start_mark.column
        self.end_index = end_mark.index
        self.end_line = end_mark.line
        self.end_column = end_mark.column
        self.value_start = 0
        self.value_end = 0
        self.aux_start = 0
        self.aux_end = 0
        self.style = ANY_SCALAR_STYLE
        self.major = 0
        self.minor = 0


struct Parser(Copyable):
    # Reader.  The raw address is stored rather than a Pointer because a struct
    # field may not expose AnyOrigin.
    var src_addr: Int
    var length: Int
    var pointer: Int
    var unread: Int
    var end: Int
    var mark: Mark
    var encoding: Int

    # Arena backing every token payload span.
    var arena: List[UInt8]
    # Scratch for the scalar scanners' temporary strings (upstream keeps these
    # as separate yaml_string_t values; one arena cannot hold two live buffers,
    # so they are staged here and joined into `arena` at the join point).
    var scratch: List[UInt8]

    # Scanner state.
    var indent: Int
    var indents: List[Int]
    var simple_key_allowed: Bool
    var simple_keys: List[SimpleKey]
    var flow_level: Int
    var tokens: List[Token]
    # The token most recently dequeued by scan(), so callers can read it back
    # after it leaves the queue.
    var last_token: Token
    var tokens_parsed: Int
    var token_available: Bool
    var stream_start_produced: Bool
    var stream_end_produced: Bool
    var error: Int
    var problem: Int
    var problem_line: Int
    var problem_column: Int

    def __init__(out self, src_addr: Int, length: Int, end: Int):
        self.src_addr = src_addr
        self.length = length
        self.end = end
        self.pointer = 0
        self.unread = end
        self.mark = Mark(0, 0, 0)
        self.encoding = 1
        self.arena = List[UInt8]()
        self.scratch = List[UInt8]()
        self.indent = -1
        self.indents = List[Int]()
        self.simple_key_allowed = True
        self.simple_keys = List[SimpleKey]()
        self.flow_level = 0
        self.tokens = List[Token]()
        self.last_token = Token(STREAM_START_TOKEN, Mark(0, 0, 0), Mark(0, 0, 0))
        self.tokens_parsed = 0
        self.token_available = False
        self.stream_start_produced = False
        self.stream_end_produced = False
        self.error = NO_ERROR
        self.problem = 0
        self.problem_line = 0
        self.problem_column = 0


def emit_byte(mut arena: List[UInt8], value: UInt8) -> Int:
    arena.append(value)
    return arena.__len__()


def emit_bytes(
    mut arena: List[UInt8], src: U8Ptr, src_start: Int, src_end: Int
) -> Int:
    for i in range(src_start, src_end):
        arena.append(src.unsafe_load(i))
    return arena.__len__()


def join_span(mut arena: List[UInt8], src_start: Int, src_end: Int) -> Int:
    for i in range(src_start, src_end):
        arena.append(arena[i])
    return arena.__len__()


def span_is_empty(start: Int, end: Int) -> Bool:
    return start == end


def span_first(arena: List[UInt8], start: Int, end: Int) -> UInt8:
    if start < end:
        return arena[start]
    return UInt8(0x00)


# ---------------------------------------------------------------------------
# Character classification (yaml_private.h macros), one def per macro.
# All take the parser pointer because `parser->buffer` in C.
# ---------------------------------------------------------------------------

def check_at(parser: Parser, octet: Int, offset: Int) -> Bool:
    return Int(src_of(parser).unsafe_load(parser.pointer + offset)) == octet


def is_alpha_at(parser: Parser, offset: Int) -> Bool:
    var c = Int(src_of(parser).unsafe_load(parser.pointer + offset))
    return (
        (c >= 0x30 and c <= 0x39)
        or (c >= 0x41 and c <= 0x5A)
        or (c >= 0x61 and c <= 0x7A)
        or c == 0x5F
        or c == 0x2D
    )


def is_digit_at(parser: Parser, offset: Int) -> Bool:
    var c = Int(src_of(parser).unsafe_load(parser.pointer + offset))
    return c >= 0x30 and c <= 0x39


def as_digit_at(parser: Parser, offset: Int) -> Int:
    return Int(src_of(parser).unsafe_load(parser.pointer + offset)) - 0x30


def is_hex_at(parser: Parser, offset: Int) -> Bool:
    var c = Int(src_of(parser).unsafe_load(parser.pointer + offset))
    return (
        (c >= 0x30 and c <= 0x39)
        or (c >= 0x41 and c <= 0x46)
        or (c >= 0x61 and c <= 0x66)
    )


def as_hex_at(parser: Parser, offset: Int) -> Int:
    var c = Int(src_of(parser).unsafe_load(parser.pointer + offset))
    if c >= 0x41 and c <= 0x46:
        return c - 0x41 + 10
    if c >= 0x61 and c <= 0x66:
        return c - 0x61 + 10
    return c - 0x30


def is_z_at(parser: Parser, offset: Int) -> Bool:
    return check_at(parser, 0x00, offset)


def is_bom_at(parser: Parser, offset: Int) -> Bool:
    return (
        check_at(parser, 0xEF, offset)
        and check_at(parser, 0xBB, offset + 1)
        and check_at(parser, 0xBF, offset + 2)
    )


def is_space_at(parser: Parser, offset: Int) -> Bool:
    return check_at(parser, 0x20, offset)


def is_tab_at(parser: Parser, offset: Int) -> Bool:
    return check_at(parser, 0x09, offset)


def is_blank_at(parser: Parser, offset: Int) -> Bool:
    return is_space_at(parser, offset) or is_tab_at(parser, offset)


def is_break_at(parser: Parser, offset: Int) -> Bool:
    # CR (#xD), LF (#xA), NEL (#x85), LS (#x2028), PS (#x2029) as UTF-8.
    return (
        check_at(parser, 0x0D, offset)
        or check_at(parser, 0x0A, offset)
        or (check_at(parser, 0xC2, offset) and check_at(parser, 0x85, offset + 1))
        or (
            check_at(parser, 0xE2, offset)
            and check_at(parser, 0x80, offset + 1)
            and check_at(parser, 0xA8, offset + 2)
        )
        or (
            check_at(parser, 0xE2, offset)
            and check_at(parser, 0x80, offset + 1)
            and check_at(parser, 0xA9, offset + 2)
        )
    )


def is_crlf_at(parser: Parser, offset: Int) -> Bool:
    return check_at(parser, 0x0D, offset) and check_at(parser, 0x0A, offset + 1)


def is_breakz_at(parser: Parser, offset: Int) -> Bool:
    return is_break_at(parser, offset) or is_z_at(parser, offset)


def is_blankz_at(parser: Parser, offset: Int) -> Bool:
    return is_blank_at(parser, offset) or is_breakz_at(parser, offset)


def width_at(parser: Parser, offset: Int) -> Int:
    var c = Int(src_of(parser).unsafe_load(parser.pointer + offset))
    if (c & 0x80) == 0x00:
        return 1
    if (c & 0xE0) == 0xC0:
        return 2
    if (c & 0xF0) == 0xE0:
        return 3
    if (c & 0xF8) == 0xF0:
        return 4
    return 0


# ---------------------------------------------------------------------------
# Error reporting (yaml_parser_set_scanner_error)
# ---------------------------------------------------------------------------

def set_scanner_error(
    mut parser: Parser, problem: Int, line: Int, column: Int
) -> Bool:
    parser.error = SCANNER_ERROR
    parser.problem = problem
    parser.problem_line = line
    parser.problem_column = column
    return False


def failed_token(
    mut parser: Parser, problem: Int, mark: Mark
) -> Token:
    _ = set_scanner_error(parser, problem, mark.line, mark.column)
    return Token(NO_TOKEN, mark, mark)


# ---------------------------------------------------------------------------
# Buffer macros: CACHE / SKIP / SKIP_LINE / READ / READ_LINE
# ---------------------------------------------------------------------------

# The document is fully resident, so CACHE only has to keep the lookahead
# window inside the buffer; the reader guarantees a NUL at `end`, which is
# where decoding stops, matching yaml_parser_update_buffer at EOF.
def cache(mut parser: Parser, length: Int) -> Bool:
    # The whole document is already resident, so CACHE never refills and never
    # fails; upstream only returns 0 here on a reader or memory error.  `unread`
    # is kept current because the buffer macros decrement it.
    var available = parser.end - parser.pointer
    if available < 0:
        available = 0
    parser.unread = available
    return True


def skip(mut parser: Parser):
    parser.mark.index += 1
    parser.mark.column += 1
    parser.unread -= 1
    parser.pointer += width_at(parser, 0)


def skip_line(mut parser: Parser):
    if is_crlf_at(parser, 0):
        parser.mark.index += 2
        parser.mark.column = 0
        parser.mark.line += 1
        parser.unread -= 2
        parser.pointer += 2
    elif is_break_at(parser, 0):
        parser.mark.index += 1
        parser.mark.column = 0
        parser.mark.line += 1
        parser.unread -= 1
        parser.pointer += width_at(parser, 0)


# Destination selector for the buffer macros: 0 is the value arena, 1 is the
# scratch buffer the scalar scanners stage whitespaces and breaks in.  Upstream
# passes a different `string` at each call site; one shared arena cannot hold
# two live buffers, so the destination is named here instead.
comptime DEST_VALUE: Int = 0
comptime DEST_SCRATCH: Int = 1


def read(mut parser: Parser, dest: Int) -> Int:
    # READ(parser, string): copy one character and advance the mark.
    var w = width_at(parser, 0)
    if w == 0:
        return -1
    var at = parser.arena.__len__() if dest == DEST_VALUE else parser.scratch.__len__()
    if dest == DEST_VALUE:
        _ = emit_bytes(parser.arena, src_of(parser), parser.pointer, parser.pointer + w)
    else:
        _ = emit_bytes(parser.scratch, src_of(parser), parser.pointer, parser.pointer + w)
    parser.mark.index += 1
    parser.mark.column += 1
    parser.unread -= 1
    parser.pointer += w
    return at


def read_line(mut parser: Parser, dest: Int) -> Int:
    # READ_LINE: CR LF -> LF, CR|LF -> LF, NEL -> LF, LS|PS copied through,
    # into the buffer named by `dest`.
    var start = (
        parser.arena.__len__() if dest == DEST_VALUE else parser.scratch.__len__()
    )
    if check_at(parser, 0x0D, 0) and check_at(parser, 0x0A, 1):
        put(parser, dest, UInt8(0x0A))
        parser.pointer += 2
        parser.mark.index += 2
        parser.mark.column = 0
        parser.mark.line += 1
        parser.unread -= 2
    elif check_at(parser, 0x0D, 0) or check_at(parser, 0x0A, 0):
        put(parser, dest, UInt8(0x0A))
        parser.pointer += 1
        parser.mark.index += 1
        parser.mark.column = 0
        parser.mark.line += 1
        parser.unread -= 1
    elif check_at(parser, 0xC2, 0) and check_at(parser, 0x85, 1):
        put(parser, dest, UInt8(0x0A))
        parser.pointer += 2
        parser.mark.index += 1
        parser.mark.column = 0
        parser.mark.line += 1
        parser.unread -= 1
    elif (
        check_at(parser, 0xE2, 0)
        and check_at(parser, 0x80, 1)
        and (check_at(parser, 0xA8, 2) or check_at(parser, 0xA9, 2))
    ):
        put(parser, dest, src_of(parser).unsafe_load(parser.pointer))
        put(parser, dest, src_of(parser).unsafe_load(parser.pointer + 1))
        put(parser, dest, src_of(parser).unsafe_load(parser.pointer + 2))
        parser.pointer += 3
        parser.mark.index += 1
        parser.mark.column = 0
        parser.mark.line += 1
        parser.unread -= 1
    return start


def read_into(mut parser: Parser, mut dest: List[UInt8]) -> Int:
    # READ(parser, string): copy one character into `dest` and advance the mark.
    var w = width_at(parser, 0)
    if w == 0:
        return -1
    _ = emit_bytes(dest, src_of(parser), parser.pointer, parser.pointer + w)
    parser.mark.index += 1
    parser.mark.column += 1
    parser.unread -= 1
    parser.pointer += w
    return dest.__len__()


def read_line_into(mut parser: Parser, mut dest: List[UInt8]) -> Int:
    # READ_LINE(parser, string) with the CR LF / NEL / LS, PS normalisation,
    # writing into `dest`.
    var start = dest.__len__()
    if check_at(parser, 0x0D, 0) and check_at(parser, 0x0A, 1):
        dest.append(UInt8(0x0A))
        parser.pointer += 2
        parser.mark.index += 2
        parser.mark.column = 0
        parser.mark.line += 1
        parser.unread -= 2
    elif check_at(parser, 0x0D, 0) or check_at(parser, 0x0A, 0):
        dest.append(UInt8(0x0A))
        parser.pointer += 1
        parser.mark.index += 1
        parser.mark.column = 0
        parser.mark.line += 1
        parser.unread -= 1
    elif check_at(parser, 0xC2, 0) and check_at(parser, 0x85, 1):
        dest.append(UInt8(0x0A))
        parser.pointer += 2
        parser.mark.index += 1
        parser.mark.column = 0
        parser.mark.line += 1
        parser.unread -= 1
    elif (
        check_at(parser, 0xE2, 0)
        and check_at(parser, 0x80, 1)
        and (check_at(parser, 0xA8, 2) or check_at(parser, 0xA9, 2))
    ):
        dest.append(src_of(parser).unsafe_load(parser.pointer))
        dest.append(src_of(parser).unsafe_load(parser.pointer + 1))
        dest.append(src_of(parser).unsafe_load(parser.pointer + 2))
        parser.pointer += 3
        parser.mark.index += 1
        parser.mark.column = 0
        parser.mark.line += 1
        parser.unread -= 1
    return start


def put(mut parser: Parser, dest: Int, value: UInt8) -> None:
    # Append to the buffer named by `dest`.
    if dest == DEST_VALUE:
        _ = emit_byte(parser.arena, value)
    else:
        _ = emit_byte(parser.scratch, value)


# ---------------------------------------------------------------------------
# Simple keys and indentation
# ---------------------------------------------------------------------------


def stale_simple_keys(mut parser: Parser) -> Bool:
    for i in range(parser.simple_keys.__len__()):
        # A simple key is limited to a single line and to 1024 characters.
        if parser.simple_keys[i].possible and (
            parser.simple_keys[i].mark_line < parser.mark.line
            or parser.simple_keys[i].mark_index + 1024 < parser.mark.index
        ):
            if parser.simple_keys[i].required:
                return set_scanner_error(
                    parser,
                    PROBLEM_EXPECTED_COLON,
                    parser.simple_keys[i].mark_line,
                    parser.simple_keys[i].mark_column,
                )
            parser.simple_keys[i].possible = False
    return True


def remove_simple_key(mut parser: Parser) -> Bool:
    var last = parser.simple_keys.__len__() - 1
    if last < 0:
        return True
    if parser.simple_keys[last].possible:
        if parser.simple_keys[last].required:
            return set_scanner_error(
                parser,
                PROBLEM_EXPECTED_COLON,
                parser.simple_keys[last].mark_line,
                parser.simple_keys[last].mark_column,
            )
    parser.simple_keys[last].possible = False
    return True


def save_simple_key(mut parser: Parser) -> Bool:
    var required = (
        parser.flow_level == 0 and parser.indent == parser.mark.column
    )
    if parser.simple_key_allowed:
        var last = parser.simple_keys.__len__() - 1
        if last >= 0:
            if not remove_simple_key(parser):
                return False
        var simple_key = SimpleKey(
            True,
            required,
            parser.tokens_parsed + parser.tokens.__len__(),
            parser.mark.index,
            parser.mark.line,
            parser.mark.column,
        )
        last = parser.simple_keys.__len__() - 1
        if last >= 0:
            parser.simple_keys[last] = simple_key^
    return True


def increase_flow_level(mut parser: Parser) -> Bool:
    # Reset the simple key on the next level.
    parser.simple_keys.append(SimpleKey(False, False, 0, 0, 0, 0))
    if parser.flow_level == MAX_NESTING_LEVEL:
        return set_scanner_error(
            parser, PROBLEM_MAX_NESTING, parser.mark.line, parser.mark.column
        )
    if parser.indents.__len__() > MAX_NESTING_LEVEL - parser.flow_level:
        return set_scanner_error(
            parser, PROBLEM_MAX_NESTING, parser.mark.line, parser.mark.column
        )
    parser.flow_level += 1
    return True


def decrease_flow_level(mut parser: Parser) -> Bool:
    if parser.flow_level > 0:
        parser.flow_level -= 1
        _ = parser.simple_keys.pop()
    return True


def enqueue(mut parser: Parser, mut token: Token):
    parser.tokens.append(token^)
    # The parameter is transferred out, so give it a valid value for the
    # implicit return.
    token = Token(NO_TOKEN, Mark(0, 0, 0), Mark(0, 0, 0))


def roll_indent(
    mut parser: Parser,
    column: Int,
    number: Int,
    type: Int,
    mark: Mark,
) -> Bool:
    # In the flow context, do nothing.
    if parser.flow_level > 0:
        return True
    if parser.indent < column:
        parser.indents.append(parser.indent)
        if parser.indents.__len__() > MAX_NESTING_LEVEL - parser.flow_level:
            return set_scanner_error(
                parser, PROBLEM_MAX_NESTING, parser.mark.line, parser.mark.column
            )
        parser.indent = column
        var token = Token(type, mark, mark)
        if number == -1:
            enqueue(parser, token)
        else:
            # QUEUE_INSERT at the position the pending simple key reserves.
            parser.tokens.insert(number - parser.tokens_parsed, token^)
    return True


def unroll_indent(mut parser: Parser, column: Int) -> Bool:
    # In the flow context, do nothing.
    if parser.flow_level > 0:
        return True
    while parser.indent > column:
        var mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
        var tmp_tok = Token(BLOCK_END_TOKEN, mark, mark)
        enqueue(parser, tmp_tok)
        parser.indent = parser.indents.pop()
    return True


# ---------------------------------------------------------------------------
# Token producers
# ---------------------------------------------------------------------------


def fetch_stream_start(mut parser: Parser) -> Bool:
    var mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    parser.indent = -1
    parser.simple_keys.append(SimpleKey(False, False, 0, 0, 0, 0))
    parser.simple_key_allowed = True
    parser.stream_start_produced = True
    var tmp_tok = Token(STREAM_START_TOKEN, mark, mark)
    enqueue(parser, tmp_tok)
    return True


def fetch_stream_end(mut parser: Parser) -> Bool:
    # Force new line.
    if parser.mark.column != 0:
        parser.mark.column = 0
        parser.mark.line += 1
    if not unroll_indent(parser, -1):
        return False
    if not remove_simple_key(parser):
        return False
    parser.simple_key_allowed = False
    var mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var tmp_tok = Token(STREAM_END_TOKEN, mark, mark)
    enqueue(parser, tmp_tok)
    return True


def fetch_document_indicator(
    mut parser: Parser, type: Int
) -> Bool:
    if not unroll_indent(parser, -1):
        return False
    if not remove_simple_key(parser):
        return False
    parser.simple_key_allowed = False
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    skip(parser)
    skip(parser)
    skip(parser)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var tmp_tok = Token(type, start_mark, end_mark)
    enqueue(parser, tmp_tok)
    return True


def fetch_flow_collection_start(
    mut parser: Parser, type: Int
) -> Bool:
    # The indicators '[' and '{' may start a simple key.
    if not save_simple_key(parser):
        return False
    if not increase_flow_level(parser):
        return False
    parser.simple_key_allowed = True
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    skip(parser)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var tmp_tok = Token(type, start_mark, end_mark)
    enqueue(parser, tmp_tok)
    return True


def fetch_flow_collection_end(
    mut parser: Parser, type: Int
) -> Bool:
    if not remove_simple_key(parser):
        return False
    if not decrease_flow_level(parser):
        return False
    parser.simple_key_allowed = False
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    skip(parser)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var tmp_tok = Token(type, start_mark, end_mark)
    enqueue(parser, tmp_tok)
    return True


def fetch_flow_entry(mut parser: Parser) -> Bool:
    if not remove_simple_key(parser):
        return False
    parser.simple_key_allowed = True
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    skip(parser)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var tmp_tok = Token(FLOW_ENTRY_TOKEN, start_mark, end_mark)
    enqueue(parser, tmp_tok)
    return True


def fetch_block_entry(mut parser: Parser) -> Bool:
    if parser.flow_level == 0:
        if not parser.simple_key_allowed:
            return set_scanner_error(
                parser, PROBLEM_BLOCK_ENTRY, parser.mark.line, parser.mark.column
            )
        var mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
        if not roll_indent(
            parser, parser.mark.column, -1, BLOCK_SEQUENCE_START_TOKEN, mark
        ):
            return False
    # It is an error for '-' in the flow context, but the Parser reports it
    # because the Parser can point at the context.
    if not remove_simple_key(parser):
        return False
    parser.simple_key_allowed = True
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    skip(parser)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var tmp_tok = Token(BLOCK_ENTRY_TOKEN, start_mark, end_mark)
    enqueue(parser, tmp_tok)
    return True


def fetch_key(mut parser: Parser) -> Bool:
    if parser.flow_level == 0:
        if not parser.simple_key_allowed:
            return set_scanner_error(
                parser, PROBLEM_MAP_KEY, parser.mark.line, parser.mark.column
            )
        var mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
        if not roll_indent(
            parser, parser.mark.column, -1, BLOCK_MAPPING_START_TOKEN, mark
        ):
            return False
    if not remove_simple_key(parser):
        return False
    # Simple keys are allowed after '?' in the block context.
    parser.simple_key_allowed = parser.flow_level == 0
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    skip(parser)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var tmp_tok = Token(KEY_TOKEN, start_mark, end_mark)
    enqueue(parser, tmp_tok)
    return True


def fetch_value(mut parser: Parser) -> Bool:
    var last = parser.simple_keys.__len__() - 1
    if last < 0:
        return set_scanner_error(
            parser, PROBLEM_MAP_VALUE, parser.mark.line, parser.mark.column
        )
    if parser.simple_keys[last].possible:
        var key_mark = Mark(
            parser.simple_keys[last].mark_index,
            parser.simple_keys[last].mark_line,
            parser.simple_keys[last].mark_column,
        )
        var key_number = parser.simple_keys[last].token_number
        parser.tokens.insert(
            key_number - parser.tokens_parsed, Token(KEY_TOKEN, key_mark, key_mark)
        )
        # In the block context, we may need a BLOCK-MAPPING-START token.
        if not roll_indent(
            parser, key_mark.column, key_number, BLOCK_MAPPING_START_TOKEN, key_mark
        ):
            return False
        parser.simple_keys[last].possible = False
        # A simple key cannot follow another simple key.
        parser.simple_key_allowed = False
    else:
        # The ':' indicator follows a complex key.
        if parser.flow_level == 0:
            if not parser.simple_key_allowed:
                return set_scanner_error(
                    parser, PROBLEM_MAP_VALUE, parser.mark.line, parser.mark.column
                )
            var mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
            if not roll_indent(
                parser, parser.mark.column, -1, BLOCK_MAPPING_START_TOKEN, mark
            ):
                return False
        # Simple keys after ':' are allowed in the block context.
        parser.simple_key_allowed = parser.flow_level == 0
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    skip(parser)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var tmp_tok = Token(VALUE_TOKEN, start_mark, end_mark)
    enqueue(parser, tmp_tok)
    return True


def fetch_anchor(mut parser: Parser, type: Int) -> Bool:
    # An anchor or an alias could be a simple key.
    if not save_simple_key(parser):
        return False
    parser.simple_key_allowed = False
    var token = scan_anchor(parser, type)
    if token.type == NO_TOKEN:
        return False
    enqueue(parser, token)
    return True


def fetch_tag(mut parser: Parser) -> Bool:
    # A tag could be a simple key.
    if not save_simple_key(parser):
        return False
    parser.simple_key_allowed = False
    var token = scan_tag(parser)
    if token.type == NO_TOKEN:
        return False
    enqueue(parser, token)
    return True


def fetch_block_scalar(
    mut parser: Parser, literal: Int
) -> Bool:
    if not remove_simple_key(parser):
        return False
    # A simple key may follow a block scalar.
    parser.simple_key_allowed = True
    var token = scan_block_scalar(parser, literal)
    if token.type == NO_TOKEN:
        return False
    enqueue(parser, token)
    return True


def fetch_flow_scalar(
    mut parser: Parser, single: Int
) -> Bool:
    # A quoted scalar could be a simple key.
    if not save_simple_key(parser):
        return False
    parser.simple_key_allowed = False
    var token = scan_flow_scalar(parser, single)
    if token.type == NO_TOKEN:
        return False
    enqueue(parser, token)
    return True


def fetch_plain_scalar(mut parser: Parser) -> Bool:
    # A plain scalar could be a simple key.
    if not save_simple_key(parser):
        return False
    parser.simple_key_allowed = False
    var token = scan_plain_scalar(parser)
    if token.type == NO_TOKEN:
        return False
    enqueue(parser, token)
    return True


def fetch_directive(mut parser: Parser) -> Bool:
    # Reset the indentation level and simple keys.
    if not unroll_indent(parser, -1):
        return False
    if not remove_simple_key(parser):
        return False
    parser.simple_key_allowed = False
    var token = scan_directive(parser)
    if token.type == NO_TOKEN:
        return False
    enqueue(parser, token)
    return True

# ---------------------------------------------------------------------------
# Token scanners
# ---------------------------------------------------------------------------

# yaml_parser_scan_to_next_token
def scan_to_next_token(mut parser: Parser) -> Bool:
    # Until the next token is found.
    while True:
        # Allow the BOM mark to start a line.
        if not cache(parser, 1):
            return False
        if parser.mark.column == 0 and is_bom_at(parser, 0):
            skip(parser)

        # Eat whitespaces.  Tabs are allowed in the flow context and in the
        # block context but not at the beginning of the line or after '-', '?'
        # or ':' (complex value).
        if not cache(parser, 1):
            return False
        while check_at(parser, 0x20, 0) or (
            (parser.flow_level > 0 or not parser.simple_key_allowed)
            and check_at(parser, 0x09, 0)
        ):
            skip(parser)
            if not cache(parser, 1):
                return False

        # Eat a comment until a line break.
        if check_at(parser, 0x23, 0):
            while not is_breakz_at(parser, 0):
                skip(parser)
                if not cache(parser, 1):
                    return False

        # If it is a line break, eat it.
        if is_break_at(parser, 0):
            if not cache(parser, 2):
                return False
            skip_line(parser)
            # In the block context, a new line may start a simple key.
            if parser.flow_level == 0:
                parser.simple_key_allowed = True
        else:
            # We have found a token.
            break
    return True


def scan_directive_name(mut parser: Parser, mut name: List[UInt8], start_mark: Mark) -> Bool:
    if not cache(parser, 1):
        return set_failed(parser, PROBLEM_EXPECTED_DIRECTIVE_NAME, start_mark)
    # Consume the directive name.
    while is_alpha_at(parser, 0):
        if read_into(parser, name) < 0:
            return set_failed(parser, PROBLEM_GENERIC, start_mark)
        if not cache(parser, 1):
            return set_failed(parser, PROBLEM_GENERIC, start_mark)
    # Check if the name is empty.
    if name.__len__() == 0:
        return set_failed(parser, PROBLEM_EXPECTED_DIRECTIVE_NAME, start_mark)
    # Check for a blank character after the name.
    if not is_blankz_at(parser, 0):
        return set_failed(parser, PROBLEM_BAD_DIRECTIVE_CHAR, start_mark)
    return True


def set_failed(mut parser: Parser, problem: Int, mark: Mark) -> Bool:
    _ = set_scanner_error(parser, problem, mark.line, mark.column)
    return False


# yaml_parser_scan_version_directive_number
def scan_version_directive_number(
    mut parser: Parser, start_mark: Mark, mut number: Int
) -> Bool:
    var value = 0
    var length = 0
    if not cache(parser, 1):
        return set_failed(parser, PROBLEM_EXPECTED_VERSION_NUMBER, start_mark)
    # Repeat while the next character is a digit.
    while is_digit_at(parser, 0):
        # Check if the number is too long.
        length += 1
        if length > MAX_NUMBER_LENGTH:
            return set_failed(parser, PROBLEM_VERSION_TOO_LONG, start_mark)
        value = value * 10 + as_digit_at(parser, 0)
        skip(parser)
        if not cache(parser, 1):
            return set_failed(parser, PROBLEM_EXPECTED_VERSION_NUMBER, start_mark)
    # Check if the number was present.
    if length == 0:
        return set_failed(parser, PROBLEM_EXPECTED_VERSION_NUMBER, start_mark)
    number = value
    return True


# yaml_parser_scan_version_directive_value
def scan_version_directive_value(
    mut parser: Parser, start_mark: Mark, mut major: Int, mut minor: Int
) -> Bool:
    # Eat whitespaces.
    if not cache(parser, 1):
        return set_failed(parser, PROBLEM_EXPECTED_DIGIT_OR_DOT, start_mark)
    while is_blank_at(parser, 0):
        skip(parser)
        if not cache(parser, 1):
            return set_failed(parser, PROBLEM_EXPECTED_DIGIT_OR_DOT, start_mark)
    # Consume the major version number.
    if not scan_version_directive_number(parser, start_mark, major):
        return False
    # Eat '.'.
    if not check_at(parser, 0x2E, 0):
        return set_failed(parser, PROBLEM_EXPECTED_DIGIT_OR_DOT, start_mark)
    skip(parser)
    # Consume the minor version number.
    if not scan_version_directive_number(parser, start_mark, minor):
        return False
    return True


# yaml_parser_scan_tag_handle
def scan_tag_handle(
    mut parser: Parser, directive: Int, start_mark: Mark, mut handle: List[UInt8]
) -> Bool:
    if not cache(parser, 1):
        return set_failed(parser, PROBLEM_EXPECTED_BANG, start_mark)
    # Check the initial '!' character.
    if not check_at(parser, 0x21, 0):
        return set_failed(parser, PROBLEM_EXPECTED_BANG, start_mark)
    # Copy the '!' character.
    if read_into(parser, handle) < 0:
        return set_failed(parser, PROBLEM_GENERIC, start_mark)
    # Copy all subsequent alphabetical and numerical characters.
    if not cache(parser, 1):
        return set_failed(parser, PROBLEM_GENERIC, start_mark)
    while is_alpha_at(parser, 0):
        if read_into(parser, handle) < 0:
            return set_failed(parser, PROBLEM_GENERIC, start_mark)
        if not cache(parser, 1):
            return set_failed(parser, PROBLEM_GENERIC, start_mark)
    # Check if the trailing character is '!' and copy it.
    if check_at(parser, 0x21, 0):
        if read_into(parser, handle) < 0:
            return set_failed(parser, PROBLEM_GENERIC, start_mark)
    else:
        # It's either the '!' tag or not really a tag handle.  If it's a %TAG
        # directive, it's an error.
        if directive != 0 and not (
            handle.__len__() == 1 and handle[0] == UInt8(0x21)
        ):
            return set_failed(parser, PROBLEM_EXPECTED_BANG, start_mark)
    return True


# yaml_parser_scan_uri_escapes: decode one escaped UTF-8 character into `dest`.
def scan_uri_escapes(
    mut parser: Parser,
    directive: Int,
    start_mark: Mark,
    mut dest: List[UInt8],
) -> Bool:
    var width = 0
    while True:
        # Check for a URI-escaped octet.
        if not cache(parser, 3):
            return False
        if not (
            check_at(parser, 0x25, 0)
            and is_hex_at(parser, 1)
            and is_hex_at(parser, 2)
        ):
            return set_failed(parser, PROBLEM_BAD_URI_ESCAPE, start_mark)
        var octet = (as_hex_at(parser, 1) << 4) + as_hex_at(parser, 2)
        # If it is the leading octet, determine the UTF-8 sequence length.
        if width == 0:
            if (octet & 0x80) == 0x00:
                width = 1
            elif (octet & 0xE0) == 0xC0:
                width = 2
            elif (octet & 0xF0) == 0xE0:
                width = 3
            elif (octet & 0xF8) == 0xF0:
                width = 4
            else:
                return set_failed(parser, PROBLEM_BAD_LEADING_UTF8, start_mark)
        else:
            # Check if the trailing octet is correct.
            if (octet & 0xC0) != 0x80:
                return set_failed(parser, PROBLEM_BAD_TRAILING_UTF8, start_mark)
        dest.append(UInt8(octet))
        skip(parser)
        skip(parser)
        skip(parser)
        width -= 1
        if width == 0:
            return True


# yaml_parser_scan_tag_uri
def scan_tag_uri(
    mut parser: Parser,
    uri_char: Int,
    directive: Int,
    head: List[UInt8],
    start_mark: Mark,
    mut uri: List[UInt8],
) -> Bool:
    var length = head.__len__()
    # Copy the head if needed.  We don't copy the leading '!' character.
    if length > 1:
        for i in range(1, length):
            uri.append(head[i])
    if not cache(parser, 1):
        return set_failed(parser, PROBLEM_EXPECTED_TAG_URI, start_mark)
    # '0'-'9', 'A'-'Z', 'a'-'z', '_', '-', ';', '/', '?', ':', '@', '&', '=',
    # '+', '$', '.', '!', '~', '*', '\'', '(', ')', '%' and, inside a verbatim
    # tag, the flow indicators.
    while (
        is_alpha_at(parser, 0)
        or check_at(parser, 0x3B, 0)
        or check_at(parser, 0x2F, 0)
        or check_at(parser, 0x3F, 0)
        or check_at(parser, 0x3A, 0)
        or check_at(parser, 0x40, 0)
        or check_at(parser, 0x26, 0)
        or check_at(parser, 0x3D, 0)
        or check_at(parser, 0x2B, 0)
        or check_at(parser, 0x24, 0)
        or check_at(parser, 0x2E, 0)
        or check_at(parser, 0x25, 0)
        or check_at(parser, 0x21, 0)
        or check_at(parser, 0x7E, 0)
        or check_at(parser, 0x2A, 0)
        or check_at(parser, 0x27, 0)
        or check_at(parser, 0x28, 0)
        or check_at(parser, 0x29, 0)
        or (
            uri_char != 0
            and (
                check_at(parser, 0x2C, 0)
                or check_at(parser, 0x5B, 0)
                or check_at(parser, 0x5D, 0)
            )
        )
    ):
        # Check if it is a URI-escape sequence.
        if check_at(parser, 0x25, 0):
            if not scan_uri_escapes(parser, directive, start_mark, uri):
                return False
        else:
            if read_into(parser, uri) < 0:
                return set_failed(parser, PROBLEM_GENERIC, start_mark)
        length += 1
        if not cache(parser, 1):
            return set_failed(parser, PROBLEM_EXPECTED_TAG_URI, start_mark)
    # Check if the tag is non-empty.
    if length == 0:
        return set_failed(parser, PROBLEM_EXPECTED_TAG_URI, start_mark)
    return True


# yaml_parser_scan_tag
def scan_tag(mut parser: Parser) -> Token:
    var handle = List[UInt8]()
    var suffix = List[UInt8]()
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    if not cache(parser, 2):
        return failed_token(parser, PROBLEM_GENERIC, start_mark)
    if check_at(parser, 0x3C, 1):
        # Canonical form: the handle is '' and we eat '!<'.
        skip(parser)
        skip(parser)
        # Consume the tag value.
        if not scan_tag_uri(parser, 1, 0, List[UInt8](), start_mark, suffix):
            return failed_token(parser, parser.problem, start_mark)
        # Check for '>' and eat it.
        if not check_at(parser, 0x3E, 0):
            return failed_token(parser, PROBLEM_EXPECTED_GT, start_mark)
        skip(parser)
    else:
        # The tag has either the '!suffix' or the '!handle!suffix' form.  First,
        # try to scan a handle.
        var scanned = List[UInt8]()
        if not scan_tag_handle(parser, 0, start_mark, scanned):
            return failed_token(parser, parser.problem, start_mark)
        # Check if it is, indeed, a handle.
        var is_handle = (
            scanned[0] == UInt8(0x21)
            and scanned.__len__() > 1
            and scanned[scanned.__len__() - 1] == UInt8(0x21)
        )
        if is_handle:
            # Scan the suffix now.
            if not scan_tag_uri(parser, 0, 0, List[UInt8](), start_mark, suffix):
                return failed_token(parser, parser.problem, start_mark)
            handle = scanned^
        else:
            # It wasn't a handle after all.  Scan the rest of the tag.
            if not scan_tag_uri(parser, 0, 0, scanned, start_mark, suffix):
                return failed_token(parser, parser.problem, start_mark)
            # Set the handle to '!'.
            handle = List[UInt8]()
            handle.append(UInt8(0x21))
            # A special case: the '!' tag sets the handle to '' and the suffix to
            # '!'.
            if suffix.__len__() == 0:
                var tmp = handle^
                handle = suffix^
                suffix = tmp^
    # Check the character which ends the tag.
    if not cache(parser, 1):
        return failed_token(parser, PROBLEM_TAG_WHITESPACE, start_mark)
    if not is_blankz_at(parser, 0):
        if parser.flow_level == 0 or not check_at(parser, 0x2C, 0):
            return failed_token(parser, PROBLEM_TAG_WHITESPACE, start_mark)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var token = Token(TAG_TOKEN, start_mark, end_mark)
    token.value_start = park_span(parser, handle)
    token.value_end = parser.arena.__len__()
    token.aux_start = park_span(parser, suffix)
    token.aux_end = parser.arena.__len__()
    return token^


# yaml_parser_scan_tag_directive_value
def scan_tag_directive_value(
    mut parser: Parser, start_mark: Mark, mut handle: List[UInt8], mut prefix: List[UInt8]
) -> Bool:
    # Eat whitespaces.
    if not cache(parser, 1):
        return set_failed(parser, PROBLEM_EXPECTED_WHITESPACE, start_mark)
    while is_blank_at(parser, 0):
        skip(parser)
        if not cache(parser, 1):
            return set_failed(parser, PROBLEM_EXPECTED_WHITESPACE, start_mark)
    # Scan a handle.
    if not scan_tag_handle(parser, 1, start_mark, handle):
        return False
    # Expect a whitespace.
    if not cache(parser, 1):
        return set_failed(parser, PROBLEM_EXPECTED_WHITESPACE, start_mark)
    if not is_blank_at(parser, 0):
        return set_failed(parser, PROBLEM_EXPECTED_WHITESPACE, start_mark)
    # Eat whitespaces.
    while is_blank_at(parser, 0):
        skip(parser)
        if not cache(parser, 1):
            return set_failed(parser, PROBLEM_EXPECTED_WHITESPACE, start_mark)
    # Scan a prefix.
    if not scan_tag_uri(parser, 1, 1, List[UInt8](), start_mark, prefix):
        return False
    # Expect a whitespace or line break.
    if not cache(parser, 1):
        return set_failed(parser, PROBLEM_EXPECTED_WHITESPACE, start_mark)
    if not is_blankz_at(parser, 0):
        return set_failed(parser, PROBLEM_EXPECTED_WHITESPACE, start_mark)
    return True


# yaml_parser_scan_directive
def scan_directive(mut parser: Parser) -> Token:
    var name = List[UInt8]()
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    # Eat '%'.
    skip(parser)
    # Scan the directive name.
    if not scan_directive_name(parser, name, start_mark):
        return failed_token(parser, parser.problem, start_mark)
    var is_yaml = name.__len__() == 4
    if is_yaml:
        if (
            name[0] != UInt8(0x59)
            or name[1] != UInt8(0x41)
            or name[2] != UInt8(0x4D)
            or name[3] != UInt8(0x4C)
        ):
            is_yaml = False
    var is_tag = name.__len__() == 3
    if is_tag:
        if (
            name[0] != UInt8(0x54)
            or name[1] != UInt8(0x41)
            or name[2] != UInt8(0x47)
        ):
            is_tag = False
    var token = Token(NO_TOKEN, start_mark, start_mark)
    if is_yaml:
        # Scan the VERSION directive value.
        var major = 0
        var minor = 0
        if not scan_version_directive_value(parser, start_mark, major, minor):
            return failed_token(parser, parser.problem, start_mark)
        token.type = VERSION_DIRECTIVE_TOKEN
        token.major = major
        token.minor = minor
    elif is_tag:
        # Scan the TAG directive value.
        var handle = List[UInt8]()
        var prefix = List[UInt8]()
        if not scan_tag_directive_value(parser, start_mark, handle, prefix):
            return failed_token(parser, parser.problem, start_mark)
        token.type = TAG_DIRECTIVE_TOKEN
        token.value_start = park_span(parser, handle)
        token.value_end = parser.arena.__len__()
        token.aux_start = park_span(parser, prefix)
        token.aux_end = parser.arena.__len__()
    else:
        return failed_token(parser, PROBLEM_UNKNOWN_DIRECTIVE, start_mark)
    # Eat the rest of the line including any comments.
    if not cache(parser, 1):
        return failed_token(parser, PROBLEM_EXPECTED_COMMENT_OR_BREAK, start_mark)
    while is_blank_at(parser, 0):
        skip(parser)
        if not cache(parser, 1):
            return failed_token(
                parser, PROBLEM_EXPECTED_COMMENT_OR_BREAK, start_mark
            )
    if check_at(parser, 0x23, 0):
        while not is_breakz_at(parser, 0):
            skip(parser)
            if not cache(parser, 1):
                return failed_token(
                    parser, PROBLEM_EXPECTED_COMMENT_OR_BREAK, start_mark
                )
    # Check if we are at the end of the line.
    if not is_breakz_at(parser, 0):
        return failed_token(parser, PROBLEM_EXPECTED_COMMENT_OR_BREAK, start_mark)
    # Eat a line break.
    if is_break_at(parser, 0):
        if not cache(parser, 2):
            return failed_token(
                parser, PROBLEM_EXPECTED_COMMENT_OR_BREAK, start_mark
            )
        skip_line(parser)
    token.end_line = parser.mark.line
    token.end_column = parser.mark.column
    token.end_index = parser.mark.index
    return token^


# yaml_parser_scan_anchor
def scan_anchor(mut parser: Parser, type: Int) -> Token:
    var value = List[UInt8]()
    var length = 0
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    # Eat the indicator character.
    skip(parser)
    if not cache(parser, 1):
        return failed_token(parser, PROBLEM_ANCHOR_CHAR, start_mark)
    # Consume the value.
    while is_alpha_at(parser, 0):
        if read_into(parser, value) < 0:
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        if not cache(parser, 1):
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        length += 1
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    # The anchor must be non-empty and followed by whitespace or one of the
    # indicators '?', ':', ',', ']', '}', '%', '@' and '`'.
    if length == 0 or not (
        is_blankz_at(parser, 0)
        or check_at(parser, 0x3F, 0)
        or check_at(parser, 0x3A, 0)
        or check_at(parser, 0x2C, 0)
        or check_at(parser, 0x5D, 0)
        or check_at(parser, 0x7D, 0)
        or check_at(parser, 0x25, 0)
        or check_at(parser, 0x40, 0)
        or check_at(parser, 0x60, 0)
    ):
        return failed_token(parser, PROBLEM_ANCHOR_CHAR, start_mark)
    var token = Token(type, start_mark, end_mark)
    park(parser, value, token)
    return token^


# yaml_parser_scan_block_scalar_breaks.  Returns the detected indent in
# `major` and the accumulated breaks in the value span.
def scan_block_scalar_breaks(
    mut parser: Parser,
    mut indent: Int,
    start_mark: Mark,
    mut breaks: List[UInt8],
) -> Int:
    # Returns the detected indent; `breaks` accumulates the line breaks.
    var max_indent = 0
    while True:
        # Eat the indentation spaces.
        if not cache(parser, 1):
            return -1
        while (indent == 0 or parser.mark.column < indent) and is_space_at(
            parser, 0
        ):
            skip(parser)
            if not cache(parser, 1):
                return -1
        if parser.mark.column > max_indent:
            max_indent = parser.mark.column
        # Check for a tab character messing the indentation.
        if (indent == 0 or parser.mark.column < indent) and is_tab_at(parser, 0):
            set_scanner_error(
                parser, PROBLEM_TAB_INDENT, start_mark.line, start_mark.column
            )
            return -1
        # Have we found a non-empty line?
        if not is_break_at(parser, 0):
            break
        # Consume the line break.
        if not cache(parser, 2):
            return -1
        read_line_into(parser, breaks)
    # Determine the indentation level if needed.
    if indent == 0:
        indent = max_indent
        if indent < parser.indent + 1:
            indent = parser.indent + 1
        if indent < 1:
            indent = 1
    return indent


# yaml_parser_scan_block_scalar
def scan_block_scalar(mut parser: Parser, literal: Int) -> Token:
    var string = List[UInt8]()
    var leading_break = List[UInt8]()
    var trailing_breaks = List[UInt8]()
    var chomping = 0
    var increment = 0
    var indent = 0
    var leading_blank = 0
    var trailing_blank = 0
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    # Eat the indicator '|' or '>'.
    skip(parser)
    # Scan the additional block scalar indicators.
    if not cache(parser, 1):
        return failed_token(parser, PROBLEM_GENERIC, start_mark)
    # Check for a chomping indicator.
    if check_at(parser, 0x2B, 0) or check_at(parser, 0x2D, 0):
        chomping = 1 if check_at(parser, 0x2B, 0) else -1
        skip(parser)
        if not cache(parser, 1):
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        if is_digit_at(parser, 0):
            if check_at(parser, 0x30, 0):
                return failed_token(parser, PROBLEM_ZERO_INDENT, start_mark)
            increment = as_digit_at(parser, 0)
            skip(parser)
    # Do the same as above, but in the opposite order.
    elif is_digit_at(parser, 0):
        if check_at(parser, 0x30, 0):
            return failed_token(parser, PROBLEM_ZERO_INDENT, start_mark)
        increment = as_digit_at(parser, 0)
        skip(parser)
        if not cache(parser, 1):
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        if check_at(parser, 0x2B, 0) or check_at(parser, 0x2D, 0):
            chomping = 1 if check_at(parser, 0x2B, 0) else -1
            skip(parser)
    # Eat whitespaces and comments to the end of the line.
    if not cache(parser, 1):
        return failed_token(parser, PROBLEM_EXPECTED_COMMENT_OR_BREAK, start_mark)
    while is_blank_at(parser, 0):
        skip(parser)
        if not cache(parser, 1):
            return failed_token(parser, PROBLEM_EXPECTED_COMMENT_OR_BREAK, start_mark)
    if check_at(parser, 0x23, 0):
        while not is_breakz_at(parser, 0):
            skip(parser)
            if not cache(parser, 1):
                return failed_token(
                    parser, PROBLEM_EXPECTED_COMMENT_OR_BREAK, start_mark
                )
    # Check if we are at the end of the line.
    if not is_breakz_at(parser, 0):
        return failed_token(parser, PROBLEM_EXPECTED_COMMENT_OR_BREAK, start_mark)
    # Eat a line break.
    if is_break_at(parser, 0):
        if not cache(parser, 2):
            return failed_token(parser, PROBLEM_EXPECTED_COMMENT_OR_BREAK, start_mark)
        skip_line(parser)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    # Set the indentation level if it was specified.
    if increment != 0:
        indent = parser.indent + increment if parser.indent >= 0 else increment
    # Scan the leading line breaks and determine the indentation if needed.
    indent = scan_block_scalar_breaks(parser, indent, start_mark, trailing_breaks)
    if indent < 0:
        return failed_token(parser, parser.problem, start_mark)
    end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    # Scan the block scalar content.
    if not cache(parser, 1):
        return failed_token(parser, PROBLEM_GENERIC, start_mark)
    while parser.mark.column == indent and not is_z_at(parser, 0):
        # We are at the beginning of a non-empty line.
        trailing_blank = 1 if is_blank_at(parser, 0) else 0
        # Check if we need to fold the leading line break.
        if (
            literal == 0
            and leading_break.__len__() > 0
            and leading_break[0] == UInt8(0x0A)
            and leading_blank == 0
            and trailing_blank == 0
        ):
            if trailing_breaks.__len__() == 0:
                _ = append_byte(parser, string, UInt8(0x20))
            leading_break = List[UInt8]()
            trailing_breaks = List[UInt8]()
        else:
            append_all(parser, string, leading_break)
            leading_break = List[UInt8]()
            append_all(parser, string, trailing_breaks)
            trailing_breaks = List[UInt8]()
        # Is it a leading whitespace?
        leading_blank = 1 if is_blank_at(parser, 0) else 0
        # Consume the current line.
        while not is_breakz_at(parser, 0):
            if read_into(parser, string) < 0:
                return failed_token(parser, PROBLEM_GENERIC, start_mark)
            if not cache(parser, 1):
                return failed_token(parser, PROBLEM_GENERIC, start_mark)
        # Consume the line break.
        if not cache(parser, 2):
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        read_line_into(parser, leading_break)
        # Eat the following indentation spaces and line breaks.
        indent = scan_block_scalar_breaks(
            parser, indent, start_mark, trailing_breaks
        )
        if indent < 0:
            return failed_token(parser, parser.problem, start_mark)
        end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    # Chomp the tail.
    if chomping != -1:
        append_all(parser, string, leading_break)
    if chomping == 1:
        append_all(parser, string, trailing_breaks)
    var token = Token(SCALAR_TOKEN, start_mark, end_mark)
    park(parser, string, token)
    token.style = LITERAL_SCALAR_STYLE if literal != 0 else FOLDED_SCALAR_STYLE
    return token^


def scan_flow_scalar(mut parser: Parser, single: Int) -> Token:
    # `string` is the value; the other three are upstream's temporaries, kept as
    # separate buffers so JOIN / CLEAR have the same meaning they do in C.
    var string = List[UInt8]()
    var leading_break = List[UInt8]()
    var trailing_breaks = List[UInt8]()
    var whitespaces = List[UInt8]()
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var quote = 0x27 if single != 0 else 0x22
    # Eat the left quote.
    skip(parser)
    while True:
        # No document indicators at the beginning of the line.
        if not cache(parser, 4):
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        if parser.mark.column == 0 and (
            (
                check_at(parser, 0x2D, 0)
                and check_at(parser, 0x2D, 1)
                and check_at(parser, 0x2D, 2)
            )
            or (
                check_at(parser, 0x2E, 0)
                and check_at(parser, 0x2E, 1)
                and check_at(parser, 0x2E, 2)
            )
        ) and is_blankz_at(parser, 3):
            return failed_token(
                parser, PROBLEM_UNEXPECTED_DOC_INDICATOR, start_mark
            )
        # Check for EOF.
        if is_z_at(parser, 0):
            return failed_token(parser, PROBLEM_UNEXPECTED_STREAM_END, start_mark)
        # Consume non-blank characters.
        if not cache(parser, 2):
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        var leading_blanks = 0
        while not is_blankz_at(parser, 0):
            if (
                single != 0
                and check_at(parser, 0x27, 0)
                and check_at(parser, 0x27, 1)
            ):
                # An escaped single quote.
                _ = append_byte(parser, string, UInt8(0x27))
                skip(parser)
                skip(parser)
            elif check_at(parser, quote, 0):
                # The right quote.
                break
            elif (
                single == 0
                and check_at(parser, 0x5C, 0)
                and is_break_at(parser, 1)
            ):
                # An escaped line break.
                if not cache(parser, 3):
                    return failed_token(parser, PROBLEM_GENERIC, start_mark)
                skip(parser)
                skip_line(parser)
                leading_blanks = 1
                break
            elif single == 0 and check_at(parser, 0x5C, 0):
                # An escape sequence.
                var code_length = 0
                if check_at(parser, 0x78, 1):
                    code_length = 2
                elif check_at(parser, 0x75, 1):
                    code_length = 4
                elif check_at(parser, 0x55, 1):
                    code_length = 8
                elif check_at(parser, 0x30, 1):
                    _ = append_byte(parser, string, UInt8(0x00))
                elif check_at(parser, 0x61, 1):
                    _ = append_byte(parser, string, UInt8(0x07))
                elif check_at(parser, 0x62, 1):
                    _ = append_byte(parser, string, UInt8(0x08))
                elif check_at(parser, 0x74, 1) or check_at(parser, 0x09, 1):
                    _ = append_byte(parser, string, UInt8(0x09))
                elif check_at(parser, 0x6E, 1):
                    _ = append_byte(parser, string, UInt8(0x0A))
                elif check_at(parser, 0x76, 1):
                    _ = append_byte(parser, string, UInt8(0x0B))
                elif check_at(parser, 0x66, 1):
                    _ = append_byte(parser, string, UInt8(0x0C))
                elif check_at(parser, 0x72, 1):
                    _ = append_byte(parser, string, UInt8(0x0D))
                elif check_at(parser, 0x65, 1):
                    _ = append_byte(parser, string, UInt8(0x1B))
                elif check_at(parser, 0x20, 1):
                    _ = append_byte(parser, string, UInt8(0x20))
                elif check_at(parser, 0x22, 1):
                    _ = append_byte(parser, string, UInt8(0x22))
                elif check_at(parser, 0x2F, 1):
                    _ = append_byte(parser, string, UInt8(0x2F))
                elif check_at(parser, 0x5C, 1):
                    _ = append_byte(parser, string, UInt8(0x5C))
                elif check_at(parser, 0x4E, 1):
                    # NEL (#x85)
                    _ = append_byte(parser, string, UInt8(0xC2))
                    _ = append_byte(parser, string, UInt8(0x85))
                elif check_at(parser, 0x5F, 1):
                    # #xA0
                    _ = append_byte(parser, string, UInt8(0xC2))
                    _ = append_byte(parser, string, UInt8(0xA0))
                elif check_at(parser, 0x4C, 1):
                    # LS (#x2028)
                    _ = append_byte(parser, string, UInt8(0xE2))
                    _ = append_byte(parser, string, UInt8(0x80))
                    _ = append_byte(parser, string, UInt8(0xA8))
                elif check_at(parser, 0x50, 1):
                    # PS (#x2029)
                    _ = append_byte(parser, string, UInt8(0xE2))
                    _ = append_byte(parser, string, UInt8(0x80))
                    _ = append_byte(parser, string, UInt8(0xA9))
                else:
                    return failed_token(parser, PROBLEM_UNKNOWN_ESCAPE, start_mark)
                skip(parser)
                skip(parser)
                # Consume an arbitrary escape code.
                if code_length != 0:
                    var value = 0
                    if not cache(parser, code_length):
                        return failed_token(parser, PROBLEM_EXPECTED_HEX, start_mark)
                    for k in range(code_length):
                        if not is_hex_at(parser, k):
                            return failed_token(
                                parser, PROBLEM_EXPECTED_HEX, start_mark
                            )
                        value = (value << 4) + as_hex_at(parser, k)
                    if (value >= 0xD800 and value <= 0xDFFF) or value > 0x10FFFF:
                        return failed_token(
                            parser, PROBLEM_BAD_UNICODE_ESCAPE, start_mark
                        )
                    if value <= 0x7F:
                        _ = append_byte(parser, string, UInt8(value))
                    elif value <= 0x7FF:
                        _ = append_byte(parser, string, UInt8(0xC0 + (value >> 6)))
                        _ = append_byte(parser, string, UInt8(0x80 + (value & 0x3F)))
                    elif value <= 0xFFFF:
                        _ = append_byte(parser, string, UInt8(0xE0 + (value >> 12)))
                        _ = append_byte(
                            parser, string, UInt8(0x80 + ((value >> 6) & 0x3F))
                        )
                        _ = append_byte(parser, string, UInt8(0x80 + (value & 0x3F)))
                    else:
                        _ = append_byte(parser, string, UInt8(0xF0 + (value >> 18)))
                        _ = append_byte(
                            parser, string, UInt8(0x80 + ((value >> 12) & 0x3F))
                        )
                        _ = append_byte(
                            parser, string, UInt8(0x80 + ((value >> 6) & 0x3F))
                        )
                        _ = append_byte(parser, string, UInt8(0x80 + (value & 0x3F)))
                    for k in range(code_length):
                        skip(parser)
            else:
                # A non-escaped non-blank character.
                if read_into(parser, string) < 0:
                    return failed_token(parser, PROBLEM_GENERIC, start_mark)
            if not cache(parser, 2):
                return failed_token(parser, PROBLEM_GENERIC, start_mark)
        # Check if we are at the end of the scalar.
        if not cache(parser, 1):
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        if check_at(parser, quote, 0):
            break
        # Consume blank characters.
        if not cache(parser, 1):
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        while is_blank_at(parser, 0) or is_break_at(parser, 0):
            if is_blank_at(parser, 0):
                if leading_blanks == 0:
                    if read_into(parser, whitespaces) < 0:
                        return failed_token(parser, PROBLEM_GENERIC, start_mark)
                else:
                    skip(parser)
            else:
                if not cache(parser, 2):
                    return failed_token(parser, PROBLEM_GENERIC, start_mark)
                if leading_blanks == 0:
                    whitespaces = List[UInt8]()
                    read_line_into(parser, leading_break)
                    leading_blanks = 1
                else:
                    read_line_into(parser, trailing_breaks)
            if not cache(parser, 1):
                return failed_token(parser, PROBLEM_GENERIC, start_mark)
        # Join the whitespaces or fold line breaks.
        if leading_blanks != 0:
            if leading_break[0] == UInt8(0x0A):
                if trailing_breaks.__len__() == 0:
                    _ = append_byte(parser, string, UInt8(0x20))
                else:
                    append_all(parser, string, trailing_breaks)
                    trailing_breaks = List[UInt8]()
                leading_break = List[UInt8]()
            else:
                append_all(parser, string, leading_break)
                leading_break = List[UInt8]()
                append_all(parser, string, trailing_breaks)
                trailing_breaks = List[UInt8]()
        else:
            append_all(parser, string, whitespaces)
            whitespaces = List[UInt8]()
    # Eat the right quote.
    skip(parser)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var token = Token(SCALAR_TOKEN, start_mark, end_mark)
    park(parser, string, token)
    token.style = (
        SINGLE_QUOTED_SCALAR_STYLE if single != 0 else DOUBLE_QUOTED_SCALAR_STYLE
    )
    return token^


def scan_plain_scalar(mut parser: Parser) -> Token:
    var string = List[UInt8]()
    var leading_break = List[UInt8]()
    var trailing_breaks = List[UInt8]()
    var whitespaces = List[UInt8]()
    var leading_blanks = 0
    var indent = parser.indent + 1
    var start_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    var end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
    while True:
        # Check for a document indicator.
        if not cache(parser, 4):
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        if parser.mark.column == 0 and (
            (
                check_at(parser, 0x2D, 0)
                and check_at(parser, 0x2D, 1)
                and check_at(parser, 0x2D, 2)
            )
            or (
                check_at(parser, 0x2E, 0)
                and check_at(parser, 0x2E, 1)
                and check_at(parser, 0x2E, 2)
            )
        ) and is_blankz_at(parser, 3):
            break
        # Check for a comment.
        if check_at(parser, 0x23, 0):
            break
        # Consume non-blank characters.
        while not is_blankz_at(parser, 0):
            # "x:" followed by ',?[]{}' in the flow context is an error.
            if (
                parser.flow_level != 0
                and check_at(parser, 0x3A, 0)
                and (
                    check_at(parser, 0x2C, 1)
                    or check_at(parser, 0x3F, 1)
                    or check_at(parser, 0x5B, 1)
                    or check_at(parser, 0x5D, 1)
                    or check_at(parser, 0x7B, 1)
                    or check_at(parser, 0x7D, 1)
                )
            ):
                return failed_token(parser, PROBLEM_UNEXPECTED_COLON, start_mark)
            # Check for indicators that may end a plain scalar.
            if (check_at(parser, 0x3A, 0) and is_blankz_at(parser, 1)) or (
                parser.flow_level != 0
                and (
                    check_at(parser, 0x2C, 0)
                    or check_at(parser, 0x5B, 0)
                    or check_at(parser, 0x5D, 0)
                    or check_at(parser, 0x7B, 0)
                    or check_at(parser, 0x7D, 0)
                )
            ):
                break
            # Check if we need to join whitespaces and breaks.
            if leading_blanks != 0 or whitespaces.__len__() != 0:
                if leading_blanks != 0:
                    # Do we need to fold line breaks?
                    if leading_break[0] == UInt8(0x0A):
                        if trailing_breaks.__len__() == 0:
                            _ = append_byte(parser, string, UInt8(0x20))
                        else:
                            append_all(parser, string, trailing_breaks)
                            trailing_breaks = List[UInt8]()
                        leading_break = List[UInt8]()
                    else:
                        append_all(parser, string, leading_break)
                        leading_break = List[UInt8]()
                        append_all(parser, string, trailing_breaks)
                        trailing_breaks = List[UInt8]()
                    leading_blanks = 0
                else:
                    append_all(parser, string, whitespaces)
                    whitespaces = List[UInt8]()
            if read_into(parser, string) < 0:
                return failed_token(parser, PROBLEM_GENERIC, start_mark)
            end_mark = Mark(parser.mark.index, parser.mark.line, parser.mark.column)
            if not cache(parser, 2):
                return failed_token(parser, PROBLEM_GENERIC, start_mark)
        # Is it the end?
        if not (is_blank_at(parser, 0) or is_break_at(parser, 0)):
            break
        # Consume blank characters.
        if not cache(parser, 1):
            return failed_token(parser, PROBLEM_GENERIC, start_mark)
        while is_blank_at(parser, 0) or is_break_at(parser, 0):
            if is_blank_at(parser, 0):
                # Check for tab characters that abuse indentation.
                if (
                    leading_blanks != 0
                    and parser.mark.column < indent
                    and is_tab_at(parser, 0)
                ):
                    return failed_token(parser, PROBLEM_TRAILING_TAB, start_mark)
                # Consume a space or a tab character.
                if leading_blanks == 0:
                    if read_into(parser, whitespaces) < 0:
                        return failed_token(parser, PROBLEM_GENERIC, start_mark)
                else:
                    skip(parser)
            else:
                if not cache(parser, 2):
                    return failed_token(parser, PROBLEM_GENERIC, start_mark)
                # Check if it is a first line break.
                if leading_blanks == 0:
                    whitespaces = List[UInt8]()
                    read_line_into(parser, leading_break)
                    leading_blanks = 1
                else:
                    read_line_into(parser, trailing_breaks)
            if not cache(parser, 1):
                return failed_token(parser, PROBLEM_GENERIC, start_mark)
        # Check the indentation level.
        if parser.flow_level == 0 and parser.mark.column < indent:
            break
    var token = Token(SCALAR_TOKEN, start_mark, end_mark)
    park(parser, string, token)
    token.style = PLAIN_SCALAR_STYLE
    # Note that we change the 'simple_key_allowed' flag.
    if leading_blanks != 0:
        parser.simple_key_allowed = True
    return token^

# The dispatcher for token fetchers (yaml_parser_fetch_next_token).
def fetch_next_token(mut parser: Parser) -> Bool:
    if not cache(parser, 1):
        return False
    # Check if we just started scanning.
    if not parser.stream_start_produced:
        return fetch_stream_start(parser)
    # Eat whitespaces and comments until we reach the next token.
    if not scan_to_next_token(parser):
        return False
    # Remove obsolete potential simple keys.
    if not stale_simple_keys(parser):
        return False
    # Check the indentation level against the current column.
    if not unroll_indent(parser, parser.mark.column):
        return False
    # 4 is the length of the longest indicators ('--- ' and '... ').
    if not cache(parser, 4):
        return False

    # One table walk over (context, symbol) replaces the C's 18-arm if-chain;
    # the rules the table encodes are the C's, in the C's order.
    var octet0 = Int(src_of(parser).unsafe_load(parser.pointer))
    var octet1 = Int(src_of(parser).unsafe_load(parser.pointer + 1))
    var octet2 = Int(src_of(parser).unsafe_load(parser.pointer + 2))
    var octet3 = Int(src_of(parser).unsafe_load(parser.pointer + 3))
    var ctx = dfa_context(
        parser.mark.column,
        parser.flow_level,
        is_blankz_at(parser, 0),
        is_blank_at(parser, 1),
        is_blankz_at(parser, 1),
        is_blankz_at(parser, 3),
    )
    var symbol = dfa_symbol(
        octet0, octet1, octet2, octet3, parser.mark.column
    )
    var action = dfa_dispatch(ctx, symbol)

    if action == ACT_STREAM_END:
        return fetch_stream_end(parser)
    if action == ACT_DIRECTIVE:
        return fetch_directive(parser)
    if action == ACT_DOCUMENT_START:
        return fetch_document_indicator(parser, DOCUMENT_START_TOKEN)
    if action == ACT_DOCUMENT_END:
        return fetch_document_indicator(parser, DOCUMENT_END_TOKEN)
    if action == ACT_FLOW_SEQUENCE_START:
        return fetch_flow_collection_start(parser, FLOW_SEQUENCE_START_TOKEN)
    if action == ACT_FLOW_MAPPING_START:
        return fetch_flow_collection_start(parser, FLOW_MAPPING_START_TOKEN)
    if action == ACT_FLOW_SEQUENCE_END:
        return fetch_flow_collection_end(parser, FLOW_SEQUENCE_END_TOKEN)
    if action == ACT_FLOW_MAPPING_END:
        return fetch_flow_collection_end(parser, FLOW_MAPPING_END_TOKEN)
    if action == ACT_FLOW_ENTRY:
        return fetch_flow_entry(parser)
    if action == ACT_BLOCK_ENTRY:
        return fetch_block_entry(parser)
    if action == ACT_KEY:
        return fetch_key(parser)
    if action == ACT_VALUE:
        return fetch_value(parser)
    if action == ACT_ALIAS:
        return fetch_anchor(parser, ALIAS_TOKEN)
    if action == ACT_ANCHOR:
        return fetch_anchor(parser, ANCHOR_TOKEN)
    if action == ACT_TAG:
        return fetch_tag(parser)
    if action == ACT_BLOCK_SCALAR_LITERAL:
        return fetch_block_scalar(parser, 1)
    if action == ACT_BLOCK_SCALAR_FOLDED:
        return fetch_block_scalar(parser, 0)
    if action == ACT_FLOW_SCALAR_SINGLE:
        return fetch_flow_scalar(parser, 1)
    if action == ACT_FLOW_SCALAR_DOUBLE:
        return fetch_flow_scalar(parser, 0)
    if action == ACT_PLAIN:
        return fetch_plain_scalar(parser)
    return set_scanner_error(
        parser, PROBLEM_UNEXPECTED_CHAR, parser.mark.line, parser.mark.column
    )


# Ensure the tokens queue contains enough tokens (yaml_parser_fetch_more_tokens).
def fetch_more_tokens(mut parser: Parser) -> Bool:
    while True:
        var need_more_tokens = False
        if parser.tokens.__len__() == 0:
            # Queue is empty.
            need_more_tokens = True
        else:
            # Check if any potential simple key may occupy the head position.
            if not stale_simple_keys(parser):
                return False
            for i in range(parser.simple_keys.__len__()):
                if (
                    parser.simple_keys[i].possible
                    and parser.simple_keys[i].token_number == parser.tokens_parsed
                ):
                    need_more_tokens = True
                    break
        if not need_more_tokens:
            break
        if not fetch_next_token(parser):
            return False
    parser.token_available = True
    return True


# Make sure the queue holds a token and leave it at the head.  This is the
# refill the parser needs before it peeks (yaml_parser_scan is the dequeuing
# counterpart the token API uses).
def fill(mut parser: Parser) -> Bool:
    if parser.tokens.__len__() > 0:
        return True
    # No tokens after STREAM-END or error.
    if parser.stream_end_produced or parser.error != NO_ERROR:
        return False
    if not parser.token_available:
        if not fetch_more_tokens(parser):
            return False
    return parser.tokens.__len__() > 0


# yaml_parser_scan: dequeue the next token.
def scan(mut parser: Parser) -> Bool:
    if not fill(parser):
        return parser.error == NO_ERROR
    stash_head_token(parser)
    var head_type = parser.last_token.type
    _ = parser.tokens.pop(0)
    parser.token_available = False
    parser.tokens_parsed += 1
    if head_type == STREAM_END_TOKEN:
        parser.stream_end_produced = True
    return True


# Copy the queued token at `index` into the parser's `last_token` slot, which
# is what scan() hands back to its caller.  The fields are read before the
# destination is written so the copy does not alias its own source.
def stash_head_token(mut parser: Parser) -> None:
    var staged = Token(
        parser.tokens[0].type,
        Mark(
            parser.tokens[0].start_index,
            parser.tokens[0].start_line,
            parser.tokens[0].start_column,
        ),
        Mark(
            parser.tokens[0].end_index,
            parser.tokens[0].end_line,
            parser.tokens[0].end_column,
        ),
    )
    staged.value_start = parser.tokens[0].value_start
    staged.value_end = parser.tokens[0].value_end
    staged.aux_start = parser.tokens[0].aux_start
    staged.aux_end = parser.tokens[0].aux_end
    staged.style = parser.tokens[0].style
    staged.major = parser.tokens[0].major
    staged.minor = parser.tokens[0].minor
    parser.last_token = staged^


# Copy the queued token at `index` into a fresh record.
def token_copy(parser: Parser, index: Int) -> Token:
    var out = Token(NO_TOKEN, Mark(0, 0, 0), Mark(0, 0, 0))
    copy_token_into(parser, index, out)
    return out^


# Copy the queued token at `index` into `dst` field by field.  A struct carrying
# a List is not implicitly copyable on this toolchain, so the record is rebuilt
# rather than assigned; callers outside the queue use this instead of reading
# `tokens[index]` directly.
def copy_token_into(
    parser: Parser, index: Int, mut dst: Token
) -> None:
    # Read the fields straight out of the indexed element: binding the element
    # to a local would need the copy this function exists to avoid.
    dst.type = parser.tokens[index].type
    dst.start_index = parser.tokens[index].start_index
    dst.start_line = parser.tokens[index].start_line
    dst.start_column = parser.tokens[index].start_column
    dst.end_index = parser.tokens[index].end_index
    dst.end_line = parser.tokens[index].end_line
    dst.end_column = parser.tokens[index].end_column
    dst.value_start = parser.tokens[index].value_start
    dst.value_end = parser.tokens[index].value_end
    dst.aux_start = parser.tokens[index].aux_start
    dst.aux_end = parser.tokens[index].aux_end
    dst.style = parser.tokens[index].style
    dst.major = parser.tokens[index].major
    dst.minor = parser.tokens[index].minor


def pending_tokens(parser: Parser) -> Int:
    return parser.tokens.__len__()


# Copy the token scan() most recently dequeued.
def last_token_copy(parser: Parser) -> Token:
    var out = Token(STREAM_START_TOKEN, Mark(0, 0, 0), Mark(0, 0, 0))
    copy_last_token_into(parser, out)
    return out^


def copy_last_token_into(
    parser: Parser, mut dst: Token
) -> None:
    dst.type = parser.last_token.type
    dst.start_index = parser.last_token.start_index
    dst.start_line = parser.last_token.start_line
    dst.start_column = parser.last_token.start_column
    dst.end_index = parser.last_token.end_index
    dst.end_line = parser.last_token.end_line
    dst.end_column = parser.last_token.end_column
    dst.value_start = parser.last_token.value_start
    dst.value_end = parser.last_token.value_end
    dst.aux_start = parser.last_token.aux_start
    dst.aux_end = parser.last_token.aux_end
    dst.style = parser.last_token.style
    dst.major = parser.last_token.major
    dst.minor = parser.last_token.minor


# ---------------------------------------------------------------------------
# Named-string helpers.
#
# The scalar scanners keep upstream's separate yaml_string_t values (string,
# leading_break, trailing_breaks, whitespaces) as local Lists.  These read a
# character into one of them and move one into another, which is what
# STRING_EXTEND / COPY, JOIN and CLEAR do in yaml_private.h.
# ---------------------------------------------------------------------------


def append_byte(parser: Parser, mut dest: List[UInt8], value: UInt8) -> Int:
    _ = parser
    dest.append(value)
    return dest.__len__()


def append_all(parser: Parser, mut dest: List[UInt8], src: List[UInt8]) -> Int:
    # JOIN(parser, a, b)
    _ = parser
    for i in range(src.__len__()):
        dest.append(src[i])
    return dest.__len__()


def park_span(mut parser: Parser, value: List[UInt8]) -> Int:
    # Append a payload and hand back where it landed.
    var at = parser.arena.__len__()
    for i in range(value.__len__()):
        parser.arena.append(value[i])
    return at


def park(mut parser: Parser, value: List[UInt8], mut token: Token) -> None:
    # Append a finished payload to the arena and record its span on the token.
    var at = parser.arena.__len__()
    for i in range(value.__len__()):
        parser.arena.append(value[i])
    token.value_start = at
    token.value_end = parser.arena.__len__()
