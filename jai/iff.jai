// SPDX-FileCopyrightText: 2024 James Webb
// SPDX-License-Identifier: MIT
// This notice is not to be removed.

IffTag :: u32;
tag_FORM: u32 : 1297239878;

IffReaderStackNode :: struct {
    start, end : u32;
    tag:         IffTag;
};

IffFormHeader :: struct {
    form, size: u32;
    tag: IffTag;
};

IffChunkHeader :: struct {
    tag : IffTag;
    size: u32;
};

IffReader :: struct {
    pos:          u32;
    data:         []u8;
    stack:        [64]IffReaderStackNode;
    stack_next:   u32;
    error_buffer: []u8;
};

IffError :: enum u32 {
    None;
    StackExhausted;
    ReadPastEof;
    UnexpectedTag;
    StackUnderflow;
    ReaderError;
    AllocationError;
    DestBufferTooSmall;
};

strlen_fast :: inline (str: *u8, max_len: int) -> int {
    ptr: *u64 = cast(*u64)str;
    i: int = 0;
    while i + 7 < max_len {
        chunk: u64 = <<ptr;
        ptr = ptr + 1;
        if (((chunk - 0x0101010101010101) & ~chunk & 0x8080808080808080) != 0) {
            c: *u8 = cast(*u8)(ptr - 1);
            while <<c != 0 {
                c = c + 1;
            }
            return c - str;
        }
        i += 8;
    }
    c: *u8 = str;
    while i < max_len && <<c != 0 {
        i += 1;
        c = c + 1;
    }
    return i;
}

iff_read_internal :: inline (self: *IffReader, $T: Type) -> (value: T, err: IffError) {
    if (size_of(T) > (self.data.count - self.pos)) {
        default : T;
        return default, .ReadPastEof;
    }
    result: T = ---;
    memcpy(*result, *self.data[self.pos], size_of(T));
    self.pos += size_of(T);
    return result, .None;
}

iff_read :: inline (self: *IffReader, $T: Type) -> (value: T, err: IffError) {
    stack_curr := self.stack_next;
    if (stack_curr == 0) {        
        default : T;
        return default, .StackExhausted;
    }
    stack_curr -= 1;
    node := *self.stack[stack_curr];
    if (size_of(T) > (node.end - self.pos)) {
        default : T;
        return default, .ReadPastEof;
    }
    result: T;
    memcpy(*result, *self.data[self.pos], size_of(T));
    self.pos += size_of(T);
    return result, .None;
}

iff_read_raw :: inline (self: *IffReader, value: *void, size: int) -> IffError {
    stack_curr := self.stack_next;
    if (stack_curr == 0) {
        return .StackExhausted;
    }
    stack_curr -= 1;
    node := *self.stack[stack_curr];
    if (size > (node.end - self.pos)) {
        return .ReadPastEof;
    }
    memcpy(value, *self.data[self.pos], size);
    self.pos += cast(u32)(size);
    return .None;
}

iff_open_form :: inline (self: *IffReader, tag: IffTag) -> IffError {
    header, err := iff_read_internal(self, IffFormHeader);
    if (err != .None) {
        return err;
    }
    header.size = byte_swap(header.size);
    if (header.form != tag_FORM) {
        return .UnexpectedTag;
    }
    if (header.tag != tag) {
        return .UnexpectedTag;
    }
    if (self.stack_next >= self.stack.count) {
        return .StackExhausted;
    }
    self.stack[self.stack_next].tag = tag;
    self.stack[self.stack_next].start = self.pos;
    self.stack[self.stack_next].end = self.pos + header.size - 4;
    self.stack_next += 1;
    return .None;
}

iff_open_chunk :: inline (self: *IffReader, tag: IffTag) -> IffError {
    header, err := iff_read_internal(self, IffChunkHeader);
    if (err != .None) {
        return err;
    }
    header.size = byte_swap(header.size);
    if (header.tag != tag) {
        return .UnexpectedTag;
    }
    if (self.stack_next >= cast(u32)self.stack.count) {
        return .StackExhausted;
    }
    self.stack[self.stack_next].tag = tag;
    self.stack[self.stack_next].start = self.pos;
    self.stack[self.stack_next].end = self.pos + header.size;
    self.stack_next += 1;
    return .None;
}

iff_close_chunk :: inline (self: *IffReader, tag: IffTag) -> IffError {
    if (self.stack_next <= 0) {
        return .StackUnderflow;
    }
    self.stack_next -= 1;
    chunk := *self.stack[self.stack_next];
    if (chunk.tag != tag) {
        return .ReaderError;
    }
    if (self.pos != chunk.end) {
        // Reading beyond the chunk is never good - but sometimes not fully reading
        // a chunk is fine so ignore the opposite case.
        if (self.pos > chunk.end) {
            return .ReaderError;
        }
    }
    self.pos = chunk.end;
    return .None;
}

iff_close_form :: inline (self: *IffReader, tag: IffTag) -> IffError {
    return iff_close_chunk(self, tag);
}

iff_read_string_to :: inline (self: *IffReader, str: *string) -> IffError {
    stack_curr := self.stack_next;
    if (stack_curr == 0) {
        return .StackExhausted;
    }
    stack_curr -= 1;
    node_end := cast(int)self.stack[stack_curr].end;

    data := self.data;
    pos := self.pos;
    write_pos := 0;
    while data[pos] != 0 && pos < node_end {
        str.data[write_pos] = data[pos];
        write_pos += 1;
        pos += 1;
    }
    str.count = write_pos;
    self.pos = pos + 1;
    return .None;

   //start := self.pos;
   //data := self.data;
   //pos := self.pos;
   //
   //pos += cast(u32)strlen_fast(*data[pos], node_end);

   //// skip null character
   //self.pos = pos + 1;
   //length := self.pos - start;
   //if (length > cast(u32)str.count) {
   //    return .DestBufferTooSmall;
   //}
   //memcpy(*str[0], *data[start], cast(int)length);
   //return .None;
}