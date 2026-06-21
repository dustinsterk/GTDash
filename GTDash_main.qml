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
**     EXIT row + Up       save to /opt/IC7/screen_configs/gtdash_config.txt & close
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
**  Bottom row also has a RACE button (inputsdata 0x800000), a SPORT button
**  (0x1000000), and a battery-voltage readout (batteryvoltagedata).
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
    // Collapse a host buffer that does not self-clear and piles a message up.
    // (A) char-level: handles a *misaligned* window of a repeated unit such as
    //     "LT FAULT FAU" — find the smallest whole-string period; if the text is
    //     >= 2 periods, take one period rotated to a word boundary -> "FAULT".
    // (B) word-level: drop consecutive duplicate words, then collapse an exact
    //     repeated phrase. Distinct messages ("TPMS FAULT", "Boost Control Fault
    //     Detected") have no short period and are left untouched.
    function canAsciiCollapse(out) {
        if (!out.length) return "";
        var w = out.split(/\s+/);
        // The host window can open or close mid-word, so the first token may be a
        // SUFFIX of the real word ("AULT FAULT", "T FAULT", "ULT FAULT") and the
        // last token a PREFIX of it ("FAULT FAU", "LT FAULT FAU"). Drop those
        // partials. (substring, not endsWith/startsWith, for Qt 5.12.8 V4 safety.)
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
    onOilpressChanged: oilPressShown = oilpress
    property real afr:       d ? (d.o2data * 14.7)  : 0      // native lambda -> AFR (canonical, x14.7)
    property real battery:   d ? d.batteryvoltagedata : 0    // volts

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
    property int  oilTempUnits:  0     // 0 = °C, 1 = °F
    property real oilPressHigh:  90    // PSI (canonical)
    property real oilPressLow:   15    // PSI (canonical)
    property int  oilPressUnits: 1     // 0 = PSI, 1 = BAR  (sensor is native BAR)
    property real batteryHigh:   14.8
    property real batteryLow:    11.8
    property real afrHigh:       1.02   // O2 limits stored in LAMBDA (1.02 = 15.0 AFR)
    property real afrLow:        0.82   //                            (0.82 = 12.0 AFR)
    property int  afrSource:     1     // O2 DISPLAY: 0 = AFR, 1 = LAMBDA, 2 = OFF
                                       // (o2data is native lambda -> afr is canonical AFR)
    // afr is canonical AFR; afrShown converts it to the selected display unit
    readonly property real afrShown: afrSource === 1 ? afr / 14.7   // LAMBDA
                                   : afr                            // AFR  (OFF hides the gauge)

    // Each unit/source setting has an OFF state (the highest value) that hides
    // that side gauge entirely — both its panel box (static layer) and its live
    // content (dynamic layer): oil-temp/oil-press/coolant OFF=2, AFR OFF=3.
    readonly property bool showOilTemp:  oilTempUnits  !== 2
    readonly property bool showOilPress: oilPressUnits !== 2
    readonly property bool showCoolant:  tempunits     !== 2
    readonly property bool showAfr:      afrSource     !== 2

    // --- display ---
    property int  nightlight: 0        // 0..100 night dimmer (0 = off)

    // accent colour assembled from the RGB scheme (CSS hex for the Canvas)
    function hx(n) { n = Math.max(0, Math.min(255, Math.round(n))); var s = n.toString(16); return (s.length < 2 ? "0" : "") + s; }
    readonly property string accent: "#" + hx(red) + hx(green) + hx(blue)
    // rpm-needle smoothing. The spring chases rpmDisplay toward the live rpm.
    // RPM DAMPING 1..10 sets the rpm-needle spring stiffness: 1 = snappiest
    // (tracks a throttle blip tightly), 10 = a calm, lazy gliding needle.
    // Geometric scale — each step multiplies stiffness by a constant ratio
    // (~0.63), so the *perceived* change is even across 1..10 instead of
    // bunching at the stiff end. Measured settle (step to 5000 rpm, to within
    // 2%), desktop sim — approximate, confirm feel on hardware:
    //    damp  spring  settle        damp  spring  settle
    //     1     55.0   ~25 ms         6      5.2   ~175 ms
    //     2     34.4   ~50 ms         7      3.3   ~300 ms
    //     3*    21.5   ~75 ms         8      2.0   ~475 ms
    //     4     13.4   ~100 ms        9      1.3   ~900 ms
    //     5      8.4   ~150 ms        10     0.8   ~1400 ms
    //   (* = default)
    readonly property real springVal: 55.0 * Math.pow(0.8 / 55.0, (Math.max(1, Math.min(10, rpmDamp)) - 1) / 9.0)

    // ---- bundled UI font ---------------------------------------------------
    // The IC7's Qt does not alias the generic "sans-serif" to a sans font (it
    // falls back to a serif), so we ship DejaVu Sans and use it explicitly.
    FontLoader { id: uiFontR; source: "assets/DejaVuSans.ttf"
        onStatusChanged: if (status === FontLoader.Ready) root.fontsReady() }
    FontLoader { id: uiFontB; source: "assets/DejaVuSans-Bold.ttf"
        onStatusChanged: if (status === FontLoader.Ready) root.fontsReady() }
    // quoted family name for Canvas ctx.font; falls back until the font loads
    readonly property string ff: (uiFontR.status === FontLoader.Ready)
                                 ? ('"' + uiFontR.name + '"') : "sans-serif"
    // unquoted family name for QML Text elements (the ListView menu)
    readonly property string menuFont: (uiFontR.status === FontLoader.Ready)
                                       ? uiFontR.name : "sans-serif"
    function fontsReady() {
        if (typeof bg !== 'undefined') bg.requestPaint();
        // (the tach, readout layer and ListView menu are all item-based; their
        //  bindings re-render on their own when menuFont changes as the font
        //  loads — bg is the only canvas, so it is the only manual repaint)
    }

    // ---- decoded telltales (inputsdata bits) ------------------------------
    property bool tRace:     inputs & 0x800000
    property bool tSport:    inputs & 0x1000000
    property bool tLeft:     inputs & 0x40
    property bool tRight:    inputs & 0x80

    // ---- spring-damped rpm + animation clock ------------------------------
    property real rpmDisplay: 0
    // damping 0.55 settles fast with little overshoot (was 0.30 = bouncy/slow).
    readonly property real springDamp: 0.30 + springVal * 0.025   // paired to the stiffness: clean settle, ~no bounce across the range
    Behavior on rpmDisplay { SpringAnimation { spring: root.springVal; damping: root.springDamp; epsilon: 1 } }
    onRpmChanged: rpmDisplay = rpm

    // ---- power-on self-test sweep ------------------------------------------
    //  On boot, sweep the tach 0 -> max -> 0 while every telltale and shift
    //  light is lit, then hand over to live data. `selfTest` gates the readouts
    //  so the sweep value (not the engine-off placeholder) is shown. rpmShown is
    //  what the tach, rpm number and shift lights read.
    property bool  selfTest: true
    property real  sweepRpm: 0
    property real  settle:   0   // 0 = showing the swept value, 1 = eased onto live
    // during the test the tach sweeps up, then eases from the peak onto the live
    // value so nothing snaps when the test hands over to real data
    readonly property real rpmShown: selfTest ? (sweepRpm * (1 - settle) + rpmDisplay * settle) : rpmDisplay
    // 0..1 sweep progress; drives every bar during the power-on self-test
    readonly property real sweepFrac: Math.max(0, Math.min(1, sweepRpm / Math.max(1, rpmmax)))
    SequentialAnimation {
        id: bootSweep; running: false
        // sweep the tach + every bar up to full
        NumberAnimation { target: root; property: "sweepRpm"; from: 0; to: root.rpmmax; duration: 850; easing.type: Easing.OutCubic }
        PauseAnimation  { duration: 200 }
        // then ease everything from full down onto the real live values (no snap)
        NumberAnimation { target: root; property: "settle";   from: 0; to: 1;            duration: 700; easing.type: Easing.InOutCubic }
        ScriptAction    { script: root.selfTest = false }
    }

    // ---- fuel-bar damping --------------------------------------------------
    //  Tank fuel sloshes under cornering / braking / hills, so the bar is eased
    //  toward the live reading with a velocity limit: rapid slosh averages out
    //  because the bar can only move so fast and the transient targets cancel.
    //  FUEL DAMP 0 = raw/instant; 1 = light (settles in ~1-2s) ... 9 = heavy
    //  (slow glide, ~8-10s, ignores transient slosh). fuelLevel is what every
    //  fuel readout reads (bar fill, low-fuel colour, pump telltale).
    readonly property real fuelVel: Math.max(8.0, 75.0 - (fuelDamp - 1) * 8.0)   // %/sec for damp 1..9
    property real fuelDisplay: 0
    Behavior on fuelDisplay { SmoothedAnimation { velocity: root.fuelVel } }
    onFuelChanged: fuelDisplay = fuel
    readonly property real fuelLevel: (fuelDamp <= 0) ? fuel : fuelDisplay
    // fuel bar fill fraction — follows the self-test sweep, else the live level
    readonly property real fuelBarFrac: selfTest ? (sweepFrac * (1 - settle) + (fuelLevel / 100) * settle) : fuelLevel / 100

    // Rev-lag debug overlay: set true to compare raw vs smoothed rpm when
    // tuning a dash's needle response. Off for normal use.
    property bool showRawRpm: false
    // Raw-sensor overlay: set true to see the RAW values the host sends, to
    // verify unit/scale assumptions (e.g. is oilpressuredata really PSI?). Off
    // for normal use.
    property bool showRawSensors: false

    // ---- repaint ----------------------------------------------------------
    //  The dash is declarative scene-graph nodes apart from the static `bg`
    //  canvas (chrome painted once). The tach ticks/glow, readouts, telltales
    //  and buttons update themselves through bindings — there is no per-frame
    //  canvas to pump. `bg` repaints only when a chrome-changing setting (rpm
    //  scale, side-gauge units) changes; those handlers live just below.

    // ---- derived ----------------------------------------------------------
    property bool overrev: rpmShown >= rpmredline    // crossed the shift value
    // engine off / key-on-engine-off: rpm sits at 0 (a running engine idles well
    // above 0). Used to show a centred placeholder instead of a lone right-aligned
    // "0", which looks lost in the fixed-width box until the car starts.
    property bool engineOff: !selfTest && Math.round(rpmShown) < 1
    // RPM / Speed placement: false (default) keeps RPM big on top with speed
    // below; true swaps them. Each value keeps its own formatting (fixed-width
    // rpm, speed unit, engine-off dashes); only the slot it occupies changes.
    property bool placementSwap: false
    // Hide the 1k tach scale numbers when true (default false = shown).
    property bool hideTachNums: false
    // Hide the three shift lights below the tach when true (default false).
    property bool hideShiftLights: false
    property int  speedShown: (speedunits === 0) ? speed : Math.round(speed / 1.609)
    property string gearLabel: {
        if ((root.inputs & 0x4000000) !== 0) return "R";   // reverse bit forces "R"
        switch (gearpos) {
            case 0: return "N"; case 9: return "P"; case 10: return "R";
            default: return (gearpos >= 1 && gearpos <= 8) ? String(gearpos) : "N";
        }
    }

    // ---- side-gauge helpers (one set per 'kind'; called from the declarative
    //  delegates below). Each reads live root.* values, so the QML bindings that
    //  call them update automatically when a reading or setting changes — no
    //  canvas repaint involved.
    function gaugeShown(k) {
        return k === "oiltemp" ? showOilTemp : k === "oilpress" ? showOilPress
             : k === "afr"     ? showAfr     : showCoolant;
    }
    function gaugeLabel(k) {
        return k === "oiltemp" ? "OIL TEMP" : k === "oilpress" ? "OIL PRESS"
             : k === "afr"     ? "AFR"      : "COOLANT";
    }
    function gaugeWarn(k) {
        if (k === "oiltemp")  return oiltemp  >= oilTempHigh;
        if (k === "oilpress") return (!engineOff && oilPressShown <= oilPressLow) || oilPressShown >= oilPressHigh;
        if (k === "afr")      { var l = afr / 14.7; return l < afrLow || l > afrHigh; }
        return watertemp >= coolantHigh;   // coolant
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
        return String(Math.round(tempunits === 0 ? watertemp : watertemp * 9/5 + 32));   // coolant
    }
    function gaugeUnit(k) {
        if (k === "oiltemp")  return oilTempUnits  === 0 ? "\u00B0C" : "\u00B0F";
        if (k === "oilpress") return oilPressUnits === 0 ? "PSI" : "BAR";
        if (k === "afr")      return afrSource === 1 ? "\u03BB" : "";
        return tempunits === 0 ? "\u00B0C" : "\u00B0F";   // coolant
    }

    // odo/trip distance conversion (km native -> selected unit)
    readonly property real distFactor: (distunits === 0) ? 1.0 : 0.621371
    readonly property string distUnit: (distunits === 0) ? " km" : " mi"

    // =======================================================================
    //  THE GAUGE — split into a STATIC background layer (repainted only when a
    //  setting changes) and a DYNAMIC foreground layer (repainted ~30x/s). The
    //  static bezel, baseline ticks, number labels, centre disc and side-gauge
    //  panel boxes are rasterised once; only the moving bits redraw per frame.
    // =======================================================================

    // repaint the static layer when geometry/colour-defining settings change
    onRpmredlineChanged: bg.requestPaint()
    onRpmmaxChanged:     bg.requestPaint()
    // hiding/showing a side gauge changes the static panel boxes, so repaint bg
    onOilTempUnitsChanged:  bg.requestPaint()
    onOilPressUnitsChanged: bg.requestPaint()
    onTempunitsChanged:     bg.requestPaint()
    onAfrSourceChanged:     bg.requestPaint()
    onHideTachNumsChanged:  bg.requestPaint()
    onSelfTestChanged:      bg.requestPaint()

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
            ctx.fillStyle = "#05070d"; ctx.fillRect(0, 0, width, height);   // backdrop
            ctx.fillStyle = "#0a1326"; ctx.fillRect(0, 366, width, 44);     // bottom bar
            drawTachStatic(ctx);     // bezel + baseline ticks
            drawCentreStatic(ctx);   // inner disc + gear pill + divider
            drawTachNumbers(ctx);    // 1k scale labels (on top of the disc)
            if (root.showOilTemp  || root.selfTest) box(ctx, 12,  96, 176, 104);   // side boxes (hidden when
            if (root.showOilPress || root.selfTest) box(ctx, 12, 214, 176, 104);   // their unit is OFF; all
            if (root.showAfr      || root.selfTest) box(ctx, 612, 96, 176, 104);   // shown during self-test)
            if (root.showCoolant  || root.selfTest) box(ctx, 612, 214, 176, 104);
        }

        function drawTachStatic(ctx) {
            var bandOut = gaugeR - 6, bandIn = gaugeR - 46;
            ctx.lineWidth = 6; ctx.strokeStyle = "#1a1f2b";
            ctx.beginPath(); ctx.arc(cx, cy, gaugeR + 4, 0, Math.PI * 2); ctx.stroke();
            // baseline (unlit) ticks every 100 rpm
            for (var v = 0; v <= root.rpmmax; v += 100) {
                var a = ang(v), major = (v % 1000 === 0), redZone = (v >= root.rpmredline);
                var ro = bandOut, ri = major ? bandIn - 4 : bandIn + 10;
                ctx.strokeStyle = redZone ? "#4a1c1c" : "#2a3550";
                ctx.lineWidth = major ? 4 : 2;
                ctx.beginPath();
                ctx.moveTo(cx + ri * Math.cos(a), cy + ri * Math.sin(a));
                ctx.lineTo(cx + ro * Math.cos(a), cy + ro * Math.sin(a));
                ctx.stroke();
            }
        }

        // 1k scale labels — drawn on TOP of the centre disc (see onPaint order)
        function drawTachNumbers(ctx) {
            if (root.hideTachNums) return;
            ctx.font = "bold 23px " + root.ff; ctx.textAlign = "center"; ctx.textBaseline = "middle";
            var rLbl = gaugeR - 58;
            for (var n = 0; n * 1000 <= root.rpmmax; n++) {
                var an = ang(n * 1000);
                ctx.fillStyle = (n * 1000 >= root.rpmredline) ? "#ff6a6a" : "#e9eefb";
                ctx.fillText(String(n), cx + rLbl * Math.cos(an), cy + rLbl * Math.sin(an));
            }
        }

        function drawCentreStatic(ctx) {
            ctx.fillStyle = "#0a0f1a";
            ctx.beginPath(); ctx.arc(cx, cy, gaugeR - 52, 0, Math.PI * 2); ctx.fill();
            // gear pill background
            rr(ctx, cx - 44, cy - 96, 88, 46, 10); ctx.fillStyle = "#11182a"; ctx.fill();
            rr(ctx, cx - 44, cy - 96, 88, 46, 10); ctx.strokeStyle = "#2a3550"; ctx.lineWidth = 2; ctx.stroke();
            // divider under the rpm readout
            ctx.strokeStyle = "#1c2740"; ctx.lineWidth = 2;
            ctx.beginPath(); ctx.moveTo(cx - 96, cy + 22); ctx.lineTo(cx + 96, cy + 22); ctx.stroke();
        }

        function box(ctx, x, y, w, h) {
            rr(ctx, x, y, w, h, 12); ctx.fillStyle = "rgba(10,16,28,0.72)"; ctx.fill();
            rr(ctx, x, y, w, h, 12); ctx.strokeStyle = "rgba(120,150,200,0.28)"; ctx.lineWidth = 2; ctx.stroke();
        }
        // rounded-rect path using quadraticCurveTo (arcTo is unreliable on the
        // IC7's Qt 5.12 paint engine; radius is clamped so tiny rects stay valid)
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
    //  The lit ticks are a Repeater of Rectangles — one spoke per 100 rpm — each
    //  rotated to its angle and bound lit/unlit by rpmDisplay. As the needle
    //  moves, only the few ticks it crosses flip opacity; the scene graph
    //  composites that on the GPU. The soft glow is a wider, low-opacity sibling
    //  behind each lit tick; where the spokes are dense they merge into a band.
    //  Nothing in this layer rasterises on the CPU.
    //
    //  Geometry: centre (400,212), spokes run radius ri..186 (ri = 142 major /
    //  156 minor) over 140deg..400deg.
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

                Rectangle {   // soft glow behind the tick (visible only when lit)
                    width: 16; height: parent.ro - parent.ri + 10; radius: 8
                    antialiasing: true
                    color: parent.glowCol
                    opacity: parent.lit ? 0.14 : 0
                    x: parent.cxg - width / 2; y: parent.cyg - height / 2
                    transformOrigin: Item.Center
                    rotation: parent.angleDeg + 90
                }
                Rectangle {   // sharp lit tick (overdraws the dim baseline on bg)
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
    //  Was a full-screen Canvas re-rasterised whenever any digit changed. Now
    //  every readout is a scene-graph Text/Rectangle node bound to its value, so
    //  only the node that actually changed re-renders (on the GPU) — there is no
    //  CPU canvas rasterisation here at all. Panel-box chrome and the centre
    //  disc/pill stay on `bg`; this layer is the live content over them.
    //
    //  Note on positioning: Canvas text is BASELINE-anchored, QML Text is
    //  TOP-LEFT anchored, so each y subtracts the font ascent for that pixel
    //  size (DejaVu Sans: ascent ~= 0.93*size — 13@14, 14@15, 17@18, 36@38,
    //  49@52, 65@70). Centre/odo use middle-baseline, so they subtract height/2.
    Item {
        id: readouts
        anchors.fill: parent

        // ===== centre stack: gear / rpm / speed =====
        Text {   // gear — centred in the bg pill (centre 400,139)
            text: root.gearLabel; color: "#ffffff"
            font.family: root.menuFont; font.bold: true; font.pixelSize: 38
            x: 400 - width / 2; y: 141 - height / 2 - 1   // glyph optical centre -> pill centre (y139)
        }
        // invisible metric: reserves a fixed width for the rpm number so the
        // readout (and the RPM tag beside it) never shifts when the digit count
        // changes crossing 1000. DejaVu Sans has tabular digits, so any value
        // with this many digits measures the same width.
        Text {
            id: rpmMetric; visible: false
            text: String(root.rpmmax)
            font.family: root.menuFont; font.bold: true; font.pixelSize: root.placementSwap ? 52 : 70
        }
        Text {   // rpm number — fixed-width box, right-aligned so digits don't reflow.
                 // Engine off: dimmed four-dash placeholder filling the box.
            id: rpmNum
            text: root.engineOff ? "\u2013\u2013\u2013\u2013" : String(Math.round(root.rpmShown / 10) * 10)
            color: root.engineOff ? "#566581"
                 : (root.overrev ? (root.blinkOn ? "#ff4040" : "#ff8a8a") : "#ffffff")
            font.family: root.menuFont; font.bold: true; font.pixelSize: root.placementSwap ? 52 : 70
            width: rpmMetric.implicitWidth
            horizontalAlignment: Text.AlignRight
            x: (root.placementSwap ? 382 : 384) - width / 2
            y: root.placementSwap ? (290 - 49) : (218 - 65)
        }
        Text {   // "RPM" tag, just right of the number (dimmed to match the off state)
            text: "RPM"
            color: root.engineOff ? "#566581" : (root.overrev ? "#ff5555" : root.accent)
            font.family: root.menuFont; font.bold: true; font.pixelSize: 18
            x: rpmNum.x + rpmNum.width + 8
            y: root.placementSwap ? 258 : (214 - 17)
        }
        Text {   // speed — real value when running (incl. "0" when stopped at a
                 // light); dimmed dash placeholder only when the engine is off
            id: spdNum
            text: root.engineOff ? "\u2013\u2013\u2013" : String(root.speedShown)
            color: root.engineOff ? "#566581" : "#ffffff"
            font.family: root.menuFont; font.bold: true; font.pixelSize: root.placementSwap ? 70 : 52
            x: (root.placementSwap ? 384 : 382) - width / 2
            y: root.placementSwap ? (218 - 65) : (290 - 49)
        }
        Text {   // speed unit (dimmed to match the off state)
            text: root.speedunits === 0 ? "km/h" : "mph"
            color: root.engineOff ? "#566581" : "#9fb2d0"
            font.family: root.menuFont; font.bold: true; font.pixelSize: 18
            x: root.placementSwap ? (spdNum.x + spdNum.width + 8) : 456
            y: root.placementSwap ? 197 : (276 - 17)
        }

        // shift lights below speed: three red rings, completely hidden until
        // triggered. Each lights by its bit OR by calculation — when rpm crosses
        // a fraction of the SHIFT RPM (rpmredline) from settings, so they come on
        // progressively toward the shift point (90% / 95% / 100%) even if the host
        // never drives the bits. (opacity 0 keeps each slot reserved so the three
        // stay fixed in place.)
        Row {
            visible: !root.hideShiftLights
            anchors.horizontalCenter: parent.horizontalCenter
            y: 312; spacing: 16
            Repeater {
                model: [ { bit: 0x80000,  rpmFrac: 0.90 },
                         { bit: 0x100000, rpmFrac: 0.95 },
                         { bit: 0x200000, rpmFrac: 1.00 } ]   // shift 1 / 2 / 3
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
                        // past the shift point everything lit flashes "shift NOW"
                        return root.overrev ? (root.blinkOn ? 1.0 : 0.0) : 1.0;
                    }
                }
            }
        }

        // ===== four side mini-gauges (box chrome is on bg) =====
        Repeater {
            model: [
                { kind: "oiltemp",  bx: 12,  by: 96  },
                { kind: "oilpress", bx: 12,  by: 214 },
                { kind: "afr",      bx: 612, by: 96  },
                { kind: "coolant",  bx: 612, by: 214 }
            ]
            delegate: Item {
                id: cell
                x: modelData.bx; y: modelData.by; width: 176; height: 104
                visible: root.selfTest || root.gaugeShown(modelData.kind)
                property bool   warn:    root.gaugeWarn(modelData.kind)
                // engine-damage criticals flash (low oil pressure / coolant overtemp)
                property bool   critical:(modelData.kind === "oilpress" && !root.engineOff && root.oilPressShown <= root.oilPressLow)
                                      || (modelData.kind === "coolant"  && root.watertemp >= root.coolantHigh)
                property real   frac:    root.selfTest ? (root.sweepFrac * (1 - root.settle) + root.gaugeFrac(modelData.kind) * root.settle) : root.gaugeFrac(modelData.kind)
                property string valStr:  root.gaugeVal(modelData.kind)
                property string unitStr: root.gaugeUnit(modelData.kind)

                Text {   // label (baseline +16,+26)
                    text: root.gaugeLabel(modelData.kind)
                    color: cell.warn ? "#ff7777" : root.accent
                    font.family: root.menuFont; font.bold: true; font.pixelSize: 14
                    x: 16; y: 26 - 13
                }
                Text {   // value (baseline +16,+64)
                    id: gVal
                    text: cell.valStr
                    color: cell.warn ? "#ff5050" : "#ffffff"
                    opacity: (cell.critical && !root.blinkOn) ? 0.25 : 1.0   // flash when critical
                    font.family: root.menuFont; font.bold: true; font.pixelSize: 38
                    x: 16; y: 64 - 36
                }
                Text {   // unit, right of the value, sharing its baseline
                    visible: cell.unitStr !== ""
                    text: cell.unitStr; color: "#9fb2d0"
                    font.family: root.menuFont; font.bold: true; font.pixelSize: 15
                    x: gVal.x + gVal.width + 8; y: 64 - 14
                }
                Rectangle { x: 16; y: 104 - 22; width: 144; height: 8; color: "#1a2336" }  // track
                Rectangle {   // fill (low..high), red when out of band
                    x: 16; y: 104 - 22; height: 8
                    width: cell.frac > 0 ? Math.max(6, 144 * cell.frac) : 0
                    color: (!root.selfTest && cell.warn) ? "#ff3b30" : root.accent
                }
            }
        }

        // ===== battery readout (bottom bar, left) =====
        Item {
            id: bat
            property bool  warn: root.battery < root.batteryLow || root.battery > root.batteryHigh
            property color col:  (!root.selfTest && warn) ? "#ff5050" : root.accent
            readonly property real realLvl: Math.max(0, Math.min(1, (root.battery - root.batteryLow)
                                 / Math.max(0.1, root.batteryHigh - root.batteryLow)))
            property real  lvl:  root.selfTest ? (root.sweepFrac * (1 - root.settle) + realLvl * root.settle) : realLvl
            Rectangle { x: 18; y: 379; width: 30; height: 18; color: "transparent"
                        border.color: bat.col; border.width: 2 }           // body
            Rectangle { x: 48; y: 384; width: 3;  height: 8;  color: bat.col }   // nub
            Rectangle { x: 20; y: 381; width: 26 * bat.lvl; height: 14; color: bat.col }  // level
            Text {   // "13.8V" (italic, canvas middle-baseline at 62,387)
                id: vText
                text: root.battery.toFixed(1) + "V"
                color: bat.warn ? "#ff7777" : "#ffffff"
                font.family: root.menuFont; font.bold: true; font.italic: true; font.pixelSize: 28
                x: 62; y: 387 - height / 2 - 3
            }
            Image {   // SERVICE wrench, right of the voltage. Hidden (not dimmed)
                      // unless the SERVICE bit (0x400000) is tripped.
                visible: root.selfTest || (root.inputs & 0x400000) !== 0
                source: "assets/service.png"
                height: 26
                width: implicitHeight > 0 ? 26 * implicitWidth / implicitHeight : 22
                fillMode: Image.PreserveAspectFit; smooth: true; antialiasing: true
                x: vText.x + vText.width + 16
                y: 388 - height / 2
            }
        }

        // ===== fuel bar (bottom bar, right): 12 segments =====
        Rectangle { x: 662; y: 377; width: 170; height: 22; color: "#1a2336" }   // track bg
        Repeater {
            model: 12
            delegate: Rectangle {
                x: 664 + index * 14; y: 379; width: 11; height: 18
                color: (index < Math.round(root.fuelBarFrac * 12))
                       ? ((!root.selfTest && root.fuelLevel < root.fuelLow) ? "#ff4444" : "#35d84a")
                       : "#26314a"
            }
        }

        // ===== odo / trip (lower-right, right-aligned at x=760) =====
        Text {
            text: "ODO " + Math.round(root.odometer * root.distFactor) + root.distUnit
            color: "#c9d6ee"; font.family: root.menuFont; font.bold: true; font.pixelSize: 13
            x: 760 - width; y: 457 - height / 2 - 1
        }
        Text {
            text: "TRIP " + Math.round(root.tripmeter * root.distFactor) + root.distUnit
            color: "#c9d6ee"; font.family: root.menuFont; font.bold: true; font.pixelSize: 13
            x: 760 - width; y: 471 - height / 2 - 1
        }
    }


    // ====================================================================
    //  TELLTALES — icon set (assets/*.png), lit from inputsdata bits
    // ====================================================================
    property bool blinkOn: true
    Timer { interval: 420; repeat: true; running: true
            onTriggered: root.blinkOn = !root.blinkOn }

    Image {   // fuel pump icon: white (fuel.png) normally, red warning
              // (fuel_level_warning.png) once the level drops below FUEL LOW
        source: root.fuelLevel < root.fuelLow ? "assets/fuel_level_warning.png"
                                              : "assets/fuel.png"
        x: 620; y: 366 + 22 - height/2; height: 26
        fillMode: Image.PreserveAspectFit; smooth: true
        opacity: root.fuelLevel < root.fuelLow ? 1.0 : 0.85
    }

    Row {   // telltale row
        x: 28; y: 417; spacing: 12
        Repeater {
            model: [
                { src: "high_beam",            bit: 0x10 },
                { src: "sidelight",            bit: 0x800 },     // sidelights (green)
                { src: "rear_fog",             bit: 0x08 },      // rear fog (amber)
                { src: "brake_warning",        bit: 0x8000100 },   // brake | handbrake
                { src: "oil_pressure_warning", bit: 0x200 },
                { src: "battery_warning",      bit: 0x02 },
                { src: "seatbelt_warning",     bit: 0x400 },
                { src: "abs_warning",          bit: 0x20000 },
                { src: "tc_warning",           bit: 0x10000 },    // traction control (amber)
                { src: "mil_warning",          bit: 0x40000 },
                { src: "airbag_warning",       bit: 0x8000 },
                { src: "door_open",            bit: 0x4000 }
            ]
            Item {
                id: ttCell
                height: 26
                width: ttImg.width
                readonly property bool isTc:  modelData.src === "tc_warning"
                readonly property bool tcOff: (root.inputs & 0x10000000) !== 0   // TC OFF bit
                Image {
                    id: ttImg
                    source: "assets/" + modelData.src + ".png"
                    height: 26
                    // Size to the glyph's true width (capped at 40) so the Row
                    // gives every icon the same 12px gap.
                    width: Math.min(40, implicitHeight > 0 ? 26 * implicitWidth / implicitHeight : 36)
                    fillMode: Image.PreserveAspectFit
                    smooth: true; antialiasing: true
                    // lit when its bit is set; the TC symbol also lights when TC
                    // is switched OFF, so the OFF tag sits on a lit icon
                    opacity: (root.selfTest || (root.inputs & modelData.bit) || (ttCell.isTc && ttCell.tcOff)) ? 1.0 : 0.25
                }
                Rectangle {   // dark backing so "OFF" reads over the amber symbol
                    visible: ttCell.isTc && ttCell.tcOff
                    anchors.centerIn: ttImg
                    width: offTxt.implicitWidth + 4; height: offTxt.implicitHeight + 1; radius: 2
                    color: "#000000"; opacity: 0.6
                }
                Text {   // small "OFF" across the traction icon when TC is disabled
                    id: offTxt
                    visible: ttCell.isTc && ttCell.tcOff
                    anchors.centerIn: ttImg
                    text: "OFF"; color: "#ffffff"
                    font.family: root.menuFont; font.bold: true; font.pixelSize: 9
                }
            }
        }
    }

    // ECU ASCII status line (CAN canasciidata), lower-left below the telltales.
    // This is a cycling status line: the ECU rotates DISTINCT messages through it
    // (FAULT, TPMS, LTC, SLIP%, ...) and also flashes misaligned fragments
    // ("AULT FAULT"), lone partials ("LT", single letters) and empty pulses.
    // Pipeline: (1) canAsciiStr collapses each value's own repetition/partials;
    // (2) a 120 ms settle accepts a value only after it holds steady that long, so
    // single-frame blips never reach the screen while a message the ECU rests on
    // shows. Each settled message REPLACES the previous (no accumulation). An empty
    // value arms a 3 s timer; 3 s of continuous quiet blanks the line.
    // (3) Nuisance pattern: "TPMS" followed by a (repeating) "FAULT" is ONE occurrence
    // -- the FAULT keeps re-showing until the next TPMS. Occurrences are tallied
    // cumulatively (repeats or other text in between do NOT reset the count). After
    // canAsciiSuppressAfter occurrences this power cycle, the whole TPMS fault latches
    // off: the "TPMS" and the FAULTs that belong to it (the repeating "FAULT FAULT")
    // stop showing for the session. A FAULT that is NOT in a TPMS-fault context (no
    // preceding TPMS, or after other text such as "OIL FAULT" / "LTC") still shows.
    // Latch lives in memory only -> a power cycle restores it.
    Text {
        id: canAsciiText
        property string pending: root.canAsciiStr    // latest collapsed value
        property int canAsciiPairs: 0                 // TPMS->FAULT occurrences this power cycle (cumulative)
        property bool canAsciiAwaitFault: false       // last settled message was TPMS (next FAULT counts once)
        property bool canAsciiInFault: false          // inside a TPMS-fault context (its FAULTs repeat)
        property bool canAsciiHushed: false           // TPMS fault latched off for the session
        readonly property int canAsciiSuppressAfter: 5  // hush after this many TPMS->FAULT occurrences (0 = never)
        onPendingChanged: canAsciiSettle.restart()    // debounce: ignore sub-120 ms blips
        visible: text.length > 0
        text: ""
        x: 28; y: 451
        width: 580; elide: Text.ElideRight
        color: "#ffcf6b"                              // amber ECU message
        font.family: root.menuFont; font.bold: true; font.pixelSize: 16
        Timer {
            id: canAsciiSettle
            interval: 120; repeat: false
            onTriggered: {
                var c = canAsciiText.pending;
                if (!c) {
                    canAsciiClearTimer.restart();             // empty -> arm blank
                } else {
                    var show = c;
                    if (c === "TPMS") {
                        if (canAsciiText.canAsciiSuppressAfter > 0
                            && canAsciiText.canAsciiPairs >= canAsciiText.canAsciiSuppressAfter)
                            canAsciiText.canAsciiHushed = true;          // enough occurrences -> latch off
                        canAsciiText.canAsciiAwaitFault = true;          // a FAULT may follow
                        canAsciiText.canAsciiInFault = true;             // entering the TPMS-fault context
                        if (canAsciiText.canAsciiHushed) show = "";
                    } else if (c === "FAULT") {
                        if (canAsciiText.canAsciiAwaitFault) {           // first FAULT after a TPMS = one occurrence
                            canAsciiText.canAsciiAwaitFault = false;
                            if (!canAsciiText.canAsciiHushed) canAsciiText.canAsciiPairs += 1;
                        }
                        if (canAsciiText.canAsciiHushed && canAsciiText.canAsciiInFault) show = "";   // hush repeating TPMS-fault FAULT
                        // a FAULT outside a TPMS-fault context keeps showing
                    } else {
                        canAsciiText.canAsciiAwaitFault = false;
                        canAsciiText.canAsciiInFault = false;            // other text ends the TPMS-fault context
                    }
                    canAsciiText.text = show;
                    canAsciiClearTimer.stop();
                }
            }
        }
        Timer {
            id: canAsciiClearTimer
            interval: 3000; repeat: false
            onTriggered: { canAsciiText.text = ""; canAsciiText.canAsciiAwaitFault = false; canAsciiText.canAsciiInFault = false; }   // quiet ends the context
        }
    }

    Rectangle {   // RACE MODE button
        x: 636; y: 414; width: 72; height: 32; radius: 5
        color: root.tRace ? "#2a1414" : "#161b28"
        border.color: root.tRace ? "#ff5555" : "#2a3550"; border.width: 1
        Column {
            anchors.centerIn: parent; spacing: 0
            Text { text: "RACE"; anchors.horizontalCenter: parent.horizontalCenter
                   color: root.tRace ? "#ff6666" : "#9fb2d0"; font.bold: true; font.pixelSize: 13 }
            Text { text: "MODE"; anchors.horizontalCenter: parent.horizontalCenter
                   color: root.tRace ? "#ff6666" : "#9fb2d0"; font.pixelSize: 8 }
        }
    }

    Rectangle {   // SPORT MODE button (inputsdata 0x1000000)
        x: 714; y: 414; width: 72; height: 32; radius: 5
        color: root.tSport ? "#2a2410" : "#161b28"
        border.color: root.tSport ? "#ffb02f" : "#2a3550"; border.width: 1
        Column {
            anchors.centerIn: parent; spacing: 0
            Text { text: "SPORT"; anchors.horizontalCenter: parent.horizontalCenter
                   color: root.tSport ? "#ffc24d" : "#9fb2d0"; font.bold: true; font.pixelSize: 13 }
            Text { text: "MODE"; anchors.horizontalCenter: parent.horizontalCenter
                   color: root.tSport ? "#ffc24d" : "#9fb2d0"; font.pixelSize: 8 }
        }
    }

    Image {   // blinking left indicator
        source: "assets/left_indicator.png"
        x: 36; y: 18; height: 50; fillMode: Image.PreserveAspectFit
        smooth: true
        visible: root.tLeft && root.blinkOn
    }
    Image {   // blinking right indicator
        source: "assets/right_indicator.png"
        x: 718; y: 18; height: 50; fillMode: Image.PreserveAspectFit
        smooth: true
        visible: root.tRight && root.blinkOn
    }

    // ---- NIGHTLIGHT dimmer (above the dash, below the menu) ----------------
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: root.nightlight / 100 * 0.7
        visible: root.nightlight > 0
    }

    // =======================================================================
    //  SETTINGS — config file, D-pad, and the scrolling menu (single file)
    // =======================================================================
    readonly property string cfgPath: "/opt/Garw_IC7/screen_configs/gtdash_config.txt"
    FileIO {
        id: cfg
        // IC7 maps this to <dash>/screen_configs/gtdash_config.txt.
        source: root.cfgPath
        onError: console.log("GTDash FileIO: " + msg)
    }


    // config line order (one value per line). Keep load + save identical.
    // Returns true if a usable config was read, false if missing/empty.
    //
    // IC7 FileIO READ CONTRACT (verified on hardware): the reader returns ONE
    // line per open, and only the FIRST readopenfile() after each open works;
    // the index selects the line. So to read line i you must:
    //     openforreading(); var s = readopenfile(i); close();
    // i.e. re-open before every single line. Reading several lines in one open
    // returns only the first; that was the long-standing "won't read" bug.
    function rline(i) {
        var s = "";
        try { cfg.openforreading(); s = cfg.readopenfile(i); cfg.close(); }
        catch (e) { console.log("GTDash: read line " + i + " failed (" + e + ")"); }
        return s;
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
                        (root.hideShiftLights ? 1 : 0)];
            // Write the whole file in a SINGLE writetoopenfile() call (verified
            // to round-trip with the per-line reader above).
            var out = "";
            for (var i = 0; i < vals.length; i++) out += String(vals[i]) + "\n";
            cfg.open();
            cfg.writetoopenfile(out);
            cfg.close();
        } catch (e) { console.log("GTDash: could not write config (" + e + ")"); }
    }
    // First run: if no config is found, write the current defaults so the file
    // exists (FileIO does not create it on a read).
    Component.onCompleted: {
        // Tell the host firmware that warnings are handled locally, so it does
        // NOT draw its own warning-light bar over the dash. Hardware-only flag
        // (the property is absent in the desktop sim), so the write is guarded.
        if (root.d) { try { root.d.DISABLE_WARNING_OVERLAY = "YES_WARNINGS_HANDLED_LOCALLY"; } catch (e) {} }
        if (!loadConfig())
            saveConfig();
        fuelDisplay = fuel;   // start the damped bar at the live level (no boot sweep)
        oilPressShown = oilpress;   // start oil pressure at live (boot self-test owns the boot sweep)
        bootSweep.start();    // power-on self-test sweep
    }

    // ---- D-pad (inputsdata bits via root.inputs; udp_packetdata fallback) --
    function udp()    { return (root.d && root.d.udp_packetdata !== undefined) ? root.d.udp_packetdata : 0; }
    function dUp()    { return ((root.inputs & 0x20) !== 0)       || ((udp() & 0x01) !== 0); }
    function dDown()  { return ((root.inputs & 0x2000) !== 0)     || ((udp() & 0x02) !== 0); }
    function dLeft()  { return ((root.inputs & 0x20000000) !== 0) || ((udp() & 0x04) !== 0); }
    function dRight() { return ((root.inputs & 0x40000000) !== 0) || ((udp() & 0x08) !== 0); }

    // ---- menu model --------------------------------------------------------
    property bool menuOpen: false
    property int  sel: 0
    property int  settingsRev: 0      // bumped on every value change -> ListView value cells re-read
    property real pulse: 0
    property bool pUp: false
    property bool pDown: false
    property bool pLeft: false
    property bool pRight: false
    property int  upHold: 0
    property int  downHold: 0
    property bool upArmed: false      // hold-to-ramp arms only after release
    property bool downArmed: false

    // every navigable row: {k: key, label: shown text}. Order = on-screen order.
    readonly property var items: [
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
        { k: "htn",    label: "HIDE TACH NUMS" },
        { k: "hsl",    label: "HIDE SHIFT LIGHTS" },
        { k: "exit",   label: "EXIT" }
    ]
    // toggles + exit aren't hold-to-ramp; everything else is.
    readonly property var noRamp: ["speed", "dist", "cun", "otun", "opun", "asrc", "swap", "htn", "hsl", "exit"]
    function isRampable(k) { return noRamp.indexOf(k) === -1; }

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

    // dir = +1 (Up) / -1 (Down). Steps / clamps are chosen per setting.
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
        root.settingsRev += 1;          // triggers the ListView value cells to re-read
    }

    // value shown on the right of each row
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
    function moveSel(dir){ sel = ((sel + dir) % items.length + items.length) % items.length; }

    // ---- input handling (signal-driven edge detection) ---------------------
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
    }
    Connections {
        target: root.d
        ignoreUnknownSignals: true
        function onInputsdataChanged()     { root.evalEdges(); }
        function onUdp_packetdataChanged() { root.evalEdges(); }
    }
    // Some backends update inputsdata without emitting a change signal, so the
    // Connections above may never fire on the hardware. Poll as a fallback —
    // evalEdges() is edge-triggered (via pUp/pDown/...), so this is harmless.
    Timer {
        interval: 50; running: true; repeat: true
        onTriggered: root.evalEdges()
    }
    Timer {   // hold-to-ramp for numeric rows (only runs while the menu is open)
        interval: 90; running: root.menuOpen; repeat: true
        onTriggered: {
            if (root.menuOpen && root.isRampable(root.items[root.sel].k)) {
                // upArmed/downArmed gate the ramp until the button is released
                // once, so the same Up-press that opened the menu can't ramp.
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
            // menu repaints only on navigation (openMenu/moveSel/applyValue),
            // so there is no per-pulse repaint here — keeps the IC7 responsive.
        }
    }

    // ---- settings overlay: panel + ListView -------------------------------
    //  Item-based, not a Canvas: only the rows that change repaint, the view
    //  recycles off-screen rows, and Rectangle.radius gives reliable rounded
    //  corners (no arcTo). Driven entirely by the D-pad: currentIndex follows
    //  root.sel; value cells re-read valueText() when settingsRev bumps.
    Item {
        id: menu
        anchors.fill: parent
        visible: root.menuOpen

        readonly property int visibleRows: 11
        readonly property int rowH: 30

        // dim the dash behind (own node so opacity doesn't fade the panel)
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
                interactive: false                     // D-pad driven; no touch flick
                model: root.items
                currentIndex: root.sel
                highlightMoveDuration: 0
                highlightRangeMode: ListView.ApplyRange // keep the selection centred
                preferredHighlightBegin: 5 * menu.rowH
                preferredHighlightEnd:   6 * menu.rowH
                delegate: Item {
                    id: row
                    width: ListView.view.width; height: menu.rowH
                    property bool current: ListView.isCurrentItem
                    Rectangle {                          // selection fill
                        visible: row.current
                        x: 0; y: 3; width: parent.width - 30; height: menu.rowH - 6
                        radius: 7; color: root.accent; opacity: 0.26
                    }
                    Rectangle {                          // accent tab
                        visible: row.current
                        x: 0; y: 3; width: 4; height: menu.rowH - 6; color: root.accent
                    }
                    Text {                               // label
                        text: modelData.label
                        x: 22; anchors.verticalCenter: parent.verticalCenter
                        color: row.current ? "#ffffff" : "#9fb2d0"
                        font.pixelSize: 18; font.bold: true; font.family: root.menuFont
                    }
                    Text {                               // value (re-reads on settingsRev)
                        anchors.right: parent.right; anchors.rightMargin: 34
                        anchors.verticalCenter: parent.verticalCenter
                        text: { var r = root.settingsRev; return root.valueText(modelData.k); }
                        color: row.current ? "#ffffff" : root.accent
                        font.pixelSize: 18; font.bold: true; font.family: root.menuFont
                    }
                }
            }

            Rectangle {                                  // scrollbar (only if overflowing)
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

    // ---- rev-lag debug readout (OFF by default). Flip showRawRpm to true to
    //      compare the raw rpm (from rpmtest) against the smoothed value on the
    //      needle while tuning a dash: if "raw" tracks the rev but "disp" trails,
    //      the lag is the spring (tune RPM DAMPING); if "raw" itself trails, the
    //      lag is upstream in the rpmdata feed. Sits below the cowl line (y:54).
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

    // ---- raw-sensor readout (OFF by default). Flip showRawSensors to true to
    //      see the RAW values the host sends, to check unit/scale assumptions
    //      (e.g. is oilpressuredata really PSI?). Stacks under the rev-lag line.
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
