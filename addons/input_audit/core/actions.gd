@tool
extends RefCounted

## The project's own input map, read from ProjectSettings.
##
## Deliberately NOT read from the InputMap singleton. Inside an editor the
## InputMap in memory is not the project's map: every enabled plugin that
## calls InputMap.add_action() during _enter_tree() has already added to it,
## and any of those would be reported as an action nothing uses. Worse, an
## action your code misspells would be reported as fine if some plugin happens
## to have added a name that matches. ProjectSettings is the file on disk,
## which is the thing a build actually ships.
##
## Actions live at "input/<name>" as { "deadzone": float, "events": [InputEvent] }.
##
## Every ui_* action the engine defines is in that property list whether or not
## the project ever touched it - measured 2026-09-06, a project whose file
## declares nine actions reports a hundred. So "it is in ProjectSettings" does
## not answer "did this project put it there", and without that answer the
## map-level rules spend their whole report on ui_text_caret_word_right. The
## names the project itself declared are read out of the [input] section of
## project.godot, which is the only place that distinction is written down.

const PREFIX := "input/"

## Godot reserves this prefix for the actions it defines itself. A name that
## starts with it is never reported as undefined, whether or not the project
## overrode it. Checked as a prefix rather than against a list of names,
## because the list differs between 4.4 and 4.7 and a hard-coded list would
## start lying the moment the engine added one.
const BUILTIN_PREFIX := "ui_"


class Action extends RefCounted:
    var name: String = ""
    var deadzone: float = 0.0
    ## Whether "deadzone" was actually present in the stored dictionary.
    var has_deadzone: bool = false
    var events: Array = []
    ## One "kind" string per event, in the same order: key, mouse, pad_button,
    ## pad_axis, touch, action, other.
    var kinds: PackedStringArray = PackedStringArray()
    ## Whether the project file's own [input] section declares this name.
    ## Defaults to true, so an action built by hand - in a test, or by another
    ## tool - is checked like any other. Only project_actions() sets it false,
    ## and only for a ui_* name the project never mentioned.
    var declared: bool = true
    ## Rows in the stored "events" array that are not InputEvents at all. The
    ## action is still checked on what could be read, and the run is marked
    ## not complete rather than reported as clean.
    var bad_events: int = 0

    func has_kind(k: String) -> bool:
        return kinds.has(k)

    func has_gamepad() -> bool:
        return has_kind("pad_button") or has_kind("pad_axis")

    func has_keyboard() -> bool:
        return has_kind("key")

    func is_builtin_name() -> bool:
        return name.begins_with(BUILTIN_PREFIX)

    ## An action that belongs to the engine and that this project never
    ## declared. It is not the project's to fix, so the map-level rules skip
    ## it. A ui_* action the project DID override is not one of these: that
    ## override is the project's own decision, and is checked like anything
    ## else.
    func is_engine_default() -> bool:
        return is_builtin_name() and not declared


## Every action the project file defines, by name. Order is stable: the
## dictionary is filled in sorted name order so two runs produce the same
## report.
static func project_actions(root: String = "res://") -> Dictionary:
    var declared := declared_names(root)
    var names: Array = []
    for p in ProjectSettings.get_property_list():
        var full := String(p.get("name", ""))
        if not full.begins_with(PREFIX):
            continue
        var short := full.substr(PREFIX.length())
        # "input/" with nothing after it is not an action.
        #
        # A further slash used to be excluded too, on the reasoning that Godot
        # forbids one in an action name. That reasoning was never put to the
        # engine. It has been now, in the test suite: InputMap.add_action(
        # "combat/jump") succeeds and has_action() agrees, so a project storing
        # such a name had it silently dropped from the map - every literal use
        # of it reported as an action that does not exist.
        if short == "":
            continue
        names.append(short)
    names.sort()

    # 🔴 "Declares nothing" and "could not be read" are different answers, and
    # collapsing them was a hole. A project file that cannot be read means "no
    # opinion": every name is then treated as declared, which is the report
    # this tool gave before the distinction existed, because a parse failure
    # must never quietly switch checks off. A project file that CAN be read and
    # declares no actions really does declare none - and treating that as "no
    # opinion" let anything written into ProjectSettings at runtime back in.
    var readable := project_file_readable(root)
    var out := {}
    for n in names:
        var a := _read(String(n))
        if a != null:
            a.declared = not readable or declared.has(a.name)
            out[a.name] = a
    return out


static func _project_file(root: String) -> String:
    var path := root
    if not path.ends_with("/"):
        path += "/"
    return path + "project.godot"


## Whether the project file was there to be read at all. An empty file is
## readable: it declares nothing, which is an answer. Only a file that is not
## there, or that will not open, means "no opinion".
static func project_file_readable(root: String = "res://") -> bool:
    var path := _project_file(root)
    if not FileAccess.file_exists(path):
        return false
    return FileAccess.open(path, FileAccess.READ) != null


## The action names written in the [input] section of the project file, as a
## set. Empty when the file cannot be read or has no such section.
static func declared_names(root: String = "res://") -> Dictionary:
    var path := _project_file(root)
    if not FileAccess.file_exists(path):
        return {}
    var text := FileAccess.get_file_as_string(path)
    if text == "":
        return {}
    var out := {}
    var in_input := false
    for raw in text.split("\n"):
        var line := String(raw).replace("\r", "")
        if line.begins_with("["):
            in_input = line.begins_with("[input]")
            continue
        if not in_input:
            continue
        # Only a line hard against the left margin can be a key. Everything
        # inside a stored dictionary is indented, quoted, or part of an
        # Object(...) literal.
        if line == "" or line.begins_with(";") or line.begins_with("\t") or line.begins_with(" "):
            continue
        var eq := line.find("=")
        if line.begins_with("\""):
            # A quoted key can hold an "=" of its own. The key ends at its
            # closing quote, so that is where the search for the separator
            # starts. A line out of a stored dictionary - "deadzone": 0.2 -
            # has no "=" after its closing quote and drops out below.
            var close := line.find("\"", 1)
            if close < 0:
                continue
            eq = line.find("=", close + 1)
        if eq <= 0:
            continue
        var name := line.substr(0, eq).strip_edges()
        # A name that is not a plain identifier is written quoted - "open map"
        # - and rejecting the quotes threw the action away, which then lost
        # every map-level check. A fully quoted key with no quote inside it is
        # one name; anything else (a line out of a stored dictionary, say) is
        # not a key at all.
        if name.length() >= 2 and name[0] == "\"" and name[name.length() - 1] == "\"":
            name = name.substr(1, name.length() - 2)
            if name == "" or name.contains("\""):
                continue
            out[name] = true
            continue
        if name == "" or name.contains("\"") or name.contains(" "):
            continue
        out[name] = true
    return out


static func _read(name: String) -> Action:
    var raw = ProjectSettings.get_setting(PREFIX + name, null)
    if raw == null or not (raw is Dictionary):
        return null
    var a := Action.new()
    a.name = name
    if raw.has("deadzone"):
        a.has_deadzone = true
        a.deadzone = float(raw["deadzone"])
    var evs = raw.get("events", [])
    if evs is Array:
        for e in evs:
            # Not "if e == null": a hand-edited project file can hold a
            # number, and passing one to kind_of(e: Object) stops the whole
            # run with a type error - so one broken row loses the report for
            # every other action too.
            if not (e is InputEvent):
                a.bad_events += 1
                continue
            a.events.append(e)
            a.kinds.append(kind_of(e))
    else:
        a.bad_events += 1
    return a


static func kind_of(e: Object) -> String:
    if e is InputEventKey:
        return "key"
    if e is InputEventMouseButton:
        return "mouse"
    if e is InputEventJoypadButton:
        return "pad_button"
    if e is InputEventJoypadMotion:
        return "pad_axis"
    if e is InputEventScreenTouch or e is InputEventScreenDrag:
        return "touch"
    if e is InputEventAction:
        return "action"
    return "other"


## A short, stable identity for one physical binding, so two actions bound to
## the same thing can be spotted. Two events with the same signature are the
## same press as far as a player is concerned.
##
## Keys are identified by their physical code when one is set. Godot stores a
## binding as either a keycode (the letter printed on the key, which moves with
## the layout) or a physical_keycode (the position, which does not), and the
## same key entered both ways would otherwise look like two different bindings.
## When only one of the two is set, the other is 0, so the pair below is the
## honest identity: the two forms are reported as a clash only when they really
## are the same field.
static func signature(e: Object) -> String:
    if e is InputEventKey:
        var k := e as InputEventKey
        var mods := 0
        if k.ctrl_pressed:
            mods |= 1
        if k.shift_pressed:
            mods |= 2
        if k.alt_pressed:
            mods |= 4
        if k.meta_pressed:
            mods |= 8
        return "key:%d:%d:%d" % [int(k.physical_keycode), int(k.keycode), mods]
    if e is InputEventMouseButton:
        return "mouse:%d" % int((e as InputEventMouseButton).button_index)
    if e is InputEventJoypadButton:
        return "pad_button:%d" % int((e as InputEventJoypadButton).button_index)
    if e is InputEventJoypadMotion:
        var m := e as InputEventJoypadMotion
        var sign_txt := "+" if m.axis_value >= 0.0 else "-"
        return "pad_axis:%d:%s" % [int(m.axis), sign_txt]
    if e is InputEventAction:
        return "action:%s" % String((e as InputEventAction).action)
    # Anything without a stable identity is given a unique one, so it can
    # never be reported as a clash with something else.
    return "other:%d" % (e.get_instance_id() if e != null else 0)


## Whether two bindings can be triggered by the same physical press. Godot
## stores a device number on every event: -1 means "any device", and a binding
## on device 0 is NOT pressed by device 1. Two players on two pads, each with
## their own jump on button 0, are not a clash - reporting them as one was
## wrong on the only projects where it mattered.
static func same_device(a: Object, b: Object) -> bool:
    var da := int(a.get("device")) if a != null else -1
    var db := int(b.get("device")) if b != null else -1
    return da == db or da < 0 or db < 0


## What to print for one binding. Never used for comparison - only for the
## report - so it is allowed to be human-shaped.
static func describe(e: Object) -> String:
    if e is InputEventKey:
        var k := e as InputEventKey
        var txt := k.as_text()
        return txt if txt != "" else "key"
    if e is InputEventMouseButton:
        return "mouse button %d" % int((e as InputEventMouseButton).button_index)
    if e is InputEventJoypadButton:
        return "gamepad button %d" % int((e as InputEventJoypadButton).button_index)
    if e is InputEventJoypadMotion:
        var m := e as InputEventJoypadMotion
        return "gamepad axis %d %s" % [int(m.axis), ("+" if m.axis_value >= 0.0 else "-")]
    if e is InputEventScreenTouch or e is InputEventScreenDrag:
        return "touch"
    if e is InputEventAction:
        return "action \"%s\"" % String((e as InputEventAction).action)
    return e.get_class() if e != null else "nothing"
