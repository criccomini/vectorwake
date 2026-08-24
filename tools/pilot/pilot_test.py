#!/usr/bin/env python3
"""Wire-state checks for the live pilot harness."""

import unittest

from pilot import PROTOCOL, S2C_MATCH, match_is_playing


class MatchStateTest(unittest.TestCase):
    def test_protocol_and_match_tag_follow_the_live_wire(self):
        self.assertEqual(PROTOCOL, 21)
        self.assertEqual(S2C_MATCH, 14)

    def test_only_the_playing_flag_releases_flight_inputs(self):
        self.assertTrue(match_is_playing(bytes([1, 180, 2])))
        self.assertTrue(match_is_playing(bytes([7, 180, 2])))
        self.assertFalse(match_is_playing(bytes([0, 180, 2])))
        self.assertFalse(match_is_playing(bytes([6, 180, 2])))
        self.assertFalse(match_is_playing(bytes([1])))
        self.assertFalse(match_is_playing(b""))


if __name__ == "__main__":
    unittest.main()
