"""C ABI surface over the scanner and the event parser.

Each export runs one complete pass in a single call and writes flat records for
the Python side to decode.  The scanner state is a frame-local `Parser` and the
parser state a frame-local `ParseState`, so there is nothing for ctypes to
allocate or free: the Mojo runtime owns all of the record storage.

That is a documented divergence from libyaml's incremental
`yaml_parser_initialize` / `yaml_parser_scan` / `yaml_parser_delete` cycle.
"""

from parser import Event, ParseState, parse
from scanner import (
    NO_ERROR,
    Parser,
    last_token_copy,
    scan,
)

# Records are a fixed stride so the Python side can stride through them.
comptime FIELDS_PER_TOKEN: Int = 16
comptime FIELDS_PER_EVENT: Int = 16


def write_token(
    parser: Parser, records: Pointer[Int64, AnyOrigin[mut=True]], index: Int
):
    var base = index * FIELDS_PER_TOKEN
    var token = last_token_copy(parser)
    records[unsafe_offset=base + 0] = Int64(token.type)
    records[unsafe_offset=base + 1] = Int64(token.start_line)
    records[unsafe_offset=base + 2] = Int64(token.start_column)
    records[unsafe_offset=base + 3] = Int64(token.end_line)
    records[unsafe_offset=base + 4] = Int64(token.end_column)
    records[unsafe_offset=base + 5] = Int64(token.value_start)
    records[unsafe_offset=base + 6] = Int64(token.value_end)
    records[unsafe_offset=base + 7] = Int64(token.aux_start)
    records[unsafe_offset=base + 8] = Int64(token.aux_end)
    records[unsafe_offset=base + 9] = Int64(token.style)
    records[unsafe_offset=base + 10] = Int64(token.major)
    records[unsafe_offset=base + 11] = Int64(token.minor)
    records[unsafe_offset=base + 12] = Int64(token.start_index)
    records[unsafe_offset=base + 13] = Int64(token.end_index)


def write_event(
    records: Pointer[Int64, AnyOrigin[mut=True]], index: Int, event: Event
):
    var base = index * FIELDS_PER_EVENT
    records[unsafe_offset=base + 0] = Int64(event.type)
    records[unsafe_offset=base + 1] = Int64(event.implicit)
    records[unsafe_offset=base + 2] = Int64(event.style)
    records[unsafe_offset=base + 3] = Int64(event.value_start)
    records[unsafe_offset=base + 4] = Int64(event.value_end)
    records[unsafe_offset=base + 5] = Int64(event.anchor_start)
    records[unsafe_offset=base + 6] = Int64(event.anchor_end)
    records[unsafe_offset=base + 7] = Int64(event.tag_start)
    records[unsafe_offset=base + 8] = Int64(event.tag_end)
    records[unsafe_offset=base + 9] = Int64(event.plain_implicit)
    records[unsafe_offset=base + 10] = Int64(event.quoted_implicit)
    records[unsafe_offset=base + 11] = Int64(event.major)
    records[unsafe_offset=base + 12] = Int64(event.minor)
    records[unsafe_offset=base + 13] = Int64(event.has_version)
    records[unsafe_offset=base + 14] = Int64(event.has_value)


def copy_payload(
    parser: Parser, bytes_out: Pointer[UInt8, AnyOrigin[mut=True]], capacity: Int
):
    var written = 0
    while written < capacity and written < parser.arena.__len__():
        bytes_out.unsafe_store(written, parser.arena[written])
        written += 1


# Scan every token of the document.
#
# Writes FIELDS_PER_TOKEN int64 slots per token into `records` and the payload
# bytes into `payload`, returning the token count, or -1 with `status` filled
# in: [error, problem, line, column].
@export("libyaml_scan_all")
def libyaml_scan_all(
    src: Int,
    length: Int,
    records: Int,
    capacity: Int,
    payload: Int,
    payload_capacity: Int,
    status: Int,
) abi("C") -> Int64:
    # The reader sees the document plus the terminator NUL.
    var parser = Parser(src, length, length + 1)
    var record_ptr = Pointer[Int64, AnyOrigin[mut=True]](unsafe_from_address=records)
    var bytes_out = Pointer[UInt8, AnyOrigin[mut=True]](unsafe_from_address=payload)
    var status_ptr = Pointer[Int64, AnyOrigin[mut=True]](unsafe_from_address=status)

    var count = 0
    var failed = False
    while True:
        # scan() reports a finished stream by producing no further token.
        var before = parser.tokens_parsed
        if not scan(parser):
            failed = True
            break
        if parser.tokens_parsed == before:
            break
        if count >= capacity:
            break
        write_token(parser, record_ptr, count)
        count += 1

    if failed:
        status_ptr[unsafe_offset=0] = Int64(parser.error)
        status_ptr[unsafe_offset=1] = Int64(parser.problem)
        status_ptr[unsafe_offset=2] = Int64(parser.problem_line)
        status_ptr[unsafe_offset=3] = Int64(parser.problem_column)
        return Int64(-1)
    copy_payload(parser, bytes_out, payload_capacity)
    status_ptr[unsafe_offset=0] = Int64(0)
    return Int64(count)


# Step the event state machine over the document, writing one record per event.
@export("libyaml_parse_events")
def libyaml_parse_events(
    src: Int,
    length: Int,
    records: Int,
    capacity: Int,
    payload: Int,
    payload_capacity: Int,
    status: Int,
) abi("C") -> Int64:
    var parser = Parser(src, length, length + 1)
    var ps = ParseState()
    var record_ptr = Pointer[Int64, AnyOrigin[mut=True]](unsafe_from_address=records)
    var bytes_out = Pointer[UInt8, AnyOrigin[mut=True]](unsafe_from_address=payload)
    var status_ptr = Pointer[Int64, AnyOrigin[mut=True]](unsafe_from_address=status)

    var count = 0
    var failed = False
    # parse() pulls a token itself when the queue runs dry, so this is just the
    # driver's loop: ask for the next event until the stream ends.
    while True:
        if count >= capacity:
            break
        var event = parse(ps, parser)
        if event.type == 0:
            if parser.error != NO_ERROR:
                failed = True
            break
        write_event(record_ptr, count, event)
        count += 1

    if failed:
        status_ptr[unsafe_offset=0] = Int64(parser.error)
        status_ptr[unsafe_offset=1] = Int64(parser.problem)
        status_ptr[unsafe_offset=2] = Int64(parser.problem_line)
        status_ptr[unsafe_offset=3] = Int64(parser.problem_column)
        return Int64(-1)
    copy_payload(parser, bytes_out, payload_capacity)
    status_ptr[unsafe_offset=0] = Int64(0)
    return Int64(count)