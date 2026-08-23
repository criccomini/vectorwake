"use strict";

const assert = require("node:assert/strict");
const maps = require("../maps.js");

const candidate = maps.blank(192, 144);
const metrics = {
  width: 192,
  height: 144,
  quality: 81.4,
  route_overlay: [[[18, 72], [96, 72], [173, 72]]],
};

assert.equal(maps.checkedMapMetrics(metrics, candidate), metrics);
assert.throws(
  () => maps.checkedMapMetrics({ ...metrics, width: 160 }, candidate),
  /not this map/,
);
assert.throws(() => maps.checkedMapMetrics(metrics, null), /open a candidate/);

console.log("map metrics sidecars match their candidate dimensions");
