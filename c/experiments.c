#include "iff.h"

#define ae_length_of(x) ((sizeof(x) / sizeof(0 [x])) / ((size_t)(!(sizeof(x) % sizeof(0 [x])))))

// No branch prediction intrinsic for MSVC - does not really matter
// for general development but for release (in the true sense) builds
// using Clang is advisable.

#if defined(__GNUC__) || defined(__llvm__)
#define ae_likely(x) (__builtin_expect(!!(x), 1))
#define ae_unlikely(x) (__builtin_expect(!!(x), 0))
#else
#define ae_likely(x) (x)
#define ae_unlikely(x) (x)
#endif

#ifdef __cplusplus
#define check_iff_result(result)                           \
{ \
iff_result = result; \
if (iff_result != IffResult_Ok) [[unlikely]] { \
    return iff_result; \
} \
}
#else
#define check_iff_result(result)                           \
    if (ae_unlikely((iff_result = (result)) != IffResult_Ok)) \
        return iff_result;
#endif

#undef check_iff_result
#define check_iff_result(result) result

IffResult read_asht(IffReader *iff)
{
    IffResult iff_result = { };

    uint8_t string_data[256];
    String8 str_buffer = { .str = &string_data[0], .size = ae_length_of(string_data) };

    check_iff_result(iff_open_form(iff, ae_iff_tag("ATSH")));
    check_iff_result(iff_open_form(iff, ae_iff_tag("INFO")));
    check_iff_result(iff_open_chunk(iff, ae_iff_tag("DATA")));
    uint32_t perm_count = 0;
    check_iff_result(iff_read(iff, &perm_count, sizeof(perm_count)));
    check_iff_result(iff_close_chunk(iff, ae_iff_tag("DATA")));

    uint32_t i;
    for (i = 0; i < perm_count; ++i) {
        check_iff_result(iff_open_chunk(iff, ae_iff_tag("PERM")));
        uint32_t flags = 0, num_defs = 0;
        u64 hash_low = 0, hash_high = 0;
        check_iff_result(iff_read(iff, &flags, sizeof(flags)));
        check_iff_result(iff_read_string(iff, &str_buffer));
        check_iff_result(iff_read(iff, &hash_low, sizeof(hash_low)));
        check_iff_result(iff_read(iff, &hash_high, sizeof(hash_high)));
        check_iff_result(iff_read(iff, &num_defs, sizeof(num_defs)));

        size_t j;
        for (j = 0; j < num_defs; ++j) {
            check_iff_result(iff_read_string(iff, &str_buffer)); // key
            check_iff_result(iff_read_string(iff, &str_buffer)); // value
        }
        check_iff_result(iff_close_chunk(iff, ae_iff_tag("PERM")));
    }
    check_iff_result(iff_close_form(iff, ae_iff_tag("INFO")));

    check_iff_result(iff_open_form(iff, ae_iff_tag("BLBS")));
    for (i = 0; i < perm_count; ++i) {
        check_iff_result(iff_open_chunk(iff, ae_iff_tag("BLOB")));
        check_iff_result(iff_close_chunk(iff, ae_iff_tag("BLOB")));
    }
    check_iff_result(iff_close_form(iff, ae_iff_tag("BLBS")));
    check_iff_result(iff_close_form(iff, ae_iff_tag("ATSH")));
    return iff_result;
}

int main()
{
    platform_file_t file = platform_file_open("test.iff", FILE_OPEN_MODE_READ, FILE_OPEN_FLAGS_EXISTING);
    if (file.handle) {
        uint32_t file_size = (uint32_t)platform_file_size(file);
        uint8_t *data = (uint8_t *)astris_alloc(&allocator, platform_file_size(file));
        platform_file_read(file, data, file_size);

        size_t N = 1000000;
        u64 start = timer_get_raw_ticks();
        for (size_t n = 0; n < N; ++n) {
            IffReader iff = {
                .data_len = file_size,
                .data = data,
            };
            IffResult err;
            if ((err = read_asht(&iff)) != IffResult_Ok) {
                log_info("Iff error: %d", err)
            }
        }

        log_info("Iff: %f", timer_get_elapsed_ms(start));
    }
}