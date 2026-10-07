# -*- coding: utf-8 -*-
"""构建 ChaoxingRunner.exe。

做法：
  1. 把 PowerShell 脚本与配置读成字节，base64 编码后写进 C# 源码
     （用 base64 而不是字符串字面量，避免 C# 源码编码与转义问题）
  2. 用 Windows 自带的 csc.exe 编译成单个 .NET Framework 4.0 可执行文件
     （.NET Framework 4 在所有 Windows 10/11 上都有，无需安装任何运行时）

产出：
  dist/ChaoxingRunner.exe

不依赖 .NET SDK —— 只用到每台 Windows 都有的 csc.exe。
"""
import base64
import glob
import io
import os
import subprocess
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

# 仓库根目录：本文件在 <repo>\gui\ 下
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'dist')
# 中间产物放在 gui\build\ 下
BUILD_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'build')

# 要内嵌进 EXE 的文件（相对仓库根目录）
EMBED = [
    'Run.ps1',
    'config.psd1',
    'lib/ChaoxingCourseRunner.psd1',
    'lib/ChaoxingCourseRunner.psm1',
    'lib/Logging.psm1',
    'lib/Settings.psm1',
    'lib/Selectors.psd1',
    'lib/Selectors.psm1',
    'lib/CdpClient.psm1',
    'lib/Browser.psm1',
    'lib/PageVisibility.psm1',
    'lib/PlatformDetect.psm1',
    'lib/Chaoxing.psm1',
    'lib/Video.psm1',
    'lib/LessonRunner.psm1',
    'scripts/Clear-Cache.ps1',
]

if not os.path.isdir(BUILD_DIR):
    os.makedirs(BUILD_DIR)

CSC = os.path.join(os.environ['WINDIR'], 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe')

# PowerShell 引擎程序集：在 GAC 中，需给出完整路径（csc 不自动解析 GAC）。
# 调用时由 .NET 运行时从 GAC 加载，EXE 本身不需要携带它。
def find_sma():
    pat = os.path.join(os.environ['WINDIR'], 'Microsoft.NET', 'assembly',
                       'GAC_MSIL', 'System.Management.Automation', 'v4.0_*', 'System.Management.Automation.dll')
    hits = glob.glob(pat)
    if hits:
        return hits[0]
    cand = os.path.join(os.environ['WINDIR'], 'System32', 'WindowsPowerShell', 'v1.0',
                        'System.Management.Automation.dll')
    return cand if os.path.exists(cand) else None

SMA = find_sma()
if not SMA or not os.path.exists(SMA):
    print('  找不到 System.Management.Automation.dll')
    sys.exit(1)
print('  PowerShell 引擎: %s' % SMA)

if not os.path.exists(CSC):
    print('  找不到 csc.exe: %s' % CSC)
    sys.exit(1)


def b64(rel):
    with open(os.path.join(ROOT, rel), 'rb') as f:
        return base64.b64encode(f.read()).decode('ascii')


# ---------------- 生成资源表 ----------------
lines = []
total = 0
for rel in EMBED:
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        print('  缺少文件: %s' % rel)
        sys.exit(1)
    total += os.path.getsize(p)
    # 路径用正斜杠：反斜杠在 C# 字符串里是转义符，会编译失败；
    # 正斜杠在 Windows 上同样能被 Path.Combine 正确处理。
    lines.append('        "%s|%s"' % (rel, b64(rel)))

# 必须是 static readonly：自检模式在静态 Main 里访问它。
    resources = ('static readonly string[] EMBEDDED = new string[] {\n'
                 + ',\n'.join(lines) + '\n    };')
print('  内嵌 %d 个文件，共 %.1f KB' % (len(EMBED), total / 1024))

# ---------------- 读 GUI 源码模板 ----------------
# 模板与脚本同目录；BUILD_DIR 只放编译中间产物。
tpl_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'Gui.cs.tpl')
if not os.path.exists(tpl_path):
    print('  缺少模板: %s' % tpl_path)
    sys.exit(1)
with io.open(tpl_path, encoding='utf-8') as f:
    gui = f.read()

if '/*__EMBEDDED__*/' not in gui:
    print('  模板里没有 /*__EMBEDDED__*/ 占位符')
    sys.exit(1)
gui = gui.replace('/*__EMBEDDED__*/', resources)

cs_path = os.path.join(BUILD_DIR, 'ChaoxingRunner.cs')
with io.open(cs_path, 'w', encoding='utf-8-sig', newline='\r\n') as f:
    f.write(gui)
print('  已生成 C# 源码: %.1f KB' % (os.path.getsize(cs_path) / 1024))

# ---------------- 编译 ----------------
if not os.path.isdir(OUT_DIR):
    os.makedirs(OUT_DIR)
exe_path = os.path.join(OUT_DIR, 'ChaoxingRunner.exe')
if os.path.exists(exe_path):
    os.remove(exe_path)

cmd = [
    CSC, '/nologo', '/target:winexe', '/platform:anycpu',
    '/codepage:65001',
    '/out:' + exe_path,
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:' + SMA,
    '/optimize+',
    cs_path,
]
print('')
print('  编译中…')
r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
out = (r.stdout or '') + (r.stderr or '')
for line in out.split('\n'):
    if line.strip():
        print('    ' + line.strip())

if os.path.exists(exe_path):
    print('')
    print('  编译成功: %s  (%.1f KB)' % (exe_path, os.path.getsize(exe_path) / 1024))
else:
    print('  编译失败')
    sys.exit(1)
