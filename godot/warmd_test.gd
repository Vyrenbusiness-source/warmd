class_name WarmdTest
extends RefCounted
## Tiny base class for warmd tests. A test file is named test_*.gd, its test methods test_*.
## Tests run in a warm engine, so they pick up edits without a restart. GUT and gdUnit4 also work.

var failures: Array[String] = []


func assert_true(value: bool, note: String = "") -> void:
	if not value:
		failures.append(note if note != "" else "expected true")


func assert_eq(got: Variant, want: Variant, note: String = "") -> void:
	if got != want:
		failures.append("%s got %s, want %s" % [note, got, want])
