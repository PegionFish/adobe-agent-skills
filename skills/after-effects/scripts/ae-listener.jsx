// ae-listener.jsx — Run this INSIDE a live After Effects instance so that the
// Windows runner can execute scripts against the user's open project.
//
// Why this exists: After Effects on Windows is single-instance. When an AE
// instance is already running, a second AfterFX.exe call (with -r or -s) exits
// immediately without executing anything, so there is no way to reach a running
// instance from the command line. This listener bridges that gap by polling a
// command directory from inside AE.
//
// How to load it (once per AE session):
//   File > Scripts > Run Script File...  ->  pick this file
// or install it permanently by copying it into:
//   %APPDATA%\Adobe\After Effects\<version>\Scripts\Startup\
//
// Protocol (all paths live in the shared temp dir == Folder.temp):
//   command.json    runner -> AE   {"nonce":"...","script":"C:/path/action.jsx"}
//   result.json     AE -> runner   whatever the script wrote via writeResult(),
//                                  plus an injected "_nonce" field
//   listener.json   heartbeat      written every ~2s while the listener is alive
//   error.txt       AE -> runner   written when the script threw
//
// ES3 only: no JSON object, no let/const, no Array.map.

var AE_L_TMP = Folder.temp.fsName;
var AE_L_CMD_DIR = AE_L_TMP + "/ae-assistant-commands";
var AE_L_CMD = AE_L_CMD_DIR + "/command.json";
var AE_L_HEARTBEAT = AE_L_TMP + "/ae-assistant-listener.json";
var AE_L_RESULT = AE_L_TMP + "/ae-assistant-result.json";
var AE_L_ERROR = AE_L_TMP + "/ae-assistant-error.txt";
var AE_L_LAST_BEAT = 0;
var AE_L_TICKS = 0;

function aeListenerWriteHeartbeat() {
    try {
        var hb = new File(AE_L_HEARTBEAT);
        hb.encoding = "UTF-8";
        hb.open("w");
        hb.write('{"alive":true,"at":"' + new Date().toString() + '","ticks":' + AE_L_TICKS + '}');
        hb.close();
    } catch (e) {}
}

function aeListenerReadText(path) {
    var f = new File(path);
    if (!f.exists) { return null; }
    f.encoding = "UTF-8";
    if (!f.open("r")) { return null; }
    var txt = f.read();
    f.close();
    return txt;
}

function aeListenerWriteError(message, nonce) {
    try {
        var ef = new File(AE_L_ERROR);
        ef.encoding = "UTF-8";
        ef.open("w");
        ef.write('{"_nonce":"' + nonce + '","error":"listener failure","detail":'
                 + '"' + String(message).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r?\n/g, "\\n") + '"}');
        ef.close();
    } catch (e) {}
}

// Inject the nonce into whatever the script wrote, so the runner can verify the
// result belongs to its own request.
function aeListenerStampResult(nonce) {
    var txt = aeListenerReadText(AE_L_RESULT);
    if (txt === null || txt === "") { return false; }
    var idx = txt.lastIndexOf("}");
    if (idx < 0) { return false; }
    var patched = txt.substring(0, idx) + ',"_nonce":"' + nonce + '"' + txt.substring(idx);
    try {
        var f = new File(AE_L_RESULT);
        f.encoding = "UTF-8";
        f.open("w");
        f.write(patched);
        f.close();
        return true;
    } catch (e) {
        return false;
    }
}

function aeListenerTick() {
    AE_L_TICKS++;

    // Heartbeat every ~2 seconds (4 ticks at 500ms)
    var nowMs = new Date().getTime();
    if (nowMs - AE_L_LAST_BEAT > 2000) {
        AE_L_LAST_BEAT = nowMs;
        aeListenerWriteHeartbeat();
    }

    var cmdFile = new File(AE_L_CMD);
    if (!cmdFile.exists) { return; }

    // Read and consume the command first so a slow script can never be
    // picked up twice.
    var payload = null;
    var nonce = "";
    try {
        cmdFile.encoding = "UTF-8";
        cmdFile.open("r");
        var txt = cmdFile.read();
        cmdFile.close();
        payload = eval("(" + txt + ")");
        nonce = payload && payload.nonce ? payload.nonce : "";
    } catch (eParse) {
        aeListenerWriteError("could not parse command file: " + eParse.toString(), "");
        try { cmdFile.remove(); } catch (eRm) {}
        return;
    }
    try { cmdFile.remove(); } catch (eRm2) {}

    if (!payload || !payload.script) { return; }

    // The invoked script is responsible for writing result.json via
    // writeResult()/writeError() from lib/utils.jsx.
    try {
        $.evalFile(new File(payload.script));
    } catch (eRun) {
        aeListenerWriteError(eRun.toString(), nonce);
        return;
    }

    if (!aeListenerStampResult(nonce)) {
        // Script produced nothing — surface it instead of letting the runner
        // wait for its full timeout.
        if (!new File(AE_L_ERROR).exists) {
            aeListenerWriteError("script completed without writing a result file", nonce);
        }
    }
}

// Only announce when loaded by hand. Installed into Scripts\Startup\ the
// listener stays silent so it does not nag on every AE launch.
function aeListenerShouldAnnounce() {
    try {
        var self = $.fileName;
        if (self && String(self).indexOf("Startup") !== -1) { return false; }
    } catch (e) {}
    return true;
}

// Global entry point used by scheduleTask
function aeListenerStart() {
    aeListenerWriteHeartbeat();
    // scheduleTask evaluates its first argument as code, so it must be a call.
    app.scheduleTask("aeListenerTick()", 500, true);
    $.writeln("ae-listener.jsx active - heartbeat: " + AE_L_HEARTBEAT);
    if (aeListenerShouldAnnounce()) {
        alert("AE Assistant listener is active.\n\nScripts can now be sent to this After Effects instance.\n(Heartbeat: " + AE_L_HEARTBEAT + ")");
    }
}

aeListenerStart();
