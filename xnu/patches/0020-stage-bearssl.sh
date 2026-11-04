#!/bin/bash
# Pinned, portable constant-time AES for the SWEET legacy CBC/ECB API.
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f libkern/crypto/corecrypto_aes.c ]] || exit 1
bearssl_sha=7bea48e5e850ab4cafbe68d3765cdaba13a86d6f
bearssl_tmp=$(mktemp -d)
trap 'rm -rf "$bearssl_tmp"' EXIT
# bearssl.org answers 502 for days at a time; retry, then fall back to the 0.6
# release sources that Debian carries (same layout, same files).
bearssl_src=""
for attempt in 1 2 3; do
    rm -rf "$bearssl_tmp"; mkdir -p "$bearssl_tmp"
    git init -q "$bearssl_tmp"
    if git -C "$bearssl_tmp" fetch -q --depth 1 \
        https://www.bearssl.org/git/BearSSL "$bearssl_sha" 2>/dev/null; then
        git -C "$bearssl_tmp" checkout -q FETCH_HEAD
        if [[ "$(git -C "$bearssl_tmp" rev-parse HEAD)" == "$bearssl_sha" ]]; then
            bearssl_src="$bearssl_tmp"
            echo "BearSSL: fetched $bearssl_sha from upstream"
            break
        fi
    fi
    echo "BearSSL: upstream unreachable (attempt $attempt), retrying"
    sleep 15
done
if [[ -z "$bearssl_src" ]]; then
    curl -fsSL --retry 4 --retry-delay 5 \
        -o "$bearssl_tmp/bearssl-0.6.tar.xz" \
        https://deb.debian.org/debian/pool/main/b/bearssl/bearssl_0.6+dfsg.1.orig.tar.xz
    tar -xJf "$bearssl_tmp/bearssl-0.6.tar.xz" -C "$bearssl_tmp"
    bearssl_src="$bearssl_tmp/bearssl-0.6"
    [[ -d "$bearssl_src/src/symcipher" ]] || { echo "BearSSL: fallback tree missing" >&2; exit 1; }
    echo "BearSSL: using the 0.6 release sources (upstream git was unavailable)"
fi
python3 - "$bearssl_src" <<'PY'
from pathlib import Path
import shutil
import sys

source = Path(sys.argv[1])
target = Path('libkern/crypto/sweet_bearssl')
if target.exists():
    raise SystemExit(f'refusing to overwrite existing AES source: {target}')
shutil.copytree(source / 'inc', target / 'inc')
(target / 'src/symcipher').mkdir(parents=True)
for file in ('inner.h', 'config.h'):
    shutil.copy2(source / 'src' / file, target / 'src' / file)
# XNU exports machine/limits.h instead of the userspace limits.h.
header = target / 'src/inner.h'
text = header.read_text()
assert text.count('#include <limits.h>') == 1
header.write_text(text.replace('#include <limits.h>',
    '#if defined(KERNEL)\n#include <machine/limits.h>\n'
    '#else\n#include <limits.h>\n#endif'))
for name in ('aes_ct', 'aes_ct_enc', 'aes_ct_dec', 'aes_ct_cbcenc', 'aes_ct_cbcdec'):
    shutil.copy2(source / 'src/symcipher' / (name + '.c'),
                 target / 'src/symcipher' / (name + '.c'))
# MD5, SHA-1 and SHA-384/512 for the legacy hash APIs, with their codecs.
for name in ('hash/md5.c', 'codec/dec32le.c', 'codec/enc32le.c',
             'hash/sha1.c', 'codec/dec32be.c', 'codec/enc32be.c',
             'hash/sha2big.c', 'codec/dec64be.c', 'codec/enc64be.c'):
    (target / 'src' / name).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / 'src' / name, target / 'src' / name)
shutil.copy2(source / 'LICENSE.txt', target / 'LICENSE.txt')
PY
echo "Staged BearSSL portable AES, MD5, SHA-1 and SHA-384/512 ($bearssl_sha) for SWEET"
