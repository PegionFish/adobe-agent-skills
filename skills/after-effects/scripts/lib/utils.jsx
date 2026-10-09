// utils.jsx — Shared helpers for AE Assistant query scripts
// All query scripts #include this file

// --- Shared IPC paths (cross-platform) -----------------------------------
// The runner and these helpers must agree on one per-user temp directory:
//   Windows: Folder.temp == %TEMP% == [IO.Path]::GetTempPath() in runner.ps1
//   macOS:   /tmp == used by runner.sh (unchanged, zero-regression)
var AE_TMP_DIR = /\bWindows\b/i.test(String($.os)) ? Folder.temp.fsName : "/tmp";
var AE_RESULT_FILE = AE_TMP_DIR + "/ae-assistant-result.json";
var AE_ARGS_FILE = AE_TMP_DIR + "/ae-assistant-args.json";

// Write JSON result to temp output file
function writeResult(obj) {
    var jsonStr = JSON.stringify(obj);
    var outFile = new File(AE_RESULT_FILE);
    outFile.encoding = "UTF-8";
    outFile.open("w");
    outFile.write(jsonStr);
    outFile.close();
}

// Write error even if JSON.stringify fails — last-resort error capture
function writeError(message, detail) {
    var errStr = '{"error":' + '"' + String(message).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"';
    if (detail) {
        errStr += ',"detail":"' + String(detail).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"';
    }
    errStr += '}';
    var outFile = new File(AE_RESULT_FILE);
    outFile.encoding = "UTF-8";
    outFile.open("w");
    outFile.write(errStr);
    outFile.close();
}

// Append to persistent log file (never throws — logging must not break a run)
function appendLog(message) {
    try {
        var logFile = new File("~/.ae-assistant-extendscript.log");
        logFile.encoding = "UTF-8";
        logFile.open("a");
        logFile.writeln("[" + new Date().toString() + "] " + message);
        logFile.close();
    } catch (e) {
        try {
            var fallback = new File(AE_TMP_DIR + "/ae-assistant-extendscript.log");
            fallback.encoding = "UTF-8";
            fallback.open("a");
            fallback.writeln("[" + new Date().toString() + "] " + message);
            fallback.close();
        } catch (e2) {}
    }
}

// Read arguments from temp input file
function readArgs() {
    var argFile = new File(AE_ARGS_FILE);
    if (!argFile.exists) return {};
    argFile.encoding = "UTF-8";
    argFile.open("r");
    var content = argFile.read();
    argFile.close();
    if (!content || content.length === 0) return {};
    return JSON.parse(content);
}

// --- Encoding-aware reading for user data files (SRT/CSV/...) -------------

// Strip a UTF-8 BOM if present (Excel's "CSV UTF-8" save adds one).
function stripBOM(s) {
    if (s && s.length > 0 && s.charAt(0) === "\uFEFF") return s.substring(1);
    return s;
}

// Read a text file that may be UTF-8 (with or without BOM) or GBK-family
// encoded — GBK/GB2312 SRT and CSV files are common output of Chinese
// Windows tools, and Excel's plain "CSV" save is ANSI/GBK on Chinese
// Windows. Reads as UTF-8 first; when that shows damage, re-reads with
// GB-family codec names until one decodes. Returns
// { text: "...", encoding: "<codec used>" }, or null when unopenable.
//
// Damage signals (AE 26.2 ExtendScript, measured): invalid UTF-8 either
// substitutes U+FFFD or makes read() return an EMPTY string while the file
// has bytes — both mean "not UTF-8". Codec candidates are tried in
// superset order; a decode that comes back one-char-per-byte is a
// single-byte passthrough (wrong codec) and is rejected.
function readTextSmart(path) {
    var f = new File(path);
    if (!f.exists) return null;
    f.encoding = "UTF-8";
    if (!f.open("r")) return null;
    var byteLen = f.length;
    var txt = stripBOM(f.read());
    f.close();
    var damaged = (txt && txt.indexOf("\uFFFD") !== -1) ||
                  (byteLen > 0 && (!txt || txt.length === 0));
    if (damaged) {
        var candidates = ["GBK", "GB18030", "GB2312", "CP936", "windows-936"];
        for (var c = 0; c < candidates.length; c++) {
            var g = new File(path);
            g.encoding = candidates[c];
            if (!g.open("r")) continue;
            var raw = stripBOM(g.read());
            var rawByteLen = g.length;
            g.close();
            if (raw && raw.length > 0 && raw.length < rawByteLen) {
                return { text: raw, encoding: candidates[c] };
            }
        }
    }
    return { text: txt, encoding: "UTF-8" };
}

// Parse CSV content per RFC 4180: quoted fields, embedded commas and
// newlines, "" as an escaped quote. Returns an array of rows, each an array
// of field strings. Strips a leading BOM; accepts CRLF and LF endings.
function parseCSV(content) {
    content = stripBOM(String(content));
    var rows = [];
    var row = [];
    var field = "";
    var inQuotes = false;
    var i = 0;
    while (i < content.length) {
        var ch = content.charAt(i);
        if (inQuotes) {
            if (ch === "\"") {
                if (content.charAt(i + 1) === "\"") { field += "\""; i += 2; }
                else { inQuotes = false; i++; }
            } else { field += ch; i++; }
            continue;
        }
        if (ch === "\"") { inQuotes = true; i++; continue; }
        if (ch === ",") { row.push(field); field = ""; i++; continue; }
        if (ch === "\r" || ch === "\n") {
            if (ch === "\r" && content.charAt(i + 1) === "\n") i++;
            i++;
            row.push(field); rows.push(row);
            field = ""; row = [];
            continue;
        }
        field += ch; i++;
    }
    // Final field/row when the content does not end with a newline.
    if (field.length > 0 || row.length > 0) {
        row.push(field);
        rows.push(row);
    }
    return rows;
}

// Detect layer type string
function getLayerType(layer) {
    switch (layer.matchName) {
        case "ADBE Vector Layer": return "shape";
        case "ADBE Text Layer": return "text";
        case "ADBE Camera Layer": return "camera";
        case "ADBE Light Layer": return "light";
        case "ADBE AV Layer":
            if (layer.nullLayer) return "null";
            if (layer.adjustmentLayer) return "adjustment";
            if (layer.guideLayer) return "guide";
            try {
                if (layer.source instanceof CompItem) return "precomp";
                if (layer.source.mainSource instanceof SolidSource) return "solid";
                if (layer.source.mainSource instanceof PlaceholderSource) return "placeholder";
                if (layer.source.mainSource instanceof FileSource) {
                    if (layer.source.footageMissing) return "missing";
                    if (!layer.source.hasVideo && layer.source.hasAudio) return "audio";
                    return "footage";
                }
            } catch(e) {}
            return "av";
        default: return "unknown";
    }
}

// Get blend mode display name
function getBlendModeName(mode) {
    for (var key in BlendingMode) {
        if (BlendingMode[key] === mode) return key;
    }
    return "unknown";
}

// Get active comp or write error and return null
function getActiveComp() {
    var comp = app.project.activeItem;
    if (!comp || !(comp instanceof CompItem)) {
        writeResult({ error: "No active composition" });
        return null;
    }
    return comp;
}

// Get selected layers, or all layers if none selected
function getSelectedOrAllLayers(comp) {
    var layers = comp.selectedLayers;
    if (layers.length > 0) return layers;
    var all = [];
    for (var i = 1; i <= comp.numLayers; i++) {
        all.push(comp.layer(i));
    }
    return all;
}

// Convert hex color string to [r, g, b] array (0-1 range)
function hexToRGB(hex) {
    hex = hex.replace(/^#/, "");
    if (hex.length === 3) {
        hex = hex.charAt(0) + hex.charAt(0) + hex.charAt(1) + hex.charAt(1) + hex.charAt(2) + hex.charAt(2);
    }
    var r = parseInt(hex.substring(0, 2), 16) / 255;
    var g = parseInt(hex.substring(2, 4), 16) / 255;
    var b = parseInt(hex.substring(4, 6), 16) / 255;
    return [r, g, b];
}

// Find comp in project by name
function getCompByName(name) {
    for (var i = 1; i <= app.project.numItems; i++) {
        var item = app.project.item(i);
        if (item instanceof CompItem && item.name === name) return item;
    }
    return null;
}

// Recursive property tree walker — calls leafFn(prop, path) on each leaf property
function walkProperties(group, leafFn, path) {
    if (path === undefined) path = "";
    for (var i = 1; i <= group.numProperties; i++) {
        var prop = group.property(i);
        var propPath = path ? (path + " > " + prop.name) : prop.name;
        if (prop.propertyType === PropertyType.PROPERTY) {
            leafFn(prop, propPath);
        } else if (prop.propertyType === PropertyType.INDEXED_GROUP ||
                   prop.propertyType === PropertyType.NAMED_GROUP) {
            walkProperties(prop, leafFn, propPath);
        }
    }
}

// ES3-compatible bubble sort (in-place)
function bubbleSort(arr, compareFn) {
    for (var i = 0; i < arr.length - 1; i++) {
        for (var j = i + 1; j < arr.length; j++) {
            if (compareFn(arr[j], arr[i]) < 0) {
                var tmp = arr[i];
                arr[i] = arr[j];
                arr[j] = tmp;
            }
        }
    }
    return arr;
}

// Convert frame count to seconds using comp's frame duration
function framesToSeconds(frames, comp) {
    return frames * comp.frameDuration;
}
