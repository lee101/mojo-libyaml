/* Reference driver over upstream libyaml, shaped like the Mojo C ABI.
 *
 * Same work as src/capi.mojo: one int64 record per token or event, with the
 * token payloads drained into one flat byte arena exactly the way the Mojo
 * scanner parks its spans, so neither side gets a free copy the other pays for.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <yaml.h>

#define FIELDS 16

static yaml_parser_t parser;
static uint8_t *arena;
static int64_t arena_len;

static void park(const char *value, size_t length, int64_t *start,
                 int64_t *end) {
  *start = arena_len;
  if (length > 0 && value != NULL) {
    memcpy(arena + arena_len, value, length);
    arena_len += (int64_t)length;
  }
  *end = arena_len;
}

int64_t ref_scan(const uint8_t *src, int64_t length, int64_t *records,
                 int64_t capacity, uint8_t *out, int64_t out_capacity) {
  yaml_event_t event;
  int64_t count = 0;
  int type;

  if (!yaml_parser_initialize(&parser)) {
    return -1;
  }
  arena = out;
  arena_len = 0;
  if (out_capacity < 0) {
    arena_len = out_capacity;
  }
  yaml_parser_set_input_string(&parser, (const unsigned char *)src,
                               (size_t)length);
  while (count < capacity) {
    if (!yaml_parser_scan(&parser, &event)) {
      yaml_parser_delete(&parser);
      return -1;
    }
    type = event.type;
    {
      int64_t *r = records + count * FIELDS;
      memset(r, 0, FIELDS * sizeof(int64_t));
      r[0] = type;
      r[1] = event.start_mark.line;
      r[2] = event.start_mark.column;
      r[3] = event.end_mark.line;
      r[4] = event.end_mark.column;
      r[12] = event.start_mark.index;
      r[13] = event.end_mark.index;
      switch (type) {
        case YAML_SCALAR_TOKEN:
          r[9] = event.data.scalar.style;
          park(event.data.scalar.value, event.data.scalar.length, &r[5],
               &r[6]);
          break;
        case YAML_ANCHOR_TOKEN:
        case YAML_ALIAS_TOKEN:
        case YAML_TAG_TOKEN:
        case YAML_TAG_DIRECTIVE_TOKEN:
        case YAML_VERSION_DIRECTIVE_TOKEN:
          park(event.data.anchor.value, event.data.anchor.length, &r[5],
               &r[6]);
          break;
        default:
          break;
      }
    }
    yaml_event_delete(&event);
    count++;
    if (type == YAML_STREAM_END_TOKEN) {
      break;
    }
  }
  yaml_parser_delete(&parser);
  return count;
}

int64_t ref_parse(const uint8_t *src, int64_t length, int64_t *records,
                  int64_t capacity, uint8_t *out, int64_t out_capacity) {
  yaml_event_t event;
  int64_t count = 0;
  int type;

  if (!yaml_parser_initialize(&parser)) {
    return -1;
  }
  arena = out;
  arena_len = 0;
  if (out_capacity < 0) {
    arena_len = out_capacity;
  }
  yaml_parser_set_input_string(&parser, (const unsigned char *)src,
                               (size_t)length);
  while (count < capacity) {
    if (!yaml_parser_parse(&parser, &event)) {
      yaml_parser_delete(&parser);
      return -1;
    }
    type = event.type;
    {
      int64_t *r = records + count * FIELDS;
      memset(r, 0, FIELDS * sizeof(int64_t));
      r[0] = type;
      r[1] = event.implicit;
      r[2] = (type == YAML_SCALAR_EVENT) ? event.data.scalar.style : 0;
      r[9] = event.data.scalar.plain_implicit;
      r[10] = event.data.scalar.quoted_implicit;
      r[13] = (type == YAML_SCALAR_EVENT);
      switch (type) {
        case YAML_SCALAR_EVENT:
          park(event.data.scalar.value, event.data.scalar.length, &r[3],
               &r[4]);
          break;
        case YAML_ALIAS_EVENT:
          park(event.data.anchor.value, event.data.anchor.length, &r[5],
               &r[6]);
          break;
        case YAML_MAPPING_START_EVENT:
          if (event.data.mapping_start.tag_handle[0] != NULL ||
              event.data.mapping_start.tag_handle[1] != NULL) {
            park(event.data.mapping_start.tag_handle, 1, &r[7], &r[8]);
          }
          break;
        case YAML_MAPPING_END_EVENT:
        case YAML_SEQUENCE_START_EVENT:
        case YAML_SEQUENCE_END_EVENT:
          break;
        default:
          break;
      }
    }
    yaml_event_delete(&event);
    count++;
    if (type == YAML_STREAM_END_EVENT) {
      break;
    }
  }
  yaml_parser_delete(&parser);
  return count;
}

int64_t ref_arena_used(void) { return arena_len; }

int64_t ref_version(void) {
  return (int64_t)YAML_VERSION_MAJOR * 100 + (int64_t)YAML_VERSION_MINOR * 10 +
         (int64_t)YAML_VERSION_PATCH;
}