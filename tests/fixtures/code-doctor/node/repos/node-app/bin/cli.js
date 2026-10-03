#!/usr/bin/env node
const { summarize } = require("../src/lib/live");

console.log(summarize(process.argv.slice(2)));
