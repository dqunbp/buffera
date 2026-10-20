// Keep upstream unchanged and enable NEON only on targets that provide it.
#if defined(__ARM_NEON)
#define SQLITE_VEC_ENABLE_NEON
#endif
#include "sqlite-vec.c"
