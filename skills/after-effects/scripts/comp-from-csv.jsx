// comp-from-csv.jsx — Generate comp variations from CSV data
// Args: {
//   "templateComp": "Lower Third",   — name of the template composition
//   "csvPath": "/path/to/data.csv",  — CSV file path
//   "outputFolder": "Versions",      — folder name for generated comps (optional)
//   "namingColumn": "name"            — which CSV column to use for comp naming (optional)
// }
// CSV columns map to text layer names. Header row is layer names.
// Example CSV:
//   name,Title,Subtitle
//   John,John Smith,CEO
//   Jane,Jane Doe,CTO
// This creates 2 comps: "Lower Third - John" and "Lower Third - Jane"
// Output: ae-assistant-result.json (system temp dir - see lib/utils.jsx)

#include "lib/json2.jsx"
#include "lib/utils.jsx"

(function() {
    app.beginUndoGroup("AE Assistant: Comp from CSV");
    try {
        var args = readArgs();

        if (!args.templateComp || !args.csvPath) {
            writeResult({ error: "Required args: templateComp (comp name), csvPath (path to CSV)" });
            return;
        }

        // Find template comp
        var templateComp = null;
        for (var i = 1; i <= app.project.numItems; i++) {
            var item = app.project.item(i);
            if (item instanceof CompItem && item.name === args.templateComp) {
                templateComp = item;
                break;
            }
        }
        if (!templateComp) {
            writeResult({ error: "Template composition not found: " + args.templateComp });
            return;
        }

        // Read CSV — Excel's plain "CSV" save is ANSI/GBK on Chinese Windows
        // and its "CSV UTF-8" save carries a BOM; readTextSmart handles both,
        // parseCSV handles quoted fields with embedded newlines.
        if (!new File(args.csvPath).exists) {
            writeResult({ error: "CSV file not found: " + args.csvPath });
            return;
        }
        var loaded = readTextSmart(args.csvPath);
        if (loaded === null) {
            writeResult({ error: "CSV file could not be opened: " + args.csvPath });
            return;
        }

        var rows = parseCSV(loaded.text);
        if (rows.length < 2) {
            writeResult({ error: "CSV needs at least a header row and one data row" });
            return;
        }

        // Parse header
        var headers = rows[0];
        var namingCol = args.namingColumn || headers[0];
        var namingIdx = -1;
        for (var h = 0; h < headers.length; h++) {
            if (headers[h] === namingCol) {
                namingIdx = h;
                break;
            }
        }
        if (namingIdx === -1) namingIdx = 0;

        // Create output folder
        var folderName = args.outputFolder || (args.templateComp + " Versions");
        var outputFolder = app.project.items.addFolder(folderName);

        var createdCount = 0;
        var createdComps = [];

        // Process each data row (skip blank lines: a lone empty field)
        for (var r = 1; r < rows.length; r++) {
            var fields = rows[r];
            if (fields.length === 1 && fields[0].length === 0) continue;
            if (fields.length === 0) continue;

            // Duplicate template comp
            var newComp = templateComp.duplicate();
            var rowName = (namingIdx < fields.length) ? fields[namingIdx] : ("Row " + r);
            newComp.name = args.templateComp + " - " + rowName;
            newComp.parentFolder = outputFolder;

            // Replace text in matching layers
            for (var c = 0; c < headers.length; c++) {
                if (c >= fields.length) continue;
                var layerName = headers[c];
                var newText = fields[c];

                // Find matching text layer in the new comp
                for (var l = 1; l <= newComp.numLayers; l++) {
                    var layer = newComp.layer(l);
                    if (layer instanceof TextLayer && layer.name === layerName) {
                        var textProp = layer.property("ADBE Text Properties").property("ADBE Text Document");
                        var textDoc = textProp.value;
                        textDoc.text = newText;
                        textProp.setValue(textDoc);
                        break;
                    }
                }
            }

            createdCount++;
            createdComps.push(newComp.name);
        }

        writeResult({
            success: true,
            message: "Created " + createdCount + " comp variations from CSV in folder '" + folderName + "'",
            count: createdCount,
            folder: folderName,
            comps: createdComps,
            sourceEncoding: loaded.encoding
        });
    } catch (e) {
        try { writeResult({ error: e.toString(), line: e.line, fileName: e.fileName }); }
        catch (e2) { writeError(e.toString(), "line:" + e.line); }
    } finally {
        app.endUndoGroup();
    }
})();
