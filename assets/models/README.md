# 美术资产放这里（有就用、没有回退程序化模型）

详细命名与染色约定见 docs/美术资产接入.md。

- assets/models/units/<unit_id>.glb     —— 单位，例：feifei.glb / scout.glb / rover.glb
- assets/models/buildings/<def_id>.glb  —— 建筑，例：miner.glb / factory.glb / turret.glb

支持 .glb 与 .gltf（.gltf 的 .bin/贴图放同目录）。
文件按名字自动匹配 id，放好即生效，不用改代码；删掉文件就自动回退程序化模型。
