// ae-json-test.jsx — verification of the recursive-descent JSON.parse in
// lib/json2.jsx. Unlike smoke.ps1 this needs a REAL After Effects install:
//
//   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\runner.ps1 -Timeout 300 scripts\tests\ae-json-test.jsx
//
// Covers: scalars, arrays, objects, \uXXXX escapes (Chinese), all string
// escapes, numbers (frac/exp/negative), nested structures with whitespace,
// stringify round-trip, the reviver, and 9 invalid inputs that must throw.
#include "lib/json2.jsx"
#include "lib/utils.jsx"

(function() {
    var failures = [];
    function check(name, actual, expected) {
        if (String(actual) !== String(expected)) {
            failures.push(name + ": got <" + actual + "> want <" + expected + ">");
        }
    }
    try {
        var o = JSON.parse('{"a":1,"b":[1,2,3],"c":"x","d":true,"e":null}');
        check("int", o.a, 1);
        check("array", o.b[2], 3);
        check("string", o.c, "x");
        check("true", o.d, true);
        check("null", o.e, null);

        var zh = JSON.parse('"\\u4e2d\\u6587"');
        check("unicode-escape", zh, String.fromCharCode(0x4E2D) + String.fromCharCode(0x6587));

        var esc = JSON.parse('"a\\nb\\tc\\\\d\\"e\\/f\\rg"');
        check("escapes", esc, "a\nb\tc\\d\"e/f\rg");

        check("exp", JSON.parse("-12.5e2"), -1250);
        check("frac", JSON.parse("3.14"), 3.14);

        var n = JSON.parse(' { "list": [ { "name": "\\u5408\\u6210" } ] } ');
        check("nested-ws", n.list[0].name, String.fromCharCode(0x5408) + String.fromCharCode(0x6210));

        var rt = JSON.parse(JSON.stringify({ k: String.fromCharCode(0x4E2D) }));
        check("roundtrip", rt.k, String.fromCharCode(0x4E2D));

        var rev = JSON.parse('{"a":1}', function (k, v) {
            return typeof v === "number" ? v + 1 : v;
        });
        check("reviver", rev.a, 2);

        var bad = ['{"a":}', '[1,2', '"unterminated', '{"a" 1}', 'garbage',
                   '{"a":1} trailing', "{'a':1}", '01x', ''];
        var threw = 0;
        for (var i = 0; i < bad.length; i++) {
            try { JSON.parse(bad[i]); } catch (eBad) { threw++; }
        }
        check("bad-json-throws", threw, bad.length);

        writeResult({ success: failures.length === 0, checks: 10, failures: failures });
    } catch (e) {
        writeResult({ error: e.toString(), line: e.line });
    }
})();
