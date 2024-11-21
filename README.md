# new-lang-iff-test

Exploring some of the new 'better C/C++' languages for IFF file parsing.

# Performance

Comparing language performance is questionable, but that said, all of these languages should perform about the same, being LLVM based (at least in optimized builds).

I observed exactly this for c/Zig/Odin.

Jai I can not compile, but have no reason to believe it would be that different assuming similar underlying LLVM version. I couldn't find any evidence of it having branch prediction hints yet, so the error handling may slow it down.