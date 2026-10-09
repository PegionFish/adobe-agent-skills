// active-state.jsx - Returns current AE working state
// Output: ae-assistant-result.json (system temp dir - see lib/utils.jsx)

#include "lib/json2.jsx"
#include "lib/utils.jsx"

(function() {
    var result = {
        aeVersion: app.version,
        uiLanguage: "",
        activeComp: null,
        selectedLayers: [],
        selectedProperties: [],
        currentTime: null,
        workAreaStart: null,
        workAreaEnd: null
    };

    // e.g. "zh_CN" - lets the caller adapt to a localized UI (render template
    // names, display names). Wrapped: very old builds lack isoLanguage.
    try { result.uiLanguage = String(app.isoLanguage); } catch (eLang) {}

    var comp = app.project.activeItem;
    if (comp && comp instanceof CompItem) {
        result.activeComp = {
            name: comp.name,
            duration: comp.duration,
            fps: comp.frameRate,
            width: comp.width,
            height: comp.height,
            numLayers: comp.numLayers
        };
        result.currentTime = comp.time;
        result.workAreaStart = comp.workAreaStart;
        result.workAreaEnd = comp.workAreaStart + comp.workAreaDuration;

        var sel = comp.selectedLayers;
        for (var i = 0; i < sel.length; i++) {
            result.selectedLayers.push({
                index: sel[i].index,
                name: sel[i].name,
                type: getLayerType(sel[i])
            });
        }

        var selProps = comp.selectedProperties;
        for (var j = 0; j < selProps.length; j++) {
            result.selectedProperties.push({
                name: selProps[j].name,
                matchName: selProps[j].matchName
            });
        }
    }

    writeResult(result);
})();
