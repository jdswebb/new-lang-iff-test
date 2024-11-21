// SPDX-FileCopyrightText: 2024 James Webb
// SPDX-License-Identifier: MIT
// This notice is not to be removed.

#pragma once

#include "core/astris_types.h"
#include <intrin.h>
#include <emmintrin.h>

#define ae_check_iff_tag_char(c) \
    static_assert((value >= 'a' and value <= 'z') or (value >= 'A' and value <= 'Z') or (value >= '0' and value <= '9') or value == ' ', "Invalid IFF tag character");
#define ae_iff_tag(str) \
    (uint32_t)(str[3] << 24 | str[2] << 16 | str[1] << 8 | str[0] << 0)

typedef struct IffStackNode IffStackNode;
struct IffStackNode
{
    uint32_t start;
    uint32_t end;
    uint32_t tag;
};

typedef struct A_IffFormHeader A_IffFormHeader;
struct A_IffFormHeader
{
    uint32_t form;
    uint32_t size;
    uint32_t tag;
};

typedef struct A_IffChunkHeader A_IffChunkHeader;
struct A_IffChunkHeader
{
    uint32_t tag;
    uint32_t size;
};

typedef enum
{
    IffResult_Ok,
    IffResult_StackExhausted,
    IffResult_ReadPastEof,
    IffResult_UnexpectedTag,
    IffResult_StackUnderflow,
    IffResult_ReaderError,
    IffResult_AllocationError,
} IffResult;

typedef struct IffReader IffReader;
struct IffReader
{
    uint32_t pos;
    uint32_t data_len;
    const uint8_t *data;
    IffStackNode stack[64];
    uint32_t stack_pos;
};

typedef struct
{
    uint8_t *str;
    u64 size;
} String8;

IffReader iff_init(const uint8_t *data, uint32_t data_len, uint8_t *error_buffer, u64 error_buffer_sz);
IffResult iff_read(IffReader *self, void *dst, uint32_t size);

IffResult iff_read_string(IffReader *self, String8 *str);
IffResult iff_open_form(IffReader *self, uint32_t tag);
IffResult iff_open_chunk(IffReader *self, uint32_t tag);
IffResult iff_close_chunk(IffReader *self, uint32_t tag);
IffResult iff_close_form(IffReader *self, uint32_t tag);

// get the number of unread children in the currently open chunk
uint32_t iff_get_remaining_children(const IffReader *self);

typedef struct IffApi
{
    IffReader (*init)(const uint8_t *data, uint32_t data_len, uint8_t* error_buffer, u64 error_buffer_sz);
    IffResult (*read)(IffReader *self, void *dst, uint32_t size);

    IffResult (*read_string)(IffReader *self, String8 *str);
    IffResult (*open_form)(IffReader *self, uint32_t tag);
    IffResult (*open_chunk)(IffReader *self, uint32_t tag);
    IffResult (*close_chunk)(IffReader *self, uint32_t tag);
    IffResult (*close_form)(IffReader *self, uint32_t tag);

    // get the number of unread children in the currently open chunk
    uint32_t (*get_remaining_children)(const IffReader *self);
} IffApi;

inline IffReader iff_init(const uint8_t *data, uint32_t data_len, uint8_t *error_buffer, u64 error_buffer_sz)
{
#ifndef __cplusplus
    return (IffReader) {
        .data_len = data_len,
        .data = data,
    };
#else
    return {
        .data_len = data_len,
        .data = data,
    };
#endif
}

inline IffResult iff_read_internal(IffReader *self, void *dst, uint32_t size)
{
    uint32_t pos = self->pos;
    if ae_unlikely(size > (self->data_len - pos)) {
        return IffResult_ReadPastEof;
    }
    memcpy(dst, self->data + pos, size);
    self->pos += size;
    return IffResult_Ok;
}

inline IffResult iff_read(IffReader *self, void *dst, uint32_t size)
{
    if ae_unlikely (self->stack_pos == 0) {
        return IffResult_StackExhausted;
    }
    const IffStackNode *node = &self->stack[self->stack_pos - 1];
    uint32_t pos = self->pos;
    if ae_unlikely (size > (node->end - pos)) {
        return IffResult_ReadPastEof;
    }
    memcpy(dst, self->data + pos, size);
    self->pos += size;
    return IffResult_Ok;
}

inline size_t fast_strlen(const uint8_t *str, size_t max_len)
{
    const u64 *ptr = (const u64 *)str;
    size_t i;

    for (i = 0; i + 7 < max_len; i += 8) {
        u64 chunk = *ptr++;
        // Check if the chunk contains a null byte
        if (((chunk - 0x0101010101010101ULL) & ~chunk & 0x8080808080808080ULL) != 0) {
            // A null byte was found within this chunk
            const uint8_t *c = (const uint8_t*)(ptr - 1);
            while (*c) {
                c++;
            }
            return c - str;
        }
    }

    // Handle the remaining bytes
    const char *c = (const char *)(ptr);
    while (i < max_len && *c) {
        i++;
        c++;
    }
    return i;
}

inline IffResult iff_read_string(IffReader *self, String8 *str)
{
    if ae_unlikely (self->stack_pos == 0) {
        return IffResult_StackExhausted;
    }
   //const IffStackNode *node = &self->stack[self->stack_pos - 1];
    uint32_t start = self->pos;
    uint32_t pos = start;

    const uint8_t* data = self->data;
    uint32_t write_pos = 0;
    while (data[pos] != 0) {
        str->str[write_pos++] = data[pos];
        pos += 1;
    }
    self->pos = pos + 1;
    return IffResult_Ok;

    //const uint8_t *const data = self->data;
    //pos += (u32)fast_strlen(&data[pos], node->start - node->end);
    //// skip null character
    //self->pos = pos + 1;
    //uint32_t length = pos + 1 - start;
    //memcpy(&str->str[0], &self->data[start], (length < str->size) ? length : str->size);
    //return IffResult_Ok;
}

inline IffResult iff_open_form(IffReader *self, uint32_t tag)
{
    IffResult result;
    A_IffFormHeader header;
    if ae_unlikely ((result = iff_read_internal(self, &header, sizeof(header))) != IffResult_Ok) {
        return result;
    }
    header.size = _byteswap_ulong(header.size);

    if (header.form != ae_iff_tag("FORM")) {
        return IffResult_UnexpectedTag;
    }
    if (header.tag != tag) {
        return IffResult_UnexpectedTag;
    }
    if (self->stack_pos >= ae_length_of(self->stack)) {
        return IffResult_StackExhausted;
    }

#ifndef __cplusplus
    self->stack[self->stack_pos] = (IffStackNode) {
        .start = self->pos,
        .end = self->pos + header.size - 4,
        .tag = tag,
    };
#else
    self->stack[self->stack_pos] = IffStackNode {
        .start = self->pos,
        .end = self->pos + header.size - 4,
        .tag = tag,
    };
#endif

    self->stack_pos += 1;
    return IffResult_Ok;
}

inline IffResult iff_open_chunk(IffReader *self, uint32_t tag)
{
    IffResult result;
    A_IffChunkHeader header;
    if ae_unlikely ((result = iff_read_internal(self, &header, sizeof(header))) != IffResult_Ok) {
        return result;
    }
    header.size = _byteswap_ulong(header.size);

    if (header.tag != tag) {
        return IffResult_UnexpectedTag;
    }
    if (self->stack_pos >= ae_length_of(self->stack)) {
        return IffResult_StackExhausted;
    }

#ifndef __cplusplus
    self->stack[self->stack_pos] = (IffStackNode) {
        .start = self->pos,
        .end = self->pos + header.size,
        .tag = tag,
    };
#else
    self->stack[self->stack_pos] = IffStackNode {
        .start = self->pos,
        .end = self->pos + header.size,
        .tag = tag,
    };
#endif
    self->stack_pos += 1;
    return IffResult_Ok;
}

inline IffResult iff_close_chunk(IffReader *self, uint32_t tag)
{
    if (self->stack_pos == 0) {
        return IffResult_StackUnderflow;
    }
    self->stack_pos -= 1;
    const IffStackNode *const chunk = &self->stack[self->stack_pos];
    if (chunk->tag != tag) {
        return IffResult_ReaderError;
    }
    if (self->pos != chunk->end) {
        // Reading beyond the chunk is never good - but sometimes not fully reading
        // a chunk is fine so ignore the opposite case
        if (self->pos > chunk->end) {
            return IffResult_ReaderError;
        }
    }
    self->pos = chunk->end;
    return IffResult_Ok;
}

inline IffResult iff_close_form(IffReader *self, uint32_t tag)
{
    return iff_close_chunk(self, tag);
}

inline uint32_t iff_get_remaining_children(const IffReader *self)
{
    uint32_t stack_pos = self->stack_pos;
    if (stack_pos == 0) {
        return 0;
    }
    uint32_t curr = self->pos;
    const IffStackNode* curr_stack = &self->stack[stack_pos - 1];
    uint32_t start = curr_stack->start;
    uint32_t end = curr_stack->end;
    if (curr < start || curr > end) {
        return 0;
    }
    uint32_t count = 0;
    while (curr < end) {
        uint32_t length;
        memcpy(&length, &self->data[curr + 4], sizeof(length));
        length = _byteswap_ulong(length);
        curr += length + 8;
        count += 1;
    }
    return count;
}
