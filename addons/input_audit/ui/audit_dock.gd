@tool
extends VBoxContainer

## The dock. A thin skin: it reads the checkboxes, calls core/, and prints.
## No rule lives here, so every rule stays testable without an editor.

const Audit := preload("res://addons/input_audit/core/audit.gd")
const Checks := preload("res://addons/input_audit/core/checks.gd")
const Report := preload("res://addons/input_audit/core/report.gd")

const MD_PATH := "res://input_audit_report.md"
const JSON_PATH := "res://input_audit_report.json"

@onready var _log: RichTextLabel = $Log

var _busy := false
## The last run, kept so the export buttons write what the buyer just saw
## rather than silently re-running with whatever the checkboxes say now.
var _last: Object = null
var _last_opts: Object = null


func _ready() -> void:
    $CheckAll.pressed.connect(_on_check_all)
    _say("Ready. \"Check the project\" reads the input map and every .gd, .tscn and .tres file that names an action.")
    _lite_connect()
    _lite_note()
    $ExportRow.queue_free()


## Action names and file paths are arbitrary. Printed raw into a bbcode label,
## a "[" turns the rest of the line into a tag and the report silently loses
## characters.
func _esc(s: String) -> String:
    return s.replace("[", "[lb]")


func _say(s: String) -> void:
    if _log != null:
        _log.append_text(_esc(s) + "\n")


func _options() -> Object:
    var o = Checks.Options.new()
    o.check_undefined = $Undefined.button_pressed
    o.check_unbound = $Unbound.button_pressed
    o.check_devices = $Devices.button_pressed
    o.check_duplicates = $Duplicates.button_pressed
    o.check_deadzone = $Deadzone.button_pressed
    o.check_unused = $Unused.button_pressed
    return o


## A run walks every .gd and .tscn in the project. A second press part way
## through would interleave two sets of findings into one report - which reads
## as a result rather than as a bug.
##
## As the run stands it is synchronous, so nothing can press the button part
## way through and this guard cannot fire in normal use (Fable audit,
## 2026-09-06). It is kept, and the test drives it by setting the flag itself,
## because the day the walk yields a frame is the day it starts mattering and
## that is not a day to be discovering it.
func _refuse_while_busy() -> bool:
    if _busy:
        _say("Still checking - wait for the current run to finish.")
        return true
    return false


func _on_check_all() -> void:
    if _refuse_while_busy():
        return
    _run()


func _run() -> void:
    _busy = true
    var opts := _options()
    # Each run replaces what is shown. Appending meant the findings the buyer
    # is looking at were mixed into every earlier set, and the label grew
    # without bound over a session.
    if _log != null:
        _log.clear()
    _say("Checking…")
    var res = Audit.run("res://", opts)
    _busy = false
    _last = res
    _last_opts = opts

    var problems: Array = res.why_incomplete()
    for why in problems:
        _say("  " + String(why))
    for line in Report.to_lines(res.findings):
        _say(line)
    _say(Report.summary(res.findings, res.actions_checked, res.files_read, res.ms))
    if res.dynamic > 0:
        _say("%d call site(s) build the action name at runtime - those were not checked, and any of them could be naming any action." % res.dynamic)
    if res.maybe > 0:
        _say("%d `action` propert(ies) name an action without proving it is one - counted as uses, so those names are not reported unused, and never reported as a name that does not exist." % res.maybe)
    if res.ignored > 0:
        _say("%d folder(s) carry a .gdignore and were not read." % res.ignored)
    if not problems.is_empty():
        _say("NOT a complete check: %d problem(s) above mean part of the project was not read." % problems.size())
    _lite_note()

var _lite_press := Vector2.ZERO
var _lite_dragged := false


func _lite_connect() -> void:
    if is_instance_valid(_log):
        if not _log.meta_clicked.is_connected(_on_lite_meta):
            _log.meta_clicked.connect(_on_lite_meta)
        if not _log.gui_input.is_connected(_on_lite_gui):
            _log.gui_input.connect(_on_lite_gui)


# Godot 4.6+ still sends meta_clicked after a drag that began on the link.
func _on_lite_gui(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
        if event.pressed:
            _lite_press = event.position
            _lite_dragged = false
        elif event.position.distance_to(_lite_press) > 4.0:
            _lite_dragged = true


func _lite_note() -> void:
    if is_instance_valid(_log):
        var lite_shown: String = _log.get_parsed_text()
        if lite_shown.count("Input Audit Lite. Paid full version adds: Markdown and JSON reports. https://theidlehands.itch.io/input-audit") >= 4:
            _log.remove_paragraph(_log.get_character_paragraph(lite_shown.find("Input Audit Lite. Paid full version adds: Markdown and JSON reports. https://theidlehands.itch.io/input-audit") + 10))
        _log.append_text("Input Audit Lite. Paid full version adds: Markdown and JSON reports. [url=https://theidlehands.itch.io/input-audit]https://theidlehands.itch.io/input-audit[/url]\n")


func _on_lite_meta(meta: Variant) -> void:
    if not (meta is String):
        return
    if meta != "https://theidlehands.itch.io/input-audit":
        return
    if _lite_dragged:
        return
    if is_instance_valid(_log) and not _log.get_selected_text().is_empty():
        return
    var error := OS.shell_open("https://theidlehands.itch.io/input-audit")
    if error != OK and is_instance_valid(_log):
        _say("Could not open the browser. Copy this URL: https://theidlehands.itch.io/input-audit")
