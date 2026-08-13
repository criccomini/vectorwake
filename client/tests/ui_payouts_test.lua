-- Payout lifetime and compaction are independent of drawing.

package.path = "client/?.lua;" .. package.path

local payouts = require("arena.ui_payouts").new()

payouts:add(10, 1, 2, 25)
payouts:add(11, 3, 4, 50)

local seen = {}
payouts:each(11.1, function(p, progress, alpha)
    seen[#seen + 1] = {p = p, progress = progress, alpha = alpha}
end)
assert(#seen == 2 and #payouts.items == 2)
assert(seen[1].p.n == 25 and seen[2].p.n == 50)
assert(seen[2].alpha == 1)

seen = {}
payouts:each(11.5, function(p) seen[#seen + 1] = p end)
assert(#seen == 1 and seen[1].n == 50 and #payouts.items == 1)

payouts:clear()
assert(#payouts.items == 0)

print("ui payout tests pass")
