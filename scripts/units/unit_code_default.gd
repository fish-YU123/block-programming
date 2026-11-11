extends RefCounted
## 预设单位的玩家代码入口（对外仍然用 DefaultCode.XXX）
##
## 每个单位支持两个固定函数：
##   def start():  开局（或点「应用」）时跑一次
##   def loop():   之后一直反复跑
## 两个都不写的话，整段代码会从头循环执行（老写法仍然有效）。
##
## 具体内容拆到 scripts/units/presets/ 下，一个单位一个文件。

const FlyerPreset = preload("res://scripts/units/presets/flyer_preset.gd")
const RedPreset = preload("res://scripts/units/presets/red_preset.gd")
const FighterPreset = preload("res://scripts/units/presets/fighter_preset.gd")
const CommanderPreset = preload("res://scripts/units/presets/commander_preset.gd")
const BuilderPreset = preload("res://scripts/units/presets/builder_preset.gd")
const ScoutPreset = preload("res://scripts/units/presets/scout_preset.gd")
const CargoPreset = preload("res://scripts/units/presets/cargo_preset.gd")
const GunshipPreset = preload("res://scripts/units/presets/gunship_preset.gd")
const KamikazePreset = preload("res://scripts/units/presets/kamikaze_preset.gd")
const MinelayerPreset = preload("res://scripts/units/presets/minelayer_preset.gd")
const RepairPreset = preload("res://scripts/units/presets/repair_preset.gd")
const JammerPreset = preload("res://scripts/units/presets/jammer_preset.gd")
const BurrowerPreset = preload("res://scripts/units/presets/burrower_preset.gd")
const CarrierPreset = preload("res://scripts/units/presets/carrier_preset.gd")
const RoverPreset = preload("res://scripts/units/presets/rover_preset.gd")

const FLYER_SOURCE := FlyerPreset.SOURCE
const RED_SOURCE := RedPreset.SOURCE
const FIGHTER_SOURCE := FighterPreset.SOURCE
const COMMANDER_SOURCE := CommanderPreset.SOURCE
const BUILDER_SOURCE := BuilderPreset.SOURCE
const SCOUT_SOURCE := ScoutPreset.SOURCE
const CARGO_SOURCE := CargoPreset.SOURCE
const GUNSHIP_SOURCE := GunshipPreset.SOURCE
const KAMIKAZE_SOURCE := KamikazePreset.SOURCE
const MINELAYER_SOURCE := MinelayerPreset.SOURCE
const REPAIR_SOURCE := RepairPreset.SOURCE
const JAMMER_SOURCE := JammerPreset.SOURCE
const BURROWER_SOURCE := BurrowerPreset.SOURCE
const CARRIER_SOURCE := CarrierPreset.SOURCE
const ROVER_SOURCE := RoverPreset.SOURCE
