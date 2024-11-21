// SPDX-FileCopyrightText: 2024 James Webb
// SPDX-License-Identifier: MIT
// This notice is not to be removed.

package iff

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

Tag :: distinct u32

tag_FORM: u32 : 1297239878

ReaderStackNode :: struct {
    start, end : u32,
    tag: Tag,
}

FormHeader :: struct {
    form, size: u32,
    tag: Tag,
}

ChunkHeader :: struct {
    tag : Tag,
    size: u32,
}

Reader :: struct {
    pos:          u32,
    data:         []u8,
    stack:        [64]ReaderStackNode,
    stack_next:   u32,
    error_buffer: []u8,
}

Error :: enum {
    None,
    StackExhausted,
    ReadPastEof,
    UnexpectedTag,
    StackUnderflow,
    ReaderError,
    AllocationError,
    DestBufferTooSmall,
}

strlen_fast :: #force_inline proc (str: ^u8, max_len: int) -> int {
    ptr: ^u64 = transmute(^u64)str
    i: int = 0
    for ; i + 7 < max_len; i += 8 {
        chunk: u64 = ptr^
        ptr = mem.ptr_offset(ptr, 1)
        if (((chunk - 0x0101010101010101) & ~chunk & 0x8080808080808080) != 0) {
            c: ^u8 = transmute(^u8)mem.ptr_offset(ptr, -1)
            for c^ != 0 {
                c = mem.ptr_offset(c, 1)
            }
            return mem.ptr_sub(c, str)
        }
    }
    c: ^u8 = str
    for i < max_len && c^ != 0 {
        i += 1
        c = mem.ptr_offset(c, 1)
    }
    return i
}

IffApi :: struct {    
    open_form : #type proc (self: ^Reader, tag: Tag) -> Error,
    open_chunk : #type proc (self: ^Reader, tag: Tag) -> Error,
    close_chunk : #type  proc (self: ^Reader, tag: Tag) -> Error,
    close_form : #type  proc (self: ^Reader, tag: Tag = 0) -> Error,
    read : #type proc (self: ^Reader, v: rawptr, size: int) -> Error,
    read_string_to : proc (self: ^Reader, str: []u8) -> Error,
}

open_form :: proc (self: ^Reader, tag: Tag) -> Error {
    header := read_internal(self, FormHeader) or_return
    header.size = intrinsics.byte_swap(header.size)
    if (intrinsics.expect(header.form != tag_FORM, false)) {
        return .UnexpectedTag
    }
    if (intrinsics.expect(header.tag != tag, false)) {
        return .UnexpectedTag
    }
    if (intrinsics.expect(self.stack_next >= cast(u32)len(self.stack), false)) {
        return .StackExhausted
    }
    self.stack[self.stack_next] = {
        tag   = tag,
        start = self.pos,
        end   = self.pos + header.size - 4,
    }
    
    self.stack_next += 1
    return .None
}

read_internal :: proc (self: ^Reader, $T: typeid) -> (T, Error) {
    if (intrinsics.expect(size_of(T) > (cast(u32)len(self.data) - self.pos), false)) {
        return T{}, .ReadPastEof
    }
    result: T
    mem.copy(&result, &self.data[self.pos], size_of(T))
    self.pos += size_of(T)
    return result, .None
}

read :: proc (self: ^Reader, $T: typeid) -> (T, Error) {
    stack_curr := self.stack_next
    if (intrinsics.expect(stack_curr == 0, false)) {
        return T{}, .StackExhausted
    }
    stack_curr -= 1
    node := &self.stack[stack_curr]
    if (intrinsics.expect(size_of(T) > (node.end - self.pos), false)) {
        return T{}, .ReadPastEof
    }
    result: T
    mem.copy(&result, &self.data[self.pos], size_of(T))
    self.pos += size_of(T)
    return result, .None
}

read_raw :: proc (self: ^Reader, value: rawptr, size: int) -> (Error) {
    stack_curr := self.stack_next
    if (intrinsics.expect(stack_curr == 0, false)) {
        return .StackExhausted
    }
    stack_curr -= 1
    node := &self.stack[stack_curr]
    if (intrinsics.expect(u32(size) > (node.end - self.pos), false)) {
        return .ReadPastEof
    }
    mem.copy(value, &self.data[self.pos], size)
    self.pos += u32(size)
    return .None
}

open_chunk :: proc (self: ^Reader, tag: Tag) -> Error {
    header := read_internal(self, ChunkHeader) or_return
    header.size = intrinsics.byte_swap(header.size)
    if (intrinsics.expect(header.tag != tag, false)) {
        return .UnexpectedTag
    }
    if (intrinsics.expect(self.stack_next >= cast(u32)len(self.stack), false)) {
        return .StackExhausted
    }
    self.stack[self.stack_next] = {
        tag   = tag,
        start = self.pos,
        end   = self.pos + header.size,
    }
    self.stack_next += 1
    return .None
}

close_chunk :: proc (self: ^Reader, tag: Tag) -> Error {
    if (self.stack_next <= 0) {
        return .StackUnderflow
    }
    self.stack_next -= 1
    chunk := &self.stack[self.stack_next]
    if (intrinsics.expect(chunk.tag != tag, false)) {
        return .ReaderError
    }
    if (intrinsics.expect(self.pos != chunk.end, false)) {
        // Reading beyond the chunk is never good - but sometimes not fully reading
        // a chunk is fine so ignore the opposite case.
        if (intrinsics.expect(self.pos > chunk.end, false)) {
            return .ReaderError
        }
    }
    self.pos = chunk.end
    return .None
}

close_form :: proc (self: ^Reader, tag: Tag) -> Error {
    return close_chunk(self, tag)
}

read_string_to :: proc (self: ^Reader, str: []u8) -> Error {
    stack_curr := self.stack_next
    if (intrinsics.expect(stack_curr == 0, false)) {
        return .StackExhausted
    }
    stack_curr -= 1
    node := &self.stack[stack_curr]

    data := self.data;
    pos := self.pos;
    write_pos := 0;
    for data[pos] != 0 {
        str[write_pos] = data[pos];
        pos += 1;
        write_pos += 1;
    }
    self.pos = pos + 1;
    return .None;

   //start := self.pos
   //length_minus_one := node.end - 1
   //data := self.data
   //pos := self.pos
   //pos += cast(u32)strlen_fast(&data[pos], cast(int)node.end)
   //// skip null character
   //self.pos = pos + 1
   //length := self.pos - start
   //if (intrinsics.expect(length > cast(u32)len(str), false)) {
   //    return .DestBufferTooSmall
   //}
   //mem.copy(&str[0], &data[start], cast(int)length)
   //return .None
}
