package.path = "client/?.lua;" .. package.path

local reconcile = require("arena.net_reconcile")

assert(reconcile.next_tick(0xffffffff) == 0)
assert(reconcile.previous_tick(0) == 0xffffffff)
assert(reconcile.serial_after(0, 0xffffffff))
assert(not reconcile.serial_after(0xffffffff, 0))
assert(reconcile.serial_delta(1, 0xffffffff) == 2)
assert(reconcile.snapshot_after(0, 0xffffffff))

local receipts = reconcile.new()
assert(receipts:record_snapshot(10) == 0)
assert(receipts.snapshot_ack == 10 and receipts.snapshot_mask == 1)
assert(receipts:record_snapshot(12) == 1)
assert(receipts.snapshot_ack == 12)
assert(not reconcile.receipt_bit(receipts.snapshot_mask, 1))
assert(receipts:record_snapshot(11) == 0)
assert(reconcile.receipt_bit(receipts.snapshot_mask, 1))

receipts:set_input(100, 5)
assert(receipts:input_received(100))
assert(not receipts:input_received(99))
assert(receipts:input_received(98))
receipts:reset()
assert(receipts.input_ack == 0 and receipts.snapshot_ack == 0)

print("net reconciliation tests pass")
