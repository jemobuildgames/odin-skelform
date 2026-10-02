# odin-skelform

纯 Odin 编写的 **SkelForm** 2D 骨骼动画运行时，附带一个 raylib 示例，可加载并播放导出的 `.skf`
骨骼资源。

对应 **SkelForm 0.8.0** —— 见[版本对应](#版本对应)。完整的函数与类型参考在
**[docs/api.md](docs/api.md)**（英文）。

[English](README.md) · **中文**

![示例运行画面，加载 example/skellington.skf](docs/example.png)

## 目录结构

仓库根目录**就是**库本身（`package skelform`），示例放在它旁边。以 `skf` 导入后，在你自己的渲染
循环里调用即可。

| 路径 | 内容 |
| --- | --- |
| `skelform.odin` | 数据模型 + 运行时：动画采样、父子继承、反向动力学（IK）、物理、网格形变 |
| `loader.odin` | `.skf` 加载：自带的小型 ZIP 读取器（stored + deflate）与 `armature.json` 映射 |
| `example/main.odin` | raylib 演示：窗口、输入、动画循环 |
| `example/render.odin` | raylib 适配层：屏幕空间构建与贴图绘制 |
| `example/*.skf` | 演示骨骼资源（`skellington`、`skellina`） |
| `docs/api.md` | API 参考：类型、函数、所有权约定、raylib 适配层契约（英文） |
| `docs/` | 本说明文档使用的运行截图 |

## 版本对应

本运行时面向 **SkelForm 0.8.0** 的导出结果。

`.skf` 自带格式版本：`armature.json` 中的 `version` 字符串，编辑器在那里写入它自己的版本号。
**本运行时不读取该字段**：解析过程与版本无关，因此来自更新版编辑器的文件会丢弃无法识别的键并正常
加载，而不会失败。`example/` 中附带的两个骨骼资源是 **0.7.0** 导出，可正常加载。

* **0.6** 之前的导出不支持。这类文件由编辑器在打开时自行升级（`src/backwards_compat.rs` 覆盖
  0.2 → 0.5），所以运行时只会见到当前版本的 JSON。旧文件请先在编辑器里重新导出，不要直接喂给
  运行时。
* 需要严格校验？自己读取 `armature.json` 里的 `version` 即可 —— `skf_find_entry` 可以把这个条目
  取出来。

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

## API 参考

所有类型的字段、所有函数的签名、运行时认识的 `Keyframe.element` 字符串、所有权表，以及 raylib
适配层契约，都在 **[docs/api.md](docs/api.md)**（英文）。需要记住的四件事：

1. 每帧的顺序是 `animate` → `construct` → 绘制 `constructed_bones` 与 `visuals`。不要绘制
   `armature.bones`。
2. 引用型 id 是 `i32`，`-1` 表示「无」；`Bone.id` 从 0 起连续编号，并且可以直接当作它在 `bones`
   中的下标。
3. `active_styles` 与 `inverse_kinematics` 返回新分配的值，调用方必须 `delete()`。
4. `Armature` 的字符串是从产生它的 `SKF`**借用**的 —— 只要还在用它的 armature 绘制，就必须让
   `SKF` 保持存活。`armature_destroy` 只释放数组，这也是手工构造的 armature 同样能被安全释放的
   原因。

## `.skf` 格式

`.skf` 文件就是一个普通的 ZIP 归档：

```text
armature.json   运行时数据（映射到 `Armature`）
atlas0.png ...  `armature.atlases` 每个条目对应一张 PNG
editor.json, thumbnail.png, readme.md   编辑器专用的额外文件（忽略）
```

`loader.odin` 自己实现了 ZIP 中央目录读取（stored 与 deflate 条目，通过 `core:compress/zlib`
处理），并手写 JSON 映射，因此缺失的键会回退到导出器预期的默认值：缺失的 tint 为 `(1, 1, 1, 1)`，
缺失的标量为 `0`，缺失的向量为 `(0, 0)`，`Keyframe.handle_preset` 为 `.Linear`，以此类推。较早的
编辑器版本把 IK 家族 id 写成 `"id"`；`"id"` 与 `"family_id"` 都会被接受。

需要注意 `Style.active` **不在** `armature.json` 里 —— 编辑器把它存在 `editor.json`。因此导出的
`.skf` 中没有任何 style 被标记为在用，`active_styles` 会退回到名为 `"Default"` 的 style，若也没有
则取最后一个。

MIT 许可 —— 见 [LICENSE](LICENSE)。
