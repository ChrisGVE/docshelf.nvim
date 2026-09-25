/** Generated with odin version dev-2026-09 (vendor "odin") Windows_amd64 @ 2026-09-24 23:43:34.577787400 +0000 UTC */
var odin_pkg_data = {
"packages": {
	"builtin": {
		"name": "builtin",
		"collection": "base",
		"path": "/base/builtin",
		"entities": [
			{"kind": "b", "name": "len", "type": "proc(v: Array_Type) -> int", "builtin": true, "comment": "`len` returns the length of `v`
according to its type, }"},
			{"kind": "t", "name": "string", "builtin": true, },
		]
	},
	"fmt": {
		"name": "fmt",
		"collection": "core",
		"path": "/core/fmt",
		"entities": [
			{"kind": "t", "name": "Info"},
			{"kind": "p", "name": "println", "comment": "Prints \"args\", then a newline."},
			{"kind": "g", "name": "print_any"},
		]
	},
	"strings": {
		"name": "strings",
		"collection": "core",
		"path": "/core/strings",
		"entities": [
			{"kind": "t", "name": "Builder"},
			{"kind": "c", "name": "MAX_SIZE"},
			{"kind": "v", "name": "default_builder"}
		]
	},
	"encoding_json": {
		"name": "encoding_json",
		"collection": "core",
		"path": "/core/encoding/json",
		"entities": [
			{"kind": "p", "name": "marshal"}
		]
	},
	"gone": {
		"name": "gone",
		"collection": "core",
		"path": "/core/gone",
		"entities": [
			{"kind": "p", "name": "vanished"}
		]
	},
	"raylib": {
		"name": "raylib",
		"collection": "vendor",
		"path": "/vendor/raylib",
		"entities": [
			{"kind": "p", "name": "DrawText"}
		]
	}
}};
