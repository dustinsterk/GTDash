/*****************************************************************************
**  GTDash.qml  —  modern blue-sweep tachometer cluster (SINGLE-FILE build)
**
**  Gauge + settings menu in one component (dash.json points here). Pure
**  QtQuick 2 core (no QtGraphicalEffects / Controls) so it stays portable to
**  the IC7's Qt 5.12. Telltale icons are PNGs in assets/.
**
**  The settings screen is a full menu: an RGB colour scheme, shift /
**  rpm-limit / rpm-damping, speed + distance units, and the Coolant / Fuel /
**  Oil-temp / Oil-pressure / Battery / AFR high-low-unit ranges, plus a
**  nightlight dimmer. The list scrolls when it overflows.
**
**     Up                  open the settings menu
**     Left / Right        move between settings
**     Up / Down           change the selected value (hold to ramp)
**     EXIT row + Up       save to the resolved config path (see cfgCandidates) & close
**
**  D-pad read from rpmtest.inputsdata (udp_packetdata fallback):
**     up 0x20  down 0x2000  left 0x20000000  right 0x40000000
**  While the menu is open, rpmtest.settings_on_offdata is set to 1.
**
**  Which settings drive this dash's visuals vs. are stored only:
**    drive visuals : RED/GREEN/BLUE (accent), SHIFT RPM, RPM LIMIT,
**                    RPM DAMPING, SPEED/DIST/COOLANT units, COOLANT HIGH
**                    (temp warn), FUEL LOW (low-fuel warn), NIGHTLIGHT, the
**                    OIL TEMP / OIL PRESS / AFR high-low-unit triplets (each
**                    drives a side bar-gauge), and BATTERY HIGH/LOW (drive
**                    the battery-voltage readout's level + warning).
**    stored only   : COOLANT LOW, FUEL HIGH, FUEL DAMP.
**
** ===========================================================================
**  IC7 HARDWARE NOTES  (lessons that differ from the desktop simulator — read
**  these before shipping any new dash; the sim hides all of them)
** ===========================================================================
**  1. FONTS — the IC7's Qt does NOT alias the generic "sans-serif" to a sans
**     font; it falls back to a SERIF and everything looks wrong. Bundle a TTF
**     and load it with FontLoader (see uiFontR/uiFontB + the `ff` property),
**     then use that family in every ctx.font. Repaint when the font loads.
**     The bundled font must also contain any glyphs you draw (e.g. the degree
**     sign \u00B0).
**
**  2. INPUT — some IC7 backends update rpmtest.inputsdata WITHOUT emitting a
**     property-change signal, so `Connections { onInputsdataChanged }` may
**     never fire (the menu never opens). POLL evalEdges() on a ~50 ms Timer as
**     well. evalEdges() is edge-triggered (pUp/pDown/...), so polling and the
**     signal together never double-act. Confirm the D-pad bit too (up 0x20).
**
**  3. CANVAS arcTo IS UNRELIABLE on the IC7's Qt 5.12 paint engine. It draws
**     diagonal/triangular corners and collapses short rounded rects to nothing
**     (a radius-4 corner on an 8 px-tall bar disappeared entirely). Build
**     rounded rectangles with quadraticCurveTo and CLAMP the radius to half the
**     smaller side (see rr()); draw tiny bars as plain fillRect.
**
**  4. PERFORMANCE — Canvas is CPU-rasterised then uploaded each frame, which is
**     the expensive path on the IC7. This dash uses just ONE canvas, and it
**     never moves:
**       * `bg`    — static chrome (bezel, baseline ticks, labels, centre disc/
**                   pill, panel boxes), full-screen but painted ONCE. It repaints
**                   only when a setting that changes the chrome does (rpm scale,
**                   side-gauge units).
**     EVERYTHING that moves is declarative scene-graph geometry, composited on
**     the GPU with no rasterisation:
**       * tach    — a Repeater of Rectangle spokes (one per 100 rpm), each
**                   rotated to its angle, lit/unlit by an opacity binding on
**                   rpmDisplay; a wider low-opacity sibling per spoke is the glow.
**                   As the needle moves, only the few spokes it crosses flip — the
**                   scene graph re-uploads just those nodes.
**       * readouts— centre gear/rpm/speed, the four side gauges, battery, fuel,
**                   odo/trip: Text/Rectangle nodes bound to their values.
**     There is no repaint timer and no per-frame canvas anywhere, so a
**     parked or steady-cruising dash does ~zero paint work and even a hard rev is
**     just opacity/rotation changes on existing nodes. The tach + readouts hide
**     for free while the menu is open (visible: !menuOpen / the overlay covers
**     them). The settings menu is an item-based ListView (not a Canvas), so only
**     changed rows repaint and off-screen rows recycle.
**
**  5. CONFIG FILE — two IC7 FileIO quirks, both handled in loadConfig/saveConfig:
**     (a) READ is one-line-per-open: openforreading() then the FIRST
**         readopenfile(i) returns line i; any further read in the same open
**         returns empty. So re-open before EVERY line: open/read(i)/close, per
**         line (see rline()). Reading all lines in one open returns only line 0.
**     (b) FileIO does NOT create the file on a read. SEED on first run: if
**         loadConfig() finds nothing, saveConfig() writes defaults. Write the
**         whole file in a SINGLE writetoopenfile() call.
**     Also wrap settings_on_offdata writes in try/catch — if a backend exposes
**     it read-only, the throw must not break the input bookkeeping.
**
**  6. RESOLUTION — the layout is a fixed 800x480; an anchored fill stretches if
**     the panel differs. Confirm the real panel size before trusting spacing.
** ===========================================================================
*****************************************************************************/
import QtQuick 2.7
import FileIO 1.0

Item {
    id: root
    width: 800; height: 480

    // ---- data interface (real rpmtest field names, dot-notation) ----------
    property var d: (typeof rpmtest !== 'undefined') ? rpmtest : null
    property real rpm:       d ? d.rpmdata          : 0
    property real speed:     d ? d.speeddata        : 0      // km/h
    property real peakRpm:   0      // session high-water marks (PEAK card); in-memory,
    property real peakSpeed: 0      // km/h canonical -> reset on power cycle
    property real peakOilTemp:     -1e9   // session max, C canonical
    property real peakCoolant:     -1e9   // session max, C canonical
    property real peakOilPressMax: -1e9   // session max, PSI canonical
    property real peakOilPressMin:  1e9   // session min, PSI canonical (low oil press = danger)
    property real peakAfrMax:      -1e9   // session max, AFR canonical (leanest)
    property real peakAfrMin:       1e9   // session min, AFR canonical (richest)
    onSpeedChanged:     if (speed     > peakSpeed)   peakSpeed   = speed
    onOiltempChanged:   if (oiltemp   > peakOilTemp) peakOilTemp = oiltemp
    onWatertempChanged: if (watertemp > peakCoolant) peakCoolant = watertemp
    onAfrChanged:       { if (afr > peakAfrMax) peakAfrMax = afr;
                          if (afr < peakAfrMin) peakAfrMin = afr; }
    function resetPeaks() {
        peakRpm = 0; peakSpeed = 0;
        peakOilTemp = -1e9; peakCoolant = -1e9;
        peakOilPressMax = -1e9; peakOilPressMin = 1e9;
        peakAfrMax = -1e9; peakAfrMin = 1e9;
        settingsRev += 1;
    }
    property int  gearpos:   d ? d.geardata         : 0
    property real watertemp: d ? d.watertempdata    : 0      // °C
    property real fuel:      d ? d.fueldata         : 0      // 0..100 %
    property real odometer:  d ? (d.odometer0data    / 10) : 0   // tenths of km
    property int  tripmeter: d ? (d.tripmileage0data / 10) : 0   // tenths of km
    property int  inputs:    d ? d.inputsdata       : 0
    // ECU ASCII status text over CAN (e.g. "TPMS Fault", "Slip %"). Host may send
    // it as a string or a NUL-terminated byte array; decode both. The raw read is
    // a binding so it stays reactive; absent in the sim -> "" (line stays hidden).
    // Read as a QML string so the host QByteArray/QString is coerced cleanly (the
    // reference dash does the same). Then sanitise: keep printable ASCII up to the
    // first NUL and trim. This drops the stray control/padding bytes that render as
    // boxes ("[]") while a multi-frame ECU message is still streaming in.
    // ECU ASCII status text (CAN canasciidata), shown raw. Read as a QML string
    // so the host value is coerced cleanly, then drop control / non-printable
    // bytes (which would render as boxes) and trim the ends — without truncating
    // at NULs. No buffering, assembly or rate-limiting: the line always reflects
    // exactly the current value the ECU is sending, and clears when it clears.
    property string canAsciiRaw: d ? d.canasciidata : ""
    readonly property string canAsciiStr: {
        var src = root.canAsciiRaw;
        if (!src) return "";
        var out = "";
        for (var i = 0; i < src.length; i++) {
            var c = src.charCodeAt(i);
            if (c >= 32 && c < 127) out += src.charAt(i);   // keep printable ASCII; drop NUL/control/high bytes
        }
        return root.canAsciiCollapse(out.trim());
    }
    // True if b is the same characters as a in a rotated order once spaces are
    // removed (b is a rotation of a). Recognises a no-separator repeat that the
    // collapse reordered ("7% Slip" vs "Slip7%", "LTC Off" vs "OffLTC") so the
    // display can hold the version already shown instead of flipping to the garble.
    function canAsciiSameRotation(a, b) {
        if (a.indexOf(" ") >= 0 || b.indexOf(" ") < 0) return false;
        var x = a.split(" ").join(""), y = b.split(" ").join("");
        if (!x.length || x.length !== y.length || x === y) return false;
        return (x + x).indexOf(y) >= 0;
    }
    // Message severity: faults outrank info. Drives BOTH the min-dwell and the
    // severity-hold gate in canAsciiSettle (one notion, no separate priority).
    function canAsciiSeverity(s) {
        if (!s) return 0;                                   // blank
        return (s.indexOf("FAULT") >= 0 || s === "TPMS") ? 2 : 1;   // 2 = fault-class, 1 = info
    }
    // Collapse a host buffer that does not self-clear and piles a message up.
    function canAsciiCollapse(out) {
        if (!out.length) return "";
        var w = out.split(/\s+/);
        if (w.length >= 2) {
            var f = w[0], s = w[1];
            if (f.length < s.length && s.substring(s.length - f.length) === f) w.shift();
        }
        if (w.length >= 2) {
            var e = w[w.length - 1], q = w[w.length - 2];
            if (e.length < q.length && q.substring(0, e.length) === e) w.pop();
        }
        var c = [];                                                // collapse consecutive duplicate words
        for (var a = 0; a < w.length; a++)
            if (a === 0 || w[a] !== w[a - 1]) c.push(w[a]);
        var n = c.length;                                          // collapse an exact repeated phrase
        for (var pp = 1; pp <= (n >> 1); pp++) {
            if (n % pp !== 0) continue;
            var rep = true;
            for (var j = pp; j < n; j++) { if (c[j] !== c[j - pp]) { rep = false; break; } }
            if (rep) return c.slice(0, pp).join(" ");
        }
        return c.join(" ");
    }
    property real oiltemp:   d ? d.oiltempdata      : 0      // °C (native)
    property real oilpress:  d ? (d.oilpressuredata * 14.5038) : 0  // native BAR -> PSI (canonical)
    // Smoothed oil-pressure display: sweeps up from 0 as the engine builds
    // pressure on start (and eases down on shut-off) instead of snapping.
    property real oilPressShown: 0
    Behavior on oilPressShown { SmoothedAnimation { velocity: 60 } }   // ~PSI/sec
    onOilpressChanged: { oilPressShown = oilpress;
                         if (oilpress > peakOilPressMax) peakOilPressMax = oilpress;
                         if (oilpress < peakOilPressMin) peakOilPressMin = oilpress; }
    property real afr:       d ? (d.o2data * 14.7)  : 0      // native lambda -> AFR (canonical, x14.7)
    property real battery:   d ? d.batteryvoltagedata : 0    // volts
    property real batteryShown: 0   // debounced volts actually shown (see battery throttle timer)

    // =======================================================================
    //  SETTABLE CONFIG  (the menu writes these directly; persisted to disk)
    // =======================================================================
    // --- engine / tach ---
    property int  rpmredline: 7000     // SHIFT RPM  (tach turns red above this)
    property int  rpmmax:     9000     // RPM LIMIT  (full-scale rpm)
    property int  rpmDamp:    3        // RPM DAMPING (1 = snappy ... 10 = smooth)

    // --- colour scheme: the accent is built from RGB ---
    property int  red:   47            // default 47/134/255 == GT blue #2f86ff
    property int  green: 134
    property int  blue:  255

    // --- units ---
    property int  speedunits: 0        // 0 = km/h, 1 = mph
    property int  distunits:  0        // 0 = km,   1 = miles (odometer + trip)
    property int  tempunits:  0        // coolant 0 = °C, 1 = °F

    // --- bar-gauge ranges ---
    property real coolantHigh:   110   // °C (canonical) — coolant turns red at/above
    property real coolantLow:    60    // °C (canonical)
    property int  fuelHigh:      90
    property int  fuelLow:       15    // % — fuel bar turns red below this
    property int  fuelDamp:      3
    property real oilTempHigh:   130   // °C (canonical)
    property real oilTempLow:    80    // °C (canonical)
    property int  oilTempUnits:  0     // 0 = °C, 1 = °F, 2 = OFF (blank)
    property real oilPressHigh:  90    // PSI (canonical)
    property real oilPressLow:   15    // PSI (canonical)
    property int  oilPressUnits: 1     // 0 = PSI, 1 = BAR, 2 = OFF  (sensor native BAR)
    property real batteryHigh:   14.8
    property real batteryLow:    11.8
    property real afrHigh:       1.02   // O2 limits stored in LAMBDA (1.02 = 15.0 AFR)
    property real afrLow:        0.82   //                            (0.82 = 12.0 AFR)
    property int  afrSource:     1     // O2 DISPLAY: 0 = AFR, 1 = LAMBDA, 2 = OFF
                                       // (o2data is native lambda -> afr is canonical AFR)
    readonly property real afrShown: afrSource === 1 ? afr / 14.7   // LAMBDA
                                   : afr                            // AFR  (OFF hides the gauge)

    readonly property bool showOilTemp:  oilTempUnits  <= 1                 // °C/°F only; OFF(2) blank
    readonly property bool showOilPress: oilPressUnits !== 2
    readonly property bool showCoolant:  tempunits     !== 2
    readonly property bool showAfr:      afrSource     !== 2
    readonly property bool showPeak:     showPeakGauge                       // PEAK card occupies a chosen corner slot
    property bool showPeakGauge:     false  // SHOW PEAK GAUGE menu toggle (default off)
    property int  peakGaugePosition: 1      // PEAK POSITION: 1=top-left 2=top-right 3=bottom-left 4=bottom-right
    property bool peakShowRpm:      true
    property bool peakShowSpeed:    true
    property bool peakShowAfr:      false
    property bool peakShowOilTemp:  false
    property bool peakShowOilPress: false
    property bool peakShowCoolant:  false

    readonly property var peakRows: {
        var a = [];
        var rpmRow = { label: "RPM", text: String(Math.round(peakRpm)) };
        var spdRow = { label: "SPEED", text: (speedunits === 0 ? String(Math.round(peakSpeed)) + " KM/H"
                                                             : String(Math.round(peakSpeed / 1.609)) + " MPH") };
        if (placementSwap) { if (peakShowSpeed) a.push(spdRow); if (peakShowRpm) a.push(rpmRow); }
        else               { if (peakShowRpm) a.push(rpmRow); if (peakShowSpeed) a.push(spdRow); }
        if (peakShowAfr)      a.push({ label: (afrSource === 1 ? "\u03BB" : "AFR"),
                                       text: peakFmtAfr(peakAfrMin) + "\u2013" + peakFmtAfr(peakAfrMax) });
        if (peakShowOilTemp)  a.push({ label: "IAT T", text: peakFmtTemp(peakOilTemp, oilTempUnits) });
        if (peakShowOilPress) a.push({ label: "OIL P", text: peakFmtPressRange(peakOilPressMin, peakOilPressMax) });
        if (peakShowCoolant)  a.push({ label: "COOL",  text: peakFmtTemp(peakCoolant, tempunits) });
        return a;
    }
    readonly property int peakRowH: Math.max(9, Math.min(24, Math.floor((74 - (Math.max(1, peakRows.length) - 1)) / Math.max(1, peakRows.length))))
    readonly property int peakMaxVal: { var m = 1; for (var i = 0; i < peakRows.length; i++) m = Math.max(m, peakRows[i].text.length);  return m; }
    readonly property int peakMaxLab: { var m = 1; for (var j = 0; j < peakRows.length; j++) m = Math.max(m, peakRows[j].label.length); return m; }
    readonly property int peakFont: Math.max(9, Math.min(20, peakRowH - 2,
                                     Math.floor(84 / (peakMaxVal * 0.60)),
                                     Math.floor(58 / (peakMaxLab * 0.60))))
    readonly property int peakColY: Math.round(28 + Math.max(0,
                                     (74 - (peakRows.length * peakRowH + Math.max(0, peakRows.length - 1))) / 2))
    function peakFmtTemp(c, units) {
        if (c <= -1e8) return "--";
        return String(Math.round(units === 1 ? c * 9/5 + 32 : c)) + (units === 1 ? "\u00B0F" : "\u00B0C");
    }
    function peakFmtPressRange(lo, hi) {
        if (hi <= -1e8) return "--";
        if (oilPressUnits === 0) return String(Math.round(lo)) + "\u2013" + String(Math.round(hi)) + " PSI";
        return (lo / 14.5038).toFixed(1) + "\u2013" + (hi / 14.5038).toFixed(1) + " BAR";
    }
    function peakFmtAfr(a) {
        if (a <= -1e8 || a >= 1e8) return "--";
        return afrSource === 1 ? (a / 14.7).toFixed(2) : a.toFixed(1);
    }
    readonly property real peakX: (peakGaugePosition === 2 || peakGaugePosition === 4) ? 612 : 12
    readonly property real peakY: (peakGaugePosition === 1 || peakGaugePosition === 2) ? 96  : 214
    readonly property bool peakAtOilPress: showPeak && peakGaugePosition === 1
    readonly property bool peakAtAfr:      showPeak && peakGaugePosition === 2
    readonly property bool peakAtOilTemp:  showPeak && peakGaugePosition === 3
    readonly property bool peakAtCoolant:  showPeak && peakGaugePosition === 4
    function peakOccupies(k) {
        return (k === "oilpress" && peakAtOilPress) || (k === "afr"     && peakAtAfr)
            || (k === "oiltemp"  && peakAtOilTemp)  || (k === "coolant" && peakAtCoolant);
    }

    // --- display ---
    property int  nightlight: 0        // 0..100 night dimmer (0 = off)

    // accent colour assembled from the RGB scheme (CSS hex for the Canvas)
    function hx(n) { n = Math.max(0, Math.min(255, Math.round(n))); var s = n.toString(16); return (s.length < 2 ? "0" : "") + s; }
    readonly property string accent: "#" + hx(red) + hx(green) + hx(blue)
    readonly property real springVal: 55.0 * Math.pow(0.8 / 55.0, (Math.max(1, Math.min(10, rpmDamp)) - 1) / 9.0)

    // ---- bundled UI font ---------------------------------------------------
    FontLoader { id: uiFontR; source: "assets/DejaVuSans.ttf"
        onStatusChanged: if (status === FontLoader.Ready) root.fontsReady() }
    FontLoader { id: uiFontB; source: "assets/DejaVuSans-Bold.ttf"
        onStatusChanged: if (status === FontLoader.Ready) root.fontsReady() }
    readonly property string ff: (uiFontR.status === FontLoader.Ready)
                                 ? ('"' + uiFontR.name + '"') : "sans-serif"
    readonly property string menuFont: (uiFontR.status === FontLoader.Ready)
                                       ? uiFontR.name : "sans-serif"
    function fontsReady() {
        if (typeof bg !== 'undefined') bg.requestPaint();
    }

    // ---- decoded telltales (inputsdata bits) ------------------------------
    property bool tLeft:     inputs & 0x40
    property bool tRight:    inputs & 0x80
    property bool tLeftActive:  false
    property bool tRightActive: false

    // ---- spring-damped rpm + animation clock ------------------------------
    property real rpmDisplay: 0
    readonly property real springDamp: 0.30 + springVal * 0.025
    Behavior on rpmDisplay { SpringAnimation { spring: root.springVal; damping: root.springDamp; epsilon: 1 } }
    onRpmChanged: { rpmDisplay = rpm; if (rpm > peakRpm) peakRpm = rpm; }

    // ---- power-on self-test sweep ------------------------------------------
    property bool  selfTest: true
    property real  sweepRpm: 0
    property real  settle:   0
    readonly property real rpmShown: selfTest ? (sweepRpm * (1 - settle) + rpmDisplay * settle) : rpmDisplay
    readonly property real sweepFrac: Math.max(0, Math.min(1, sweepRpm / Math.max(1, rpmmax)))
    SequentialAnimation {
        id: bootSweep; running: false
        NumberAnimation { target: root; property: "sweepRpm"; from: 0; to: root.rpmmax; duration: 850; easing.type: Easing.OutCubic }
        PauseAnimation  { duration: 200 }
        NumberAnimation { target: root; property: "settle";   from: 0; to: 1;            duration: 700; easing.type: Easing.InOutCubic }
        ScriptAction    { script: root.selfTest = false }
    }

    // ---- fuel-bar damping --------------------------------------------------
    readonly property real fuelVel: Math.max(8.0, 75.0 - (fuelDamp - 1) * 8.0)
    property real fuelDisplay: 0
    Behavior on fuelDisplay { SmoothedAnimation { velocity: root.fuelVel } }
    onFuelChanged: fuelDisplay = fuel
    readonly property real fuelLevel: (fuelDamp <= 0) ? fuel : fuelDisplay
    readonly property real fuelBarFrac: selfTest ? (sweepFrac * (1 - settle) + (fuelLevel / 100) * settle) : fuelLevel / 100

    property bool showRawRpm: false
    property bool showRawSensors: false

    // ---- derived ----------------------------------------------------------
    property bool overrev: rpmShown >= rpmredline
    property bool engineOff: !selfTest && Math.round(rpmShown) < 1
    property bool placementSwap: false
    property bool hideTachNums: false
    property bool hideShiftLights: false
    property int  speedShown: (speedunits === 0) ? speed : Math.round(speed / 1.609)
    property string gearLabel: {
        if ((root.inputs & 0x4000000) !== 0) return "R";
        switch (gearpos) {
            case 0: return "N"; case 9: return "P"; case 10: return "R";
            default: return (gearpos >= 1 && gearpos <= 8) ? String(gearpos) : "N";
        }
    }

    // ---- side-gauge helpers -----------------------------------------------
    function gaugeShown(k) {
        return k === "oiltemp" ? showOilTemp : k === "oilpress" ? showOilPress
             : k === "afr"     ? showAfr     : showCoolant;
    }
    function gaugeLabel(k) {
        return k === "oiltemp" ? "IAT TEMP" : k === "oilpress" ? "OIL PRESS"
             : k === "afr"     ? "AFR"      : "COOLANT";
    }
    function gaugeWarn(k) {
        if (k === "oiltemp")  return oiltemp  >= oilTempHigh;
        if (k === "oilpress") return (!engineOff && oilPressShown <= oilPressLow) || oilPressShown >= oilPressHigh;
        if (k === "afr")      { var l = afr / 14.7; return l < afrLow || l > afrHigh; }
        return watertemp >= coolantHigh;
    }
    function gaugeFrac(k) {
        var f;
        if (k === "oiltemp")       f = (oiltemp  - oilTempLow)  / Math.max(1, oilTempHigh  - oilTempLow);
        else if (k === "oilpress") f = (oilPressShown - oilPressLow) / Math.max(1, oilPressHigh - oilPressLow);
        else if (k === "afr")    { var l = afr / 14.7; f = (l - afrLow) / Math.max(0.001, afrHigh - afrLow); }
        else                       f = (watertemp - coolantLow) / Math.max(1, coolantHigh - coolantLow);
        return Math.max(0, Math.min(1, f));
    }
    function gaugeVal(k) {
        if (k === "oiltemp")  return String(Math.round(oilTempUnits === 0 ? oiltemp : oiltemp * 9/5 + 32));
        if (k === "oilpress") return oilPressUnits === 0 ? String(Math.round(oilPressShown)) : (oilPressShown / 14.5038).toFixed(1);
        if (k === "afr")      return afrSource === 0 ? afrShown.toFixed(1) : afrShown.toFixed(2);
        return String(Math.round(tempunits === 0 ? watertemp : watertemp * 9/5 + 32));
    }
    function gaugeUnit(k) {
        if (k === "oiltemp")  return oilTempUnits  === 0 ? "\u00B0C" : "\u00B0F";
        if (k === "oilpress") return oilPressUnits === 0 ? "PSI" : "BAR";
        if (k === "afr")      return afrSource === 1 ? "\u03BB" : "";
        return tempunits === 0 ? "\u00B0C" : "\u00B0F";
    }

    readonly property real distFactor: (distunits === 0) ? 1.0 : 0.621371
    readonly property string distUnit: (distunits === 0) ? " km" : " mi"

    onRpmredlineChanged: bg.requestPaint()
    onRpmmaxChanged:     bg.requestPaint()
    onOilTempUnitsChanged:  bg.requestPaint()
    onOilPressUnitsChanged: bg.requestPaint()
    onTempunitsChanged:     bg.requestPaint()
    onAfrSourceChanged:     bg.requestPaint()
    onHideTachNumsChanged:  bg.requestPaint()
    onSelfTestChanged:      bg.requestPaint()
    onShowPeakGaugeChanged:     bg.requestPaint()
    onPeakGaugePositionChanged: bg.requestPaint()

    // ---- STATIC layer ------------------------------------------------------
    Canvas {
        id: bg
        anchors.fill: parent
        antialiasing: true
        renderStrategy: Canvas.Cooperative

        readonly property real cx: 400
        readonly property real cy: 212
        readonly property real gaugeR: 192
        function ang(rpm) {
            var deg = 140 + (Math.max(0, Math.min(root.rpmmax, rpm)) / root.rpmmax) * 260;
            return deg * Math.PI / 180;
        }

        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.fillStyle = "#05070d"; ctx.fillRect(0, 0, width, height);
            ctx.fillStyle = "#0a1326"; ctx.fillRect(0, 366, width, 44);     // bottom bar
            drawTachStatic(ctx);
            drawCentreStatic(ctx);
            drawTachNumbers(ctx);
            if (root.showOilPress || root.peakAtOilPress || root.selfTest) box(ctx, 12,  96, 176, 104);
            if (root.showOilTemp  || root.peakAtOilTemp  || root.selfTest) box(ctx, 12, 214, 176, 104);
            if (root.showAfr      || root.peakAtAfr      || root.selfTest) box(ctx, 612, 96, 176, 104);
            if (root.showCoolant  || root.peakAtCoolant  || root.selfTest) box(ctx, 612, 214, 176, 104);
        }

        function drawTachStatic(ctx) {
            var bandOut = gaugeR - 6, bandIn = gaugeR - 46;
            ctx.lineWidth = 7; ctx.strokeStyle = "#7486aa";
            ctx.beginPath(); ctx.arc(cx, cy, gaugeR + 4, 0, Math.PI * 2); ctx.stroke();
            for (var v = 0; v <= root.rpmmax; v += 100) {
                var a = ang(v), major = (v % 1000 === 0), redZone = (v >= root.rpmredline);
                var ro = bandOut, ri = major ? bandIn - 4 : bandIn + 10;
                ctx.strokeStyle = redZone ? "#cc6666" : "#94a8cc";
                ctx.lineWidth = major ? 4 : 3;
                ctx.beginPath();
                ctx.moveTo(cx + ri * Math.cos(a), cy + ri * Math.sin(a));
                ctx.lineTo(cx + ro * Math.cos(a), cy + ro * Math.sin(a));
                ctx.stroke();
            }
        }

	function drawTachNumbers(ctx) {
    	if (root.hideTachNums) return;
    	ctx.font = "bold 23px " + root.ff; ctx.textAlign = "center"; ctx.textBaseline = "middle";
    	var rLbl = gaugeR - 68;   // was gaugeR - 58 — pulls numbers ~10px further from the ticks
    	for (var n = 0; n * 1000 <= root.rpmmax; n++) {
        	var an = ang(n * 1000);
        	ctx.fillStyle = (n * 1000 >= root.rpmredline) ? "#ff6a6a" : "#e9eefb";
        	ctx.fillText(String(n), cx + rLbl * Math.cos(an), cy + rLbl * Math.sin(an));
    	    }
	}

        function drawCentreStatic(ctx) {
            ctx.fillStyle = "#0a0f1a";
            ctx.beginPath(); ctx.arc(cx, cy, gaugeR - 52, 0, Math.PI * 2); ctx.fill();
            rr(ctx, cx - 44, cy - 96, 88, 46, 10); ctx.fillStyle = "#11182a"; ctx.fill();
            rr(ctx, cx - 44, cy - 96, 88, 46, 10); ctx.strokeStyle = "#8ea3c7"; ctx.lineWidth = 2; ctx.stroke();
            ctx.strokeStyle = "#5f7093"; ctx.lineWidth = 2;
            ctx.beginPath(); ctx.moveTo(cx - 96, cy + 22); ctx.lineTo(cx + 96, cy + 22); ctx.stroke();
        }

        function box(ctx, x, y, w, h) {
            rr(ctx, x, y, w, h, 12); ctx.fillStyle = "rgba(10,16,28,0.72)"; ctx.fill();
            rr(ctx, x, y, w, h, 12); ctx.strokeStyle = "rgba(155,185,230,0.55)"; ctx.lineWidth = 2; ctx.stroke();
        }
        function rr(ctx, x, y, w, h, r) {
            r = Math.min(r, w / 2, h / 2);
            ctx.beginPath();
            ctx.moveTo(x + r, y);
            ctx.lineTo(x + w - r, y);            ctx.quadraticCurveTo(x + w, y, x + w, y + r);
            ctx.lineTo(x + w, y + h - r);        ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
            ctx.lineTo(x + r, y + h);            ctx.quadraticCurveTo(x, y + h, x, y + h - r);
            ctx.lineTo(x, y + r);                ctx.quadraticCurveTo(x, y, x + r, y);
            ctx.closePath();
        }
    }

    // ---- TACH layer (declarative, GPU-composited) --------------------------
    Item {
        id: tachLit
        anchors.fill: parent

        property int tickCount: Math.floor(root.rpmmax / 100) + 1

        Repeater {
            model: tachLit.tickCount
            delegate: Item {
                readonly property int    v:        index * 100
                readonly property bool   major:    (v % 1000) === 0
                readonly property bool   redZone:  v >= root.rpmredline
                readonly property bool   lit:      v <= root.rpmShown + 30
                readonly property real   angleDeg: 140 + (v / Math.max(1, root.rpmmax)) * 260
                readonly property real   aRad:     angleDeg * Math.PI / 180
                readonly property real   ri:       major ? 142 : 156
                readonly property real   ro:       186
                readonly property real   rmid:     (ri + ro) / 2
                readonly property real   cxg:      400 + rmid * Math.cos(aRad)
                readonly property real   cyg:      212 + rmid * Math.sin(aRad)
                readonly property string litCol:   redZone ? "#ff2a2a" : (major ? "#bcd6ff" : root.accent)
                readonly property string glowCol:  root.overrev ? "#ef2a2a" : root.accent

                Rectangle {
                    width: 16; height: parent.ro - parent.ri + 10; radius: 8
                    antialiasing: true
                    color: parent.glowCol
                    opacity: parent.lit ? 0.14 : 0
                    x: parent.cxg - width / 2; y: parent.cyg - height / 2
                    transformOrigin: Item.Center
                    rotation: parent.angleDeg + 90
                }
                Rectangle {
                    width: parent.major ? 4 : 2; height: parent.ro - parent.ri
                    antialiasing: true
                    color: parent.litCol
                    opacity: parent.lit ? 1 : 0
                    x: parent.cxg - width / 2; y: parent.cyg - height / 2
                    transformOrigin: Item.Center
                    rotation: parent.angleDeg + 90
                }
            }
        }
    }

    // ---- DYNAMIC readout layer (declarative) -------------------------------
    Item {
        id: readouts
        anchors.fill: parent

        // ===== centre stack: gear / rpm / speed =====
        Text {   // gear — centred in the bg pill (centre 400,139)
            text: root.gearLabel; color: "#ffffff"
            font.family: root.menuFont; font.bold: true; font.pixelSize: 38
            x: 400 - width / 2; y: 141 - height / 2 - 1
        }

        // RPM number — centered horizontally in its slot
        Text {
            id: rpmNum
            text: root.engineOff ? "\u2013\u2013\u2013\u2013" : String(Math.round(root.rpmShown / 10) * 10)
            color: root.engineOff ? "#566581"
                 : (root.overrev ? (root.blinkOn ? "#ff4040" : "#ff8a8a") : "#ffffff")
            font.family: root.menuFont; font.bold: true; font.pixelSize: root.placementSwap ? 48 : 54
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.placementSwap ? (290 - 52) : (214 - 56)
        }

        // "RPM" tag — centered directly below the RPM number
        Text {
            id: rpmTag
            text: "RPM"
            color: root.engineOff ? "#566581" : (root.overrev ? "#ff5555" : root.accent)
            font.family: root.menuFont; font.bold: true; font.pixelSize: 14
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.placementSwap ? 292 : 216
        }

        // Speed number — centered horizontally in its slot
        Text {
            id: spdNum
            text: root.engineOff ? "\u2013\u2013\u2013" : String(root.speedShown)
            color: root.engineOff ? "#566581" : "#ffffff"
            font.family: root.menuFont; font.bold: true; font.pixelSize: root.placementSwap ? 54 : 48
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.placementSwap ? (214 - 56) : (290 - 52)
        }

        // Speed unit — centered directly below the speed number
        Text {
            id: spdUnit
            text: root.speedunits === 0 ? "km/h" : "mph"
            color: root.engineOff ? "#566581" : "#9fb2d0"
            font.family: root.menuFont; font.bold: true; font.pixelSize: 14
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.placementSwap ? 216 : 292
        }

        // shift lights below speed: three red rings
        Row {
            visible: !root.hideShiftLights
            anchors.horizontalCenter: parent.horizontalCenter
            y: 312; spacing: 16
            Repeater {
                model: [ { bit: 0x80000,  rpmFrac: 0.90 },
                         { bit: 0x100000, rpmFrac: 0.95 },
                         { bit: 0x200000, rpmFrac: 1.00 } ]
                Image {
                    source: "assets/shiftlight.png"
                    height: 22
                    width: implicitHeight > 0 ? 22 * implicitWidth / implicitHeight : 32
                    fillMode: Image.PreserveAspectFit
                    smooth: true; antialiasing: true
                    opacity: {
                        var lit = ((root.inputs & modelData.bit) !== 0)
                                  || (root.rpmShown >= root.rpmredline * modelData.rpmFrac);
                        if (!lit) return 0.0;
                        return root.overrev ? (root.blinkOn ? 1.0 : 0.0) : 1.0;
                    }
                }
            }
        }

        // ===== four side mini-gauges (box chrome is on bg) =====
        Repeater {
            model: [
                { kind: "oilpress", bx: 12,  by: 96,  isRight: false },
                { kind: "oiltemp",  bx: 12,  by: 214, isRight: false },
                { kind: "afr",      bx: 612, by: 96,  isRight: true  },
                { kind: "coolant",  bx: 612, by: 214, isRight: true  }
            ]
            delegate: Item {
                id: cell
                x: modelData.bx; y: modelData.by; width: 176; height: 104
                visible: root.selfTest || (root.gaugeShown(modelData.kind) && !root.peakOccupies(modelData.kind))
                property bool   isRight: modelData.isRight
                property bool   warn:    root.gaugeWarn(modelData.kind)
                property bool   critical:(modelData.kind === "oilpress" && !root.engineOff && root.oilPressShown <= root.oilPressLow)
                                      || (modelData.kind === "coolant"  && root.watertemp >= root.coolantHigh)
                property real   frac:    root.selfTest ? (root.sweepFrac * (1 - root.settle) + root.gaugeFrac(modelData.kind) * root.settle) : root.gaugeFrac(modelData.kind)
                property string valStr:  root.gaugeVal(modelData.kind)
                property string unitStr: root.gaugeUnit(modelData.kind)

                Text {   // label
                    text: root.gaugeLabel(modelData.kind)
                    color: cell.warn ? "#ff7777" : root.accent
                    font.family: root.menuFont; font.bold: true; font.pixelSize: 14
                    x: cell.isRight ? (parent.width - 16 - width) : 16
                    y: 26 - 13
                }
                Text {   // unit, sharing baseline with value
                    id: gUnit
                    visible: cell.unitStr !== ""
                    text: cell.unitStr; color: "#9fb2d0"
                    font.family: root.menuFont; font.bold: true; font.pixelSize: 15
                    x: cell.isRight ? (parent.width - 16 - width) : (gVal.x + gVal.width + 8)
                    y: 64 - 14
                }
                Text {   // value (left-aligned on left tiles, right-aligned on right tiles)
                    id: gVal
                    text: cell.valStr
                    color: cell.warn ? "#ff5050" : "#ffffff"
                    opacity: (cell.critical && !root.blinkOn) ? 0.25 : 1.0
                    font.family: root.menuFont; font.bold: true; font.pixelSize: 38
                    x: cell.isRight ? (gUnit.visible ? (gUnit.x - width - 6) : (parent.width - 16 - width)) : 16
                    y: 64 - 36
                }
                Rectangle { x: 16; y: 104 - 22; width: 144; height: 8; color: "#1a2336" }  // track
                Rectangle {   // fill bar
                    x: 16; y: 104 - 22; height: 8
                    width: cell.frac > 0 ? Math.max(6, 144 * cell.frac) : 0
                    color: (!root.selfTest && cell.warn) ? "#ff3b30" : root.accent
                }
            }
        }

        // ===== PEAK card =====
        Item {
            id: peakCard
            x: root.peakX; y: root.peakY; width: 176; height: 104
            visible: root.showPeak && !root.selfTest
            readonly property bool isRight: (x > 400)

            Text {                                   // label
                text: "PEAK"; color: root.accent
                font.family: root.menuFont; font.bold: true; font.pixelSize: 14
                x: peakCard.isRight ? (parent.width - 16 - width) : 16
                y: 13
            }
            Column {                                 // one row per enabled peak metric
                x: 16; y: root.peakColY; width: 148; spacing: 1
                Repeater {
                    model: root.peakRows
                    delegate: Item {
                        width: 148; height: root.peakRowH
                        Text {
                            text: modelData.label; color: "#9fb2d0"
                            font.family: root.menuFont; font.bold: true; font.pixelSize: root.peakFont
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            width: 60; fontSizeMode: Text.HorizontalFit; minimumPixelSize: 8
                        }
                        Text {
                            text: modelData.text; color: "#ffffff"
                            font.family: root.menuFont; font.bold: true; font.pixelSize: root.peakFont
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignRight; width: 84
                            fontSizeMode: Text.HorizontalFit; minimumPixelSize: 9
                        }
                    }
                }
            }
        }

        // ===== battery readout (bottom bar, left - aligned with left tiles above) =====
        Item {
            id: bat
            property bool  warn: root.batteryShown < root.batteryLow || root.batteryShown > root.batteryHigh
            property color col:  (!root.selfTest && warn) ? "#ff5050" : root.accent
            readonly property real realLvl: Math.max(0, Math.min(1, (root.batteryShown - root.batteryLow)
                                 / Math.max(0.1, root.batteryHigh - root.batteryLow)))
            property real  lvl:  root.selfTest ? (root.sweepFrac * (1 - root.settle) + realLvl * root.settle) : realLvl

            // Battery body (x=28 matches left edge of tiles)
            Rectangle {
                id: batBody
                x: 28; y: 388 - height / 2; width: 32; height: 20; radius: 3
                color: "#0e1626"
                border.color: bat.col; border.width: 2
            }
            // Positive terminal nub
            Rectangle {
                x: batBody.x + batBody.width; y: 388 - height / 2
                width: 3; height: 8; radius: 1
                color: bat.col
            }
            // Level fill
            Rectangle {
                x: batBody.x + 3; y: 388 - height / 2
                width: Math.max(0, (batBody.width - 6) * bat.lvl)
                height: batBody.height - 6; radius: 1
                color: bat.col
            }
            // Voltage text (proportional size, vertical center aligned)
            Text {
                id: vText
                text: root.batteryShown.toFixed(1) + "V"
                color: bat.warn ? "#ff7777" : "#ffffff"
                font.family: root.menuFont; font.bold: true; font.italic: true; font.pixelSize: 18
                anchors.verticalCenter: batBody.verticalCenter
                x: batBody.x + batBody.width + 10
            }
            // Service icon
            Image {
                visible: root.selfTest || (root.inputs & 0x400000) !== 0
                source: "assets/service.png"
                height: 20
                width: implicitHeight > 0 ? 20 * implicitWidth / implicitHeight : 20
                fillMode: Image.PreserveAspectFit; smooth: true; antialiasing: true
                anchors.verticalCenter: batBody.verticalCenter
                x: vText.x + vText.width + 12
            }
        }

        // ===== fuel readout (bottom bar, right - aligned with right tiles above) =====
        Item {
            id: fuelGrp
            property int  segCount: 10
            property int  litCount: Math.round(root.fuelBarFrac * segCount)
            property bool isLow:    !root.selfTest && (root.fuelLevel < root.fuelLow)

            // Fuel bar track (width 114, ends at x=772 to align with tiles above)
            Rectangle {
                id: fuelTrack
                x: 772 - width; y: 388 - height / 2
                width: 114; height: 20; radius: 3
                color: "#0e1626"
                border.color: fuelGrp.isLow ? "#ff4444" : "#1f2d47"
                border.width: 1

                Row {
                    anchors.centerIn: parent
                    spacing: 3
                    Repeater {
                        model: fuelGrp.segCount
                        delegate: Rectangle {
                            width: 8; height: 14; radius: 1
                            color: (index < fuelGrp.litCount)
                                   ? (fuelGrp.isLow ? "#ff4040" : "#2ed573")
                                   : "#182236"
                        }
                    }
                }
            }

            // Fuel pump icon (starts at x=628 to complete the 144px column width)
            Image {
                id: fuelImg
                source: fuelGrp.isLow ? "assets/fuel_level_warning.png"
                                      : "assets/fuel.png"
                height: 20
                width: implicitHeight > 0 ? 20 * implicitWidth / implicitHeight : 20
                fillMode: Image.PreserveAspectFit; smooth: true; antialiasing: true
                anchors.verticalCenter: fuelTrack.verticalCenter
                anchors.right: fuelTrack.left
                anchors.rightMargin: 10
                opacity: fuelGrp.isLow ? 1.0 : 0.85
            }
        }

        // ===== odo / trip (in telltale row, right-aligned) =====
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 28
            y: 417 + 13 - height / 2
            spacing: 16
            Text {
                text: "ODO " + Math.round(root.odometer * root.distFactor) + root.distUnit
                color: "#c9d6ee"; font.family: root.menuFont; font.bold: true; font.pixelSize: 13
            }
            Text {
                text: "TRIP " + Math.round(root.tripmeter * root.distFactor) + root.distUnit
                color: "#c9d6ee"; font.family: root.menuFont; font.bold: true; font.pixelSize: 13
            }
        }
    }

    // ====================================================================
    //  TELLTALES — icon set (assets/*.png), lit from inputsdata bits
    // ====================================================================
    property bool blinkOn: true
    Timer { interval: 420; repeat: true; running: true
            onTriggered: root.blinkOn = !root.blinkOn }
    Timer {
        interval: 400; repeat: true; running: true
        onTriggered: {
            if (root.batteryShown === 0 || Math.abs(root.battery - root.batteryShown) >= 0.08)
                root.batteryShown = root.battery;
        }
    }

    Row {
        x: 28; y: 417; spacing: 12
        Repeater {
            model: [
                { src: "high_beam",            bit: 0x10 },
                { src: "sidelight",            bit: 0x800 },
                { src: "rear_fog",             bit: 0x08 },
                { src: "brake_warning",        bit: 0x8000100 },
                { src: "oil_pressure_warning", bit: 0x200 },
                { src: "battery_warning",      bit: 0x02 },
                { src: "seatbelt_warning",     bit: 0x400 },
                { src: "abs_warning",          bit: 0x20000 },
                { src: "tc_warning",           bit: 0x10000 },
                { src: "mil_warning",          bit: 0x40000 },
                { src: "airbag_warning",       bit: 0x8000 },
                { src: "door_open",            bit: 0x4000 }
            ]
            Item {
                id: ttCell
                height: 26
                width: ttImg.width
                readonly property bool isTc:  modelData.src === "tc_warning"
                readonly property bool tcOff: (root.inputs & 0x10000000) !== 0
                Image {
                    id: ttImg
                    source: "assets/" + modelData.src + ".png"
                    height: 26
                    width: Math.min(40, implicitHeight > 0 ? 26 * implicitWidth / implicitHeight : 36)
                    fillMode: Image.PreserveAspectFit
                    smooth: true; antialiasing: true
                    opacity: (root.selfTest || (root.inputs & modelData.bit) || (ttCell.isTc && ttCell.tcOff)) ? 1.0 : 0.25
                }
                Rectangle {
                    visible: ttCell.isTc && ttCell.tcOff
                    anchors.centerIn: ttImg
                    width: offTxt.implicitWidth + 4; height: offTxt.implicitHeight + 1; radius: 2
                    color: "#000000"; opacity: 0.6
                }
                Text {
                    id: offTxt
                    visible: ttCell.isTc && ttCell.tcOff
                    anchors.centerIn: ttImg
                    text: "OFF"; color: "#ffffff"
                    font.family: root.menuFont; font.bold: true; font.pixelSize: 9
                }
            }
        }
    }

    // ECU ASCII status line
    Text {
        id: canAsciiText
        property string pending: root.canAsciiStr
        property int canAsciiPairs: 0
        property bool canAsciiAwaitFault: false
        property bool canAsciiInFault: false
        property bool canAsciiHushed: false
        readonly property int canAsciiSuppressAfter: 5
        readonly property int canAsciiDwellMs: 900
        onPendingChanged: canAsciiSettle.restart()
        visible: text.length > 0
        text: ""
        x: 28; y: 451
        width: 580; elide: Text.ElideRight
        color: "#ffcf6b"
        font.family: root.menuFont; font.bold: true; font.pixelSize: 16
        Timer {
            id: canAsciiSettle
            interval: 120; repeat: false
            onTriggered: {
                var c = canAsciiText.pending;
                if (!c) {
                    canAsciiClearTimer.restart();
                } else {
                    var show = c;
                    if (c === "TPMS") {
                        if (canAsciiText.canAsciiSuppressAfter > 0
                            && canAsciiText.canAsciiPairs >= canAsciiText.canAsciiSuppressAfter)
                            canAsciiText.canAsciiHushed = true;
                        canAsciiText.canAsciiAwaitFault = true;
                        canAsciiText.canAsciiInFault = true;
                        if (canAsciiText.canAsciiHushed) show = "";
                    } else if (c === "FAULT") {
                        if (canAsciiText.canAsciiAwaitFault) {
                            canAsciiText.canAsciiAwaitFault = false;
                            if (!canAsciiText.canAsciiHushed) canAsciiText.canAsciiPairs += 1;
                        }
                        if (canAsciiText.canAsciiHushed && canAsciiText.canAsciiInFault) show = "";
                    } else {
                        canAsciiText.canAsciiAwaitFault = false;
                        canAsciiText.canAsciiInFault = false;
                    }
                    if (show && canAsciiText.text && show !== canAsciiText.text
                        && root.canAsciiSameRotation(show, canAsciiText.text)) show = canAsciiText.text;
                    if (show && canAsciiText.text && show !== canAsciiText.text
                        && root.canAsciiSeverity(show) !== 2 && canAsciiDwell.running)
                        return;
                    canAsciiClearTimer.stop();
                    if (show !== canAsciiText.text) {
                        canAsciiText.text = show;
                        if (show) canAsciiDwell.restart(); else canAsciiDwell.stop();
                    }
                }
            }
        }
        Timer {
            id: canAsciiClearTimer
            interval: 3000; repeat: false
            onTriggered: { canAsciiText.text = ""; canAsciiText.canAsciiAwaitFault = false; canAsciiText.canAsciiInFault = false; }
        }
        Timer {
            id: canAsciiDwell
            interval: canAsciiText.canAsciiDwellMs; repeat: false
            onTriggered: canAsciiSettle.restart()
        }
    }

    Image {
        source: "assets/left_indicator.png"
        x: 36; y: 18; height: 50; fillMode: Image.PreserveAspectFit
        smooth: true
        visible: root.tLeftActive
    }
    Image {
        source: "assets/right_indicator.png"
        x: 718; y: 18; height: 50; fillMode: Image.PreserveAspectFit
        smooth: true
        visible: root.tRightActive
    }

    // ---- NIGHTLIGHT dimmer ------------------------------------------------
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: root.nightlight / 100 * 0.7
        visible: root.nightlight > 0
    }

    // =======================================================================
    //  SETTINGS — config file, D-pad, and the scrolling menu
    // =======================================================================
    property string cfgPath: "/opt/IC7/screen_configs/gtdash_config.txt"
    readonly property var cfgCandidates: [
        "/opt/Garw_IC7/screen_configs/gtdash_config.txt",
        "/opt/IC7/screen_configs/gtdash_config.txt"
    ]
    FileIO {
        id: cfg
        source: root.cfgPath
        onError: console.log("GTDash FileIO: " + msg)
    }

    function rline(i) {
        var s = "";
        try { cfg.openforreading(); s = cfg.readopenfile(i); cfg.close(); }
        catch (e) { console.log("GTDash: read line " + i + " failed (" + e + ")"); }
        return s;
    }
    function resolveCfgPath() {
        var i, s;
        for (i = 0; i < root.cfgCandidates.length; i++) {
            root.cfgPath = root.cfgCandidates[i];
            s = rline(0);
            if (s !== "" && s !== undefined && s !== null) return;
        }
        for (i = 0; i < root.cfgCandidates.length; i++) {
            root.cfgPath = root.cfgCandidates[i];
            saveConfig();
            s = rline(0);
            if (s !== "" && s !== undefined && s !== null) return;
        }
        root.cfgPath = root.cfgCandidates[root.cfgCandidates.length - 1];
    }
    function loadConfig() {
        function pI(s, def) { return (s !== "" && s !== undefined && s !== null) ? parseInt(s)   : def; }
        function pF(s, def) { return (s !== "" && s !== undefined && s !== null) ? parseFloat(s) : def; }
        var s0 = rline(0);
        var found = (s0 !== "" && s0 !== undefined && s0 !== null);
        if (!found) return false;
        root.red          = pI(s0,         root.red);
        root.green        = pI(rline(1),   root.green);
        root.blue         = pI(rline(2),   root.blue);
        root.rpmredline   = pI(rline(3),   root.rpmredline);
        root.rpmmax       = pI(rline(4),   root.rpmmax);
        root.rpmDamp      = pI(rline(5),   root.rpmDamp);
        root.speedunits   = pI(rline(6),   root.speedunits);
        root.distunits    = pI(rline(7),   root.distunits);
        root.coolantHigh  = pF(rline(8),   root.coolantHigh);
        root.coolantLow   = pF(rline(9),   root.coolantLow);
        root.tempunits    = pI(rline(10),  root.tempunits);
        root.fuelHigh     = pI(rline(11),  root.fuelHigh);
        root.fuelLow      = pI(rline(12),  root.fuelLow);
        root.fuelDamp     = pI(rline(13),  root.fuelDamp);
        root.oilTempHigh  = pF(rline(14),  root.oilTempHigh);
        root.oilTempLow   = pF(rline(15),  root.oilTempLow);
        root.oilTempUnits = pI(rline(16),  root.oilTempUnits);
        root.oilPressHigh = pF(rline(17),  root.oilPressHigh);
        root.oilPressLow  = pF(rline(18),  root.oilPressLow);
        root.oilPressUnits= pI(rline(19),  root.oilPressUnits);
        root.batteryHigh  = pF(rline(20),  root.batteryHigh);
        root.batteryLow   = pF(rline(21),  root.batteryLow);
        root.afrHigh      = pF(rline(22),  root.afrHigh);
        root.afrLow       = pF(rline(23),  root.afrLow);
        root.nightlight   = pI(rline(24),  root.nightlight);
        root.afrSource    = pI(rline(25),  root.afrSource);
        root.placementSwap= pI(rline(26),  root.placementSwap ? 1 : 0) !== 0;
        root.hideTachNums = pI(rline(27),  root.hideTachNums ? 1 : 0) !== 0;
        root.hideShiftLights = pI(rline(28), root.hideShiftLights ? 1 : 0) !== 0;
        root.showPeakGauge   = pI(rline(29), root.showPeakGauge ? 1 : 0) !== 0;
        root.peakGaugePosition = pI(rline(30), root.peakGaugePosition);
        root.peakShowRpm      = pI(rline(31), root.peakShowRpm      ? 1 : 0) !== 0;
        root.peakShowSpeed    = pI(rline(32), root.peakShowSpeed    ? 1 : 0) !== 0;
        root.peakShowAfr      = pI(rline(33), root.peakShowAfr      ? 1 : 0) !== 0;
        root.peakShowOilTemp  = pI(rline(34), root.peakShowOilTemp  ? 1 : 0) !== 0;
        root.peakShowOilPress = pI(rline(35), root.peakShowOilPress ? 1 : 0) !== 0;
        root.peakShowCoolant  = pI(rline(36), root.peakShowCoolant  ? 1 : 0) !== 0;
        return found;
    }
    function saveConfig() {
        try {
            var vals = [root.red, root.green, root.blue, root.rpmredline, root.rpmmax,
                        root.rpmDamp, root.speedunits, root.distunits, root.coolantHigh.toFixed(1),
                        root.coolantLow.toFixed(1), root.tempunits, root.fuelHigh, root.fuelLow,
                        root.fuelDamp, root.oilTempHigh.toFixed(1), root.oilTempLow.toFixed(1), root.oilTempUnits,
                        root.oilPressHigh.toFixed(1), root.oilPressLow.toFixed(1), root.oilPressUnits,
                        root.batteryHigh.toFixed(1), root.batteryLow.toFixed(1),
                        root.afrHigh.toFixed(2), root.afrLow.toFixed(2), root.nightlight,
                        root.afrSource, (root.placementSwap ? 1 : 0), (root.hideTachNums ? 1 : 0),
                        (root.hideShiftLights ? 1 : 0),
                        (root.showPeakGauge ? 1 : 0), root.peakGaugePosition,
                        (root.peakShowRpm ? 1 : 0), (root.peakShowSpeed ? 1 : 0),
                        (root.peakShowAfr ? 1 : 0), (root.peakShowOilTemp ? 1 : 0),
                        (root.peakShowOilPress ? 1 : 0), (root.peakShowCoolant ? 1 : 0)];
            var out = "";
            for (var i = 0; i < vals.length; i++) out += String(vals[i]) + "\n";
            cfg.open();
            cfg.writetoopenfile(out);
            cfg.close();
        } catch (e) { console.log("GTDash: could not write config (" + e + ")"); }
    }

    Component.onCompleted: {
        if (root.d) { try { root.d.DISABLE_WARNING_OVERLAY = "YES_WARNINGS_HANDLED_LOCALLY"; } catch (e) {} }
        resolveCfgPath();
        if (!loadConfig())
            saveConfig();
        fuelDisplay = fuel;
        oilPressShown = oilpress;
        bootSweep.start();
    }

    // ---- D-pad input -------------------------------------------------------
    function udp()    { return (root.d && root.d.udp_packetdata !== undefined) ? root.d.udp_packetdata : 0; }
    function dUp()    { return ((root.inputs & 0x20) !== 0)       || ((udp() & 0x01) !== 0); }
    function dDown()  { return ((root.inputs & 0x2000) !== 0)     || ((udp() & 0x02) !== 0); }
    function dLeft()  { return ((root.inputs & 0x20000000) !== 0) || ((udp() & 0x04) !== 0); }
    function dRight() { return ((root.inputs & 0x40000000) !== 0) || ((udp() & 0x08) !== 0); }

    // ---- menu model --------------------------------------------------------
    property bool menuOpen: false
    property int  sel: 0
    property int  settingsRev: 0
    property real pulse: 0
    property bool pUp: false
    property bool pDown: false
    property bool pLeft: false
    property bool pRight: false
    property int  upHold: 0
    property int  downHold: 0
    property bool upArmed: false
    property bool downArmed: false

    readonly property var itemsAll: [
        { k: "shift",  label: "SHIFT RPM" },
        { k: "limit",  label: "RPM LIMIT" },
        { k: "rdamp",  label: "RPM DAMPING" },
        { k: "red",    label: "RED" },
        { k: "green",  label: "GREEN" },
        { k: "blue",   label: "BLUE" },
        { k: "speed",  label: "SPEED UNIT" },
        { k: "dist",   label: "DIST UNIT" },
        { k: "chi",    label: "COOLANT HIGH" },
        { k: "clo",    label: "COOLANT LOW" },
        { k: "cun",    label: "COOLANT UNIT" },
        { k: "fhi",    label: "FUEL HIGH" },
        { k: "flo",    label: "FUEL LOW" },
        { k: "fdmp",   label: "FUEL DAMP" },
        { k: "othi",   label: "OIL TEMP HIGH" },
        { k: "otlo",   label: "OIL TEMP LOW" },
        { k: "otun",   label: "OIL TEMP UNIT" },
        { k: "ophi",   label: "OIL PRESS HIGH" },
        { k: "oplo",   label: "OIL PRESS LOW" },
        { k: "opun",   label: "OIL PRESS UNIT" },
        { k: "bhi",    label: "BATTERY HIGH" },
        { k: "blo",    label: "BATTERY LOW" },
        { k: "ahi",    label: "AFR HIGH" },
        { k: "alo",    label: "AFR LOW" },
        { k: "asrc",   label: "AFR SOURCE" },
        { k: "night",  label: "NIGHTLIGHT" },
        { k: "swap",   label: "RPM/SPEED SWAP" },
        { k: "pkon",   label: "SHOW PEAK GAUGE" },
        { k: "pkpos",  label: "PEAK POSITION" },
        { k: "pkrpm",  label: "PEAK: RPM" },
        { k: "pkspd",  label: "PEAK: SPEED" },
        { k: "pkafr",  label: "PEAK: AFR" },
        { k: "pkotm",  label: "PEAK: OIL TEMP" },
        { k: "pkopr",  label: "PEAK: OIL PRESS" },
        { k: "pkcol",  label: "PEAK: COOLANT" },
        { k: "pkrst",  label: "RESET PEAKS" },
        { k: "htn",    label: "HIDE TACH NUMS" },
        { k: "hsl",    label: "HIDE SHIFT LIGHTS" },
        { k: "exit",   label: "EXIT" }
    ]
    readonly property var peakItemKeys: ["pkrpm","pkspd","pkafr","pkotm","pkopr","pkcol","pkrst"]
    readonly property var items: itemsAll
    function rowHidden(k) { return !showPeakGauge && peakItemKeys.indexOf(k) !== -1; }
    readonly property var noRamp: ["speed", "dist", "cun", "otun", "opun", "asrc", "swap", "pkon", "pkpos", "pkrpm", "pkspd", "pkafr", "pkotm", "pkopr", "pkcol", "pkrst", "htn", "hsl", "exit"]
    function isRampable(k) { return noRamp.indexOf(k) === -1; }

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

    function applyValue(dir) {
        var k = items[sel].k;
        switch (k) {
        case "shift":  root.rpmredline   = clamp(root.rpmredline + dir * 100, 2000, root.rpmmax - 100); break;
        case "limit":  root.rpmmax       = clamp(root.rpmmax     + dir * 100, 4000, 12000); break;
        case "rdamp":  root.rpmDamp      = clamp(root.rpmDamp    + dir,        1,    10);    break;
        case "red":    root.red          = clamp(root.red        + dir * 5,    0,    255);   break;
        case "green":  root.green        = clamp(root.green      + dir * 5,    0,    255);   break;
        case "blue":   root.blue         = clamp(root.blue       + dir * 5,    0,    255);   break;
        case "speed":  root.speedunits   = (root.speedunits === 0) ? 1 : 0;   break;
        case "dist":   root.distunits    = (root.distunits  === 0) ? 1 : 0;   break;
        case "chi":    root.coolantHigh  = clamp(root.coolantHigh + dir * (root.tempunits === 1 ? 5/9 : 1), 60, 150);  break;
        case "clo":    root.coolantLow   = clamp(root.coolantLow  + dir * (root.tempunits === 1 ? 5/9 : 1), 0,  140);  break;
        case "cun":    root.tempunits    = ((root.tempunits + dir) % 3 + 3) % 3;    break;
        case "fhi":    root.fuelHigh     = clamp(root.fuelHigh + dir, 0, 100); break;
        case "flo":    root.fuelLow      = clamp(root.fuelLow  + dir, 0, 100); break;
        case "fdmp":   root.fuelDamp     = clamp(root.fuelDamp + dir, 0, 9);   break;
        case "othi":   root.oilTempHigh  = clamp(root.oilTempHigh + dir * (root.oilTempUnits === 1 ? 5/9 : 1), 0, 250); break;
        case "otlo":   root.oilTempLow   = clamp(root.oilTempLow  + dir * (root.oilTempUnits === 1 ? 5/9 : 1), 0, 250); break;
        case "otun":   root.oilTempUnits = ((root.oilTempUnits + dir) % 3 + 3) % 3; break;
        case "pkon":   root.showPeakGauge = !root.showPeakGauge; break;
        case "pkpos":  root.peakGaugePosition = ((root.peakGaugePosition - 1 + dir) % 4 + 4) % 4 + 1; break;
        case "pkrpm":  root.peakShowRpm      = !root.peakShowRpm;      break;
        case "pkspd":  root.peakShowSpeed    = !root.peakShowSpeed;    break;
        case "pkafr":  root.peakShowAfr      = !root.peakShowAfr;      break;
        case "pkotm":  root.peakShowOilTemp  = !root.peakShowOilTemp;  break;
        case "pkopr":  root.peakShowOilPress = !root.peakShowOilPress; break;
        case "pkcol":  root.peakShowCoolant  = !root.peakShowCoolant;  break;
        case "pkrst":  if (dir > 0) root.resetPeaks(); break;
        case "ophi":   root.oilPressHigh = clamp(root.oilPressHigh + dir * (root.oilPressUnits === 1 ? 1.45038 : 1), 0, 200); break;
        case "oplo":   root.oilPressLow  = clamp(root.oilPressLow  + dir * (root.oilPressUnits === 1 ? 1.45038 : 1), 0, 200); break;
        case "opun":   root.oilPressUnits= ((root.oilPressUnits + dir) % 3 + 3) % 3; break;
        case "bhi":    root.batteryHigh  = clamp(root.batteryHigh + dir * 0.1, 0, 20); break;
        case "blo":    root.batteryLow   = clamp(root.batteryLow  + dir * 0.1, 0, 20); break;
        case "ahi":    root.afrHigh      = clamp(root.afrHigh + dir * (root.afrSource === 0 ? 0.1/14.7 : 0.01), 0.5, 1.5); break;
        case "alo":    root.afrLow       = clamp(root.afrLow  + dir * (root.afrSource === 0 ? 0.1/14.7 : 0.01), 0.5, 1.5); break;
        case "asrc":   root.afrSource    = ((root.afrSource + dir) % 3 + 3) % 3; break;
        case "night":  root.nightlight   = clamp(root.nightlight + dir * 5, 0, 100); break;
        case "swap":   root.placementSwap = !root.placementSwap; break;
        case "htn":    root.hideTachNums  = !root.hideTachNums;  break;
        case "hsl":    root.hideShiftLights = !root.hideShiftLights; break;
        case "exit":   if (dir > 0) { saveConfig(); closeMenu(); return; } break;
        }
        root.settingsRev += 1;
    }

    function valueText(k) {
        switch (k) {
        case "shift":  return String(root.rpmredline);
        case "limit":  return String(root.rpmmax);
        case "rdamp":  return String(root.rpmDamp);
        case "red":    return String(root.red);
        case "green":  return String(root.green);
        case "blue":   return String(root.blue);
        case "speed":  return root.speedunits === 0 ? "KM/H" : "MPH";
        case "dist":   return root.distunits  === 0 ? "KM" : "MI";
        case "chi":    return (root.tempunits === 1 ? Math.round(root.coolantHigh * 9/5 + 32) : Math.round(root.coolantHigh)) + "\u00B0";
        case "clo":    return (root.tempunits === 1 ? Math.round(root.coolantLow  * 9/5 + 32) : Math.round(root.coolantLow))  + "\u00B0";
        case "cun":    return root.tempunits === 0 ? "\u00B0C" : root.tempunits === 1 ? "\u00B0F" : "OFF";
        case "fhi":    return root.fuelHigh + "%";
        case "flo":    return root.fuelLow  + "%";
        case "fdmp":   return String(root.fuelDamp);
        case "othi":   return (root.oilTempUnits === 1 ? Math.round(root.oilTempHigh * 9/5 + 32) : Math.round(root.oilTempHigh)) + "\u00B0";
        case "otlo":   return (root.oilTempUnits === 1 ? Math.round(root.oilTempLow  * 9/5 + 32) : Math.round(root.oilTempLow))  + "\u00B0";
        case "otun":   return root.oilTempUnits === 0 ? "\u00B0C" : root.oilTempUnits === 1 ? "\u00B0F" : "OFF";
        case "pkon":   return root.showPeakGauge ? "TRUE" : "FALSE";
        case "pkpos":  return root.peakGaugePosition === 1 ? "1 TL" : root.peakGaugePosition === 2 ? "2 TR" : root.peakGaugePosition === 3 ? "3 BL" : "4 BR";
        case "pkrpm":  return root.peakShowRpm      ? "TRUE" : "FALSE";
        case "pkspd":  return root.peakShowSpeed    ? "TRUE" : "FALSE";
        case "pkafr":  return root.peakShowAfr      ? "TRUE" : "FALSE";
        case "pkotm":  return root.peakShowOilTemp  ? "TRUE" : "FALSE";
        case "pkopr":  return root.peakShowOilPress ? "TRUE" : "FALSE";
        case "pkcol":  return root.peakShowCoolant  ? "TRUE" : "FALSE";
        case "pkrst":  return "PUSH \u25B2";
        case "ophi":   return root.oilPressUnits === 1 ? (root.oilPressHigh / 14.5038).toFixed(1) : String(Math.round(root.oilPressHigh));
        case "oplo":   return root.oilPressUnits === 1 ? (root.oilPressLow  / 14.5038).toFixed(1) : String(Math.round(root.oilPressLow));
        case "opun":   return root.oilPressUnits === 0 ? "PSI" : root.oilPressUnits === 1 ? "BAR" : "OFF";
        case "bhi":    return root.batteryHigh.toFixed(1) + "V";
        case "blo":    return root.batteryLow.toFixed(1) + "V";
        case "ahi":    return root.afrSource === 0 ? (root.afrHigh * 14.7).toFixed(1) : root.afrHigh.toFixed(2) + "\u03BB";
        case "alo":    return root.afrSource === 0 ? (root.afrLow  * 14.7).toFixed(1) : root.afrLow.toFixed(2)  + "\u03BB";
        case "asrc":   return root.afrSource === 0 ? "AFR" : root.afrSource === 1 ? "LAMBDA" : "OFF";
        case "night":  return root.nightlight === 0 ? "OFF" : String(root.nightlight);
        case "swap":   return root.placementSwap ? "TRUE" : "FALSE";
        case "htn":    return root.hideTachNums  ? "TRUE" : "FALSE";
        case "hsl":    return root.hideShiftLights ? "TRUE" : "FALSE";
        case "exit":   return "SAVE";
        }
        return "";
    }

    function openMenu()  { menuOpen = true; sel = 0; upArmed = false; downArmed = false; upHold = 0; downHold = 0; try { if (root.d) root.d.settings_on_offdata = 1; } catch (e) {} }
    function closeMenu() { menuOpen = false; try { if (root.d) root.d.settings_on_offdata = 0; } catch (e) {} }
    function moveSel(dir){
        var n = items.length;
        do { sel = ((sel + dir) % n + n) % n; } while (rowHidden(items[sel].k));
    }

    function evalEdges() {
        var u = dUp(), dn = dDown(), l = dLeft(), r = dRight();
        if (!menuOpen) {
            if (u && !pUp) openMenu();
        } else {
            if (l && !pLeft)  moveSel(-1);
            if (r && !pRight) moveSel(1);
            if (u && !pUp)   { applyValue(1);  upHold = 0; }
            if (dn && !pDown){ applyValue(-1); downHold = 0; }
        }
        pUp = u; pDown = dn; pLeft = l; pRight = r;
        root.tLeftActive  = ((root.inputs & 0x40) !== 0);
        root.tRightActive = ((root.inputs & 0x80) !== 0);
    }
    Connections {
        target: root.d
        ignoreUnknownSignals: true
        function onInputsdataChanged()     { root.evalEdges(); }
        function onUdp_packetdataChanged() { root.evalEdges(); }
    }
    Timer {
        interval: 50; running: true; repeat: true
        onTriggered: root.evalEdges()
    }
    Timer {
        interval: 90; running: root.menuOpen; repeat: true
        onTriggered: {
            if (root.menuOpen && root.isRampable(root.items[root.sel].k)) {
                if (root.dUp()) {
                    if (root.upArmed) { root.upHold += 1;
                        var ru = Math.max(1, 3 - Math.floor((root.upHold - 2) / 5));
                        if (root.upHold > 2 && root.upHold % ru === 0) root.applyValue(1);
                    }
                } else { root.upArmed = true; root.upHold = 0; }
                if (root.dDown()) {
                    if (root.downArmed) { root.downHold += 1;
                        var rd = Math.max(1, 3 - Math.floor((root.downHold - 2) / 5));
                        if (root.downHold > 2 && root.downHold % rd === 0) root.applyValue(-1);
                    }
                } else { root.downArmed = true; root.downHold = 0; }
            }
        }
    }

    // ---- settings overlay: panel + ListView -------------------------------
    Item {
        id: menu
        anchors.fill: parent
        visible: root.menuOpen

        readonly property int visibleRows: 11
        readonly property int rowH: 30

        Rectangle { anchors.fill: parent; color: "#03050c"; opacity: 0.80 }

        Rectangle {
            id: panel
            width: 540; height: 444; anchors.centerIn: parent
            radius: 16; color: "#0a0f1a"; border.color: "#1e2a44"; border.width: 2

            Text {
                text: "SETTINGS"; color: "#ffffff"
                font.pixelSize: 24; font.bold: true; font.family: root.menuFont
                anchors.horizontalCenter: parent.horizontalCenter; y: 14
            }
            Rectangle { x: 40; y: 50; width: parent.width - 80; height: 3; color: root.accent }

            ListView {
                id: menuList
                x: 22; y: 64
                width: parent.width - 44; height: menu.visibleRows * menu.rowH
                clip: true
                interactive: false
                model: root.items
                currentIndex: root.sel
                highlightMoveDuration: 0
                highlightRangeMode: ListView.ApplyRange
                preferredHighlightBegin: 5 * menu.rowH
                preferredHighlightEnd:   6 * menu.rowH
                delegate: Item {
                    id: row
                    width: ListView.view.width
                    height: root.rowHidden(modelData.k) ? 0 : menu.rowH
                    visible: !root.rowHidden(modelData.k)
                    property bool current: ListView.isCurrentItem
                    Rectangle {
                        visible: row.current
                        x: 0; y: 3; width: parent.width - 30; height: menu.rowH - 6
                        radius: 7; color: root.accent; opacity: 0.26
                    }
                    Rectangle {
                        visible: row.current
                        x: 0; y: 3; width: 4; height: menu.rowH - 6; color: root.accent
                    }
                    Text {
                        text: modelData.label
                        x: 22; anchors.verticalCenter: parent.verticalCenter
                        color: row.current ? "#ffffff" : "#9fb2d0"
                        font.pixelSize: 18; font.bold: true; font.family: root.menuFont
                    }
                    Text {
                        anchors.right: parent.right; anchors.rightMargin: 34
                        anchors.verticalCenter: parent.verticalCenter
                        text: { var r = root.settingsRev; return root.valueText(modelData.k); }
                        color: row.current ? "#ffffff" : root.accent
                        font.pixelSize: 18; font.bold: true; font.family: root.menuFont
                    }
                }
            }

            Rectangle {
                visible: menuList.contentHeight > menuList.height
                x: parent.width - 26; y: 64; width: 5
                height: menu.visibleRows * menu.rowH
                radius: 2; color: "#1c2740"
                Rectangle {
                    x: 0; width: 5; radius: 2; color: root.accent
                    y: parent.height * menuList.visibleArea.yPosition
                    height: Math.max(24, parent.height * menuList.visibleArea.heightRatio)
                }
            }

            Text {
                text: "Default units:  km \u00B7 \u00B0C \u00B7 bar \u00B7 \u03BB"
                color: "#7f93b6"; font.pixelSize: 12; font.family: root.menuFont
                anchors.horizontalCenter: parent.horizontalCenter
                y: parent.height - 48
            }
            Text {
                text: "L / R  SELECT      U / D  CHANGE"
                color: "#5f6f8a"; font.pixelSize: 13; font.family: root.menuFont
                anchors.horizontalCenter: parent.horizontalCenter
                y: parent.height - 28
            }
        }
    }

    // ---- rev-lag debug readout --------------------------------------------
    Rectangle {
        visible: root.showRawRpm
        x: 4; y: 54; width: dbgText.implicitWidth + 8; height: dbgText.implicitHeight + 4
        color: "#000000"; opacity: 0.55; radius: 4
    }
    Text {
        id: dbgText
        visible: root.showRawRpm
        x: 8; y: 56
        color: "#ffd23a"
        font.pixelSize: 14; font.bold: true
        font.family: uiFontR.status === FontLoader.Ready ? uiFontR.name : "sans-serif"
        text: "raw " + Math.round(root.rpm)
              + "   disp " + Math.round(root.rpmDisplay)
              + "   \u0394 " + Math.round(root.rpm - root.rpmDisplay)
    }

    // ---- raw-sensor readout -----------------------------------------------
    Rectangle {
        visible: root.showRawSensors
        x: 4; y: 76; width: rawSensText.implicitWidth + 8; height: rawSensText.implicitHeight + 4
        color: "#000000"; opacity: 0.55; radius: 4
    }
    Text {
        id: rawSensText
        visible: root.showRawSensors
        x: 8; y: 78
        color: "#7ee787"
        font.pixelSize: 13; font.bold: true
        font.family: uiFontR.status === FontLoader.Ready ? uiFontR.name : "sans-serif"
        text: "oilP=" + (root.d ? root.d.oilpressuredata : "?")
              + "  oilT=" + (root.d ? root.d.oiltempdata : "?")
              + "  cool=" + (root.d ? root.d.watertempdata : "?")
              + "  o2=" + (root.d ? root.d.o2data : "?")
              + "  spd=" + (root.d ? root.d.speeddata : "?")
    }
}