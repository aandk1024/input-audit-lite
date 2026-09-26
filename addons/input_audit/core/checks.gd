@tool
extends RefCounted

## The rules. Each one is a question asked of the project file and of the
## places the project names an action, and each finding names the action and
## the reason, so it can be argued with rather than merely trusted.

const Actions := preload("res://addons/input_audit/core/actions.gd")
const Scan := preload("res://addons/input_audit/core/scan.gd")


class Finding extends RefCounted:
    var action: String = ""
    ## Where it was seen, when the finding is about a use rather than about the
    ## input map itself. Empty for findings about the map.
    var file: String = ""
    var line: int = 0
    ## "undefined_action" | "no_binding" | "pointer_only" | "no_gamepad"
    ## | "no_keyboard" | "unused_action" | "duplicate_binding" | "bad_deadzone"
    var kind: String = ""
    var detail: String = ""
    ## Extra context that is neither the action nor the reason.
    var note: String = ""

    func _head() -> String:
        if file == "":
            return "\"%s\" " % action
        return "%s:%d \"%s\" " % [file, line, action]

    func to_line() -> String:
        match kind:
            "undefined_action":
                return _head() + ("is not in the project's input map, so %s() returns false for ever. "
                    + "Godot says nothing until that line runs%s") % [detail, _tail()]
            "no_binding":
                return _head() + "is in the input map with no binding at all - nothing can trigger it"
            "pointer_only":
                # Only blame a pointer when a pointer is what it is bound to.
                # An action bound only through another action, or through an
                # event this tool does not recognise, has no key and no gamepad
                # either - but saying it "cannot be pressed without a pointer"
                # sends the reader looking for a mouse binding that is not
                # there.
                if note == "pointer":
                    return _head() + ("can only be triggered with %s. No key and no gamepad button is "
                        + "bound to it, so it cannot be pressed without a pointer") % detail
                return _head() + "is bound only to %s - no key and no gamepad button can trigger it" % detail
            "no_gamepad":
                return _head() + "has no gamepad binding (%s only) - a controller cannot trigger it" % detail
            "no_keyboard":
                return _head() + "has no key bound (%s only) - a keyboard cannot trigger it" % detail
            "unused_action":
                return _head() + "is in the input map and nothing in the project uses it as input" + _tail()
            "duplicate_binding":
                return _head() + "shares %s with \"%s\" - one press fires both" % [detail, note]
            "bad_deadzone":
                return _head() + "is bound to a gamepad axis with deadzone %s - %s" % [detail, note]
        return _head() + kind

    func _tail() -> String:
        if note == "":
            return ""
        return " (" + note + ")"


class Options extends RefCounted:
    ## Report action names used in the project that the input map does not have.
    var check_undefined := true
    ## Report actions in the input map that nothing names.
    var check_unused := true
    ## Report actions with no binding, and actions only a pointer can trigger.
    var check_unbound := true
    ## Report actions a gamepad cannot trigger, and actions a keyboard cannot.
    ## The noisiest pair on a project that has decided it is one or the other.
    var check_devices := true
    ## Report one physical binding shared by two actions.
    var check_duplicates := true
    ## Report gamepad-axis actions whose deadzone makes the stick unusable.
    var check_deadzone := true


## A deadzone of 0 means a stick at rest is already past the threshold, so the
## action reads as held for ever on a controller with any drift at all - which
## is most of them. Godot's own default is 0.2 (0.5 before 4.3), and nothing
## above this upper bound leaves usable travel.
const DEADZONE_MIN := 0.01
const DEADZONE_MAX := 0.9


static func run(actions: Dictionary, found, opts: Options = null) -> Array:
    var o := opts if opts != null else Options.new()
    var out: Array = []
    _undefined(actions, found, o, out)
    _unused(actions, found, o, out)
    _bindings(actions, o, out)
    _duplicates(actions, o, out)
    _deadzone(actions, o, out)
    return out


## A name the project uses that the input map does not have. This is the one
## the engine will not tell you about at build time: Input.is_action_pressed()
## with a name that does not exist returns false and prints nothing until the
## line actually runs, so a typo in a menu nobody opens during testing ships.
static func _undefined(actions: Dictionary, found, o: Options, out: Array) -> void:
    if not o.check_undefined:
        return
    # When the engine's own actions are visible in the map, an unknown ui_
    # name is a typo like any other - "ui_acceppt" is not an engine action.
    # When they are not visible, there is no way to tell one from the other,
    # so the whole prefix is left alone rather than guessed at.
    var builtins_visible := _map_shows_builtins(actions)
    for name in found.names():
        if actions.has(name):
            continue
        if String(name).begins_with(Actions.BUILTIN_PREFIX) and not builtins_visible:
            continue
        # An action the project itself creates with InputMap.add_action() is
        # not in the file, and is not a typo. A name some other plugin creates
        # is that plugin's business and does not vouch for the buyer's spelling.
        if bool(found.added.get(name, false)):
            continue
        # A name only another plugin mentions belongs to that plugin.
        if not found.named_outside_addons(name):
            continue
        var refs: Array = found.refs[name]
        for r in refs:
            if r.in_addon:
                continue
            # InputMap.has_action("x") asks whether x exists. "No" is the
            # answer, not a fault.
            if Scan.PROBES.has(String(r.via)):
                continue
            # An `action` property - in code, or the inspector value of an
            # @export var action on a node - is any property of that name, and
            # a quest resource has one too. It counts as a use, so the action
            # is not called unused; it is never evidence of a typo, because
            # "open_shop is not in the input map" about a quest sends the
            # reader to break working data.
            if not r.certain:
                continue
            var f := Finding.new()
            f.action = name
            f.file = r.file
            f.line = r.line
            f.kind = "undefined_action"
            f.detail = r.via
            f.note = _nearest(name, actions)
            out.append(f)


## Whether this map contains the engine's own ui_ actions. In a project whose
## settings list them, an unrecognised ui_ name cannot be one of theirs.
static func _map_shows_builtins(actions: Dictionary) -> bool:
    var n := 0
    for name in actions.keys():
        if not String(name).begins_with(Actions.BUILTIN_PREFIX):
            continue
        # A ui_ name the project file never declared can only have come from
        # the engine, so the engine's own list is in front of us and an
        # unrecognised ui_ name is a typo. In a real project every one of the
        # engine's ninety-odd names arrives this way; a hand-built map with a
        # couple of ui_ names in it is enough on its own.
        if not actions[name].declared:
            return true
        n += 1
        if n >= 2:
            return true
    return false


## The closest action that does exist, when one is close enough to be worth
## naming. A typo is nearly always one edit away from the real name, and
## "jmup / did you mean jump" is the whole fix.
static func _nearest(name: String, actions: Dictionary) -> String:
    var best := ""
    var best_d := 0x7FFFFFFF
    var keys: Array = actions.keys()
    # Sorted first, so a tie is broken the same way on every run.
    keys.sort()
    for k in keys:
        var d := _distance(name, String(k))
        if d < best_d:
            best_d = d
            best = String(k)
    # Two edits is a typo. More than that is a different word, and offering a
    # wrong name is worse than offering none - it sends the reader to change a
    # line that was already right.
    if best == "" or best_d > 2 or best_d >= name.length():
        return ""
    return "did you mean \"%s\"?" % best


## Plain edit distance. String.similarity() is not usable here: it compares
## two-character pairs, and the commonest typo of all - two letters swapped,
## "jmup" for "jump" - shares no pair at all with the word it came from and
## scores zero. Action names are short, so the full table is cheap.
static func _distance(a: String, b: String) -> int:
    var la := a.length()
    var lb := b.length()
    if la == 0:
        return lb
    if lb == 0:
        return la
    var prev: Array = []
    prev.resize(lb + 1)
    for j in range(lb + 1):
        prev[j] = j
    for i in range(1, la + 1):
        var cur: Array = []
        cur.resize(lb + 1)
        cur[0] = i
        for j in range(1, lb + 1):
            var cost := 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(min(int(cur[j - 1]) + 1, int(prev[j]) + 1), int(prev[j - 1]) + cost)
        prev = cur
    return int(prev[lb])


static func _unused(actions: Dictionary, found, o: Options, out: Array) -> void:
    if not o.check_unused:
        return
    # 🔴 One call site that builds its name at runtime can be naming any
    # action in the map, so "nothing uses this" is not something this check
    # can know on its own. It is also the one finding that gets working input
    # deleted, so when there is such a call site every line of it carries the
    # caveat rather than being presented as a fact.
    var caveat := ""
    if not found.dynamic.is_empty():
        caveat = ("%d call site(s) build the action name at runtime, so this may be one of them"
            % found.dynamic.size())
    for name in _sorted(actions):
        var a = actions[name]
        # A ui_* override is used by the engine itself, everywhere, without
        # anyone naming it.
        if a.is_builtin_name():
            continue
        # Not declared in the project file, so it is not this project's action
        # to delete. See _bindings() for why that is the gate.
        if not a.declared:
            continue
        # Bookkeeping - InputMap.erase_action("x"), action_get_deadzone("x") -
        # names an action without the game ever being able to press it.
        if found.used_as_input(name):
            continue
        var f := Finding.new()
        f.action = name
        f.kind = "unused_action"
        f.note = caveat
        out.append(f)


static func _bindings(actions: Dictionary, o: Options, out: Array) -> void:
    for name in _sorted(actions):
        var a = actions[name]
        # Only what the project file itself declares. The engine's own ui_*
        # defaults are in every project's settings and are not the project's to
        # fix - reporting them buries the eight findings that ARE the project's
        # under ninety that are not. The same gate also covers an action some
        # other plugin wrote into ProjectSettings at runtime: the map is read
        # from ProjectSettings, which anything in a live editor can add to
        # without the project file changing, and a finding about a name the
        # buyer cannot find in their own file is a finding they cannot act on.
        if not a.declared:
            continue
        if a.events.is_empty():
            if o.check_unbound:
                var f := Finding.new()
                f.action = name
                f.kind = "no_binding"
                out.append(f)
            continue
        var pad: bool = a.has_gamepad()
        var key: bool = a.has_keyboard()
        if not pad and not key:
            if o.check_unbound:
                var f2 := Finding.new()
                f2.action = name
                f2.kind = "pointer_only"
                f2.detail = _kinds_text(a)
                if a.has_kind("mouse") or a.has_kind("touch"):
                    f2.note = "pointer"
                out.append(f2)
            continue
        if not o.check_devices:
            continue
        if not pad:
            var f3 := Finding.new()
            f3.action = name
            f3.kind = "no_gamepad"
            f3.detail = _kinds_text(a)
            out.append(f3)
        elif not key:
            var f4 := Finding.new()
            f4.action = name
            f4.kind = "no_keyboard"
            f4.detail = _kinds_text(a)
            out.append(f4)


const KIND_WORDS := {
    "key": "keyboard", "mouse": "mouse", "pad_button": "gamepad button",
    "pad_axis": "gamepad axis", "touch": "touch", "action": "another action",
    "other": "an unrecognised event",
}


static func _kinds_text(a) -> String:
    var seen: Array = []
    for k in a.kinds:
        var w := String(KIND_WORDS.get(k, k))
        if not seen.has(w):
            seen.append(w)
    seen.sort()
    return ", ".join(PackedStringArray(seen))


## The same press wired to two actions. Reported once, on the action that
## sorts later, naming the earlier one - so the pair produces one line rather
## than two halves of the same sentence.
static func _duplicates(actions: Dictionary, o: Options, out: Array) -> void:
    if not o.check_duplicates:
        return
    var by_sig := {}
    for name in _sorted(actions):
        var a = actions[name]
        # Anything the project file does not declare is left out of the
        # grouping entirely, not merely left unreported: Space is ui_accept and
        # ui_select in every project ever made, and a clash with a default
        # nobody wrote is not news.
        if not a.declared:
            continue
        for e in a.events:
            var sig := Actions.signature(e)
            if not by_sig.has(sig):
                by_sig[sig] = []
            by_sig[sig].append({"action": name, "event": e})
    var sigs: Array = by_sig.keys()
    sigs.sort()
    for sig in sigs:
        var group: Array = by_sig[sig]
        if group.size() < 2:
            continue
        for i in range(1, group.size()):
            var entry: Dictionary = group[i]
            var partner := ""
            for j in range(0, i):
                var other: Dictionary = group[j]
                if String(other["action"]) == String(entry["action"]):
                    # The same action bound to the same thing twice is a
                    # duplicate row in the input map, not a clash between two
                    # actions. Harmless, and not this check's business.
                    continue
                if not Actions.same_device(entry["event"], other["event"]):
                    continue
                partner = String(other["action"])
                break
            if partner == "":
                continue
            var f := Finding.new()
            f.action = String(entry["action"])
            f.kind = "duplicate_binding"
            f.detail = Actions.describe(entry["event"])
            f.note = partner
            out.append(f)


static func _deadzone(actions: Dictionary, o: Options, out: Array) -> void:
    if not o.check_deadzone:
        return
    for name in _sorted(actions):
        var a = actions[name]
        if not a.declared:
            continue
        if not a.has_kind("pad_axis"):
            continue
        if not a.has_deadzone:
            continue
        var why := ""
        if a.deadzone < DEADZONE_MIN:
            why = "a stick at rest already reads as pressed, so this stays held for ever on any pad with drift"
        elif a.deadzone > DEADZONE_MAX:
            why = "almost the whole travel of the stick is ignored, so it takes a hard push to register at all"
        if why == "":
            continue
        var f := Finding.new()
        f.action = name
        f.kind = "bad_deadzone"
        f.detail = String.num(a.deadzone, 3)
        f.note = why
        out.append(f)


static func _sorted(actions: Dictionary) -> Array:
    var keys: Array = actions.keys()
    keys.sort()
    return keys
