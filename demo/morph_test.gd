extends Control
## CharacterMorph2D 비주얼 GUI 에디터 및 테스트 컨트롤러.
## 화면 해상도(1152x648 등) 밖으로 UI가 절대 넘치지 않도록 컴팩트한 레이아웃과
## 캔버스 위 핸들(위치·크기·화살표) 직접 드래그 조작을 제공합니다.

const DEFAULT_PRESET_PATH: String = "res://presets/default_breathing.json"
const MULTI_PRESET_PATH: String = "res://presets/multi_region_sway.json"

const UI_FONT_SIZE: int = 12

enum BgMode {
	CHECKERBOARD_DARK,
	CHECKERBOARD_LIGHT,
	SOLID_DARK,
	SOLID_LIGHT,
	CHROMA_GREEN,
}

enum ToolMode {
	GIZMO_DIRECT = 0,
	MASK_ERASE = 1,
	MASK_PAINT = 2,
	TOUCH_BOUNCE = 3,
}

enum LayerLoadTarget {
	SINGLE_OR_BODY = 0,
	MORPH_PART = 1,
	PROTECTED_OUTLINE = 2,
}

@onready var toolbar_hbox: HBoxContainer = $RootVBox/TopToolbar/ToolbarMargin/ToolbarHBox
@onready var viewport_panel: Control = $RootVBox/MainSplit/ViewportPanel
@onready var canvas_bg: Control = $RootVBox/MainSplit/ViewportPanel/CanvasClip/CanvasBg
@onready var stage_root: Node2D = $RootVBox/MainSplit/ViewportPanel/CanvasClip/StageRoot
@onready var original_sprite: Sprite2D = $RootVBox/MainSplit/ViewportPanel/CanvasClip/StageRoot/OriginalCompareSprite
@onready var morph_node: CharacterMorph2D = $RootVBox/MainSplit/ViewportPanel/CanvasClip/StageRoot/CharacterMorph2D
@onready var compare_labels: Control = $RootVBox/MainSplit/ViewportPanel/CanvasClip/CompareLabels
@onready var cursor_badge: PanelContainer = $RootVBox/MainSplit/ViewportPanel/CanvasClip/CursorBadge
@onready var badge_label: Label = $RootVBox/MainSplit/ViewportPanel/CanvasClip/CursorBadge/BadgeLabel
@onready var bottom_hint_bar: PanelContainer = $RootVBox/MainSplit/ViewportPanel/BottomHintBar
@onready var hint_label: Label = $RootVBox/MainSplit/ViewportPanel/BottomHintBar/HintLabel
@onready var right_side_panel: PanelContainer = $RootVBox/MainSplit/RightSidePanel
@onready var playback_hbox: HBoxContainer = $RootVBox/BottomPlaybackBar/PlaybackMargin/PlaybackHBox
@onready var image_file_dialog: FileDialog = $ImageFileDialog
@onready var preset_save_dialog: FileDialog = $PresetSaveDialog
@onready var preset_load_dialog: FileDialog = $PresetLoadDialog
@onready var gif_save_dialog: FileDialog = $GifSaveDialog

# 뷰포트 줌 / 팬 / 직접 조작 상태
var _zoom_level: float = 1.0
var _pan_offset: Vector2 = Vector2.ZERO
var _is_panning: bool = false
var _is_left_dragging: bool = false
var _dragged_gizmo_part: int = CharacterMorph2D.GizmoPart.NONE
var _side_by_side_compare: bool = true
var _show_original_right: bool = false
var _result_sprite: Sprite2D = null
var _source_basename: String = ""
var _space_holding_original: bool = false
var _bg_mode: BgMode = BgMode.CHECKERBOARD_DARK
var _current_tool: ToolMode = ToolMode.GIZMO_DIRECT
var _layer_load_target: LayerLoadTarget = LayerLoadTarget.SINGLE_OR_BODY
var _updating_ui: bool = false
var _is_exporting_gif: bool = false

# 상단 툴바 & 하단 바 위젯 참조
var _tool_buttons: Dictionary = {}
var _zoom_label: Button
var _gizmo_toggle_btn: Button
var _bypass_toggle_btn: Button
var _split_toggle_btn: Button
var _play_pause_btn: Button
var _timeline_slider: HSlider
var _timeline_val_label: Label
var _is_scrubbing_timeline: bool = false

# 우측 탭 컨테이너 및 주요 GUI 위젯
var _tabs: TabContainer
var _region_list: ItemList
var _region_enable_check: CheckButton
var _joystick_pad: Control
var _joystick_dragging: bool = false
var _joystick_info_label: Label
var _scale_slider: Dictionary
var _falloff_slider: Dictionary
var _outline_protect_slider: Dictionary

var _speed_slider: Dictionary
var _amplitude_slider: Dictionary
var _spring_switch: CheckButton
var _stiffness_slider: Dictionary
var _damping_slider: Dictionary
var _delay_slider: Dictionary
var _weight_slider: Dictionary

var _mask_switch: CheckButton
var _brush_size_slider: Dictionary
var _layer_switch: CheckButton
var _ghost_slider: Dictionary
var _outline_follow_slider: Dictionary
var _layer_thumb_body: TextureRect
var _layer_thumb_part: TextureRect
var _layer_thumb_outline: TextureRect

var _preset_list: ItemList
var _preset_files: Array[String] = []


func _ready() -> void:
	_apply_panel_styles()
	_build_top_toolbar()
	_build_right_tabs()
	_build_bottom_playback_bar()
	_setup_result_view()
	_connect_signals()

	morph_node.show_debug_gizmo = true
	if FileAccess.file_exists(DEFAULT_PRESET_PATH):
		morph_node.load_preset_file(DEFAULT_PRESET_PATH)
	_refresh_preset_file_list()
	_sync_ui_from_morph_node()
	_set_tool_mode(ToolMode.GIZMO_DIRECT)
	call_deferred("_reset_view_transform")


## 오른쪽 '결과 전용' 뷰: 왼쪽 편집 노드와 동일한 ShaderMaterial을 공유하므로 기즈모 없이 같은 변형 결과만 표시됩니다.
func _setup_result_view() -> void:
	_result_sprite = Sprite2D.new()
	_result_sprite.name = "ResultSprite"
	_result_sprite.centered = true
	_result_sprite.material = morph_node.get_shader_material()
	stage_root.add_child(_result_sprite)

	(compare_labels.get_node("OrigTag") as Label).text = "✎ 편집 (조작 화면)"
	(compare_labels.get_node("MorphTag") as Label).text = "결과"


func _apply_original_view(show_original: bool) -> void:
	_show_original_right = show_original
	_update_compare_layout()
	var tag := compare_labels.get_node("MorphTag") as Label
	tag.text = "원본" if show_original else "결과"


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_SPACE:
		if event.pressed and not event.echo:
			_space_holding_original = true
			_apply_original_view(true)
			_set_hint("🌓 스페이스바 홀드 중: 오른쪽에 원본 이미지를 보여줍니다.")
		elif not event.pressed and _space_holding_original:
			_space_holding_original = false
			_apply_original_view(_bypass_toggle_btn != null and _bypass_toggle_btn.button_pressed)
			_update_tool_hint()


# ============================================================================
# 시각 스타일 및 컴팩트 위젯 생성 도우미
# ============================================================================

func _apply_panel_styles() -> void:
	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = Color(0.13, 0.14, 0.18, 1.0)
	bar_style.border_color = Color(0.24, 0.27, 0.34, 1.0)
	bar_style.border_width_bottom = 1
	bar_style.border_width_top = 1
	($RootVBox/TopToolbar as PanelContainer).add_theme_stylebox_override("panel", bar_style)
	($RootVBox/BottomPlaybackBar as PanelContainer).add_theme_stylebox_override("panel", bar_style)

	var side_style := StyleBoxFlat.new()
	side_style.bg_color = Color(0.15, 0.16, 0.20, 1.0)
	side_style.border_color = Color(0.24, 0.27, 0.34, 1.0)
	side_style.border_width_left = 1
	right_side_panel.add_theme_stylebox_override("panel", side_style)

	var hint_style := StyleBoxFlat.new()
	hint_style.bg_color = Color(0.08, 0.10, 0.14, 0.86)
	hint_style.border_color = Color(0.25, 0.75, 0.95, 0.55)
	hint_style.set_border_width_all(1)
	hint_style.set_corner_radius_all(6)
	hint_style.content_margin_left = 8
	hint_style.content_margin_right = 8
	hint_style.content_margin_top = 4
	hint_style.content_margin_bottom = 4
	bottom_hint_bar.add_theme_stylebox_override("panel", hint_style)

	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = Color(0.08, 0.10, 0.14, 0.92)
	badge_style.border_color = Color(1.0, 0.85, 0.25, 0.9)
	badge_style.set_border_width_all(1)
	badge_style.set_corner_radius_all(5)
	badge_style.content_margin_left = 6
	badge_style.content_margin_right = 6
	badge_style.content_margin_top = 3
	badge_style.content_margin_bottom = 3
	cursor_badge.add_theme_stylebox_override("panel", badge_style)


func _make_btn(text_str: String, tip: String = "") -> Button:
	var btn := Button.new()
	btn.text = text_str
	btn.tooltip_text = tip
	btn.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	return btn


func _create_card_panel(title_text: String, parent_box: VBoxContainer) -> VBoxContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.18, 0.20, 0.25, 1.0)
	st.border_color = Color(0.28, 0.31, 0.39, 1.0)
	st.set_border_width_all(1)
	st.set_corner_radius_all(6)
	st.content_margin_left = 8
	st.content_margin_right = 8
	st.content_margin_top = 7
	st.content_margin_bottom = 7
	card.add_theme_stylebox_override("panel", st)

	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 6)
	card.add_child(inner)

	if not title_text.is_empty():
		var title_lbl := Label.new()
		title_lbl.text = title_text
		title_lbl.add_theme_font_size_override("font_size", UI_FONT_SIZE)
		title_lbl.add_theme_color_override("font_color", Color(0.55, 0.88, 1.0))
		title_lbl.clip_text = true
		inner.add_child(title_lbl)

	parent_box.add_child(card)
	return inner


# ============================================================================
# 1. 상단 비주얼 툴바 (열기 / 애드온저장 / GIF저장 + 도구 & 개별 초기화 + 줌/비교)
# ============================================================================

func _build_top_toolbar() -> void:
	toolbar_hbox.add_theme_constant_override("separation", 3)

	var open_btn := _make_btn("📂 그림열기", "PNG/JPG/WebP/SVG 캐릭터 이미지를 엽니다 (창으로 파일 드래그 앤 드롭 가능)")
	open_btn.pressed.connect(func() -> void:
		_layer_load_target = LayerLoadTarget.SINGLE_OR_BODY
		image_file_dialog.popup_centered_ratio(0.65)
	)
	toolbar_hbox.add_child(open_btn)

	var save_addon_btn := _make_btn("💾 프리셋저장", "CharacterMorph2D 애드온에서 바로 불러와 쓸 수 있는 설정 파일(.json)로 저장합니다")
	save_addon_btn.pressed.connect(_open_preset_save_dialog)
	toolbar_hbox.add_child(save_addon_btn)

	var load_addon_btn := _make_btn("📂 프리셋열기", "저장해 둔 애드온 설정 파일(.json)을 불러옵니다")
	load_addon_btn.pressed.connect(_open_preset_load_dialog)
	toolbar_hbox.add_child(load_addon_btn)

	var save_gif_btn := _make_btn("🎞️ GIF저장", "현재 움직이는 캐릭터 애니메이션을 무한 반복 GIF(.gif) 파일로 저장합니다")
	save_gif_btn.pressed.connect(_open_gif_save_dialog)
	toolbar_hbox.add_child(save_gif_btn)

	toolbar_hbox.add_child(VSeparator.new())

	# 중앙: 마우스 도구 선택 버튼들 + 보호지우개/변형브러시 바로 옆 개별 초기화(↺) 버튼
	var tool_group := ButtonGroup.new()
	_add_tool_button("✥ 영역조절", ToolMode.GIZMO_DIRECT, tool_group, "마우스로 원의 중심·크기·화살표를 직접 끌어 조절합니다")

	_add_tool_button("🧽 보호지우개", ToolMode.MASK_ERASE, tool_group, "움직이지 말아야 할 부분(옷깃, 턱선 등)을 문질러 고정합니다")
	var reset_erase_top_btn := _make_btn("↺", "보호지우개 초기화 (지우개로 고정한 영역만 초기화)")
	reset_erase_top_btn.pressed.connect(_reset_protection_eraser)
	toolbar_hbox.add_child(reset_erase_top_btn)

	_add_tool_button("🖌️ 변형브러시", ToolMode.MASK_PAINT, tool_group, "움직일 영역을 브러시로 직접 칠합니다")
	var reset_brush_top_btn := _make_btn("↺", "변형브러시 초기화 (브러시로 칠한 변형 영역만 초기화)")
	reset_brush_top_btn.pressed.connect(_reset_deform_brush)
	toolbar_hbox.add_child(reset_brush_top_btn)

	_add_tool_button("👋 탄성터치", ToolMode.TOUCH_BOUNCE, tool_group, "캐릭터를 클릭해 스프링 탄성을 테스트합니다")

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar_hbox.add_child(spacer)

	# 우측: 줌 컨트롤 및 비교 버튼
	var zoom_out_btn := _make_btn("－", "축소")
	zoom_out_btn.pressed.connect(func() -> void: _set_zoom(_zoom_level / 1.2))
	toolbar_hbox.add_child(zoom_out_btn)

	_zoom_label = _make_btn("100%", "클릭하면 화면 크기에 맞게 배율을 초기화합니다")
	_zoom_label.custom_minimum_size = Vector2(44, 0)
	_zoom_label.pressed.connect(_reset_view_transform)
	toolbar_hbox.add_child(_zoom_label)

	var zoom_in_btn := _make_btn("＋", "확대")
	zoom_in_btn.pressed.connect(func() -> void: _set_zoom(_zoom_level * 1.2))
	toolbar_hbox.add_child(zoom_in_btn)

	var bg_opt := OptionButton.new()
	bg_opt.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	bg_opt.tooltip_text = "배경 격자/색상 변경"
	bg_opt.add_item("🏁 어두운격자", BgMode.CHECKERBOARD_DARK)
	bg_opt.add_item("🏳️ 밝은격자", BgMode.CHECKERBOARD_LIGHT)
	bg_opt.add_item("⬛ 어두운배경", BgMode.SOLID_DARK)
	bg_opt.add_item("⬜ 밝은배경", BgMode.SOLID_LIGHT)
	bg_opt.add_item("🟩 그린스크린", BgMode.CHROMA_GREEN)
	bg_opt.item_selected.connect(func(idx: int) -> void:
		_bg_mode = bg_opt.get_item_id(idx) as BgMode
		canvas_bg.queue_redraw()
	)
	toolbar_hbox.add_child(bg_opt)

	_gizmo_toggle_btn = _make_btn("👁️ 가이드", "변형 영역 원과 화살표 표시 켜기/끄기")
	_gizmo_toggle_btn.toggle_mode = true
	_gizmo_toggle_btn.button_pressed = true
	_gizmo_toggle_btn.toggled.connect(func(on: bool) -> void:
		morph_node.show_debug_gizmo = on
	)
	toolbar_hbox.add_child(_gizmo_toggle_btn)

	_bypass_toggle_btn = _make_btn("🌓 원본", "오른쪽 화면을 원본 ↔ 결과로 전환합니다 (Space 키 홀드)")
	_bypass_toggle_btn.toggle_mode = true
	_bypass_toggle_btn.toggled.connect(func(on: bool) -> void:
		_apply_original_view(on)
	)
	toolbar_hbox.add_child(_bypass_toggle_btn)

	_split_toggle_btn = _make_btn("◫ 비교", "왼쪽 편집 / 오른쪽 결과 나란히 보기 (끄면 편집 화면만 크게)")
	_split_toggle_btn.toggle_mode = true
	_split_toggle_btn.set_pressed_no_signal(true)
	_split_toggle_btn.toggled.connect(func(on: bool) -> void:
		_side_by_side_compare = on
		_reset_view_transform()
	)
	toolbar_hbox.add_child(_split_toggle_btn)


func _add_tool_button(text_str: String, mode: ToolMode, group: ButtonGroup, tip: String) -> void:
	var btn := _make_btn(text_str, tip)
	btn.toggle_mode = true
	btn.button_group = group
	btn.pressed.connect(func() -> void:
		_set_tool_mode(mode)
	)
	toolbar_hbox.add_child(btn)
	_tool_buttons[mode] = btn


func _set_tool_mode(mode: ToolMode) -> void:
	_current_tool = mode
	if _tool_buttons.has(mode):
		(_tool_buttons[mode] as Button).set_pressed_no_signal(true)

	morph_node.brush_is_eraser = (mode == ToolMode.MASK_ERASE)
	morph_node.brush_preview_active = (mode in [ToolMode.MASK_ERASE, ToolMode.MASK_PAINT])
	morph_node.show_mask_overlay = (mode in [ToolMode.MASK_ERASE, ToolMode.MASK_PAINT]) or morph_node.preset.freeform_mask_enabled
	if mode != ToolMode.GIZMO_DIRECT:
		morph_node.hovered_gizmo_part = CharacterMorph2D.GizmoPart.NONE
		cursor_badge.visible = false
	_update_tool_hint()
	morph_node.queue_redraw()


func _reset_protection_eraser() -> void:
	morph_node.clear_protection_eraser()
	_set_hint("🧽 보호지우개로 고정했던 영역이 모두 초기화되었습니다.")


func _reset_deform_brush() -> void:
	morph_node.clear_deform_brush()
	_set_hint("🖌️ 변형브러시로 칠했던 영역이 모두 초기화되었습니다.")


func _default_save_basename() -> String:
	return _source_basename if not _source_basename.is_empty() else "my_character_morph"


func _open_preset_save_dialog() -> void:
	preset_save_dialog.current_dir = "res://presets"
	preset_save_dialog.current_file = _default_save_basename() + ".json"
	preset_save_dialog.popup_centered_ratio(0.65)


func _open_preset_load_dialog() -> void:
	preset_load_dialog.current_dir = "res://presets"
	preset_load_dialog.popup_centered_ratio(0.65)


func _open_gif_save_dialog() -> void:
	if morph_node.get_texture_size().x <= 0.0:
		_set_hint("⚠️ 먼저 [📂 그림열기]로 캐릭터 이미지를 불러온 뒤 GIF로 저장해 주세요!")
		return
	if _is_exporting_gif:
		return
	gif_save_dialog.current_file = _default_save_basename() + ".gif"
	gif_save_dialog.popup_centered_ratio(0.65)


func _update_tool_hint() -> void:
	if morph_node.get_texture_size().x <= 0.0:
		_set_hint("📂 상단 [그림열기] 버튼을 누르거나 이미지 파일을 창으로 드래그해 캐릭터를 불러오세요.")
		return
	match _current_tool:
		ToolMode.GIZMO_DIRECT:
			_set_hint("💡 원 안을 드래그해 위치 이동 | 네모 점(■)으로 크기 조절 | 노란 화살표 끝(●)으로 방향·세기 조절")
		ToolMode.MASK_ERASE:
			_set_hint("🧽 움직이면 안 되는 부위(턱, 옷깃 등)를 드래그해 빨갛게 칠하면 고정됩니다. (옆 ↺ 버튼으로 지우개만 초기화)")
		ToolMode.MASK_PAINT:
			_set_hint("🖌️ 움직임을 추가할 부위를 드래그해 초록색으로 칠하세요. (옆 ↺ 버튼으로 브러시만 초기화)")
		ToolMode.TOUCH_BOUNCE:
			_set_hint("👋 캐릭터 위를 클릭할 때마다 스프링 탄성으로 출렁입니다!")


# ============================================================================
# 2. 하단 재생 바 및 타임라인 독 (컴팩트 폭)
# ============================================================================

func _build_bottom_playback_bar() -> void:
	_play_pause_btn = _make_btn("⏸ 일시정지", "자동 호흡 재생/일시정지")
	_play_pause_btn.custom_minimum_size = Vector2(92, 0)
	_play_pause_btn.pressed.connect(func() -> void:
		morph_node.auto_play = not morph_node.auto_play
		_update_play_button_label()
	)
	playback_hbox.add_child(_play_pause_btn)

	var stop_btn := _make_btn("⏹ 정지", "변형을 0% 상태로 초기화")
	stop_btn.pressed.connect(func() -> void:
		morph_node.stop()
		_update_play_button_label()
		_timeline_slider.set_value_no_signal(0.0)
		_timeline_val_label.text = "0%"
	)
	playback_hbox.add_child(stop_btn)

	var wave_lbl := Label.new()
	wave_lbl.text = "움직임:"
	wave_lbl.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	playback_hbox.add_child(wave_lbl)

	_timeline_slider = HSlider.new()
	_timeline_slider.min_value = -1.0
	_timeline_slider.max_value = 1.0
	_timeline_slider.step = 0.01
	_timeline_slider.value = 0.0
	_timeline_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_timeline_slider.tooltip_text = "드래그하면 수동으로 움직임을 테스트합니다"
	_timeline_slider.drag_started.connect(func() -> void:
		_is_scrubbing_timeline = true
		morph_node.auto_play = false
		_update_play_button_label()
	)
	_timeline_slider.drag_ended.connect(func(_changed: bool) -> void:
		_is_scrubbing_timeline = false
	)
	_timeline_slider.value_changed.connect(func(v: float) -> void:
		if _is_scrubbing_timeline or not morph_node.auto_play:
			morph_node.auto_play = false
			_update_play_button_label()
			morph_node.manual_phase = v
			_timeline_val_label.text = "%+d%%" % int(round(v * 100.0))
	)
	playback_hbox.add_child(_timeline_slider)

	_timeline_val_label = Label.new()
	_timeline_val_label.custom_minimum_size = Vector2(42, 0)
	_timeline_val_label.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	_timeline_val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_timeline_val_label.text = "0%"
	playback_hbox.add_child(_timeline_val_label)

	playback_hbox.add_child(VSeparator.new())

	var feel_calm := _make_btn("💨 잔잔한호흡")
	feel_calm.pressed.connect(func() -> void:
		morph_node.preset.breathing_speed = 0.9
		morph_node.preset.breathing_amplitude = 0.85
		morph_node.preset.spring_enabled = false
		morph_node.play()
		_sync_ui_from_morph_node()
	)
	playback_hbox.add_child(feel_calm)

	var feel_deep := _make_btn("💓 깊은호흡")
	feel_deep.pressed.connect(func() -> void:
		morph_node.preset.breathing_speed = 1.5
		morph_node.preset.breathing_amplitude = 1.45
		morph_node.preset.spring_enabled = false
		morph_node.play()
		_sync_ui_from_morph_node()
	)
	playback_hbox.add_child(feel_deep)

	var feel_spring := _make_btn("🍮 탱탱한탄성")
	feel_spring.pressed.connect(func() -> void:
		morph_node.preset.spring_enabled = true
		morph_node.preset.spring_stiffness = 160.0
		morph_node.preset.spring_damping = 7.0
		morph_node.trigger_impulse(1.5)
		_sync_ui_from_morph_node()
	)
	playback_hbox.add_child(feel_spring)


func _update_play_button_label() -> void:
	if _play_pause_btn == null:
		return
	if morph_node.auto_play:
		_play_pause_btn.text = "⏸ 일시정지"
	else:
		_play_pause_btn.text = "▶ 자동재생"


# ============================================================================
# 3. 우측 4-탭 사이드바 (295px 내부에 100% 들어맞도록 설계)
# ============================================================================

func _build_right_tabs() -> void:
	_tabs = TabContainer.new()
	_tabs.clip_tabs = true
	_tabs.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_side_panel.add_child(_tabs)

	_build_tab_region_and_direction()
	_build_tab_motion_and_spring()
	_build_tab_mask_and_layers()
	_build_tab_presets()


func _create_tab_scroll_vbox(tab_title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	scroll.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)
	return vbox


func _build_tab_region_and_direction() -> void:
	var vbox := _create_tab_scroll_vbox("🎯영역")

	# 카드 1: 변형 영역 목록
	var list_card := _create_card_panel("📍 변형 영역 목록 (최대 8개)", vbox)
	_region_list = ItemList.new()
	_region_list.custom_minimum_size = Vector2(0, 76)
	_region_list.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	_region_list.item_selected.connect(func(idx: int) -> void:
		morph_node.selected_region_index = idx
		_sync_ui_from_morph_node()
	)
	list_card.add_child(_region_list)

	var list_btns := HBoxContainer.new()
	list_btns.add_theme_constant_override("separation", 4)
	var add_btn := _make_btn("＋ 영역 추가")
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(func() -> void:
		var idx: int = morph_node.preset.add_region()
		morph_node.selected_region_index = idx
		morph_node._update_shader_uniforms()
		_sync_ui_from_morph_node()
		if _region_list != null and idx < _region_list.item_count:
			_region_list.select(idx)
			_region_list.ensure_current_is_visible()
	)
	var del_btn := _make_btn("🗑️ 삭제")
	del_btn.pressed.connect(func() -> void:
		morph_node.preset.remove_region(morph_node.selected_region_index)
		morph_node.selected_region_index = clampi(
			morph_node.selected_region_index,
			0,
			morph_node.preset.get_region_count() - 1
		)
		morph_node._update_shader_uniforms()
		_sync_ui_from_morph_node()
	)
	list_btns.add_child(add_btn)
	list_btns.add_child(del_btn)
	list_card.add_child(list_btns)

	_region_enable_check = CheckButton.new()
	_region_enable_check.text = "선택 영역 움직임 켜기"
	_region_enable_check.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	_region_enable_check.toggled.connect(func(on: bool) -> void:
		if not _updating_ui:
			morph_node.set_region_enabled(on)
			_refresh_region_item_list()
	)
	list_card.add_child(_region_enable_check)

	# 카드 2: 시각적 2D 방향·강도 조이스틱 패드 (컴팩트 92x92)
	var pad_card := _create_card_panel("🕹️ 방향 & 세기 조이스틱", vbox)
	var pad_hbox := HBoxContainer.new()
	pad_hbox.add_theme_constant_override("separation", 8)
	pad_card.add_child(pad_hbox)

	_joystick_pad = Control.new()
	_joystick_pad.custom_minimum_size = Vector2(92, 92)
	_joystick_pad.draw.connect(_on_joystick_pad_draw)
	_joystick_pad.gui_input.connect(_on_joystick_pad_input)
	pad_hbox.add_child(_joystick_pad)

	var pad_right := VBoxContainer.new()
	pad_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad_right.alignment = BoxContainer.ALIGNMENT_CENTER
	pad_right.add_theme_constant_override("separation", 4)
	pad_hbox.add_child(pad_right)

	_joystick_info_label = Label.new()
	_joystick_info_label.add_theme_font_size_override("font_size", 11)
	_joystick_info_label.text = "방향: (0.0, -1.0)\n세기: 30%"
	_joystick_info_label.clip_text = true
	pad_right.add_child(_joystick_info_label)

	var dir_preset_grid := GridContainer.new()
	dir_preset_grid.columns = 2
	dir_preset_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dir_preset_grid.add_theme_constant_override("h_separation", 4)
	dir_preset_grid.add_theme_constant_override("v_separation", 4)
	pad_right.add_child(dir_preset_grid)

	_add_small_dir_btn(dir_preset_grid, "⬆️ 위로", Vector2(0.0, -1.0))
	_add_small_dir_btn(dir_preset_grid, "⬇️ 아래", Vector2(0.0, 1.0))
	_add_small_dir_btn(dir_preset_grid, "⬅️ 좌측", Vector2(-1.0, 0.0))
	_add_small_dir_btn(dir_preset_grid, "➡️ 우측", Vector2(1.0, 0.0))

	# 카드 3: 볼륨 팽창 & 경계선 부드럽기
	var detail_card := _create_card_panel("🎚️ 부풀리기 & 경계 다듬기", vbox)
	_scale_slider = _add_slider_row(
		detail_card,
		"부풀어 오르기 (팽창)",
		-0.15, 0.15, 0.005, 0.04, "%+d%%", 500.0,
		"호흡 주기에 맞춰 선택 영역이 입체적으로 볼록하게 부풀거나 수축하는 세기입니다.\n양수(+)는 들숨 시 팽창, 음수(-)는 수축합니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.set_region_scale_strength(v)
	)
	_falloff_slider = _add_slider_row(
		detail_card,
		"경계선 부드럽기",
		0.4, 3.5, 0.05, 1.5, "%.1f", 1.0,
		"영역 중심에서 외곽으로 갈수록 변형이 부드럽게 감쇠(Falloff)되는 정도입니다.\n값이 클수록 경계선이 주변과 매우 자연스럽게 이어집니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.set_region_falloff(v)
	)
	_outline_protect_slider = _add_slider_row(
		detail_card,
		"외곽선 찌그러짐 보호",
		0.0, 1.0, 0.05, 0.5, "%d%%", 100.0,
		"변형 시 캐릭터의 바깥 테두리 실루엣이 찌그러지거나 찢어지지 않도록 보호하는 강도입니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.preset.outline_protect = v
				morph_node._update_shader_uniforms()
	)


func _build_tab_motion_and_spring() -> void:
	var vbox := _create_tab_scroll_vbox("🏃탄성")

	var breath_card := _create_card_panel("💨 호흡 속도 & 전체 진폭", vbox)
	_speed_slider = _add_slider_row(
		breath_card,
		"호흡 빠르기",
		0.2, 3.5, 0.05, 1.2, "%.1f배", 1.0,
		"캐릭터의 전체적인 숨쉬기/반복 모션 주기 속도입니다.\n배수가 높을수록 빠르게 호흡하며 움직입니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.preset.breathing_speed = v
	)
	_amplitude_slider = _add_slider_row(
		breath_card,
		"전체 움직임 크기",
		0.0, 2.5, 0.05, 1.0, "%d%%", 100.0,
		"모든 변형 영역의 이동 및 팽창 진폭을 일괄 조절하는 전체 크기 배율입니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.preset.breathing_amplitude = v
				morph_node._update_shader_uniforms()
	)

	var spring_card := _create_card_panel("🍮 출렁이는 스프링 탄성", vbox)
	_spring_switch = CheckButton.new()
	_spring_switch.text = "스프링 탄성 물리 효과 켜기"
	_spring_switch.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	_spring_switch.toggled.connect(func(on: bool) -> void:
		if not _updating_ui:
			morph_node.preset.spring_enabled = on
	)
	spring_card.add_child(_spring_switch)

	var bounce_btn := _make_btn("💥 지금 통! 튕겨보기 (탄성 테스트)")
	bounce_btn.custom_minimum_size = Vector2(0, 32)
	bounce_btn.pressed.connect(func() -> void:
		_spring_switch.button_pressed = true
		morph_node.preset.spring_enabled = true
		morph_node.trigger_impulse(1.45)
	)
	spring_card.add_child(bounce_btn)

	_stiffness_slider = _add_slider_row(
		spring_card,
		"탄성 탱탱함 (강성)",
		30.0, 300.0, 5.0, 140.0, "%.0f", 1.0,
		"물리 탄성 스프링의 복원력(Stiffness)입니다.\n값이 높을수록 본래 위치로 빠르고 탱탱하게 튕겨 돌아옵니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.preset.spring_stiffness = v
	)
	_damping_slider = _add_slider_row(
		spring_card,
		"흔들림 멈춤 (감쇠)",
		2.0, 25.0, 0.5, 10.0, "%.1f", 1.0,
		"출렁임이 잦아드는 저항 계수(Damping)입니다.\n값이 작으면 젤리처럼 오래 출렁이고, 크면 빠르게 멈춥니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.preset.spring_damping = v
	)

	var delay_card := _create_card_panel("⏱️ 선택 영역 시차 (딜레이)", vbox)
	_delay_slider = _add_slider_row(
		delay_card,
		"움직임 타이밍 시차",
		-3.14, 3.14, 0.05, 0.0, "%.2f", 1.0,
		"선택된 영역이 전체 호흡 주기보다 앞서거나 늦게 움직이도록 시차(위상 차이)를 줍니다.\n부위마다 시차를 다르게 두면 훨씬 생동감 있는 유기적인 움직임이 연출됩니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.set_region_phase_offset(v)
	)
	_weight_slider = _add_slider_row(
		delay_card,
		"영역 무게감 (관성)",
		0.3, 2.5, 0.05, 1.0, "%.1f배", 1.0,
		"이 영역의 가상 무게/관성 배율입니다.\n무거울수록 탄성 충격 시 더 둔중하고 묵직하게 흔들립니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.set_region_spring_weight(v)
	)


func _build_tab_mask_and_layers() -> void:
	var vbox := _create_tab_scroll_vbox("🖌️마스크")

	var mask_card := _create_card_panel("🧽 브러시 마스킹 (보호지우개 / 변형브러시)", vbox)
	_mask_switch = CheckButton.new()
	_mask_switch.text = "자유형 브러시 마스크 켜기"
	_mask_switch.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	_mask_switch.toggled.connect(func(on: bool) -> void:
		if not _updating_ui:
			morph_node.preset.freeform_mask_enabled = on
			morph_node.show_mask_overlay = on
			morph_node._update_shader_uniforms()
			morph_node.queue_redraw()
	)
	mask_card.add_child(_mask_switch)

	# 1. 보호 지우개 + 옆에 전용 초기화 버튼
	var erase_row := HBoxContainer.new()
	erase_row.add_theme_constant_override("separation", 4)
	var erase_btn := _make_btn("🧽 보호 지우개", "움직이면 안 되는 영역을 칠해 고정합니다")
	erase_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	erase_btn.pressed.connect(func() -> void:
		_set_tool_mode(ToolMode.MASK_ERASE)
	)
	var erase_reset_btn := _make_btn("↺ 초기화", "보호 지우개로 칠한 고정 영역만 초기화합니다")
	erase_reset_btn.pressed.connect(_reset_protection_eraser)
	erase_row.add_child(erase_btn)
	erase_row.add_child(erase_reset_btn)
	mask_card.add_child(erase_row)

	# 2. 변형 브러시 + 옆에 전용 초기화 버튼
	var paint_row := HBoxContainer.new()
	paint_row.add_theme_constant_override("separation", 4)
	var paint_btn := _make_btn("🖌️ 변형 브러시", "움직임을 추가할 영역을 직접 칠합니다")
	paint_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	paint_btn.pressed.connect(func() -> void:
		_set_tool_mode(ToolMode.MASK_PAINT)
	)
	var paint_reset_btn := _make_btn("↺ 초기화", "변형 브러시로 칠한 변형 영역만 초기화합니다")
	paint_reset_btn.pressed.connect(_reset_deform_brush)
	paint_row.add_child(paint_btn)
	paint_row.add_child(paint_reset_btn)
	mask_card.add_child(paint_row)

	_brush_size_slider = _add_slider_row(
		mask_card,
		"브러시 크기 (화면 고정)",
		4.0, 200.0, 1.0, 30.0, "%d px", 1.0,
		"마우스로 칠하거나 지울 브러시의 원형 크기(화면 픽셀 단위)입니다.",
		func(v: float) -> void:
			morph_node.brush_screen_radius = v
			morph_node.queue_redraw()
	)

	# 카드 2: 5단계 3레이어 합성
	var layer_card := _create_card_panel("📑 3레이어 분리 합성 (5단계)", vbox)
	_layer_switch = CheckButton.new()
	_layer_switch.text = "3레이어 합성 모드 켜기"
	_layer_switch.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	_layer_switch.toggled.connect(func(on: bool) -> void:
		if not _updating_ui:
			morph_node.preset.layer_composite_enabled = on
			morph_node._update_shader_uniforms()
	)
	layer_card.add_child(_layer_switch)

	var thumbs_hbox := HBoxContainer.new()
	thumbs_hbox.add_theme_constant_override("separation", 4)
	layer_card.add_child(thumbs_hbox)

	_layer_thumb_body = _create_layer_slot_box(thumbs_hbox, "1.몸체", LayerLoadTarget.SINGLE_OR_BODY)
	_layer_thumb_part = _create_layer_slot_box(thumbs_hbox, "2.파츠", LayerLoadTarget.MORPH_PART)
	_layer_thumb_outline = _create_layer_slot_box(thumbs_hbox, "3.외곽선", LayerLoadTarget.PROTECTED_OUTLINE)

	_ghost_slider = _add_slider_row(
		layer_card,
		"밑그림 비침 지우기",
		0.0, 1.0, 0.05, 0.85, "%d%%", 100.0,
		"움직이는 파츠 뒤로 비치는 원본 몸체 밑그림을 지워주는 비율입니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.preset.ghost_suppress = v
				morph_node._update_shader_uniforms()
	)
	_outline_follow_slider = _add_slider_row(
		layer_card,
		"외곽선 따라가기",
		0.0, 1.0, 0.05, 0.65, "%d%%", 100.0,
		"분리된 외곽선 레이어가 파츠의 모핑 움직임을 함께 따라가는 비율입니다.",
		func(v: float) -> void:
			if not _updating_ui:
				morph_node.preset.outline_follow_ratio = v
				morph_node._update_shader_uniforms()
	)


func _create_layer_slot_box(parent: HBoxContainer, title: String, target: LayerLoadTarget) -> TextureRect:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)

	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.clip_text = true
	box.add_child(lbl)

	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(48, 48)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	box.add_child(preview)

	var btn := _make_btn("변경")
	btn.pressed.connect(func() -> void:
		_layer_load_target = target
		image_file_dialog.popup_centered_ratio(0.65)
	)
	box.add_child(btn)

	parent.add_child(box)
	return preview


func _build_tab_presets() -> void:
	var vbox := _create_tab_scroll_vbox("💾저장")

	var addon_card := _create_card_panel("📦 애드온용 파일 저장 / 열기 (.json)", vbox)
	var addon_desc := Label.new()
	addon_desc.text = "CharacterMorph2D 애드온에 넣어 바로 재사용하는 설정 파일입니다."
	addon_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	addon_desc.add_theme_font_size_override("font_size", 11)
	addon_desc.add_theme_color_override("font_color", Color(0.76, 0.82, 0.90))
	addon_card.add_child(addon_desc)

	var save_btn := _make_btn("💾 애드온 프리셋(.json) 저장하기...")
	save_btn.custom_minimum_size = Vector2(0, 32)
	save_btn.pressed.connect(_open_preset_save_dialog)
	addon_card.add_child(save_btn)

	var load_btn := _make_btn("📂 애드온 프리셋(.json) 불러오기...")
	load_btn.pressed.connect(_open_preset_load_dialog)
	addon_card.add_child(load_btn)

	var gif_card := _create_card_panel("🎞️ 움직이는 GIF 애니메이션 저장 (.gif)", vbox)
	var gif_desc := Label.new()
	gif_desc.text = "현재 캐릭터의 모핑 호흡 1주기를 무한 반복되는 움직이는 GIF로 저장합니다."
	gif_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gif_desc.add_theme_font_size_override("font_size", 11)
	gif_desc.add_theme_color_override("font_color", Color(0.76, 0.82, 0.90))
	gif_card.add_child(gif_desc)

	var export_gif_btn := _make_btn("🎞️ 움직이는 GIF(.gif)로 저장하기...")
	export_gif_btn.custom_minimum_size = Vector2(0, 32)
	export_gif_btn.pressed.connect(_open_gif_save_dialog)
	gif_card.add_child(export_gif_btn)

	var lib_card := _create_card_panel("📚 프리셋 보관함 (클릭 즉시 적용)", vbox)
	_preset_list = ItemList.new()
	_preset_list.custom_minimum_size = Vector2(0, 110)
	_preset_list.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	_preset_list.item_selected.connect(func(idx: int) -> void:
		if idx >= 0 and idx < _preset_files.size():
			var path: String = _preset_files[idx]
			if morph_node.load_preset_file(path) == OK:
				_sync_ui_from_morph_node()
				_set_hint("📂 프리셋 적용됨: %s" % path.get_file())
	)
	lib_card.add_child(_preset_list)

	var lib_btns := HBoxContainer.new()
	lib_btns.add_theme_constant_override("separation", 4)
	var refresh_btn := _make_btn("🔄 목록 새로고침")
	refresh_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refresh_btn.pressed.connect(_refresh_preset_file_list)
	var reset_btn := _make_btn("🔄 설정 초기화")
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(func() -> void:
		morph_node.reset_preset()
		_sync_ui_from_morph_node()
		_set_hint("모든 설정이 기본 상태로 초기화되었습니다.")
	)
	lib_btns.add_child(refresh_btn)
	lib_btns.add_child(reset_btn)
	lib_card.add_child(lib_btns)


# ============================================================================
# 2D 방향 & 세기 조이스틱 패드 렌더링 및 조작
# ============================================================================

func _on_joystick_pad_draw() -> void:
	if _joystick_pad == null or morph_node == null:
		return
	var sz: Vector2 = _joystick_pad.size
	var center: Vector2 = sz * 0.5
	var max_r: float = minf(sz.x, sz.y) * 0.44

	_joystick_pad.draw_circle(center, max_r, Color(0.11, 0.13, 0.17, 1.0))
	_joystick_pad.draw_arc(center, max_r, 0.0, TAU, 48, Color(0.32, 0.38, 0.48), 1.5, true)
	_joystick_pad.draw_arc(center, max_r * 0.5, 0.0, TAU, 36, Color(0.25, 0.30, 0.38, 0.6), 1.0, true)
	_joystick_pad.draw_line(Vector2(center.x - max_r, center.y), Vector2(center.x + max_r, center.y), Color(0.25, 0.30, 0.38), 1.0)
	_joystick_pad.draw_line(Vector2(center.x, center.y - max_r), Vector2(center.x, center.y + max_r), Color(0.25, 0.30, 0.38), 1.0)

	var reg: Dictionary = morph_node.get_active_region()
	var dir_v: Vector2 = reg.get("direction", Vector2(0.0, -1.0))
	var str_v: float = float(reg.get("strength", 0.018))
	var norm_len: float = clampf(str_v / 0.06, 0.0, 1.0)
	var knob_pos: Vector2 = center + dir_v.normalized() * (norm_len * max_r) if dir_v.length() > 0.001 else center

	_joystick_pad.draw_line(center, knob_pos, Color(1.0, 0.82, 0.2, 0.95), 2.2, true)
	_joystick_pad.draw_circle(knob_pos, 5.5, Color(1.0, 0.88, 0.25))
	_joystick_pad.draw_arc(knob_pos, 5.5, 0.0, TAU, 16, Color(0.1, 0.1, 0.15), 1.2, true)


func _on_joystick_pad_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_joystick_dragging = event.pressed
		if event.pressed:
			_update_joystick_from_local_pos(event.position)
		accept_event()
	elif event is InputEventMouseMotion and _joystick_dragging:
		_update_joystick_from_local_pos(event.position)
		accept_event()


func _update_joystick_from_local_pos(pos: Vector2) -> void:
	var sz: Vector2 = _joystick_pad.size
	var center: Vector2 = sz * 0.5
	var max_r: float = maxf(minf(sz.x, sz.y) * 0.44, 1.0)
	var delta: Vector2 = pos - center
	var ratio: float = clampf(delta.length() / max_r, 0.0, 1.0)
	var dir_norm: Vector2 = delta.normalized() if delta.length() > 1.0 else Vector2(0.0, -1.0)
	var new_strength: float = ratio * 0.06

	morph_node.set_region_direction(dir_norm)
	morph_node.set_region_strength(new_strength)
	_update_joystick_label()
	_joystick_pad.queue_redraw()


func _update_joystick_label() -> void:
	if _joystick_info_label == null:
		return
	var reg: Dictionary = morph_node.get_active_region()
	var d: Vector2 = reg.get("direction", Vector2(0.0, -1.0))
	var s: float = float(reg.get("strength", 0.018))
	_joystick_info_label.text = "방향: (%.1f, %.1f)\n세기: %d%%" % [d.x, d.y, int(round((s / 0.06) * 100.0))]


# ============================================================================
# 캔버스 마우스 조작 (기즈모 핸들 직접 드래그 / 브러시 / 줌 / 팬)
# ============================================================================

func _on_canvas_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_set_zoom(_zoom_level * 1.12)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_set_zoom(_zoom_level / 1.12)
			accept_event()
		elif mb.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_is_panning = mb.pressed
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_is_left_dragging = mb.pressed
			if mb.pressed:
				_on_canvas_left_down(mb.global_position)
			else:
				_on_canvas_left_up()
			accept_event()

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _is_panning:
			_pan_offset += mm.relative
			_apply_stage_transform()
			accept_event()
		elif _is_left_dragging:
			_on_canvas_left_drag(mm.global_position)
			accept_event()
		else:
			_on_canvas_hover(mm.global_position, mm.position)


func _on_canvas_hover(global_mouse_pos: Vector2, local_canvas_pos: Vector2) -> void:
	if morph_node.get_texture_size().x <= 0.0:
		cursor_badge.visible = false
		return

	var on_edit: bool = _is_on_edit_side(global_mouse_pos)
	var is_mask_tool: bool = _current_tool in [ToolMode.MASK_ERASE, ToolMode.MASK_PAINT]
	var raw_uv: Vector2 = morph_node.global_pos_to_uv(global_mouse_pos)
	var hover_uv: Vector2 = raw_uv.clamp(Vector2.ZERO, Vector2.ONE)
	morph_node.brush_preview_uv = raw_uv
	morph_node.brush_preview_active = is_mask_tool and on_edit
	morph_node.queue_redraw()

	if not on_edit:
		morph_node.hovered_gizmo_part = CharacterMorph2D.GizmoPart.NONE
		cursor_badge.visible = false
		canvas_bg.mouse_default_cursor_shape = Control.CURSOR_ARROW
		return

	if _current_tool != ToolMode.GIZMO_DIRECT or not morph_node.show_debug_gizmo:
		morph_node.hovered_gizmo_part = CharacterMorph2D.GizmoPart.NONE
		cursor_badge.visible = false
		canvas_bg.mouse_default_cursor_shape = Control.CURSOR_CROSS if is_mask_tool else Control.CURSOR_ARROW
		return

	var hit: Dictionary = morph_node.hit_test_gizmo(global_mouse_pos)
	var part: int = hit["part"]
	morph_node.hovered_gizmo_part = part

	match part:
		CharacterMorph2D.GizmoPart.HANDLE_ARROW_TIP:
			canvas_bg.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			_show_cursor_badge(local_canvas_pos, "↗ 방향·세기 조절")
		CharacterMorph2D.GizmoPart.HANDLE_RADIUS_X:
			canvas_bg.mouse_default_cursor_shape = Control.CURSOR_HSIZE
			_show_cursor_badge(local_canvas_pos, "↔ 가로 크기 조절")
		CharacterMorph2D.GizmoPart.HANDLE_RADIUS_Y:
			canvas_bg.mouse_default_cursor_shape = Control.CURSOR_VSIZE
			_show_cursor_badge(local_canvas_pos, "↕ 세로 크기 조절")
		CharacterMorph2D.GizmoPart.HANDLE_RADIUS_XY:
			canvas_bg.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
			_show_cursor_badge(local_canvas_pos, "⤡ 전체 크기 조절")
		CharacterMorph2D.GizmoPart.OTHER_REGION:
			canvas_bg.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			_show_cursor_badge(local_canvas_pos, "👆 영역 %d 선택" % (int(hit["region_index"]) + 1))
		_:
			canvas_bg.mouse_default_cursor_shape = Control.CURSOR_MOVE
			if morph_node.is_uv_in_bounds(hover_uv):
				_show_cursor_badge(local_canvas_pos, "✥ 위치 이동")
			else:
				cursor_badge.visible = false


func _show_cursor_badge(canvas_pos: Vector2, text_str: String) -> void:
	badge_label.text = text_str
	cursor_badge.visible = true
	var desired: Vector2 = canvas_pos + Vector2(14, -14)
	var max_pos: Vector2 = canvas_bg.size - cursor_badge.size - Vector2(6, 40)
	cursor_badge.position = desired.clamp(Vector2(6, 6), Vector2(maxf(6.0, max_pos.x), maxf(6.0, max_pos.y)))


## 좌우 비교 모드에서 마우스가 왼쪽 '편집 화면' 위에 있는지 판정합니다.
func _is_on_edit_side(global_mouse_pos: Vector2) -> bool:
	if not _side_by_side_compare:
		return true
	return global_mouse_pos.x <= stage_root.global_position.x


func _on_canvas_left_down(global_mouse_pos: Vector2) -> void:
	if morph_node.get_texture_size().x <= 0.0 or not _is_on_edit_side(global_mouse_pos):
		return
	var uv: Vector2 = morph_node.global_pos_to_uv(global_mouse_pos)
	var brush_r: float = morph_node.get_brush_radius_tex_px()
	match _current_tool:
		ToolMode.GIZMO_DIRECT:
			var hit: Dictionary = morph_node.hit_test_gizmo(global_mouse_pos)
			var part: int = hit["part"]
			if part == CharacterMorph2D.GizmoPart.OTHER_REGION:
				morph_node.selected_region_index = int(hit["region_index"])
				_dragged_gizmo_part = CharacterMorph2D.GizmoPart.CENTER_MOVE
				morph_node.active_gizmo_part = _dragged_gizmo_part
				_sync_ui_from_morph_node()
				return
			_dragged_gizmo_part = part
			morph_node.active_gizmo_part = part
			_apply_gizmo_drag(global_mouse_pos)
		ToolMode.MASK_ERASE:
			_ensure_mask_mode_on()
			morph_node.paint_protection_eraser_uv(uv, brush_r, 0.7)
		ToolMode.MASK_PAINT:
			_ensure_mask_mode_on()
			morph_node.paint_deform_brush_uv(uv, brush_r, 0.7)
		ToolMode.TOUCH_BOUNCE:
			morph_node.preset.spring_enabled = true
			_spring_switch.set_pressed_no_signal(true)
			morph_node.trigger_impulse(1.5)


func _on_canvas_left_drag(global_mouse_pos: Vector2) -> void:
	if morph_node.get_texture_size().x <= 0.0:
		return
	var uv: Vector2 = morph_node.global_pos_to_uv(global_mouse_pos)
	var brush_r: float = morph_node.get_brush_radius_tex_px()
	match _current_tool:
		ToolMode.GIZMO_DIRECT:
			if _dragged_gizmo_part != CharacterMorph2D.GizmoPart.NONE:
				_apply_gizmo_drag(global_mouse_pos)
		ToolMode.MASK_ERASE:
			morph_node.brush_preview_uv = uv
			morph_node.paint_protection_eraser_uv(uv, brush_r, 0.7)
		ToolMode.MASK_PAINT:
			morph_node.brush_preview_uv = uv
			morph_node.paint_deform_brush_uv(uv, brush_r, 0.7)


func _on_canvas_left_up() -> void:
	_dragged_gizmo_part = CharacterMorph2D.GizmoPart.NONE
	morph_node.active_gizmo_part = CharacterMorph2D.GizmoPart.NONE
	if _current_tool in [ToolMode.MASK_ERASE, ToolMode.MASK_PAINT]:
		morph_node.finalize_freeform_mask_stroke()


func _apply_gizmo_drag(global_mouse_pos: Vector2) -> void:
	var uv: Vector2 = morph_node.global_pos_to_uv(global_mouse_pos)
	var reg: Dictionary = morph_node.get_active_region()
	var c: Vector2 = reg.get("center", Vector2(0.5, 0.48))
	var r: Vector2 = reg.get("radius", Vector2(0.16, 0.14))

	match _dragged_gizmo_part:
		CharacterMorph2D.GizmoPart.CENTER_MOVE:
			morph_node.set_region_center(uv.clamp(Vector2.ZERO, Vector2.ONE))
		CharacterMorph2D.GizmoPart.HANDLE_RADIUS_X:
			var new_rx: float = clampf(absf(uv.x - c.x), 0.02, 0.60)
			morph_node.set_region_radius(Vector2(new_rx, r.y))
		CharacterMorph2D.GizmoPart.HANDLE_RADIUS_Y:
			var new_ry: float = clampf(absf(uv.y - c.y), 0.02, 0.60)
			morph_node.set_region_radius(Vector2(r.x, new_ry))
		CharacterMorph2D.GizmoPart.HANDLE_RADIUS_XY:
			var new_rx2: float = clampf(absf(uv.x - c.x) / 0.70710678, 0.02, 0.60)
			var new_ry2: float = clampf(absf(uv.y - c.y) / 0.70710678, 0.02, 0.60)
			morph_node.set_region_radius(Vector2(new_rx2, new_ry2))
		CharacterMorph2D.GizmoPart.HANDLE_ARROW_TIP:
			morph_node.drag_arrow_tip_to_global_pos(global_mouse_pos)
			_update_joystick_label()
			_joystick_pad.queue_redraw()


func _ensure_mask_mode_on() -> void:
	if not morph_node.preset.freeform_mask_enabled:
		morph_node.preset.freeform_mask_enabled = true
		_mask_switch.set_pressed_no_signal(true)
	morph_node.show_mask_overlay = true


# ============================================================================
# 이미지 로드, 애드온 프리셋(.json) 저장/열기, 움직이는 GIF(.gif) 저장
# ============================================================================

func _connect_signals() -> void:
	get_viewport().files_dropped.connect(_on_files_dropped)
	canvas_bg.gui_input.connect(_on_canvas_gui_input)
	canvas_bg.mouse_exited.connect(func() -> void:
		cursor_badge.visible = false
		morph_node.hovered_gizmo_part = CharacterMorph2D.GizmoPart.NONE
		morph_node.brush_preview_active = false
		morph_node.queue_redraw()
	)
	canvas_bg.draw.connect(_on_canvas_bg_draw)
	canvas_bg.resized.connect(_apply_stage_transform)

	morph_node.phase_updated.connect(func(p: float) -> void:
		if _timeline_slider != null and not _is_scrubbing_timeline and morph_node.auto_play:
			var norm_p: float = clampf(p / maxf(morph_node.preset.breathing_amplitude, 0.01), -1.0, 1.0)
			_timeline_slider.set_value_no_signal(norm_p)
			_timeline_val_label.text = "%+d%%" % int(round(norm_p * 100.0))
	)

	image_file_dialog.file_selected.connect(func(path: String) -> void:
		match _layer_load_target:
			LayerLoadTarget.SINGLE_OR_BODY:
				_load_character_image(path)
				_reset_view_transform()
			LayerLoadTarget.MORPH_PART:
				if morph_node.load_morph_part_from_file(path) == OK:
					morph_node.preset.layer_composite_enabled = true
					morph_node._update_shader_uniforms()
					_sync_ui_from_morph_node()
			LayerLoadTarget.PROTECTED_OUTLINE:
				if morph_node.load_protected_outline_from_file(path) == OK:
					morph_node.preset.layer_composite_enabled = true
					morph_node._update_shader_uniforms()
					_sync_ui_from_morph_node()
	)

	preset_save_dialog.file_selected.connect(func(path: String) -> void:
		var save_path: String = path if path.to_lower().ends_with(".json") else path + ".json"
		if morph_node.save_preset_file(save_path) == OK:
			_refresh_preset_file_list()
			_set_hint("💾 애드온 프리셋(.json) 저장 완료: %s" % save_path.get_file())
		else:
			_set_hint("⚠️ 프리셋 저장 실패: %s" % save_path.get_file())
	)

	preset_load_dialog.file_selected.connect(func(path: String) -> void:
		if morph_node.load_preset_file(path) == OK:
			_sync_ui_from_morph_node()
			_set_hint("📂 애드온 프리셋(.json) 불러오기 완료: %s" % path.get_file())
		else:
			_set_hint("⚠️ 프리셋 불러오기 실패: %s" % path.get_file())
	)

	gif_save_dialog.file_selected.connect(_on_gif_save_file_selected)


func _on_gif_save_file_selected(path: String) -> void:
	if _is_exporting_gif:
		return
	var save_path: String = path if path.to_lower().ends_with(".gif") else path + ".gif"
	_is_exporting_gif = true
	_set_hint("🎞️ 원본급 고화질 움직이는 GIF 생성 준비 중...")

	var err: Error = await morph_node.export_animated_gif(
		save_path,
		20,
		1024,
		func(cur_f: int, total_f: int, is_encoding: bool = false) -> void:
			if is_encoding:
				_set_hint("🎨 고화질 255색 팔레트 분석 및 GIF 인코딩 중... (%d / %d)" % [cur_f, total_f])
			else:
				_set_hint("🎞️ 고화질 프레임 캡처 중... (%d / %d)" % [cur_f, total_f])
	)

	_is_exporting_gif = false
	if err == OK:
		_set_hint("✅ 고화질 움직이는 GIF 저장 완료: %s" % save_path)
	else:
		_set_hint("⚠️ GIF 저장 실패 (오류 코드: %d)" % err)


func _load_character_image(path: String) -> void:
	if morph_node.load_image_from_file(path) == OK:
		_source_basename = path.get_file().get_basename()
		original_sprite.texture = morph_node.character_texture
		_update_compare_layout()
		_update_layer_thumbnails()
		canvas_bg.queue_redraw()

		# 그림 파일과 동일한 이름의 프리셋(.json)이 있으면 함께 자동 로드
		var companion_loaded: bool = false
		var candidate_paths: Array[String] = [
			path.get_basename() + ".json",
			"res://presets/" + _source_basename + ".json"
		]
		for c_path in candidate_paths:
			if FileAccess.file_exists(c_path):
				if morph_node.load_preset_file(c_path) == OK:
					companion_loaded = true
					_sync_ui_from_morph_node()
					_set_hint("🖼️ 이미지 및 연계 프리셋 자동 로드 완료: %s (+ %s)" % [path.get_file(), c_path.get_file()])
					break

		if not companion_loaded:
			_set_hint("🖼️ 이미지 열기 완료: %s (%dx%d)" % [
				path.get_file(),
				int(morph_node.get_texture_size().x),
				int(morph_node.get_texture_size().y)
			])
	else:
		_set_hint("⚠️ 이미지 열기 실패: %s (지원되지 않거나 손상된 파일입니다)" % path.get_file())


func _update_layer_thumbnails() -> void:
	if _layer_thumb_body != null:
		_layer_thumb_body.texture = morph_node.character_texture
	if _layer_thumb_part != null:
		_layer_thumb_part.texture = morph_node.morph_part_texture
	if _layer_thumb_outline != null:
		_layer_thumb_outline.texture = morph_node.protected_outline_texture


func _on_files_dropped(files: PackedStringArray) -> void:
	if files.is_empty():
		return
	var path: String = files[0]
	var ext: String = path.get_extension().to_lower()
	if ext in ["png", "jpg", "jpeg", "webp", "svg", "bmp"]:
		_load_character_image(path)
		_reset_view_transform()
		_set_hint("🖼️ 새 캐릭터 이미지 적용됨: %s" % path.get_file())
	elif ext == "json":
		if morph_node.load_preset_file(path) == OK:
			_sync_ui_from_morph_node()
			_set_hint("📂 프리셋 적용됨: %s" % path.get_file())


func _refresh_preset_file_list() -> void:
	if _preset_list == null:
		return
	_preset_list.clear()
	_preset_files.clear()

	var dir := DirAccess.open("res://presets")
	if dir != null:
		dir.list_dir_begin()
		var fname: String = dir.get_next()
		while not fname.is_empty():
			if not dir.current_is_dir() and fname.to_lower().ends_with(".json"):
				var full_path: String = "res://presets/" + fname
				_preset_files.append(full_path)
				_preset_list.add_item("📄 " + fname.get_basename())
			fname = dir.get_next()
		dir.list_dir_end()


# ============================================================================
# 부위별 템플릿 및 UI 위젯 빌더 헬퍼
# ============================================================================



func _add_small_dir_btn(parent: GridContainer, label_str: String, dir_vec: Vector2) -> void:
	var btn := _make_btn(label_str)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.clip_text = true
	btn.pressed.connect(func() -> void:
		morph_node.set_region_direction(dir_vec)
		if float(morph_node.get_active_region().get("strength", 0.0)) < 0.005:
			morph_node.set_region_strength(0.018)
		_update_joystick_label()
		_joystick_pad.queue_redraw()
	)
	parent.add_child(btn)


func _add_slider_row(
	parent: Control,
	label_text: String,
	min_val: float,
	max_val: float,
	step_val: float,
	default_val: float,
	fmt: String,
	display_mult: float,
	tooltip_str: String,
	callback: Callable
) -> Dictionary:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 1)
	if not tooltip_str.is_empty():
		vbox.tooltip_text = tooltip_str

	var top_row := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = label_text
	name_lbl.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.clip_text = true
	name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	if not tooltip_str.is_empty():
		name_lbl.tooltip_text = tooltip_str

	var val_lbl := Label.new()
	val_lbl.add_theme_font_size_override("font_size", UI_FONT_SIZE)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.add_theme_color_override("font_color", Color(0.75, 0.90, 1.0))
	val_lbl.text = _format_slider_val(default_val, fmt, display_mult)
	val_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	if not tooltip_str.is_empty():
		val_lbl.tooltip_text = tooltip_str

	top_row.add_child(name_lbl)
	top_row.add_child(val_lbl)
	vbox.add_child(top_row)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step_val
	slider.value = default_val
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not tooltip_str.is_empty():
		slider.tooltip_text = tooltip_str

	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = _format_slider_val(v, fmt, display_mult)
		callback.call(v)
	)

	vbox.add_child(slider)
	parent.add_child(vbox)

	return {"slider": slider, "value_label": val_lbl, "format": fmt, "mult": display_mult}


func _format_slider_val(val: float, fmt: String, mult: float) -> String:
	if fmt.find("%d") != -1 or fmt.find("%+d") != -1:
		return fmt % int(round(val * mult))
	return fmt % (val * mult)


func _set_slider_dict_value(slider_dict: Dictionary, val: float) -> void:
	if not slider_dict.has("slider"):
		return
	var s: HSlider = slider_dict["slider"]
	var l: Label = slider_dict["value_label"]
	s.set_value_no_signal(val)
	l.text = _format_slider_val(val, slider_dict["format"], slider_dict["mult"])


func _refresh_region_item_list() -> void:
	if _region_list == null:
		return
	_region_list.clear()
	for i in range(morph_node.preset.get_region_count()):
		var reg: Dictionary = morph_node.preset.get_region(i)
		var is_on: bool = bool(reg.get("enabled", true))
		var prefix: String = "🟢 " if is_on else "⚪ "
		_region_list.add_item("%s%d. %s" % [prefix, i + 1, String(reg.get("name", "영역"))])
	if morph_node.selected_region_index >= 0 and morph_node.selected_region_index < _region_list.item_count:
		_region_list.select(morph_node.selected_region_index)
		_region_list.ensure_current_is_visible()


func _sync_ui_from_morph_node() -> void:
	if morph_node == null or morph_node.preset == null:
		return
	_updating_ui = true

	_refresh_region_item_list()

	var reg: Dictionary = morph_node.get_active_region()
	_region_enable_check.set_pressed_no_signal(bool(reg.get("enabled", true)))
	_set_slider_dict_value(_scale_slider, float(reg.get("scale_strength", 0.04)))
	_set_slider_dict_value(_falloff_slider, float(reg.get("falloff", 1.5)))
	_set_slider_dict_value(_outline_protect_slider, morph_node.preset.outline_protect)

	_set_slider_dict_value(_speed_slider, morph_node.preset.breathing_speed)
	_set_slider_dict_value(_amplitude_slider, morph_node.preset.breathing_amplitude)
	_spring_switch.set_pressed_no_signal(morph_node.preset.spring_enabled)
	_set_slider_dict_value(_stiffness_slider, morph_node.preset.spring_stiffness)
	_set_slider_dict_value(_damping_slider, morph_node.preset.spring_damping)
	_set_slider_dict_value(_delay_slider, float(reg.get("phase_offset", 0.0)))
	_set_slider_dict_value(_weight_slider, float(reg.get("spring_weight", 1.0)))

	_mask_switch.set_pressed_no_signal(morph_node.preset.freeform_mask_enabled)
	_layer_switch.set_pressed_no_signal(morph_node.preset.layer_composite_enabled)
	_set_slider_dict_value(_ghost_slider, morph_node.preset.ghost_suppress)
	_set_slider_dict_value(_outline_follow_slider, morph_node.preset.outline_follow_ratio)

	_update_play_button_label()
	_update_joystick_label()
	_update_layer_thumbnails()
	if _joystick_pad != null:
		_joystick_pad.queue_redraw()

	_updating_ui = false


# ============================================================================
# 뷰포트 줌 / 팬 / 배경 그리기
# ============================================================================

func _set_zoom(new_zoom: float) -> void:
	_zoom_level = clampf(new_zoom, 0.2, 5.0)
	if _zoom_label != null:
		_zoom_label.text = "%d%%" % int(round(_zoom_level * 100.0))
	_apply_stage_transform()
	morph_node.queue_redraw()


func _reset_view_transform() -> void:
	var view_size: Vector2 = canvas_bg.size
	var tex_size: Vector2 = morph_node.get_texture_size()
	if view_size.x > 10.0 and view_size.y > 10.0 and tex_size.y > 10.0:
		var fit_scale: float = minf(
			(view_size.x * 0.78) / maxf(tex_size.x * (2.1 if _side_by_side_compare else 1.0), 1.0),
			(view_size.y * 0.78) / maxf(tex_size.y, 1.0)
		)
		_zoom_level = clampf(fit_scale, 0.25, 2.0)
	else:
		_zoom_level = 0.8
	_pan_offset = Vector2.ZERO
	_set_zoom(_zoom_level)
	_update_compare_layout()


func _apply_stage_transform() -> void:
	if stage_root == null or canvas_bg == null:
		return
	stage_root.position = canvas_bg.size * 0.5 + _pan_offset
	stage_root.scale = Vector2(_zoom_level, _zoom_level)
	canvas_bg.queue_redraw()


func _update_compare_layout() -> void:
	if original_sprite == null or morph_node == null or _result_sprite == null:
		return
	var tex_size: Vector2 = morph_node.get_texture_size()
	_result_sprite.texture = morph_node.character_texture
	original_sprite.texture = morph_node.character_texture
	if _side_by_side_compare and tex_size.x > 0.0:
		var gap: float = tex_size.x * 0.54
		morph_node.position = Vector2(-gap, 0.0)
		_result_sprite.position = Vector2(gap, 0.0)
		original_sprite.position = Vector2(gap, 0.0)
		_result_sprite.visible = not _show_original_right
		original_sprite.visible = _show_original_right
		compare_labels.visible = true
	else:
		morph_node.position = Vector2.ZERO
		_result_sprite.visible = false
		original_sprite.visible = false
		compare_labels.visible = false
	morph_node.queue_redraw()


func _on_canvas_bg_draw() -> void:
	var rect_size: Vector2 = canvas_bg.size
	if rect_size.x <= 0.0 or rect_size.y <= 0.0:
		return

	match _bg_mode:
		BgMode.SOLID_DARK:
			canvas_bg.draw_rect(Rect2(Vector2.ZERO, rect_size), Color(0.11, 0.12, 0.15))
		BgMode.SOLID_LIGHT:
			canvas_bg.draw_rect(Rect2(Vector2.ZERO, rect_size), Color(0.88, 0.89, 0.91))
		BgMode.CHROMA_GREEN:
			canvas_bg.draw_rect(Rect2(Vector2.ZERO, rect_size), Color(0.0, 0.68, 0.18))
		BgMode.CHECKERBOARD_DARK, BgMode.CHECKERBOARD_LIGHT:
			var is_dark: bool = (_bg_mode == BgMode.CHECKERBOARD_DARK)
			var col_a: Color = Color(0.14, 0.15, 0.18) if is_dark else Color(0.82, 0.83, 0.85)
			var col_b: Color = Color(0.20, 0.21, 0.25) if is_dark else Color(0.93, 0.94, 0.96)
			canvas_bg.draw_rect(Rect2(Vector2.ZERO, rect_size), col_a)
			var tile: float = 24.0
			var cols: int = int(ceil(rect_size.x / tile))
			var rows: int = int(ceil(rect_size.y / tile))
			for y in range(rows):
				for x in range(cols):
					if (x + y) % 2 == 1:
						canvas_bg.draw_rect(
							Rect2(Vector2(x * tile, y * tile), Vector2(tile, tile)),
							col_b
						)

	if morph_node != null and morph_node.get_texture_size().x <= 0.0:
		var font: Font = ThemeDB.fallback_font
		if font != null:
			var msg: String = "📂 상단 [그림열기] 버튼을 누르거나 이미지를 창으로 드래그하세요"
			var fsize: int = 15
			var tsize: Vector2 = font.get_string_size(msg, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize)
			var box_rect := Rect2((rect_size - tsize) * 0.5 - Vector2(18, 14), tsize + Vector2(36, 28))
			canvas_bg.draw_rect(box_rect, Color(0.08, 0.10, 0.14, 0.85), true)
			canvas_bg.draw_rect(box_rect, Color(0.35, 0.75, 1.0, 0.55), false, 1.5)
			canvas_bg.draw_string(
				font,
				Vector2((rect_size.x - tsize.x) * 0.5, rect_size.y * 0.5 + 5.0),
				msg,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				fsize,
				Color(0.88, 0.94, 1.0, 0.95)
			)


func _set_hint(msg: String) -> void:
	if hint_label != null:
		hint_label.text = msg
