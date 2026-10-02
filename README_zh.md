# odin-skelform

纯 Odin 编写的 **SkelForm** 2D 骨骼动画运行时，附带一个 raylib 示例，可加载并播放导出的 `.skf`
骨骼资源。

对应 **SkelForm 0.8.0** —— 见[版本对应](#版本对应)。

[English](README.md) · **中文**

![示例运行画面，加载 example/skellington.skf](docs/example.png)

## 目录结构

仓库根目录**就是**库本身（`package skelform`），示例放在它旁边。以 `skf` 导入后，在你自己的渲染
循环里调用即可。

运行时逐行移植自 Rust 的通用运行时
[`rusty_skelform`](https://github.com/Retropaint/rusty_skelform) v0.8.0，并以 Go 运行时
[`skelform_go`](https://github.com/Retropaint/skelform_go) 作为行为校准。类型、字段顺序、求值顺序
完全一致，因此 `skelform.odin` 可以直接和 Rust 的 `src/lib.rs` 对照 diff。

| 路径 | 内容 |
| --- | --- |
| `skelform.odin` | 数据模型 + 运行时：动画采样、父子继承、反向动力学（IK）、物理、网格形变 |
| `loader.odin` | `.skf` 加载：自带的小型 ZIP 读取器（stored + deflate）与 `armature.json` 映射 |
| `example/main.odin` | raylib 演示：窗口、输入、动画循环 |
| `example/render.odin` | raylib 适配层：屏幕空间构建与贴图绘制 |
| `example/*.skf` | 演示骨骼资源（`skellington`、`skellina`） |
| `docs/` | 本说明文档使用的运行截图 |

## 版本对应

| 组件 | 本移植对应的版本 |
| --- | --- |
| SkelForm 编辑器（`.skf` 的导出方） | **0.8.0** |
| `rusty_skelform`（本移植所依据的运行时） | **0.8.0** |
| `rusty_skelform_macroquad`（`example/render.odin` 对照的适配层） | **0.8.0** |
| `skelform_go`（行为交叉核对） | 最新 |

`.skf` 自带格式版本：`armature.json` 中的 `version` 字符串，编辑器写入的是它自己的
`CARGO_PKG_VERSION`。**`rusty_skelform` 与本移植都不读取该字段**：解析过程与版本无关。
`example/` 中附带的两个骨骼资源由 SkelForm **0.7.0** 导出，可正常加载。

实际含义：

* `loader.odin` 手写映射 `armature.json`，缺失的键套用与 serde 一致的默认值，因此含有*额外*键的
  文件（来自更新的编辑器）会丢弃那些键并正常加载，而不会失败。它不会因为版本不符而拒绝文件 ——
  需要严格校验时请自行检查 `version`。
* **0.6** 之前的导出**不支持**。这类文件由编辑器在打开时自行升级（`src/backwards_compat.rs` 覆盖
  0.2 → 0.5），运行时只会见到当前版本的 JSON。旧文件请先在编辑器里重新导出，不要直接喂给运行时。
* 已对照编辑器源码 `68b66d2`（`Cargo.toml` 版本 `0.8.0`）验证。

## 环境要求

* Odin `dev-2026-09-nightly` 或更新版本（开发环境为 `dev-2026-09-nightly:a2fb372`）。
* 运行时本身不依赖 C，也没有任何第三方 Odin 依赖，只用 `core:` 包（`core:encoding/json`、
  `core:compress/zlib`、`core:mem` 等）。
* 示例额外需要 `vendor:raylib`，它随 Odin 编译器一起分发。

## 在项目中使用运行时

每帧四次调用，下面就是 `example/main.odin` 做的事。

```odin
import skf "path/to/odin-skelform"

// 1) 加载 SkelForm 编辑器导出的归档。只做一次，不要每帧加载。
archive, ok := skf.skf_load("hero.skf")
if !ok {
	return
}
defer skf.skf_destroy(&archive)

armature := &archive.armature

// 2) 把动画采样到骨骼上。三个切片里每个播放中的动画各占一个元素 --
//    运行时支持同时播放多个动画，示例只播一个。
animations := []skf.Animation{armature.animations[0]}
frames := []u32{skf.time_frame(elapsed_seconds, &animations[0], false, true)}
smooth_frames := []u32{20}
skf.animate(
	&armature.bones,
	&armature.inverse_kinematics,
	&armature.visuals,
	animations,
	frames,
	smooth_frames,
)

// 3) 构建骨架：得到骨骼的最终变换和形变后的网格。
skf.construct(armature)

// 4) 用你自己的渲染器绘制 `armature.constructed_bones` 和 `armature.visuals`。
```

第 4 步是库刻意不提供的一部分。`example/render.odin` 是 raylib 版本：它把骨骼空间翻转成 raylib
Y 轴朝下的屏幕空间，并把每个骨骼（无论是网格还是贴图四边形）都作为 rlgl 三角形发出。可以复制到
工程里改，也可以直接调用（见[运行示例](#运行示例)）。

绘制前需要知道两件事：

* 图集 PNG 以原始字节返回在 `archive.atlases` 中，顺序与 `armature.atlases` 一致；
  `Texture.atlas_idx` 决定某个骨骼取样哪张图集。上传成纹理要自己做。
* 贴图是按 **style**（服装）查找的。传给绘制环节的只能是在用的 style；某个 style 里查不到该贴图、
  或者只有一张 1×1 的贴图，就意味着这个部位在该服装下被隐藏。`skf.active_styles` 返回骨骼自己的
  选用结果。

## 运行示例

```sh
odin run example                        # 开窗，默认加载 example/skellington.skf
odin run example -- example/skellina.skf
```

也可以先编译成 exe 再运行 —— 它同时会在自身所在目录下逐级查找骨骼资源，所以 `build/example.exe`
在任意工作目录都能跑：

```sh
odin build example -out:build/example.exe
./build/example.exe
```

窗口尺寸 900×700，左上角 HUD 会实时列出按键。

![同一个示例加载 example/skellina.skf](docs/example_skellina.png)

| 按键 | 作用 |
| --- | --- |
| `A` / `D` | 向左 / 向右走。朝向跟随最后一次按下的水平键。 |
| `W` / `S` | 上移 / 下移 |
| `SPACE` | 切换到下一个动画 |
| `1` … `9` | 只穿第 N 套服装（style） |
| `0` | 回到骨骼自身选用的服装集合 |
| `B` | 切换骨骼线框：每根骨骼到父骨骼一条线，每个关节一个点，被隐藏的骨骼显示为红色 |
| `F12` | 截图 —— 仅在同时给出 `-screenshot file.png` 时生效 |

按下 `B` 可以打开骨骼线框，这是查看 `construct` 究竟算出了什么的最快方式 —— 下面两张分别是
`Stand` 与 `Run` 动画：

![站立动画，开启骨骼线框](docs/bones_stand.png)

![奔跑动画，开启骨骼线框](docs/bones_run.png)

按键能进入的每个模式，都可以从命令行直接启动：

| 参数 | 含义 |
| --- | --- |
| `<file>.skf` | 要加载的骨骼资源（位置参数，默认 `example/skellington.skf`） |
| `-frames N` | 跑 N 帧后退出 —— 让示例可被脚本调用 |
| `-hidden` | 以隐藏窗口创建（不会闪一下桌面），与 `-frames` 搭配 |
| `-stats` | 读取最后一帧，打印与清屏色不同的像素数量 |
| `-static` | 把动画冻结在第 0 帧 |
| `-bones` | 启动时即打开骨骼线框 |
| `-left` | 初始朝向改为向左（默认向右） |
| `-screenshot file.png` | `F12` 的写出路径；不给这个参数就不会有任何截图输出 |

```sh
odin run example -- -frames 120 -hidden -stats          # 无头渲染冒烟测试
odin run example -- -static -bones                      # 观察骨架
odin run example -- -left                               # 检查镜像朝向
```

`-stats` 让示例变成一个不需要窗口的渲染自检：

```text
skelform: loaded example/skellington.skf: 61 bones, 4 animations, 21 visuals, 5 IK families, 1 atlases, 4 styles
skelform: 59561 / 630000 pixels differ from the clear color (9.5%)
skelform: ok, drew 30 frames, 61 constructed bones
```

如果加载成功但什么都没画出来，会报 `0 / 630000 ... (0.0%)`，所以「计数非零」就是通过条件。

## API 概览

类型与 Rust 运行时一一对应：`Vec2`、`Tint`、`Vertex`、`BoneBindVert`、`BoneBind`、`Keyframe`、
`Animation`、`InverseKinematics`、`Visuals`、`Physics`、`Bone`、`Style`、`Texture`、`TexAtlas`、
`Armature`，以及 `HandlePreset` / `AnimElement` / `JointConstraint` / `InverseKinematicsMode`
枚举。

运行时：

| 过程 | 用途 |
| --- | --- |
| `animate` | 把动画采样进 `bones` / `visuals` / `inverse_kinematics`，并让未被采样的元素缓动回初始值 |
| `construct` | 依次执行 `reset_inheritance` → `inheritance` → IK → 物理 → `construct_verts` → `propagate_hidden` |
| `inverse_kinematics` | FABRIK 与圆弧解算器；返回逐骨骼旋转（返回的 map 由调用方释放） |
| `inheritance`、`reset_inheritance` | 子对父的变换继承 |
| `construct_verts`、`inherit_vert` | 基于骨骼绑定的网格形变（权重绑定与路径绑定） |
| `format_frame`、`time_frame` | 循环/往返、由秒数求帧号等辅助函数 |
| `get_bone_texture`、`active_styles` | style / 贴图查找 |
| `rotate_vec2`、`shortest_angle_delta`、`is_facing_left`、`vec2_magnitude`、`vec2_normalize` 等 | 数学辅助函数 |
| `armature_destroy` | 释放一个 armature 里的所有动态数组 |

加载：

| 过程 | 用途 |
| --- | --- |
| `skf_load(path)`、`skf_load_from_memory(data)` | 把 `.skf` 归档解析成 `SKF { armature, atlases }` |
| `skf_destroy(skf)` | 释放 armature、图集字节以及承载字符串的存储 |
| `armature_parse_json(data)` | 只解析 `armature.json`（返回持有字符串的 `json.Value`） |
| `skf_find_entry(data, name)` | 从内存中的归档里复制出单个条目 |

### 命名约定

过程名保留 Rust 的 `snake_case`、类型名保留 `PascalCase`，而没有采用 Odin「一律 PascalCase」的
惯例，这样每个名字都能与 `rusty_skelform` 一一对应，移植 diff 也保持可读。Rust 中私有的 `fn`
在这里写作 `@(private = "package")`；公开接口上唯一的增补是 `vec2_*` 系列（Rust 用运算符表达）
以及 `skelform.odin` 中 "Lookup helpers" 一节里的查找函数。

## 所有权与内存

`Armature` 的字符串是**借用**的（骨骼 / 贴图 / style 名、关键帧的 `element` 与 `value_str`、IK 的
约束与模式），它只拥有自己的动态数组：

* `armature_destroy` 只释放数组，因此对手工构造、使用字符串字面量的 armature 也是安全的。
* `skf_destroy` 释放 `SKF` 拥有的一切，包括支撑那些字符串的 JSON 解析树、图集 PNG 字节以及
  armature 的数组。只要还在用它的 armature 绘制，就必须让 `SKF` 保持存活。

运行时过程确实会分配内存。每次调用中，`animate` 构造一个元素重置 map，`propagate_hidden` 构造一个
隐藏标记缓冲，`inverse_kinematics` 为每个 IK 家族构造一个索引数组，外加它返回的 `map[u32]f32`
（调用方必须 `delete`）。`construct` 本身只增长由 armature 持有的 `constructed_bones`，第一帧之后
就不再增长。这些都来自环境的 `context.allocator`，所以在帧周围给 context 装一个 `mem.Scope`
分配器，就能把这些流量挡在堆之外。

## `.skf` 格式

`.skf` 文件就是一个普通的 ZIP 归档：

```text
armature.json   运行时数据（映射到 `Armature`）
atlas0.png ...  `armature.atlases` 每个条目对应一张 PNG
editor.json, thumbnail.png, readme.md   编辑器专用的额外文件（忽略）
```

`loader.odin` 自己实现了 ZIP 中央目录读取（stored 与 deflate 条目，通过 `core:compress/zlib`
处理），并手写 JSON 映射，因此 serde 的兼容默认值被精确复现：缺失的 tint 为 `(1, 1, 1, 1)`，缺失的
标量为 `0`，缺失的向量为 `(0, 0)`，`Keyframe.handle_preset` 默认为 `.Linear`，以此类推。较早的
编辑器版本把 IK 家族 id 写成 `"id"`；`"id"` 与 `"family_id"` 都会被接受。

需要注意 `Style.active` **不在** `armature.json` 里 —— 编辑器把它存在 `editor.json`。因此导出的
`.skf` 中没有任何 style 被标记为在用，`active_styles` 会退回到名为 `"Default"` 的 style，若也没有
则取最后一个。

## 移植说明（以 `skelform_go` 校准）

| 位置 | `rusty_skelform` 0.8.0 | `skelform_go` | 本移植 |
| --- | --- | --- | --- |
| 物理缩放阻尼 | 判断 `pos_ratio`（复制粘贴 bug） | 判断 `scale_ratio` | `scale_ratio` |
| `animate` 的元素跟踪 | 即使关键帧已超过当前帧也会登记（登记发生在提前 `break` 之前） | 只登记真正被应用的帧 | 采用 Go 行为 |
| 贴图重置 | 应用时判断 `"Tex"`，重置时却判断 `"Texture"`，导致动画贴图总被重置回去 | 未实现 | 每个元素一个标记，`"Tex"` 被正确跟踪 |
| `point_bones` 的末端骨骼 | 跳过末端骨骼，保留其原始旋转 | 把末端旋转设为 `atan2(0, 0) = 0` | 采用 Rust 行为 |
| `inheritance` 镜像 | 父骨骼朝左时对子骨骼取反 | 未实现 | 采用 Rust 行为 |
| Visuals/IK 动画、`propagate_hidden`、`baked_ik` | 存在（0.8.0 特性） | 不存在 | 采用 Rust 行为 |
| 越界访问 | panic（`unwrap` / 索引） | 查找失败时返回 `bones[0]` | 跳过，并标注 `NOTE(panic-safety)` |

对畸形输入的处理是唯一有意为之的行为差异。Rust 代码会在越界的 `unwrap()` 或索引处 panic，本运行时
则跳过出问题的元素，这些位置都标了 `NOTE(panic-safety):`。无论是否加保护，越界索引都会干净地 trap
—— 除非构建时使用了 `-no-bounds-check`，那会把它们变成静默的越界访问，所以在这样的构建里发布
之前请先校验 `.skf` 文件。

剩下的差异属于表达习惯而非行为：Rust 的浮点转整数用 `f32_as_u32` 复现，使 `NaN` / 负值饱和到 `0`
而不是未定义，与 Rust 的 `as` 运算符一致。

## 出处

* 运行时逻辑、数据模型与示例资源移植自
  [`rusty_skelform`](https://github.com/Retropaint/rusty_skelform) /
  [`rusty_skelform_macroquad`](https://github.com/Retropaint/rusty_skelform_macroquad)
  （MIT，© Retropaint）。`example/` 下的 `.skf` 来自 macroquad 运行时的 `examples/` 目录。
* 行为已与 [`skelform_go`](https://github.com/Retropaint/skelform_go) 交叉核对，`.skf` 的导出
  语义则对照 [SkelForm 编辑器](https://github.com/Retropaint/SkelForm) 本身确认。
* raylib 集成沿用 `rusty_skelform_macroquad` 的引擎适配层，但有三处改动是 Y-up → Y-down 的坐标
  映射强制要求的：关闭背面剔除（该映射会反转三角形绕序）、骨骼的 pivot 偏移在绕骨骼旋转**之前**
  先对 Y 取反、贴图四边形与网格走同一个三角形发射路径（因为在 X 缩放为负时 `DrawTexturePro` 不再
  是干净的镜像）。

MIT 许可 —— 见 [LICENSE](LICENSE)。
