// SPDX-FileCopyrightText: 2024 James Webb
// SPDX-License-Identifier: MIT
// This notice is not to be removed.

package foundation

import "core:fmt"
import "base:runtime"
import "base:intrinsics"
import "core:time"
import "core:mem"
import "core:log"
import "core:os"

tag_ATSH: iff.Tag : 1213420609
tag_INFO: iff.Tag : 1330007625
tag_DATA: iff.Tag : 1096040772
tag_PERM: iff.Tag : 1297237328
tag_BLOB: iff.Tag : 1112493122
tag_BLBS: iff.Tag : 1396853826

test_iff :: proc(reader: ^iff.Reader) -> iff.Error {
    struct_data: [256]u8 = ---
    iff.open_form(reader, tag_ATSH) or_return
    iff.open_form(reader, tag_INFO) or_return
    iff.open_chunk(reader, tag_DATA) or_return
    permCount := iff.read(reader, u32) or_return
    iff.close_chunk(reader, tag_DATA) or_return

    for i in 0 ..< permCount {
        iff.open_chunk(reader, tag_PERM)
        flags := iff.read(reader, u32) or_return
        iff.read_string_to(reader, struct_data[:]) or_return // model
        hash_low := iff.read(reader, u64) or_return
        hash_high := iff.read(reader, u64) or_return
        num_defs := iff.read(reader, u32) or_return
        for j in 0 ..< num_defs {
            iff.read_string_to(reader, struct_data[:]) or_return // key
            iff.read_string_to(reader, struct_data[:]) or_return // value
        }
        iff.close_chunk(reader, tag_PERM)
    }
    iff.close_form(reader, tag_INFO)

    iff.open_form(reader, tag_BLBS)
    for i in 0 ..< permCount {
        iff.open_chunk(reader, tag_BLOB) or_return
        iff.close_chunk(reader, tag_BLOB) or_return
    }
    iff.close_form(reader, tag_BLBS) or_return
    iff.close_form(reader, tag_ATSH) or_return
    return .None
}

test_iff_outer :: proc() {
    foo := #load("../test.iff")

    N := 1000000;
    stopwatch: time.Stopwatch
    time.stopwatch_reset(&stopwatch)
    time.stopwatch_start(&stopwatch)
    for i in 0 ..< N {
        reader: iff.Reader = {
            data = foo,
        }
        test_iff(&reader)
    }
    time.stopwatch_stop(&stopwatch)
    fmt.println("IFF stress time(ms): ", time.duration_milliseconds(time.stopwatch_duration(stopwatch)))
}

main :: proc() {
    test_iff_outer()
}
