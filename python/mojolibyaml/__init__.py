"""A Mojo port of libyaml's YAML tokenizer.

Covers the scanner (``scanner.c``) and the event state machine (``parser.c``).
See README.md for the coverage table and the documented divergences from
upstream.
"""

from __future__ import annotations

from ._lib import (
    ERROR_NAMES,
    EVENT_NAMES,
    PARSER_MESSAGES,
    SCANNER_MESSAGES,
    STYLE_ANY,
    STYLE_BLOCK,
    STYLE_FLOW,
    STYLE_NAMES,
    TOKEN_NAMES,
    Event,
    Token,
    YamlError,
    event_names,
    lib,
    parse_events,
    scalar_values,
    scan,
    token_names,
)

__all__ = [
    "ERROR_NAMES",
    "EVENT_NAMES",
    "PARSER_MESSAGES",
    "SCANNER_MESSAGES",
    "STYLE_ANY",
    "STYLE_BLOCK",
    "STYLE_FLOW",
    "STYLE_NAMES",
    "TOKEN_NAMES",
    "Event",
    "Token",
    "YamlError",
    "event_names",
    "lib",
    "parse_events",
    "scalar_values",
    "scan",
    "token_names",
]

__version__ = "0.1.0"