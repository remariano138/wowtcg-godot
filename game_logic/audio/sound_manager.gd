extends Node
## Autoload. Plays a random sound clip from a named folder under
## res://assets/card_sounds/<folder>/. Each folder holds interchangeable
## variations of one sound (e.g. SFX_CardMoveFast01..09.wav).

const SOUND_ROOT := "res://assets/card_sounds/"
const POOL_SIZE := 8  # concurrent players, so overlapping sounds don't cut each other

var _players: Array[AudioStreamPlayer] = []
var _next_player := 0
var _cache: Dictionary = {}  # folder name -> Array[AudioStream]

func _ready() -> void:
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)

## Play a random clip from res://assets/card_sounds/<folder>/.
func play_random(folder: String, volume_db: float = 0.0) -> void:
	var streams := _get_streams(folder)
	if streams.is_empty():
		return
	var stream: AudioStream = streams[randi() % streams.size()]
	var player := _players[_next_player]
	_next_player = (_next_player + 1) % _players.size()
	player.stream = stream
	player.volume_db = volume_db
	player.play()

func _get_streams(folder: String) -> Array:
	if _cache.has(folder):
		return _cache[folder]
	var streams: Array = []
	var dir_path := SOUND_ROOT + folder
	var dir := DirAccess.open(dir_path)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if not dir.current_is_dir():
				# Godot renames imported audio; match .wav (ignore .import sidecars).
				var lower := fname.to_lower()
				if lower.ends_with(".wav") or lower.ends_with(".ogg") or lower.ends_with(".mp3"):
					var res := load(dir_path + "/" + fname)
					if res is AudioStream:
						streams.append(res)
			fname = dir.get_next()
		dir.list_dir_end()
	else:
		push_warning("SoundManager: folder not found: " + dir_path)
	_cache[folder] = streams
	return streams
