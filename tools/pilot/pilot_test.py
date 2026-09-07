#!/usr/bin/env python3
"""Wire-state checks for the live pilot harness."""

import os
import re
import unittest

from pilot import PROTOCOL, S2C_MATCH, match_is_playing

PROTOCOL_RS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "..", "server", "src", "protocol.rs")


def wire_constant(name):
    """The number the zone server compiles in, read off its source."""
    with open(PROTOCOL_RS) as f:
        m = re.search(r"const %s: u8 = (\d+);" % name, f.read())
    return int(m.group(1)) if m else None


class MatchStateTest(unittest.TestCase):
    def test_protocol_and_match_tag_follow_the_live_wire(self):
        # Off the server's source rather than a literal beside the tool's own,
        # which agreed with itself through sixteen bumps of the real number.
        self.assertEqual(PROTOCOL, wire_constant("CLIENT_PROTOCOL"))
        self.assertEqual(S2C_MATCH, wire_constant("S2C_MATCH"))

    def test_only_the_playing_flag_releases_flight_inputs(self):
        self.assertTrue(match_is_playing(bytes([1, 180, 2])))
        self.assertTrue(match_is_playing(bytes([7, 180, 2])))
        self.assertFalse(match_is_playing(bytes([0, 180, 2])))
        self.assertFalse(match_is_playing(bytes([6, 180, 2])))
        self.assertFalse(match_is_playing(bytes([1])))
        self.assertFalse(match_is_playing(b""))


if __name__ == "__main__":
    unittest.main()
