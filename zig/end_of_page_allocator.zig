// SPDX-FileCopyrightText: 2024 James Webb
// SPDX-License-Identifier: MIT
// This notice is not to be removed.

const std = @import("std");
const builtin = @import("builtin");

const AllocationInfo = struct {
    base: *anyopaque,
    size: u64,
    // Some extra padding to allow for alignment
    pad: [1024 - 16]u8,
};

comptime {
    if (@sizeOf(AllocationInfo) != 1024) {
        @compileError("AllocationInfo expected to be 1024 bytes.");
    }
}

// A wasteful allocator that can detect out of bounds memory accesses for debugging.
// By allocating the memory to align with the end of a page, writing to the next address after
// the allocation will cause a page fault.
// The idea for this came from https://www.gamedeveloper.com/programming/virtual-memory-tricks
pub const EndOfPageAllocator = struct {
    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn align_down(value: [*]u8, alignment: u64) [*]u8 {
        return @ptrFromInt((@intFromPtr(value) / alignment) * alignment);
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = ret_addr;

        const dw_page_size: std.os.windows.DWORD = 4 * 1024;
        const pages: u64 = (@sizeOf(AllocationInfo) + len + dw_page_size - 1) / dw_page_size;
        const base_opaque = std.os.windows.VirtualAlloc(null, pages * dw_page_size, std.os.windows.MEM_RESERVE, std.os.windows.PAGE_NOACCESS) catch return null;
        const base: [*]u8 = @ptrCast(base_opaque);

        const offset: u64 = pages * dw_page_size - len;
        const offset_ptr = align_down(@as([*]u8, base) + offset, ptr_align);

        _ = std.os.windows.VirtualAlloc(offset_ptr - @sizeOf(AllocationInfo), @sizeOf(AllocationInfo) + len, std.os.windows.MEM_COMMIT, std.os.windows.PAGE_READWRITE) catch return null;
        const alloc_info: *AllocationInfo = @alignCast(@ptrCast(offset_ptr - @sizeOf(AllocationInfo)));
        alloc_info.*.base = base;
        alloc_info.*.size = len;
        return @ptrCast(base + offset);
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_old_align_u8: u8, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = ret_addr;
        _ = new_len;
        _ = log2_old_align_u8;
        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = ctx;
        _ = ret_addr;
        _ = buf_align;
        const alloc_info: *AllocationInfo = @ptrFromInt(@intFromPtr(&buf[0]) - @sizeOf(AllocationInfo));
        std.os.windows.VirtualFree(alloc_info.*.base, 0, std.os.windows.MEM_RELEASE);
    }
};
