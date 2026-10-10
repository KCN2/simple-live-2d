# CharacterMorph2D 모듈

2D 캐릭터 PNG 한 장의 특정 국소 영역(호흡, 바스트 모핑, 머리카락·의상 흔들림 등)에 부드러운 UV 변형 애니메이션을 적용하는 독립형 Godot 4 모듈입니다.

---

## 1. 다른 Godot 프로젝트에서 재사용하는 방법

1. `addons/character_morph/` 폴더를 대상 Godot 프로젝트의 `res://addons/character_morph/` 위치로 복사합니다.
2. 게임 씬에 `res://addons/character_morph/character_morph_2d.tscn`을 인스턴스로 배치하거나, 코드에서 `CharacterMorph2D.new()`를 생성합니다.
3. 인스펙터(Inspector) 또는 스크립트에서 캐릭터 PNG 텍스처(`character_texture`)와 테스트 도구에서 저장한 JSON 프리셋(`preset_json_path`)을 지정하면 즉시 작동합니다.

---

## 2. 스크립트 사용 예시

### 기본 사용 (프리셋 파일과 이미지 지정)

```gdscript
extends Node2D

@onready var morph_character: CharacterMorph2D = $CharacterMorph2D

func _ready() -> void:
	# 1. 캐릭터 이미지 설정 (res:// 리소스 또는 외부 PNG 경로)
	morph_character.load_image_from_file("res://assets/heroine.png")

	# 2. 테스트 도구에서 저장한 JSON 프리셋 불러오기
	morph_character.load_preset_file("res://presets/default_breathing.json")

	# 3. 실게임에서는 기즈모 숨김 및 자동 재생 활성화
	morph_character.show_debug_gizmo = false
	morph_character.play()
```

### 런타임에 탄성 자극(터치/이동 반동) 주기

```gdscript
# 캐릭터 클릭 또는 점프 착지 시 탄성 흔들림 발생
morph_character.trigger_impulse(1.5)
```

---

## 3. 구성 파일

| 파일명 | 역할 |
| :--- | :--- |
| `character_morph_2d.tscn` | `CharacterMorph2D` 루트 노드와 셰이더가 적용된 `Sprite2D`를 포함한 재사용 씬 |
| `character_morph_2d.gd` | 애니메이션 루프, 프리셋 연동, 좌표 변환, 기즈모 렌더링을 담당하는 핵심 클래스 |
| `local_morph.gdshader` | 타원형 국소 영역 C1 연속 감쇠 변형, 보호지우개/변형브러시 마스크 및 외곽선 보호 셰이더 |
| `morph_preset.gd` | 해상도 독립적 정규화 UV(`0.0 ~ 1.0`) 기반 설정 데이터 및 JSON 저장/불러오기 클래스 |
| `gif_exporter.gd` | 외부 플러그인 없이 모핑 애니메이션을 움직이는 GIF89a(`.gif`)로 내보내는 인코더 |

