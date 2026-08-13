package.path = "client/?.lua;" .. package.path

local codec = require("arena.net_codec")

assert(codec.u16(0x34, 0x12) == 0x1234)
assert(codec.u32(0x78, 0x56, 0x34, 0x12) == 0x12345678)
assert(codec.i16(0xff, 0xff) == -1)
assert(codec.i32(0xff, 0xff, 0xff, 0xff) == -1)

local encoded = codec.put_u32(0x89abcdef)
assert(#encoded == 4)
assert(codec.u32(string.byte(encoded, 1, 4)) == 0x89abcdef)

assert(codec.byte_or_zero(7.9) == 7)
assert(codec.byte_or_zero(-1) == 0)
assert(codec.byte_or_zero(256) == 0)
assert(codec.byte_or_zero("7") == 0)

print("net codec tests pass")
