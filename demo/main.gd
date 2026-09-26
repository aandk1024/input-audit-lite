extends Control

## The demo. Press play and it runs the same audit the dock runs, over this
## project, and prints what it found.
##
## Everything it reports is planted: the input map in project.godot has one of
## every fault in it, and _gameplay() below names the actions the way real code
## does. Nothing here is a trick - the addon has no idea which project it is
## looking at.

const Audit := preload("res://addons/input_audit/core/audit.gd")
const Report := preload("res://addons/input_audit/core/report.gd")

@onready var _out: RichTextLabel = $Panel/Out


func _ready() -> void:
    var res = Audit.run("res://")
    _print("Input Audit - the report for this project")
    _print("")
    for line in Report.to_lines(res.findings):
        _print(line)
    _print("")
    _print(Report.summary(res.findings, res.actions_checked, res.files_read, res.ms))
    if res.dynamic > 0:
        _print("%d call site(s) build the action name at runtime and were not checked." % res.dynamic)


func _print(s: String) -> void:
    if _out != null:
        _out.append_text(s.replace("[", "[lb]") + "\n")


## Ordinary movement code. This is the half of the project the addon reads:
## every literal action name below is a use, and one of them is a typo.
func _gameplay(delta: float) -> void:
    var move := Input.get_axis("move_left", "move_right")
    var speed := 200.0 * move * delta

    if Input.is_action_just_pressed("jump"):
        speed += 1.0
    if Input.is_action_pressed("fire"):
        speed += 1.0
    if Input.is_action_pressed("crouch"):
        speed *= 0.5
    if Input.is_action_just_pressed("interact"):
        speed = 0.0
    if Input.is_action_just_pressed("pause"):
        get_tree().paused = true

    # A typo. Godot never says a word about this one: the call returns false,
    # for ever, and the double jump simply does not exist.
    if Input.is_action_just_pressed("jmup"):
        speed += 2.0

    # A "#" in front of a call is a comment, and a comment is not a use.
    # Input.is_action_pressed("ghost_action")
    position.x += speed


## A remapping screen builds the name from a row in a table. There is nothing
## wrong with this, and there is also nothing the addon can say about it, so
## it is counted and reported as a number rather than guessed at.
func _remap_row(action_name: String) -> bool:
    return Input.is_action_pressed(action_name)
