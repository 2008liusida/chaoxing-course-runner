# 贡献指南

感谢愿意一起维护这个工具。因为它的"易燃部分"是第三方平台的 DOM，
最需要的是**在平台改版时能快速定位并只改一处**。

---

## 先读这两份

1. [`docs/PLATFORM-CONTRACT.md`](docs/PLATFORM-CONTRACT.md) —— 平台 DOM 契约与排查步骤
2. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) —— 分层原则、设计取舍、5.1 兼容坑

改代码前请先看 `lib/Selectors.psd1`：**所有平台选择器只写在这里**。

---

## 开发环境

- Windows 10/11
- PowerShell 5.1（系统自带）**和/或** PowerShell 7.x
- Edge 或 Chrome
- 无需 Python / Node / 任何第三方模块

**务必在 5.1 上验证**（`powershell.exe`，不是 `pwsh`）。
本项目要求同时兼容两者，只在 7.x 上测试会漏掉一批问题。

---

## 编码约定

1. **脚本必须带 UTF-8 BOM**。5.1 对无 BOM 文件按 ANSI 读，中文会变乱码并直接语法报错。
   用 UTF-8 保存时请选择"带 BOM"。

2. **判据只用 id / class / 结构，不用可见文字**。
   课节标题被反爬字体处理过，`innerText` 是乱码。

3. **新增函数要同步导出清单**：`lib/ChaoxingCourseRunner.psd1` 的
   `FunctionsToExport`。子模块内不要写 `Export-ModuleMember`。
   改完跑 `tests/module-smoke.ps1`。

4. **不要在跨模块处用 `$script:` 共享状态**，用环境变量或显式参数。
   原因见 ARCHITECTURE 的"三个刻意的设计决定"。

5. **JSON 数组解析一律走 `ConvertFrom-JsonArray`**，不要写
   `@($json | ConvertFrom-Json)`（5.1 上会得到错误元素个数）。

6. **失败路径要记日志并且不抛异常**（在 `Invoke-Lesson` 内）。
   一节课的问题不该中断整批任务。

7. 注释写"为什么"，不写"做了什么"。重点是交代约束与取舍，
   例如"为什么这里的导航不能等待响应"，让下一个人不必重新推导。

---

## 提交前自检

```powershell
# 1) 语法 + 导出 + 配置校验（不需要浏览器）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\module-smoke.ps1

# 2) JSON 数组兼容性
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\check-jsonarray.ps1

# 3) 选择器与夹具结构对齐（需要浏览器已开调试端口）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\check-fixture.ps1

# 4) 端到端（自动起本地服务与夹具页）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-fixture.ps1
```

再确认所有改动过的脚本仍然带 BOM：

```powershell
Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.psd1 | ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    $bom = $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
    if (-not $bom) { Write-Warning "缺少 BOM: $($_.FullName)" }
}
```

---

## 平台改版了怎么办

这是最常见的维护场景，步骤见
[`docs/PLATFORM-CONTRACT.md` 第四节](docs/PLATFORM-CONTRACT.md#四平台改版时的排查步骤)。
通常只需要改 `lib/Selectors.psd1` 里的一两个键。

工具在异常时会把**实际执行的 JS**写进 `logs/run.log`（DEBUG 行），
可以直接复制到浏览器控制台验证选择器。

---

## 不建议的改动

- **加入倍速/跳过**：平台会检测倍速，非 1 倍可能不计入时长；
  未完成任务点前进度条也不可拖拽。这类"优化"通常只会让完成度失效。
- **把选择器写回业务逻辑**：会重新引入"改版要改多处"的问题。
- **为了少写几行而绕过 `Selectors` 表**：同上。
- **引入第三方依赖**：本项目的卖点之一是"零依赖、解压即用"。

---

## 行为边界

请保持工具的能力范围：**只播放、只读状态**。

不要加入：代登录、处理验证码、代答测验/作业、批量操作他人账号。
这不是技术限制，而是让项目保持在"辅助观看"的定位上。

---

## 许可证

本项目采用 PolyForm Noncommercial License 1.0.0（禁止商业使用，需保留署名）。
提交代码即表示你同意以同一许可证分发你的贡献。
若要改为允许商用（如 MIT），需维护者统一替换 `LICENSE` 并更新 `README.md`。

## 构建图形界面版本

仓库 `dist\` 下的 `ChaoxingRunner.exe` 不进版本库，由构建脚本生成：

```powershell
python gui\build.py
```

只用到 Windows 自带的 `csc.exe`，不需要 .NET SDK。
产物在 `dist\ChaoxingRunner.exe`。

改完脚本后要重新构建，否则 exe 里还是旧的内嵌脚本 ——
这是最容易忘的一步。
（`ChaoxingRunner.exe --selftest` 可以确认内嵌资源是否完好。）
