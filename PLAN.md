# egit as a Mob plugin

Goal: make this fork of [saleyn/egit](https://github.com/saleyn/egit) usable as a
[Mob](https://hexdocs.pm/mob) plugin, so a Mob app gets libgit2 on Android and iOS
by adding one dependency, with no system libgit2 on the device.

## Approach

mob_dev builds egit itself, from source, as a `lang: :cpp_archive` plugin NIF
(`MobDev.Plugin.CppArchive`). One manifest entry lists `c_src/git.cpp` plus the
C sources of libgit2 and mbedTLS; mob_dev cross-compiles them into `libgit.a` for
every target it builds (Android arm64 / arm32 / x86_64, iOS device / simulator),
checks that `git_nif_init` is exported, adds it to the driver table and
static-links it into the app.

Not chosen:

- **Prebuilt archives from elixir-runtimes** (`priv/nifs/egit.mk`). A Mob plugin
  cannot link prebuilt `.a` files without a mob_dev change, elixir-runtimes is
  Android-only, and its OpenSSL 3.6 would clash with the libcrypto 3.4.0 already
  in Mob's OTP. Its libgit2 settings are reused below.
- **Project-level `:static_nifs`** in the app's `mob.exs`. Meant for NIFs whose
  sources live in the app's `c_src/` or `native/`; egit belongs in its own
  package.

The fork stays mergeable with upstream: changes are additive (new files), and
the few edits to upstream files are small and worth proposing upstream.

## Decisions

| Topic | Choice | Reason |
|---|---|---|
| Package / plugin name | `:egit` | Matches the repo and `src/egit.app.src`; Mix requires the dep name to equal the app name |
| NIF module | `:git`, init symbol `git_nif_init` | egit's `ERL_NIF_INIT(git, …)`; set with `-DSTATIC_ERLANG_NIF_LIBNAME=git` (not `-DSTATIC_ERLANG_NIF`, see mob_dev's NIF guide) |
| libgit2 | v1.9.7 (`vendor/libgit2`) | Same version as elixir-runtimes |
| HTTPS, Android | mbedTLS **3.6 LTS** | No OpenSSL in the binary to clash with Mob's libcrypto 3.4.0 |
| HTTPS, iOS | SecureTransport | System TLS and trust store; no extra sources. Needs the `Security` framework |
| SHA1 / SHA256 | libgit2 built-in (collision-detecting SHA1) | No crypto library dependency |
| Regex | `regcomp` | Bundled PCRE2 clashes with ERTS' `libepcre.a` (same as elixir-runtimes) |
| zlib | system `-lz` | Both Mob app builds already link it |
| SSH | off | libssh2 needs its own crypto backend. Revisit after v1 |
| NTLM / Negotiate | off | Not needed; drops `deps/ntlmclient` |
| `std::format` | `-DHAVE_FORMAT -DHAVE_SRCLOC`, `-std=c++20` | NDK and Xcode libc++ have both; the `c_src/fmt` submodule is not used |

### mbedTLS must be 3.6, not 4.x

`vendor/mbedtls` is currently at `mbedtls-4.2.0`. libgit2 v1.9.7's
`src/libgit2/streams/mbedtls.c` uses `mbedtls_ctr_drbg_*` and
`mbedtls_entropy_*`, which mbedTLS 4 moved out of its public API (into
TF-PSA-Crypto, a nested submodule). Pin the submodule to the latest
`mbedtls-3.6.*` tag instead. 3.6 needs no nested submodule to build the library.

## Target layout

```
egit/
  mix.exs                      new   Mix project, compiles src/git.erl
  rebar.config, Makefile       upstream, unchanged (host .so builds)
  src/git.erl                  edit  tolerant on_load, set_ssl_cert_locations/1
  c_src/git.cpp                edit  set_ssl_cert_locations NIF
  lib/egit/                    new   Elixir API for Mob screens (MobGit-style async)
  lib/mix/tasks/egit.gen_sources.ex   new   regenerates the source list
  priv/mob_plugin.exs          new   cpp_archive manifest
  priv/native/git2_features.h  new   libgit2 build config, per-platform #ifdefs
  priv/native/egit_mbedtls_config.h   new   mbedTLS config (MBEDTLS_CONFIG_FILE)
  priv/native/sources.exs      generated   source list read by the manifest
  vendor/libgit2               submodule v1.9.7
  vendor/mbedtls               submodule mbedtls-3.6.x
```

## Phases

### Phase 0: spike (Android arm64, no HTTPS)

Prove that the toolchain path works before building anything reusable.

- [X] Re-pin `vendor/mbedtls` to `mbedtls-3.6.x`.
- [X] Minimal `mix.exs` and `priv/mob_plugin.exs` with one `cpp_archive` entry:
      `git.cpp` plus the libgit2 sources (`src/libgit2`, `src/util`,
      `deps/xdiff`, `deps/llhttp`, builtin and sha1dc hash backends, `unix/`
      only), HTTPS off. The list is in `priv/native/sources.exs`, taken from
      the `compile_commands.json` of the CMake configure below.
- [X] A first `git2_features.h` for Android: threads, regcomp, builtin SHA, no
      HTTPS, no SSH, no NTLM. Copied from the CMake configure below, with
      `GIT_ARCH_64` / `GIT_ARCH_32` switched on pointer size.
- [X] In `marmoos_app`: `{:egit, path: "../egit"}`, `:egit` activated in
      `mob.exs` and listed in `:acknowledge_unsafe_plugins`.
- [X] `libgit.a` builds for `android_arm64` through mob_dev's cpp_archive
      builder: 179 objects, `git_nif_init` defined, every undefined symbol is
      libc / zlib / pthread / libc++ / `enif_*`.
- [X] `mix mob.deploy --native --android` on the Pixel 7 (libgit.a built for
      arm64, arm32 and x86_64), then:
  - [X] `llvm-readelf --dyn-syms` on `libmarmoos_app.so` (arm64) shows
        `git_nif_init` once, exported;
  - [X] `:git` loads on device, i.e. egit's `load_nif(".../priv/git", [])`
        resolves to the static entry, unchanged `on_load`;
  - [X] init, `config_set`, `add`, `commit`, `open`, `status`, `rev_list`,
        `list_branches` on a repo in `/data/user/0/<app>/files/`, over RPC
        from `mix mob.connect`;
  - [X] no duplicate-symbol errors at link time (zlib, PCRE, libc++).

Exit: a commit and `:git.status/1` on a local repo in the app's documents
directory. **Done.**

CMake configure used for `git2_features.h` and `sources.exs` in Phase 0 (NDK
27, from the repo root; the output directory is scratch). Phase 3 replaces it
with `mix egit.gen_sources`:

```sh
NDK=~/Android/Sdk/ndk/27.2.12479018
cmake -S vendor/libgit2 -B /tmp/lg2-android -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF -DBUILD_CLI=OFF \
  -DUSE_THREADS=ON -DUSE_SSH=OFF -DUSE_HTTPS=OFF -DUSE_NTLMCLIENT=OFF \
  -DUSE_GSSAPI=OFF -DUSE_AUTH_NEGOTIATE=OFF -DUSE_AUTH_NTLM=OFF \
  -DREGEX_BACKEND=regcomp -DUSE_SHA1=CollisionDetection -DUSE_SHA256=Builtin \
  -DUSE_BUNDLED_ZLIB=OFF -DUSE_HTTP_PARSER=builtin \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

Outputs: `/tmp/lg2-android/gen_headers/{git2_features,experimental}.h` and
`/tmp/lg2-android/compile_commands.json` (sources and per-directory flags; the
C `cflags` in the manifest are their union).

### Phase 1: HTTPS on Android (mbedTLS)

- [X] Add mbedTLS `library/*.c` (109 files, generated ones included in the
      3.6.7 tag) to the sources, globbed in the manifest, and
      `-DMBEDTLS_CONFIG_FILE="egit_mbedtls_config.h"` to `cflags`.
      `vendor/mbedtls/library` is deliberately not an include dir: its
      `common.h` would shadow libgit2's.
- [X] `egit_mbedtls_config.h`: mbedTLS' default plus `MBEDTLS_THREADING_C` +
      `MBEDTLS_THREADING_PTHREAD`. No size trimming yet (DTLS, server, PSK
      still in).
- [X] `git2_features.h`: `GIT_HTTPS` + `GIT_MBEDTLS`. A CMake reconfigure with
      `-DUSE_HTTPS=mbedTLS` changes only these two defines; the libgit2 source
      list is the same.
- [X] Default CA store compiled in:
      `-DGIT_DEFAULT_CERT_LOCATION="/system/etc/security/cacerts"`, which
      libgit2 loads at `git_libgit2_init()`. It exists on every Android
      version Mob supports.
- [X] `git:set_ssl_cert_locations(File, Path)` (either may be `nil`), wrapping
      `git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, …)`, dirty IO NIF.
      Arity 2 rather than 1, to follow libgit2 (bundle file and/or directory).
- [ ] The Elixir layer calls it once at startup on Android when
      `/apex/com.android.conscrypt/cacerts` exists (Android 14+: updatable CA
      store). Moved to Phase 4.
- [X] Device checks (Pixel 7, Android 17), with the app in the foreground:
  - clone `https://github.com/octocat/Hello-World.git` with the default store
    and again with the APEX store (120 certificates): both OK, ~1 s;
  - `self-signed.badssl.com`: refused, "not correctly signed by the trusted
    CA"; `expired.badssl.com`: refused, "validity has expired".

Sizes: `libgit.a` (arm64) is 4.8 MB; the stripped arm64
`libmarmoos_app.so` is 11.8 MB with egit, libgit2 and mbedTLS in it.

**Android cuts background apps off the network.** With the screen locked or
the app not in front, the app's UID is blocked (`dumpsys netpolicy`:
`blocked=APP_BACKGROUND`), and every DNS lookup fails with "No address
associated with hostname", libgit2's and Erlang's alike. Not an egit bug, but
the Elixir layer must report it clearly and network operations need the app in
the foreground (or a foreground service). See Phase 4.

### Phase 2: iOS (SecureTransport)

- [ ] `git2_features.h`: `GIT_HTTPS` + `GIT_SECURE_TRANSPORT` under
      `__APPLE__`.
- [ ] `ios: %{frameworks: ["Security"]}` in the manifest. `-lz` is already
      linked by the iOS build.
- [ ] mbedTLS stays in the shared source list; nothing references it on iOS, so
      its objects are not pulled from the archive. If the validator accepts
      the same module twice, split into `platform: :android` / `platform: :ios`
      entries instead.
- [ ] `set_ssl_cert_locations/2` is not called on iOS.
- [ ] Simulator and device: same HTTPS clone checks as Phase 1.

### Phase 3: maintainable build

- [X] `mix egit.gen_sources` (`lib/mix/tasks/egit.gen_sources.ex`). Rather
      than hand-written include / exclude rules over `vendor/libgit2`, it runs
      libgit2's own CMake configure for Android arm64 with the plugin's options
      (`@cmake_options` in the task, the single place they are kept), and:
  - writes `priv/native/sources.exs` from `compile_commands.json`;
  - compares CMake's `git2_features.h` with `priv/native/git2_features.h`
    (which stays hand-merged, for every ABI and later iOS) and lists the
    defines to merge;
  - lists libgit2 `-D` flags missing from the manifest's `:cflags`;
  - `--check` writes nothing and fails when `sources.exs` is stale;
    `--ndk PATH` picks the NDK (default: the newest one found), `--keep`
    keeps the CMake build directory.

  mbedTLS needs no list: the manifest globs `vendor/mbedtls/library/*.c`.
  Needs `cmake` and `ninja`. Tested: no-op on the current tree; a removed
  source is reported and restored; a wrong TLS define is reported.
- [X] The CMake command of Phase 0 is superseded by the task.
- [ ] Commit the generated files; after moving `vendor/libgit2`, run
      `mix egit.gen_sources`, merge what it reports, and rebuild on a device.

### Phase 4: Erlang / Elixir API

- [ ] `src/git.erl`: `on_load` returns `ok` when no NIF library is found (as
      the Mob scaffold's stub does), so the module still loads on a host
      without a native build; calls then raise `nif_not_loaded`.
- [ ] Elixir layer for Mob screens:
  - network operations (`clone`, `fetch`, `pull`, `push`) run in a Task and
    report back as messages to the caller, e.g. `{:git, :cloned, repo}` /
    `{:git, :error, op, reason}`, like Mob's device APIs. They block for
    seconds and must not run in a screen process;
  - local operations stay synchronous;
  - at startup on Android, call `git:set_ssl_cert_locations(nil, Dir)` with
    `/apex/com.android.conscrypt/cacerts` when it exists;
  - network operations fail with a DNS error while the app is in the
    background (Phase 1 finding): detect it, report it as such, and retry when
    the app comes back to the foreground;
  - a long-lived process owns each repository handle. egit ties a handle to
    the process that opened it and frees it when that process exits;
  - repositories live in the app's documents directory, never under
    `MOB_BEAMS_DIR`, which a deploy replaces;
  - credentials pass through egit's existing options (see `CREDENTIALS.md`),
    with tokens coming from the app's secure storage.
- [ ] Demo screen declared in the manifest's `:screens` (like
      `MobCamera.DemoScreen`): clone over HTTPS, show the log.

### Phase 5: tests, packaging, upstream

- [ ] Host tests: keep upstream's eunit suite running through rebar3 against
      system `libgit2-dev`. Add Mix-side tests for the Elixir layer, using
      `elixir_make` to build the host `.so` in `:dev` / `:test` only, so a Mob
      app compiling `:egit` as a dep never needs libgit2 on the host.
- [ ] `mix mob.validate_plugin` from `marmoos_app`; sign with
      `mix mob.plugin.keygen` / `mix mob.plugin.sign`.
- [ ] Distribution: a `github:` dep with `submodules: true` works. Hex cannot
      carry submodules; publishing to Hex would mean shipping the vendored
      sources in the package (size, license notices for libgit2 GPLv2 with
      linking exception and mbedTLS Apache-2.0).
- [ ] Offer upstream: the tolerant `on_load` and `set_ssl_cert_locations/1`.

## Risks

- **mbedTLS version.** See above. Re-check `streams/mbedtls.c` on every libgit2
  bump; libgit2 may move to mbedTLS 4 / PSA.
- **Hand-merged `git2_features.h`.** A wrong define compiles fine and fails at
  runtime (wrong hash backend, missing HTTPS). Phase 0 and 1 device checks are
  the guard; Phase 3 documents how to regenerate it.
- **Static NIF name lookup.** egit loads `".../priv/git"`; the static table
  entry is `git`. Confirmed in Phase 0: it resolves.
- **Android CA store.** The updatable APEX store exists from Android 14;
  older devices only have `/system/etc/security/cacerts`. User-added CAs
  (`/data/misc/user/0/cacerts-added`) are not readable by apps and are not
  supported.
- **SecureTransport is deprecated** by Apple but still shipped and still
  libgit2's iOS backend. If it is ever removed, iOS switches to mbedTLS with
  the Keychain roots exported at startup.
- **Build time and size.** Roughly 400 C files per ABI on `mix android.native`
  / iOS native builds only; BEAM-only deploys are unaffected. Measure the
  `.so` size increase in Phase 1.
