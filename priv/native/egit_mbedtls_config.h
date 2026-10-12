/*
 * mbedTLS configuration for the Mob plugin build, selected with
 * -DMBEDTLS_CONFIG_FILE="egit_mbedtls_config.h" (priv/mob_plugin.exs).
 *
 * mbedTLS' default configuration, plus thread safety: libgit2 shares one
 * mbedtls_ssl_config, RNG and CA chain between threads, and egit runs on
 * several dirty schedulers. The PSA core that a TLS 1.3 handshake starts
 * (psa_crypto_init(), called by mbedTLS itself since 3.6) needs it too.
 */
#ifndef EGIT_MBEDTLS_CONFIG_H
#define EGIT_MBEDTLS_CONFIG_H

#include <mbedtls/mbedtls_config.h>

#define MBEDTLS_THREADING_C
#define MBEDTLS_THREADING_PTHREAD

#endif
