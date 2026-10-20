Vendored sqlite-vec 0.1.9 from the official amalgamation release:
https://github.com/asg017/sqlite-vec/releases/tag/v0.1.9

Archive: sqlite-vec-0.1.9-amalgamation.tar.gz
SHA-256: 3acd67cb4aff080c7050926fd3cf8227905fe5b7ee3829d8ee5024ab1283cf61
Upstream commit: e9f598abfa0c06b328d8fe5da9c3760cce74be10

The upstream C source and header are unchanged. Compiled statically against the
system SQLite with SQLITE_CORE and SQLITE_VEC_STATIC. VecExtension.c enables
NEON on supported ARM targets while retaining the scalar path for other targets.
MIT/Apache-2.0 dual license; both license files are included.
