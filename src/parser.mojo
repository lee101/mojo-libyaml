"""Event stream ported from libyaml's parser.c.

The state machine that turns the scanner's token stream into events keeps
upstream's states, transitions and productions.  Tag directive resolution (the
`%TAG` prefix table) lives on the ParseState record because a struct field may
not own reference-typed state across this boundary.
"""

from scanner import (
    ALIAS_TOKEN,
    ANCHOR_TOKEN,
    BLOCK_END_TOKEN,
    BLOCK_ENTRY_TOKEN,
    BLOCK_MAPPING_START_TOKEN,
    BLOCK_SEQUENCE_START_TOKEN,
    DOCUMENT_END_TOKEN,
    DOCUMENT_START_TOKEN,
    FLOW_ENTRY_TOKEN,
    FLOW_MAPPING_END_TOKEN,
    FLOW_MAPPING_START_TOKEN,
    FLOW_SEQUENCE_END_TOKEN,
    FLOW_SEQUENCE_START_TOKEN,
    KEY_TOKEN,
    Mark,
    NO_ERROR,
    NO_TOKEN,
    PLAIN_SCALAR_STYLE,
    Parser,
    SCALAR_TOKEN,
    STREAM_END_TOKEN,
    STREAM_START_TOKEN,
    TAG_DIRECTIVE_TOKEN,
    TAG_TOKEN,
    Token,
    VALUE_TOKEN,
    VERSION_DIRECTIVE_TOKEN,
    fill,
    token_copy,
)

# yaml.h: YAML_PARSER_ERROR, distinct from the scanner's codes.
comptime PARSER_ERROR: Int = 3

# yaml.h: yaml_event_type_e
comptime NO_EVENT: Int = 0
comptime STREAM_START_EVENT: Int = 1
comptime STREAM_END_EVENT: Int = 2
comptime DOCUMENT_START_EVENT: Int = 3
comptime DOCUMENT_END_EVENT: Int = 4
comptime ALIAS_EVENT: Int = 5
comptime SCALAR_EVENT: Int = 6
comptime SEQUENCE_START_EVENT: Int = 7
comptime SEQUENCE_END_EVENT: Int = 8
comptime MAPPING_START_EVENT: Int = 9
comptime MAPPING_END_EVENT: Int = 10

# yaml.h: yaml_sequence_style_e / yaml_mapping_style_e
comptime BLOCK_SEQUENCE_STYLE: Int = 1
comptime FLOW_SEQUENCE_STYLE: Int = 2
comptime BLOCK_MAPPING_STYLE: Int = 1
comptime FLOW_MAPPING_STYLE: Int = 2

# Parser problems.
comptime PROBLEM_EXPECTED_STREAM_START: Int = 100
comptime PROBLEM_EXPECTED_DOCUMENT_START: Int = 101
comptime PROBLEM_UNSUPPORTED_VERSION: Int = 102
comptime PROBLEM_DUPLICATE_YAML_DIRECTIVE: Int = 103
comptime PROBLEM_DUPLICATE_TAG_DIRECTIVE: Int = 104
comptime PROBLEM_UNDEFINED_TAG_HANDLE: Int = 105
comptime PROBLEM_EXPECTED_NODE_CONTENT: Int = 106
comptime PROBLEM_EXPECTED_BLOCK_ENTRY: Int = 107
comptime PROBLEM_EXPECTED_KEY: Int = 108
comptime PROBLEM_EXPECTED_FLOW_ENTRY: Int = 109

# The state machine's states, named as in parser.c.
comptime PARSE_END_STATE: Int = 0
comptime PARSE_STREAM_START_STATE: Int = 1
comptime PARSE_IMPLICIT_DOCUMENT_START_STATE: Int = 2
comptime PARSE_DOCUMENT_START_STATE: Int = 3
comptime PARSE_DOCUMENT_CONTENT_STATE: Int = 4
comptime PARSE_DOCUMENT_END_STATE: Int = 5
comptime PARSE_BLOCK_NODE_STATE: Int = 6
comptime PARSE_BLOCK_NODE_OR_INDENTLESS_SEQUENCE_STATE: Int = 7
comptime PARSE_FLOW_NODE_STATE: Int = 8
comptime PARSE_BLOCK_SEQUENCE_FIRST_ENTRY_STATE: Int = 9
comptime PARSE_BLOCK_SEQUENCE_ENTRY_STATE: Int = 10
comptime PARSE_INDENTLESS_SEQUENCE_ENTRY_STATE: Int = 11
comptime PARSE_BLOCK_MAPPING_FIRST_KEY_STATE: Int = 12
comptime PARSE_BLOCK_MAPPING_KEY_STATE: Int = 13
comptime PARSE_BLOCK_MAPPING_VALUE_STATE: Int = 14
comptime PARSE_FLOW_SEQUENCE_FIRST_ENTRY_STATE: Int = 15
comptime PARSE_FLOW_SEQUENCE_ENTRY_STATE: Int = 16
comptime PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_KEY_STATE: Int = 17
comptime PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_VALUE_STATE: Int = 18
comptime PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_END_STATE: Int = 19
comptime PARSE_FLOW_MAPPING_FIRST_KEY_STATE: Int = 20
comptime PARSE_FLOW_MAPPING_KEY_STATE: Int = 21
comptime PARSE_FLOW_MAPPING_VALUE_STATE: Int = 22
comptime PARSE_FLOW_MAPPING_EMPTY_VALUE_STATE: Int = 23

# Event payloads reuse the scanner's arena: an event records a span for its
# scalar value, anchor and tag rather than owning the bytes.  `has_value` marks
# an empty scalar, whose value is "" and not a missing payload.
struct Event(Copyable):
    var type: Int
    var has_value: Int
    var implicit: Int
    var style: Int
    var major: Int
    var minor: Int
    var value_start: Int
    var value_end: Int
    var anchor_start: Int
    var anchor_end: Int
    var tag_start: Int
    var tag_end: Int
    var plain_implicit: Int
    var quoted_implicit: Int
    var has_version: Int

    def __init__(out self, type: Int):
        self.type = type
        self.has_value = 0
        self.implicit = 0
        self.style = PLAIN_SCALAR_STYLE
        self.major = 0
        self.minor = 0
        self.value_start = 0
        self.value_end = 0
        self.anchor_start = 0
        self.anchor_end = 0
        self.tag_start = 0
        self.tag_end = 0
        self.plain_implicit = 0
        self.quoted_implicit = 0
        self.has_version = 0


# parser.c keeps the state, the state stack and the mark stack on the parser
# object; they live in a side record so one value covers both stages.
struct ParseState(Copyable):
    var state: Int
    var states: List[Int]
    var marks: List[Token]
    var tag_handles: List[Int]
    var tag_prefixes: List[Int]
    var version_major: Int
    var version_minor: Int
    var has_version: Int

    def __init__(out self):
        self.state = PARSE_STREAM_START_STATE
        self.states = List[Int]()
        self.marks = List[Token]()
        self.tag_handles = List[Int]()
        self.tag_prefixes = List[Int]()
        self.version_major = 0
        self.version_minor = 0
        self.has_version = 0


def set_parser_error(
    ps: ParseState,
    mut parser: Parser,
    problem: Int,
    line: Int,
    column: Int,
) -> Bool:
    _ = ps
    parser.error = PARSER_ERROR
    parser.problem = problem
    parser.problem_line = line
    parser.problem_column = column
    return False


# PEEK_TOKEN, with the scanner's refill.  Upstream fetches a token at the top of
# each state function that peeks rather than inside the peek itself.
def peek(mut parser: Parser) -> Token:
    if not fill(parser):
        return Token(NO_TOKEN, Mark(0, 0, 0), Mark(0, 0, 0))
    return token_copy(parser, 0)


# SKIP_TOKEN: consume the token at the head of the queue.
def skip_token(mut parser: Parser):
    if parser.tokens.__len__() > 0:
        _ = parser.tokens.pop(0)
        parser.token_available = False


def emit_byte_into(mut parser: Parser, b: UInt8) -> Int:
    var at = parser.arena.__len__()
    parser.arena.append(b)
    return at


# Copy a span of the arena to its end, so a resolved tag can be built without
# disturbing the spans already recorded on queued tokens.
def emit_bytes_into(mut parser: Parser, start: Int, end: Int) -> Int:
    var at = parser.arena.__len__()
    var staged = List[UInt8]()
    for i in range(start, end):
        staged.append(parser.arena[i])
    for i in range(staged.__len__()):
        parser.arena.append(staged[i])
    return at


def arena_span_equals(
    parser: Parser, start: Int, end: Int, other_start: Int, other_end: Int
) -> Bool:
    if end - start != other_end - other_start:
        return False
    for i in range(end - start):
        if (
            parser.arena[start + i] != parser.arena[other_start + i]
        ):
            return False
    return True


# yaml_parser_append_tag_directive
def append_tag_directive(
    mut ps: ParseState,
    handle_start: Int,
    handle_end: Int,
    prefix_start: Int,
    prefix_end: Int,
    allow_duplicates: Int,
    mut parser: Parser,
) -> Bool:
    # Handles and prefixes are recorded as (start, end) pairs side by side.
    for i in range(ps.tag_handles.__len__() // 2):
        var existing_start = ps.tag_handles[i * 2]
        var existing_end = ps.tag_handles[i * 2 + 1]
        if arena_span_equals(
            parser, existing_start, existing_end, handle_start, handle_end
        ):
            if allow_duplicates != 0:
                return True
            return set_parser_error(
                ps,
                parser,
                PROBLEM_DUPLICATE_TAG_DIRECTIVE,
                parser.mark.line,
                parser.mark.column,
            )
    ps.tag_handles.append(handle_start)
    ps.tag_handles.append(handle_end)
    ps.tag_prefixes.append(prefix_start)
    ps.tag_prefixes.append(prefix_end)
    return True


# yaml_parser_process_empty_scalar
def process_empty_scalar(mut ps: ParseState) -> Event:
    _ = ps
    var event = Event(SCALAR_EVENT)
    event.implicit = 1
    event.plain_implicit = 1
    event.has_value = 1
    return event^


# yaml_parser_parse_stream_start
def parse_stream_start(
    mut ps: ParseState, mut parser: Parser
) -> Event:
    var token = peek(parser)
    if token.type != STREAM_START_TOKEN:
        _ = set_parser_error(
            ps,
            parser,
            PROBLEM_EXPECTED_STREAM_START,
            token.start_line,
            token.start_column,
        )
        return Event(NO_EVENT)
    ps.state = PARSE_IMPLICIT_DOCUMENT_START_STATE
    var event = Event(STREAM_START_EVENT)
    skip_token(parser)
    return event^


# yaml_parser_parse_document_start
def parse_document_start(
    mut ps: ParseState, mut parser: Parser, implicit: Int
) -> Event:
    var token = peek(parser)
    # Parse extra document end indicators.
    if implicit == 0:
        while token.type == DOCUMENT_END_TOKEN:
            skip_token(parser)
            token = peek(parser)
    # Parse an implicit document.
    if (
        implicit != 0
        and token.type != VERSION_DIRECTIVE_TOKEN
        and token.type != TAG_DIRECTIVE_TOKEN
        and token.type != DOCUMENT_START_TOKEN
        and token.type != STREAM_END_TOKEN
    ):
        if not process_directives(ps, parser, 0):
            return Event(NO_EVENT)
        ps.states.append(PARSE_DOCUMENT_END_STATE)
        ps.state = PARSE_BLOCK_NODE_STATE
        var event = Event(DOCUMENT_START_EVENT)
        event.implicit = 1
        return event^
    # Parse an explicit document.
    elif token.type != STREAM_END_TOKEN:
        if not process_directives(ps, parser, 1):
            return Event(NO_EVENT)
        token = peek(parser)
        if token.type != DOCUMENT_START_TOKEN:
            _ = set_parser_error(
                ps,
                parser,
                PROBLEM_EXPECTED_DOCUMENT_START,
                token.start_line,
                token.start_column,
            )
            return Event(NO_EVENT)
        ps.states.append(PARSE_DOCUMENT_END_STATE)
        ps.state = PARSE_DOCUMENT_CONTENT_STATE
        var event = Event(DOCUMENT_START_EVENT)
        event.major = ps.version_major
        event.minor = ps.version_minor
        event.has_version = ps.has_version
        skip_token(parser)
        return event^
    # Parse the stream end.
    else:
        ps.state = PARSE_END_STATE
        var event = Event(STREAM_END_EVENT)
        skip_token(parser)
        return event^


# yaml_parser_parse_document_content
def parse_document_content(
    mut ps: ParseState, mut parser: Parser
) -> Event:
    var token = peek(parser)
    if (
        token.type == VERSION_DIRECTIVE_TOKEN
        or token.type == TAG_DIRECTIVE_TOKEN
        or token.type == DOCUMENT_START_TOKEN
        or token.type == DOCUMENT_END_TOKEN
        or token.type == STREAM_END_TOKEN
    ):
        ps.state = ps.states.pop()
        return process_empty_scalar(ps)
    return parse_node(ps, parser, 1, 0)


# yaml_parser_parse_document_end
def parse_document_end(mut ps: ParseState, mut parser: Parser) -> Event:
    var token = peek(parser)
    var implicit = 1
    if token.type == DOCUMENT_END_TOKEN:
        implicit = 0
        skip_token(parser)
    # Drop the document's tag directives.
    ps.tag_handles = List[Int]()
    ps.tag_prefixes = List[Int]()
    ps.state = PARSE_DOCUMENT_START_STATE
    var event = Event(DOCUMENT_END_EVENT)
    event.implicit = implicit
    return event^


# yaml_parser_parse_node
def parse_node(
    mut ps: ParseState,
    mut parser: Parser,
    block: Int,
    indentless_sequence: Int,
) -> Event:
    var token = peek(parser)
    var anchor_start = 0
    var anchor_end = 0
    var tag_handle_start = 0
    var tag_handle_end = 0
    var tag_suffix_start = 0
    var tag_suffix_end = 0
    var has_anchor = 0
    var has_tag_token = 0
    if token.type == ALIAS_TOKEN:
        ps.state = ps.states.pop()
        var event = Event(ALIAS_EVENT)
        event.value_start = token.value_start
        event.value_end = token.value_end
        skip_token(parser)
        return event^
    var start_line = token.start_line
    if token.type == ANCHOR_TOKEN:
        anchor_start = token.value_start
        anchor_end = token.value_end
        has_anchor = 1
        skip_token(parser)
        token = peek(parser)
        if token.type == TAG_TOKEN:
            tag_handle_start = token.value_start
            tag_handle_end = token.value_end
            tag_suffix_start = token.aux_start
            tag_suffix_end = token.aux_end
            has_tag_token = 1
            skip_token(parser)
            token = peek(parser)
    elif token.type == TAG_TOKEN:
        tag_handle_start = token.value_start
        tag_handle_end = token.value_end
        tag_suffix_start = token.aux_start
        tag_suffix_end = token.aux_end
        has_tag_token = 1
        start_line = token.start_line
        skip_token(parser)
        token = peek(parser)
        if token.type == ANCHOR_TOKEN:
            anchor_start = token.value_start
            anchor_end = token.value_end
            has_anchor = 1
            skip_token(parser)
            token = peek(parser)
    # Resolve the tag handle into a full tag.
    var tag_start = 0
    var tag_end = 0
    var has_tag = 0
    if has_tag_token != 0:
        if tag_handle_end == tag_handle_start:
            # The verbatim '!<...>' form carries an empty handle.
            tag_start = tag_suffix_start
            tag_end = tag_suffix_end
            has_tag = 1
        else:
            var found = False
            for i in range(ps.tag_handles.__len__() // 2):
                var h_start = ps.tag_handles[i * 2]
                var h_end = ps.tag_handles[i * 2 + 1]
                var p_start = ps.tag_prefixes[i * 2]
                var p_end = ps.tag_prefixes[i * 2 + 1]
                if arena_span_equals(
                    parser, h_start, h_end, tag_handle_start, tag_handle_end
                ):
                    tag_start = emit_bytes_into(parser, p_start, p_end)
                    tag_end = emit_bytes_into(
                        parser, tag_suffix_start, tag_suffix_end
                    )
                    found = True
                    break
            if not found:
                _ = set_parser_error(
                    ps,
                    parser,
                    PROBLEM_UNDEFINED_TAG_HANDLE,
                    start_line,
                    0,
                )
                return Event(NO_EVENT)
            has_tag = 1
    var implicit = 0
    if has_tag != 0 and tag_end > tag_start:
        implicit = 0
    else:
        implicit = 1
    if indentless_sequence != 0 and token.type == BLOCK_ENTRY_TOKEN:
        var event = Event(SEQUENCE_START_EVENT)
        event.style = BLOCK_SEQUENCE_STYLE
        event.anchor_start = anchor_start
        event.anchor_end = anchor_end
        event.tag_start = tag_start
        event.tag_end = tag_end
        event.implicit = implicit
        ps.state = PARSE_INDENTLESS_SEQUENCE_ENTRY_STATE
        return event^
    if token.type == SCALAR_TOKEN:
        var plain_implicit = 0
        var quoted_implicit = 0
        if (token.style == PLAIN_SCALAR_STYLE and has_tag == 0) or (
            has_tag != 0
            and tag_end - tag_start == 1
            and parser.arena[tag_start] == UInt8(0x21)
        ):
            plain_implicit = 1
        elif has_tag == 0:
            quoted_implicit = 1
        ps.state = ps.states.pop()
        var event = Event(SCALAR_EVENT)
        event.style = token.style
        event.anchor_start = anchor_start
        event.anchor_end = anchor_end
        event.tag_start = tag_start
        event.tag_end = tag_end
        event.value_start = token.value_start
        event.value_end = token.value_end
        event.has_value = 1
        event.plain_implicit = plain_implicit
        event.quoted_implicit = quoted_implicit
        skip_token(parser)
        return event^
    elif token.type == FLOW_SEQUENCE_START_TOKEN:
        var event = Event(SEQUENCE_START_EVENT)
        event.style = FLOW_SEQUENCE_STYLE
        event.anchor_start = anchor_start
        event.anchor_end = anchor_end
        event.tag_start = tag_start
        event.tag_end = tag_end
        event.implicit = implicit
        ps.state = PARSE_FLOW_SEQUENCE_FIRST_ENTRY_STATE
        return event^
    elif token.type == FLOW_MAPPING_START_TOKEN:
        var event = Event(MAPPING_START_EVENT)
        event.style = FLOW_MAPPING_STYLE
        event.anchor_start = anchor_start
        event.anchor_end = anchor_end
        event.tag_start = tag_start
        event.tag_end = tag_end
        event.implicit = implicit
        ps.state = PARSE_FLOW_MAPPING_FIRST_KEY_STATE
        return event^
    elif block != 0 and token.type == BLOCK_SEQUENCE_START_TOKEN:
        var event = Event(SEQUENCE_START_EVENT)
        event.style = BLOCK_SEQUENCE_STYLE
        event.anchor_start = anchor_start
        event.anchor_end = anchor_end
        event.tag_start = tag_start
        event.tag_end = tag_end
        event.implicit = implicit
        ps.state = PARSE_BLOCK_SEQUENCE_FIRST_ENTRY_STATE
        return event^
    elif block != 0 and token.type == BLOCK_MAPPING_START_TOKEN:
        var event = Event(MAPPING_START_EVENT)
        event.style = BLOCK_MAPPING_STYLE
        event.anchor_start = anchor_start
        event.anchor_end = anchor_end
        event.tag_start = tag_start
        event.tag_end = tag_end
        event.implicit = implicit
        ps.state = PARSE_BLOCK_MAPPING_FIRST_KEY_STATE
        return event^
    elif has_anchor != 0 or has_tag != 0:
        # An empty scalar carrying only properties.
        var event = Event(SCALAR_EVENT)
        event.style = PLAIN_SCALAR_STYLE
        event.anchor_start = anchor_start
        event.anchor_end = anchor_end
        event.tag_start = tag_start
        event.tag_end = tag_end
        event.implicit = implicit
        event.plain_implicit = 1
        event.has_value = 1
        ps.state = ps.states.pop()
        return event^
    _ = set_parser_error(
        ps,
        parser,
        PROBLEM_EXPECTED_NODE_CONTENT,
        token.start_line,
        token.start_column,
    )
    return Event(NO_EVENT)


# yaml_parser_parse_block_sequence_entry
def parse_block_sequence_entry(
    mut ps: ParseState, mut parser: Parser, first: Int
) -> Event:
    var token = peek(parser)
    if first != 0:
        ps.marks.append(token^)
        skip_token(parser)
    token = peek(parser)
    if token.type == BLOCK_ENTRY_TOKEN:
        skip_token(parser)
        token = peek(parser)
        if token.type != BLOCK_ENTRY_TOKEN and token.type != BLOCK_END_TOKEN:
            ps.states.append(PARSE_BLOCK_SEQUENCE_ENTRY_STATE)
            return parse_node(ps, parser, 1, 0)
        else:
            ps.state = PARSE_BLOCK_SEQUENCE_ENTRY_STATE
            return process_empty_scalar(ps)
    elif token.type == BLOCK_END_TOKEN:
        ps.state = ps.states.pop()
        _ = ps.marks.pop()
        var event = Event(SEQUENCE_END_EVENT)
        skip_token(parser)
        return event^
    _ = set_parser_error(
        ps,
        parser,
        PROBLEM_EXPECTED_BLOCK_ENTRY,
        token.start_line,
        token.start_column,
    )
    return Event(NO_EVENT)


# yaml_parser_parse_indentless_sequence_entry
def parse_indentless_sequence_entry(
    mut ps: ParseState, mut parser: Parser
) -> Event:
    var token = peek(parser)
    if token.type == BLOCK_ENTRY_TOKEN:
        skip_token(parser)
        token = peek(parser)
        if (
            token.type != BLOCK_ENTRY_TOKEN
            and token.type != KEY_TOKEN
            and token.type != VALUE_TOKEN
            and token.type != BLOCK_END_TOKEN
        ):
            ps.states.append(PARSE_INDENTLESS_SEQUENCE_ENTRY_STATE)
            return parse_node(ps, parser, 1, 0)
        else:
            ps.state = PARSE_INDENTLESS_SEQUENCE_ENTRY_STATE
            return process_empty_scalar(ps)
    else:
        ps.state = ps.states.pop()
        return Event(SEQUENCE_END_EVENT)


# yaml_parser_parse_block_mapping_key
def parse_block_mapping_key(
    mut ps: ParseState, mut parser: Parser, first: Int
) -> Event:
    var token = peek(parser)
    if first != 0:
        ps.marks.append(token^)
        skip_token(parser)
    token = peek(parser)
    if token.type == KEY_TOKEN:
        skip_token(parser)
        token = peek(parser)
        if (
            token.type != KEY_TOKEN
            and token.type != VALUE_TOKEN
            and token.type != BLOCK_END_TOKEN
        ):
            ps.states.append(PARSE_BLOCK_MAPPING_VALUE_STATE)
            return parse_node(ps, parser, 1, 1)
        else:
            ps.state = PARSE_BLOCK_MAPPING_VALUE_STATE
            return process_empty_scalar(ps)
    elif token.type == BLOCK_END_TOKEN:
        ps.state = ps.states.pop()
        _ = ps.marks.pop()
        var event = Event(MAPPING_END_EVENT)
        skip_token(parser)
        return event^
    _ = set_parser_error(
        ps,
        parser,
        PROBLEM_EXPECTED_KEY,
        token.start_line,
        token.start_column,
    )
    return Event(NO_EVENT)


# yaml_parser_parse_block_mapping_value
def parse_block_mapping_value(
    mut ps: ParseState, mut parser: Parser
) -> Event:
    var token = peek(parser)
    if token.type == VALUE_TOKEN:
        skip_token(parser)
        token = peek(parser)
        if (
            token.type != KEY_TOKEN
            and token.type != VALUE_TOKEN
            and token.type != BLOCK_END_TOKEN
        ):
            ps.states.append(PARSE_BLOCK_MAPPING_KEY_STATE)
            return parse_node(ps, parser, 1, 1)
        else:
            ps.state = PARSE_BLOCK_MAPPING_KEY_STATE
            return process_empty_scalar(ps)
    else:
        ps.state = PARSE_BLOCK_MAPPING_KEY_STATE
        return process_empty_scalar(ps)


# yaml_parser_parse_flow_sequence_entry
def parse_flow_sequence_entry(
    mut ps: ParseState, mut parser: Parser, first: Int
) -> Event:
    var token = peek(parser)
    if first != 0:
        ps.marks.append(token^)
        skip_token(parser)
    token = peek(parser)
    if token.type != FLOW_SEQUENCE_END_TOKEN:
        if first == 0:
            if token.type == FLOW_ENTRY_TOKEN:
                skip_token(parser)
                token = peek(parser)
            else:
                _ = set_parser_error(
                    ps,
                    parser,
                    PROBLEM_EXPECTED_FLOW_ENTRY,
                    token.start_line,
                    token.start_column,
                )
                return Event(NO_EVENT)
        if token.type == KEY_TOKEN:
            ps.state = PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_KEY_STATE
            var event = Event(MAPPING_START_EVENT)
            event.style = FLOW_MAPPING_STYLE
            event.implicit = 1
            skip_token(parser)
            return event^
        elif token.type != FLOW_SEQUENCE_END_TOKEN:
            ps.states.append(PARSE_FLOW_SEQUENCE_ENTRY_STATE)
            return parse_node(ps, parser, 0, 0)
    ps.state = ps.states.pop()
    _ = ps.marks.pop()
    var event = Event(SEQUENCE_END_EVENT)
    skip_token(parser)
    return event^


# yaml_parser_parse_flow_sequence_entry_mapping_key
def parse_flow_sequence_entry_mapping_key(
    mut ps: ParseState, mut parser: Parser
) -> Event:
    var token = peek(parser)
    if (
        token.type != VALUE_TOKEN
        and token.type != FLOW_ENTRY_TOKEN
        and token.type != FLOW_SEQUENCE_END_TOKEN
    ):
        ps.states.append(PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_VALUE_STATE)
        return parse_node(ps, parser, 0, 0)
    elif token.type == FLOW_SEQUENCE_END_TOKEN:
        ps.state = PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_VALUE_STATE
        return process_empty_scalar(ps)
    else:
        skip_token(parser)
        ps.state = PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_VALUE_STATE
        return process_empty_scalar(ps)


# yaml_parser_parse_flow_sequence_entry_mapping_value
def parse_flow_sequence_entry_mapping_value(
    mut ps: ParseState, mut parser: Parser
) -> Event:
    var token = peek(parser)
    if token.type == VALUE_TOKEN:
        skip_token(parser)
        token = peek(parser)
        if token.type != FLOW_ENTRY_TOKEN and token.type != FLOW_SEQUENCE_END_TOKEN:
            ps.states.append(PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_END_STATE)
            return parse_node(ps, parser, 0, 0)
    ps.state = PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_END_STATE
    return process_empty_scalar(ps)


# yaml_parser_parse_flow_sequence_entry_mapping_end
def parse_flow_sequence_entry_mapping_end(
    mut ps: ParseState, mut parser: Parser
) -> Event:
    _ = peek(parser)
    ps.state = PARSE_FLOW_SEQUENCE_ENTRY_STATE
    return Event(MAPPING_END_EVENT)


# yaml_parser_parse_flow_mapping_key
def parse_flow_mapping_key(
    mut ps: ParseState, mut parser: Parser, first: Int
) -> Event:
    var token = peek(parser)
    if first != 0:
        ps.marks.append(token^)
        skip_token(parser)
    token = peek(parser)
    if token.type != FLOW_MAPPING_END_TOKEN:
        if first == 0:
            if token.type == FLOW_ENTRY_TOKEN:
                skip_token(parser)
                token = peek(parser)
            else:
                _ = set_parser_error(
                    ps,
                    parser,
                    PROBLEM_EXPECTED_FLOW_ENTRY,
                    token.start_line,
                    token.start_column,
                )
                return Event(NO_EVENT)
        if token.type == KEY_TOKEN:
            skip_token(parser)
            token = peek(parser)
            if (
                token.type != VALUE_TOKEN
                and token.type != FLOW_ENTRY_TOKEN
                and token.type != FLOW_MAPPING_END_TOKEN
            ):
                ps.states.append(PARSE_FLOW_MAPPING_VALUE_STATE)
                return parse_node(ps, parser, 0, 0)
            else:
                ps.state = PARSE_FLOW_MAPPING_VALUE_STATE
                return process_empty_scalar(ps)
        elif token.type != FLOW_MAPPING_END_TOKEN:
            ps.states.append(PARSE_FLOW_MAPPING_EMPTY_VALUE_STATE)
            return parse_node(ps, parser, 0, 0)
    ps.state = ps.states.pop()
    _ = ps.marks.pop()
    var event = Event(MAPPING_END_EVENT)
    skip_token(parser)
    return event^


# yaml_parser_parse_flow_mapping_value
def parse_flow_mapping_value(
    mut ps: ParseState, mut parser: Parser, empty: Int
) -> Event:
    var token = peek(parser)
    if empty != 0:
        ps.state = PARSE_FLOW_MAPPING_KEY_STATE
        return process_empty_scalar(ps)
    if token.type == VALUE_TOKEN:
        skip_token(parser)
        token = peek(parser)
        if token.type != FLOW_ENTRY_TOKEN and token.type != FLOW_MAPPING_END_TOKEN:
            ps.states.append(PARSE_FLOW_MAPPING_KEY_STATE)
            return parse_node(ps, parser, 0, 0)
    ps.state = PARSE_FLOW_MAPPING_KEY_STATE
    return process_empty_scalar(ps)


# yaml_parser_process_directives
def process_directives(
    mut ps: ParseState, mut parser: Parser, explicit: Int
) -> Bool:
    ps.has_version = 0
    ps.version_major = 0
    ps.version_minor = 0
    var token = peek(parser)
    while token.type == VERSION_DIRECTIVE_TOKEN or token.type == TAG_DIRECTIVE_TOKEN:
        if token.type == VERSION_DIRECTIVE_TOKEN:
            if ps.has_version != 0:
                return set_parser_error(
                    ps,
                    parser,
                    PROBLEM_DUPLICATE_YAML_DIRECTIVE,
                    token.start_line,
                    token.start_column,
                )
            if token.major != 1 or (token.minor != 1 and token.minor != 2):
                return set_parser_error(
                    ps,
                    parser,
                    PROBLEM_UNSUPPORTED_VERSION,
                    token.start_line,
                    token.start_column,
                )
            ps.version_major = token.major
            ps.version_minor = token.minor
            ps.has_version = 1
        else:
            if not append_tag_directive(
                ps,
                token.value_start,
                token.value_end,
                token.aux_start,
                token.aux_end,
                0,
                parser,
            ):
                return False
        skip_token(parser)
        token = peek(parser)
    # The default tag directives from parser.c:
    #   { "!", "!" }, { "!!", "tag:yaml.org,2002:" }
    var bang_start = emit_byte_into(parser, UInt8(0x21))
    var bang_end = parser.arena.__len__()
    if not append_tag_directive(
        ps, bang_start, bang_end, bang_start, bang_end, 1, parser
    ):
        return False
    var dbl_start = emit_byte_into(parser, UInt8(0x21))
    _ = emit_byte_into(parser, UInt8(0x21))
    var dbl_end = parser.arena.__len__()
    # "tag:yaml.org,2002:", spelled out because a String literal cannot be
    # indexed on this dialect.
    var prefix_start = emit_byte_into(parser, UInt8(0x74))  # t
    _ = emit_byte_into(parser, UInt8(0x61))  # a
    _ = emit_byte_into(parser, UInt8(0x67))  # g
    _ = emit_byte_into(parser, UInt8(0x3A))  # :
    _ = emit_byte_into(parser, UInt8(0x79))  # y
    _ = emit_byte_into(parser, UInt8(0x61))  # a
    _ = emit_byte_into(parser, UInt8(0x6D))  # m
    _ = emit_byte_into(parser, UInt8(0x6C))  # l
    _ = emit_byte_into(parser, UInt8(0x2E))  # .
    _ = emit_byte_into(parser, UInt8(0x6F))  # o
    _ = emit_byte_into(parser, UInt8(0x72))  # r
    _ = emit_byte_into(parser, UInt8(0x67))  # g
    _ = emit_byte_into(parser, UInt8(0x2C))  # ,
    _ = emit_byte_into(parser, UInt8(0x32))  # 2
    _ = emit_byte_into(parser, UInt8(0x30))  # 0
    _ = emit_byte_into(parser, UInt8(0x30))  # 0
    _ = emit_byte_into(parser, UInt8(0x32))  # 2
    var prefix_end = emit_byte_into(parser, UInt8(0x3A))  # :
    if not append_tag_directive(
        ps, dbl_start, dbl_end, prefix_start, prefix_end, 1, parser
    ):
        return False
    _ = explicit
    return True


# yaml_parser_state_machine
def state_machine(mut ps: ParseState, mut parser: Parser) -> Event:
    if ps.state == PARSE_STREAM_START_STATE:
        return parse_stream_start(ps, parser)
    if ps.state == PARSE_IMPLICIT_DOCUMENT_START_STATE:
        return parse_document_start(ps, parser, 1)
    if ps.state == PARSE_DOCUMENT_START_STATE:
        return parse_document_start(ps, parser, 0)
    if ps.state == PARSE_DOCUMENT_CONTENT_STATE:
        return parse_document_content(ps, parser)
    if ps.state == PARSE_DOCUMENT_END_STATE:
        return parse_document_end(ps, parser)
    if ps.state == PARSE_BLOCK_NODE_STATE:
        return parse_node(ps, parser, 1, 0)
    if ps.state == PARSE_BLOCK_NODE_OR_INDENTLESS_SEQUENCE_STATE:
        return parse_node(ps, parser, 1, 1)
    if ps.state == PARSE_FLOW_NODE_STATE:
        return parse_node(ps, parser, 0, 0)
    if ps.state == PARSE_BLOCK_SEQUENCE_FIRST_ENTRY_STATE:
        return parse_block_sequence_entry(ps, parser, 1)
    if ps.state == PARSE_BLOCK_SEQUENCE_ENTRY_STATE:
        return parse_block_sequence_entry(ps, parser, 0)
    if ps.state == PARSE_INDENTLESS_SEQUENCE_ENTRY_STATE:
        return parse_indentless_sequence_entry(ps, parser)
    if ps.state == PARSE_BLOCK_MAPPING_FIRST_KEY_STATE:
        return parse_block_mapping_key(ps, parser, 1)
    if ps.state == PARSE_BLOCK_MAPPING_KEY_STATE:
        return parse_block_mapping_key(ps, parser, 0)
    if ps.state == PARSE_BLOCK_MAPPING_VALUE_STATE:
        return parse_block_mapping_value(ps, parser)
    if ps.state == PARSE_FLOW_SEQUENCE_FIRST_ENTRY_STATE:
        return parse_flow_sequence_entry(ps, parser, 1)
    if ps.state == PARSE_FLOW_SEQUENCE_ENTRY_STATE:
        return parse_flow_sequence_entry(ps, parser, 0)
    if ps.state == PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_KEY_STATE:
        return parse_flow_sequence_entry_mapping_key(ps, parser)
    if ps.state == PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_VALUE_STATE:
        return parse_flow_sequence_entry_mapping_value(ps, parser)
    if ps.state == PARSE_FLOW_SEQUENCE_ENTRY_MAPPING_END_STATE:
        return parse_flow_sequence_entry_mapping_end(ps, parser)
    if ps.state == PARSE_FLOW_MAPPING_FIRST_KEY_STATE:
        return parse_flow_mapping_key(ps, parser, 1)
    if ps.state == PARSE_FLOW_MAPPING_KEY_STATE:
        return parse_flow_mapping_key(ps, parser, 0)
    if ps.state == PARSE_FLOW_MAPPING_VALUE_STATE:
        return parse_flow_mapping_value(ps, parser, 0)
    if ps.state == PARSE_FLOW_MAPPING_EMPTY_VALUE_STATE:
        return parse_flow_mapping_value(ps, parser, 1)
    return Event(NO_EVENT)


# yaml_parser_parse: peek a token, then step the machine.  Several transitions
# consume the last queued token and leave the queue empty, so refill before each
# attempt; upstream does this at the top of every state function that peeks.
def parse(mut ps: ParseState, mut parser: Parser) -> Event:
    # No events after the end of the stream or an error.
    if (
        parser.stream_end_produced
        or parser.error != NO_ERROR
        or ps.state == PARSE_END_STATE
    ):
        return Event(NO_EVENT)
    while True:
        if not fill(parser):
            return Event(NO_EVENT)
        var event = state_machine(ps, parser)
        if event.type != NO_EVENT:
            return event^
        if parser.error != NO_ERROR:
            return event^
        if parser.stream_end_produced or ps.state == PARSE_END_STATE:
            return event^