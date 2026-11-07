# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise when the jumbo hold gives way to a larger reservation, shipped in madeira-unix 0290
(Playport Dishnur 20)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0290-virtual-give-an-unused-jumbo-hold-to-a-larger-reserv.patch"


def added_header():
    text = PATCH.read_text()
    section = text.split("diff --git a/build/ntdll-unix/pp_jumbo_yield.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_jumbo_yield.h"
#include <assert.h>

#define MB(n) ((uint64_t)(n) << 20)

int main(void) {
    /* Trails in the Sky 1st Chapter's 25,600 MB reservation gets every game's 8,960 MB hold released. */
    assert(ppj_hold_yields(MB(25600), MB(8960)));
    /* RDR2's own 8,960 MB takes the hold instead (ml997), and a smaller one leaves it. */
    assert(!ppj_hold_yields(MB(8960), MB(8960)));
    assert(!ppj_hold_yields(MB(2048), MB(8960)));
    /* No hold, nothing to release. */
    assert(!ppj_hold_yields(MB(25600), 0));
    return 0;
}
'''


class JumboYieldTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        with tempfile.TemporaryDirectory() as tmp:
            d = pathlib.Path(tmp)
            (d / "pp_jumbo_yield.h").write_text(added_header())
            (d / "t.c").write_text(TEST_C)
            subprocess.run([cc, "-std=c11", "-Wall", "-Werror", "-o", str(d / "t"), str(d / "t.c")], check=True, cwd=d)
            subprocess.run([str(d / "t")], check=True)

    def test_the_call_site_releases_and_restores(self):
        text = PATCH.read_text()
        self.assertIn("ppj_hold_yields( *size_ptr, ios_jumbo_hold_size )", text)
        self.assertIn("munmap( (void *)hbase, hsize );", text)
        self.assertIn("anon_mmap_tryfixed( (void *)hbase, hsize, PROT_NONE, MAP_NORESERVE )", text)


if __name__ == "__main__":
    unittest.main()
