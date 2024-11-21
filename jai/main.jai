// SPDX-FileCopyrightText: 2024 James Webb
// SPDX-License-Identifier: MIT
// This notice is not to be removed.

tag_ATSH: IffTag : 1213420609;
tag_INFO: IffTag : 1330007625;
tag_DATA: IffTag : 1096040772;
tag_PERM: IffTag : 1297237328;
tag_BLOB: IffTag : 1112493122;
tag_BLBS: IffTag : 1396853826;

test_iff :: (reader: *IffReader) -> IffError {
    struct_data: [256]u8 = ---;
    str : string = ---;
    str.count = 0;
    str.data = struct_data.data;
    iff_open_form(reader, tag_ATSH);
    iff_open_form(reader, tag_INFO);
    iff_open_chunk(reader, tag_DATA);
    permCount := iff_read(reader, u32);
    iff_close_chunk(reader, tag_DATA);
    for i: 0 .. permCount - 1 {
        iff_open_chunk(reader, tag_PERM);
        flags := iff_read(reader, u32);
        iff_read_string_to(reader, *str); // model
        hash_low := iff_read(reader, u64);
        hash_high := iff_read(reader, u64);
        num_defs := iff_read(reader, u32);
        for j: 0 .. num_defs - 1 {
            iff_read_string_to(reader, *str); // key
            iff_read_string_to(reader, *str); // value
        }
        iff_close_chunk(reader, tag_PERM);
    }
    iff_close_form(reader, tag_INFO);

    iff_open_form(reader, tag_BLBS);
    for i: 0 .. permCount - 1 {
        iff_open_chunk(reader, tag_BLOB);
        iff_close_chunk(reader, tag_BLOB);
    }
    iff_close_form(reader, tag_BLBS);
    iff_close_form(reader, tag_ATSH);

    return .None;
}