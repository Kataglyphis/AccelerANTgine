#!/usr/bin/env bash
# Checks the include kataglyphis_embed_text_file writes: the file's bytes, CRLF as LF, no string literal; it compiles nothing.
set -euo pipefail

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
root=$SUITE_ROOT work=$SUITE_WORK
cat > "${work}/embed.cmake" <<'CMAKE'
include("${MODULE}")
kataglyphis_write_embedded_text("${SOURCE}" kProbe "${OUTPUT}")
CMAKE
cat > "${work}/decode.py" <<'PY'
"""Reads the include back: the exact frame around the bytes, then the bytes against the source with CRLF as LF."""
import re
import sys
from pathlib import Path

include, source = sys.argv[1:3]
text = Path(include).read_text(encoding="ascii")
head = "inline constexpr char kProbe_bytes[] = {\n"
tail = "'\\0' };\ninline constexpr std::string_view kProbe{ kProbe_bytes, sizeof(kProbe_bytes) - 1 };\n"
if not (text.startswith(head) and text.endswith(tail)):
    sys.exit(f"{include}: not the array and the view over it without its terminator")
body = text[len(head) : len(text) - len(tail)]
if re.sub(r"'\\x[0-9a-f]{2}',|\n", "", body):
    sys.exit(f"{include}: something besides one char per byte")
# A string literal is what MSVC refuses over 16380 bytes, so none may come back.
if '"' in text:
    sys.exit(f"{include}: holds a string literal")
found = bytes(int(pair, 16) for pair in re.findall(r"'\\x([0-9a-f]{2})',", body))
wanted = Path(source).read_bytes().replace(b"\r\n", b"\n")
if found != wanted:
    sys.exit(f"{include}: {len(found)} bytes, the source has {len(wanted)} with CRLF as LF, or they differ")
PY

embeds() {
  cmake "-DMODULE=${root}/cmake/EmbedTextFile.cmake" "-DSOURCE=$1" "-DOUTPUT=${work}/kProbe.inc" \
    -P "${work}/embed.cmake" >"${work}/out" 2>&1 || return 1
  python3 -I "${work}/decode.py" "${work}/kProbe.inc" "$1" >>"${work}/out" 2>&1
}

# Past both of MSVC's literal limits, with CRLF, a lone CR, 0d d0 a0 across two bytes, and what CMake and C++ treat specially.
python3 -I - "${work}/large.txt" <<'PY'
import sys
from pathlib import Path

special = b"a\r\nb\r\n\rc\n\x0d\xd0\xa0;[x]${y}@z@ \\ \"q\" )kgembed\" '\x00"
Path(sys.argv[1]).write_bytes(special + bytes(range(256)) * 280)
PY
: > "${work}/empty.txt"
suite_expect pass 'a 70 KB file with every byte value' embeds "${work}/large.txt"
suite_expect pass 'an empty file' embeds "${work}/empty.txt"
suite_expect pass 'the pinned inference contract' embeds "${root}/third_party/ModelANT/contracts/inference-v1.json"
suite_expect pass 'the class list the library compiles in' embeds "${root}/resources/coco-classes.txt"
suite_finish 'embedded text'
echo 'kataglyphis_embed_text_file writes the bytes of a file of any size as a char array'
