// SPDX-FileCopyrightText: 2024 James Webb
// SPDX-License-Identifier: MIT
// This notice is not to be removed.

const std = @import("std");
const builtin = @import("builtin");
// const eop = @import("end_of_page_allocator.zig");
const iff = @import("iff.zig");

const tag_ATSH: u32 = 1213420609;
const tag_INFO: u32 = 1330007625;
const tag_DATA: u32 = 1096040772;
const tag_PERM: u32 = 1297237328;
const tag_BLOB: u32 = 1112493122;
const tag_BLBS: u32 = 1396853826;

noinline fn read_asht(reader: *iff.Reader) iff.Error!void {
    var struct_data: [256]u8 = undefined;
    try reader.open_form(tag_ATSH); // 12
    try reader.open_form(tag_INFO); // 24
    try reader.open_chunk(tag_DATA); // 32
    const permCount: u32 = try reader.read(u32); // 36
    try reader.close_chunk(tag_DATA);

    for (0..permCount) |_| {
        try reader.open_chunk(tag_PERM);
        const flags: u32 = try reader.read(u32); // 40
        _ = try reader.read_string_to(&struct_data); // model
        const hash_low: u64 = try reader.read(u64);
        const hash_high: u64 = try reader.read(u64);
        const num_defs: u32 = try reader.read(u32);
        _ = hash_high;
        _ = hash_low;
        _ = flags;

        for (0..num_defs) |_| {
            _ = try reader.read_string_to(&struct_data); // key
            _ = try reader.read_string_to(&struct_data); // value
        }
        try reader.close_chunk(tag_PERM);
    }
    try reader.close_form(tag_INFO);

    try reader.open_form(tag_BLBS);
    for (0..permCount) |_| {
        try reader.open_chunk(tag_BLOB);
        try reader.close_chunk(tag_BLOB);
    }
    try reader.close_form(tag_BLBS);
    try reader.close_form(tag_ATSH);
}

fn test_iff(allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().openFile(
        "../test.iff",
        .{ .mode = .read_only },
    );
    const file_content = try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    file.close();
    defer allocator.free(file_content);
    std.debug.print("IFF len: ({})\n", .{file_content.len});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var timer: std.time.Timer = try std.time.Timer.start();
    const n: u64 = 1000000;
    for (0..n) |_| {
        var err_buffer: [256]u8 = undefined;
        err_buffer[0] = 0;
        var reader = iff.Reader.init(file_content, &err_buffer);
        read_asht(&reader) catch {
            // const err_slice: [*:0]const u8 = @ptrCast(&err_buffer);
            // const _ = std.mem.len(err_slice);
            // log("IFF error [{}]: {s}\n", .{ err, err_buffer[0..err_length] });
        };
    }
    const elapsed: f32 = @as(f32, @floatFromInt(timer.read())) / 1000000.0;
    std.debug.print("IFF parse time: {d:.6}\n", .{elapsed});
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    try test_iff(allocator);
}
