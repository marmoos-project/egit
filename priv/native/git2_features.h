/*
 * libgit2 build configuration for the Mob plugin build (priv/mob_plugin.exs),
 * standing in for the header libgit2's CMake generates. Taken from a CMake
 * configure of libgit2 v1.9.7 for Android arm64, API 28, with:
 *
 *   -DUSE_THREADS=ON -DUSE_SSH=OFF -DUSE_HTTPS=OFF -DUSE_NTLMCLIENT=OFF
 *   -DUSE_GSSAPI=OFF -DUSE_AUTH_NEGOTIATE=OFF -DUSE_AUTH_NTLM=OFF
 *   -DREGEX_BACKEND=regcomp -DUSE_SHA1=CollisionDetection -DUSE_SHA256=Builtin
 *   -DUSE_BUNDLED_ZLIB=OFF -DUSE_HTTP_PARSER=builtin
 *
 * Only change: GIT_ARCH_64 / GIT_ARCH_32 follow the pointer size, so one header
 * serves every Android ABI. See PLAN.md for how to regenerate it.
 */
#ifndef INCLUDE_features_h__
#define INCLUDE_features_h__

#if !defined(__ANDROID__)
#error "egit's Mob build only supports Android so far (PLAN.md, Phase 2 adds iOS)"
#endif

#define GIT_THREADS 1

#if __SIZEOF_POINTER__ == 8
#define GIT_ARCH_64 1
#else
#define GIT_ARCH_32 1
#endif

#define GIT_USE_NSEC 1
#define GIT_USE_STAT_MTIM 1
#define GIT_USE_FUTIMENS 1

#define GIT_REGEX_REGCOMP

/* No HTTPS yet (PLAN.md, Phase 1), no SSH, no NTLM / GSSAPI. */

#define GIT_HTTPPARSER_BUILTIN 1

#define GIT_SHA1_COLLISIONDETECT 1
#define GIT_SHA256_BUILTIN 1

#define GIT_COMPRESSION_ZLIB 1

/* getentropy(3) is in bionic from API 28, Mob's minimum. */
#define GIT_RAND_GETENTROPY 1

#define GIT_IO_POLL 1
#define GIT_IO_SELECT 1

#endif
