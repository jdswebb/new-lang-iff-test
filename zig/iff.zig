// SPDX-FileCopyrightText: 2024 James Webb
// SPDX-License-Identifier: MIT
// This notice is not to be removed.

const std = @import("std");

pub inline fn make_tag(comptime tag: *const [4]u8) u32 {
    comptime {
        if (tag.len != 4) {
            @compileError("IFF tag must be 4 characters");
        }
        for (tag) |char| {
            if (!is_valid_tag_char(char)) {
                @compileError("Invalid IFF tag character");
            }
        }
        return (@as(u32, tag[3]) << 24 | @as(u32, tag[2]) << 16 | @as(u32, tag[1]) << 8 | @as(u32, tag[0]));
    }
}

pub inline fn is_valid_tag_char(value: u8) bool {
    return (value >= 'a' and value <= 'z') or
        (value >= 'A' and value <= 'Z') or
        (value >= '0' and value <= '9') or
        value == ' ';
}

pub inline fn is_valid(tag: u32) bool {
    return is_valid_tag_char((tag >> 24) & 0xFF) and
        is_valid_tag_char((tag >> 16) & 0xFF) and
        is_valid_tag_char((tag >> 8) & 0xFF) and
        is_valid_tag_char((tag >> 0) & 0xFF);
}

const StackNode = struct {
    start: u32 = 0,
    end: u32 = 0,
    tag: u32 = 0,
};

const FormHeader = extern struct {
    form: u32,
    size: u32,
    tag: u32,
};

const ChunkHeader = extern struct {
    tag: u32,
    size: u32,
};

pub const Error = error{
    StackExhausted,
    ReadPastEof,
    UnexpectedTag,
    StackUnderflow,
    ReaderError,
    AllocationError,
    DestBufferTooSmall,
};
const form_tag: u32 = make_tag("FORM");

comptime {
    if (@sizeOf(FormHeader) != 12) {
        @compileError("Wrong FormHeader size!");
    }
    if (@sizeOf(ChunkHeader) != 8) {
        @compileError("Wrong ChunkHeader size!");
    }
}

pub const Reader = struct {
    const Self = @This();

    pub fn init(data_in: []const u8, error_buffer: []u8) Self {
        return .{
            .data = data_in,
            .error_buffer = error_buffer,
        };
    }

    fn set_error(self: *Self, comptime fmt: []const u8, args: anytype) void {
        var fba = std.heap.FixedBufferAllocator.init(self.error_buffer);
        var string = std.ArrayList(u8).init(fba.allocator());
        std.fmt.format(string.writer(), fmt, args) catch {};
        std.fmt.format(string.writer(), " at offset {}. Stack trace:", .{self.pos}) catch {};

        const spaces = comptime [_]u8{' '} ** 256;
        for (0..self.stack_next) |i| {
            std.fmt.format(string.writer(), "\n{s}{s} {} {}", .{
                spaces[0 .. (i + 1) * 2],
                tag_to_string(self.stack[i].tag),
                self.stack[i].start,
                self.stack[i].end,
            }) catch {};
        }
        string.append(0) catch {
            string.items[string.items.len - 1] = 0;
        };
    }

    fn tag_to_string(tag: u32) [4]u8 {
        var buffer: [4]u8 = undefined;
        buffer[3] = @intCast((tag >> 24) & 0xFF);
        buffer[2] = @intCast((tag >> 16) & 0xFF);
        buffer[1] = @intCast((tag >> 8) & 0xFF);
        buffer[0] = @intCast(tag & 0xFF);
        return buffer;
    }

    pub fn open_form(self: *Self, tag: u32) Error!void {
        var header = try read_internal(self, FormHeader);
        header.size = @byteSwap(header.size);
        if (header.form != form_tag) {
            @branchHint(.unlikely);
            self.set_error("Expected 'FORM' but found '{s}'", .{
                tag_to_string(header.form),
            });
            return Error.UnexpectedTag;
        }
        if (header.tag != tag) {
            @branchHint(.unlikely);
            self.set_error("Expected 'FORM' with tag '{s}' but found '{s}'", .{
                tag_to_string(tag),
                tag_to_string(header.tag),
            });
            return Error.UnexpectedTag;
        }
        if (self.stack_next >= self.stack.len) {
            return Error.StackExhausted;
        }
        self.stack[self.stack_next] = .{
            .tag = tag,
            .start = self.pos,
            .end = self.pos + header.size - 4,
        };
        self.stack_next += 1;
    }

    pub fn open_chunk(self: *Self, tag: u32) Error!void {
        var header = try read_internal(self, ChunkHeader);
        header.size = @byteSwap(header.size);
        if (header.tag != tag) {
            @branchHint(.unlikely);
            self.set_error("Expected chunk tag '{s}' but found '{s}'", .{
                tag_to_string(tag),
                tag_to_string(header.tag),
            });
            return Error.UnexpectedTag;
        }
        if (self.stack_next >= self.stack.len) {
            return Error.StackExhausted;
        }
        self.stack[self.stack_next] = .{
            .tag = tag,
            .start = self.pos,
            .end = self.pos + header.size,
        };
        self.stack_next += 1;
    }

    pub fn close_form(self: *Self, tag: u32) Error!void {
        try close_chunk(self, tag);
    }

    pub fn close_chunk(self: *Self, tag: u32) Error!void {
        if (self.stack_next <= 0) {
            return Error.StackUnderflow;
        }
        self.stack_next -= 1;
        const chunk = self.stack[self.stack_next];
        if (chunk.tag != tag) {
            @branchHint(.unlikely);
            self.set_error("Tag mismatch, found '{s}' expected '{s}'", .{
                tag_to_string(chunk.tag),
                tag_to_string(tag),
            });
            return Error.ReaderError;
        }
        if (self.pos != chunk.end) {
            // Reading beyond the chunk is never good - but sometimes not fully reading
            // a chunk is fine so ignore the opposite case.
            if (self.pos > chunk.end) {
                @branchHint(.unlikely);
                self.set_error("Read beyond end of chunk '{s}'", .{
                    tag_to_string(tag),
                });
                return Error.ReaderError;
            }
        }
        self.pos = chunk.end;
    }

    // Get the number of unread children in the currently open chunk.
    pub fn get_remaining_children(self: *const Self) u32 {
        if (self.stack.items.len == 0) {
            return 0;
        }
        var curr = self.pos;
        const last_chunk = self.stack.getLast();
        if ((curr < last_chunk.start) or (curr > last_chunk.end)) {
            return 0;
        }
        var count: u32 = 0;
        while (curr < last_chunk.end) {
            var len: u32 = undefined;
            @memcpy(std.mem.asBytes(&len), self.data[curr + 4 .. curr + 4 + @sizeOf(u32)]);
            len = @byteSwap(len);
            curr += len + 8;
            count += 1;
        }
        return count;
    }

    // Reads a value directly from the underlying buffer, ignoring chunk structure.
    fn read_internal(self: *Self, comptime T: type) Error!T {
        if (@sizeOf(T) > (self.data.len - self.pos)) {
            @branchHint(.unlikely);
            self.set_error("Tried to read beyond node contents", .{});
            return Error.ReadPastEof;
        }
        var result: T = undefined;
        @memcpy(std.mem.asBytes(&result), self.data[self.pos .. self.pos + @sizeOf(T)]);
        self.pos += @sizeOf(T);
        return result;
    }

    // Reads a value from the current position in the current chunk.
    pub fn read(self: *Self, comptime T: type) Error!T {
        var stack_curr = self.stack_next;
        if (stack_curr == 0) {
            @branchHint(.unlikely);
            self.set_error("Tried to read with no open node", .{});
            return Error.StackExhausted;
        }
        stack_curr -= 1;
        const node = &self.stack[stack_curr];
        if (@sizeOf(T) > (node.end - self.pos)) {
            @branchHint(.unlikely);
            self.set_error("Tried to read beyond node contents", .{});
            return Error.ReadPastEof;
        }
        var result: T = undefined;
        @memcpy(std.mem.asBytes(&result), self.data[self.pos .. self.pos + @sizeOf(T)]);
        self.pos += @sizeOf(T);
        return result;
    }

    // Reads a value from the current position in the current chunk.
    pub fn read_to_raw(self: *Self, dst: *anyopaque, dst_size: usize) Error!void {
        var stack_curr = self.stack_next;
        if (stack_curr == 0) {
            @branchHint(.unlikely);
            self.set_error("Tried to read with no open node", .{});
            return Error.StackExhausted;
        }
        stack_curr -= 1;
        const node = &self.stack[stack_curr];
        if (dst_size > (node.end - self.pos)) {
            @branchHint(.unlikely);
            self.set_error("Tried to read beyond node contents", .{});
            return Error.ReadPastEof;
        }
        const ptr = @as([*]u8, @ptrCast(@alignCast(dst)));
        @memcpy(ptr[0..dst_size], self.data[self.pos .. self.pos + dst_size]);
        self.pos += @intCast(dst_size);
    }

    // Reads a value from the current position in the current chunk.
    pub fn read_to(self: *Self, comptime T: type, value: *T) Error!void {
        var stack_curr = self.stack_next;
        if (stack_curr == 0) {
            @branchHint(.unlikely);
            self.set_error("Tried to read with no open node", .{});
            return Error.StackExhausted;
        }
        stack_curr -= 1;
        const node = &self.stack[stack_curr];
        if (@sizeOf(T) > (node.end - self.pos)) {
            @branchHint(.unlikely);
            self.set_error("Tried to read beyond node contents", .{});
            return Error.ReadPastEof;
        }
        @memcpy(std.mem.asBytes(value), self.data[self.pos .. self.pos + @sizeOf(T)]);
        self.pos += @sizeOf(T);
    }

    // Reads a sentinel terminated string from the current position in the current chunk.
    pub fn read_string(self: *Self, allocator: std.mem.Allocator) Error![]u8 {
        var stack_curr = self.stack_next;
        if (stack_curr == 0) {
            @branchHint(.unlikely);
            self.set_error("Tried to read with no open node", .{});
            return Error.StackExhausted;
        }
        stack_curr -= 1;
        const node = &self.stack[stack_curr];

        const start: u32 = self.pos;
        const data = self.data;
        const last = node.end - 1;
        var pos = self.pos;
        while ((data[self.pos] != 0) and (pos < last)) {
            pos += 1;
        }
        // skip null character
        self.pos = pos + 1;
        const length = self.pos - start;
        var string = allocator.alloc(u8, length) catch return Error.AllocationError;
        @memcpy(string[0..], data[start..self.pos]);
        return string;
    }

    // Reads a sentinel terminated string from the current position in the current chunk.
    pub fn read_string_to(self: *Self, str: []u8) Error!void {
        var stack_curr = self.stack_next;
        if (stack_curr == 0) {
            @branchHint(.unlikely);
            self.set_error("Tried to read with no open node", .{});
            return Error.StackExhausted;
        }
        stack_curr -= 1;
        const node = &self.stack[stack_curr];

        const start: u32 = self.pos;
        const length_minus_one = node.end - 1;
        const data = self.data;
        var pos = self.pos;
        while ((data[pos] != 0) and (pos < length_minus_one)) {
            pos += 1;
        }
        // skip null character
        self.pos = pos + 1;
        const length = self.pos - start;
        if (length > str.len) {
            @branchHint(.unlikely);
            return Error.DestBufferTooSmall;
        }
        @memcpy(str[0..length], data[start..self.pos]);
    }

    pos: u32 = 0,
    data: []const u8 = undefined,
    stack: [64]StackNode = [_]StackNode{.{}} ** 64,
    stack_next: u32 = 0,
    error_buffer: []u8 = undefined,
};
