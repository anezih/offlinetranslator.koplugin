#!/usr/bin/env sh
set -eu

CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
CHECKOUTS="$CARGO_HOME_DIR/git/checkouts"

if [ ! -d "$CHECKOUTS" ]; then
    exit 0
fi

find "$CHECKOUTS" -path '*/vendor/slimt/slimt/Aligned.cc' -print | while IFS= read -r aligned_cc; do
    slimt_dir=$(dirname "$aligned_cc")
    arena_cc="$slimt_dir/Arena.cc"
    if [ ! -f "$arena_cc" ]; then
        continue
    fi

    if ! grep -q 'posix_memalign(&p, alignment, aligned_size)' "$aligned_cc"; then
        perl -0pi -e 's/return aligned_alloc\(alignment, aligned_size\);/#if defined(__ANDROID__) \&\& __ANDROID_API__ < 28\n  void* p = nullptr;\n  if (posix_memalign(\&p, alignment, aligned_size) != 0) {\n    return nullptr;\n  }\n  return p;\n#else\n  return aligned_alloc(alignment, aligned_size);\n#endif/' "$aligned_cc"
    fi

    if ! grep -q 'allocate_chunk(size_t cap)' "$arena_cc"; then
        perl -0pi -e 's/thread_local Arena\* g_active_arena = nullptr;\n/thread_local Arena* g_active_arena = nullptr;\n\nuint8_t* allocate_chunk(size_t cap) {\n#if defined(__ANDROID__) \&\& __ANDROID_API__ < 28\n  void* p = nullptr;\n  if (posix_memalign(\&p, kAlignWidth, cap) != 0) {\n    return nullptr;\n  }\n  return static_cast<uint8_t*>(p);\n#else\n  return static_cast<uint8_t*>(std::aligned_alloc(kAlignWidth, cap));\n#endif\n}\n/' "$arena_cc"
    fi
    perl -0pi -e 's/#else\n  return allocate_chunk\(cap\);\n#endif/#else\n  return static_cast<uint8_t*>(std::aligned_alloc(kAlignWidth, cap));\n#endif/' "$arena_cc"
    perl -0pi -e 's/: data\(static_cast<uint8_t\*>\(std::aligned_alloc\(kAlignWidth, cap\)\),/: data(allocate_chunk(cap),/' "$arena_cc"
done
