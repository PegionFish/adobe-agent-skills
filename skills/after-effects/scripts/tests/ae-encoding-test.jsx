// ae-encoding-test.jsx - real-AE verification of readTextSmart/parseCSV in
// lib/utils.jsx (Chinese Windows adaptation). Data files are produced by
// ae-enc-prep.ps1 in the temp dir. Run with:
//
//   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\runner.ps1 -Timeout 300 -ArgsFile <args.json> scripts\tests\ae-encoding-test.jsx
//
// args.json: {"plainPath":"...","bomPath":"...","gbkPath":"...","csvPath":"..."}
// NOTE: this file lives in tests\, so the includes go up one level. A plain
// "lib/..." include resolves to tests\lib\ (missing) and the whole script
// then silently fails to execute - the engine just idles until timeout.
#include "../lib/json2.jsx"
#include "../lib/utils.jsx"

(function() {
    var failures = [];
    function check(name, actual, expected) {
        if (String(actual) !== String(expected)) {
            failures.push(name + ": got <" + actual + "> want <" + expected + ">");
        }
    }
    function zh(codes) {
        var s = "";
        for (var i = 0; i < codes.length; i++) s += String.fromCharCode(codes[i]);
        return s;
    }
    try {
        var args = readArgs();
        var expected = zh([0x4E3B, 0x5408, 0x6210, 0x6D4B, 0x8BD5]);  // 5 hanzi, see ae-enc-prep.ps1

        var plain = readTextSmart(args.plainPath);
        check("plain-encoding", plain && plain.encoding, "UTF-8");
        check("plain-text", plain && plain.text, expected);

        var bom = readTextSmart(args.bomPath);
        check("bom-encoding", bom && bom.encoding, "UTF-8");
        check("bom-text", bom && bom.text, expected);

        var gbk = readTextSmart(args.gbkPath);
        check("gbk-encoding", gbk && gbk.encoding !== "UTF-8" ? "GB-family" : "UTF-8", "GB-family");
        check("gbk-text", gbk && gbk.text, expected);

        var csv = readTextSmart(args.csvPath);
        check("csv-encoding", csv && csv.encoding !== "UTF-8" ? "GB-family" : "UTF-8", "GB-family");
        var rows = parseCSV(csv && csv.text ? csv.text : "");
        check("csv-rows", rows.length, 2);
        var diag = {
            plainLen: plain && plain.text ? plain.text.length : -1,
            bomLen: bom && bom.text ? bom.text.length : -1,
            gbkLen: gbk && gbk.text ? gbk.text.length : -1,
            csvLen: csv && csv.text ? csv.text.length : -1,
            csvFirst8: "",
            rowCount: rows.length
        };
        if (csv && csv.text) {
            for (var d = 0; d < csv.text.length && d < 8; d++) {
                diag.csvFirst8 += csv.text.charCodeAt(d).toString(16) + " ";
            }
        }
        if (rows.length >= 2 && rows[0] && rows[1]) {
            check("csv-header0", rows[0][0], zh([0x540D, 0x79F0]));          // 2 hanzi
            check("csv-header1", rows[0][1], zh([0x5907, 0x6CE8]));          // 2 hanzi
            check("csv-row0", rows[1][0], zh([0x4E3B, 0x5408, 0x6210]));     // 3 hanzi
            if (rows[1][1] !== undefined) {
                var lines = rows[1][1].split("\n");
                check("csv-multiline", lines.length, 2);
                check("csv-line0", lines[0], zh([0x7B2C, 0x4E00, 0x884C]));  // 3 hanzi
                check("csv-line1", lines[1], zh([0x7B2C, 0x4E8C, 0x884C]));  // 3 hanzi
            } else {
                failures.push("csv-row1-field1 missing");
            }
        } else {
            failures.push("csv rows malformed: " + rows.length);
        }

        // ASCII CSV: CRLF endings, quoted comma, trailing newline
        var rows2 = parseCSV("a,b\r\n\"c,d\",e\r\n");
        check("ascii-rows", rows2.length, 2);
        check("ascii-quoted", rows2[1][0], "c,d");
        check("ascii-last", rows2[1][1], "e");

        writeResult({
            success: failures.length === 0,
            checks: 16,
            failures: failures,
            diag: diag,
            decoded: { plain: plain && plain.text, gbk: gbk && gbk.text },
            uiLanguage: String(app.isoLanguage)
        });
    } catch (e) {
        writeResult({ error: e.toString(), line: e.line });
    }
})();
