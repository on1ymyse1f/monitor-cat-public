# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path


windows_root = Path(SPECPATH).resolve()
repository_root = windows_root.parent
entry_point = windows_root / "monitor_cat.py"
resources = repository_root / "Sources" / "aimonitor-app" / "Resources"
icon = windows_root / "build" / "AIMonitor.ico"

if not entry_point.is_file():
    raise FileNotFoundError(f"Windows entry point does not exist: {entry_point}")
if not resources.is_dir():
    raise FileNotFoundError(f"Shared resource directory does not exist: {resources}")
if not icon.is_file():
    raise FileNotFoundError(f"Generate the Windows icon before running PyInstaller: {icon}")

# pystray chooses its backend dynamically, so PyInstaller cannot discover the
# Windows backend through normal import analysis. Pillow's image plugins and
# ImageTk are similarly loaded behind runtime paths used by tray/Tk UIs.
hidden_imports = [
    "pystray._win32",
    "pystray._util.win32",
    "PIL.Image",
    "PIL.ImageDraw",
    "PIL.ImageFont",
    "PIL.ImageTk",
    "PIL.IcoImagePlugin",
    "PIL.PngImagePlugin",
    "tkinter",
    "tkinter.ttk",
]

analysis = Analysis(
    [str(entry_point)],
    pathex=[str(windows_root), str(repository_root)],
    binaries=[],
    datas=[(str(resources), "Resources")],
    hiddenimports=hidden_imports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        "pystray._appindicator",
        "pystray._darwin",
        "pystray._gtk",
        "pystray._xorg",
    ],
    noarchive=False,
    optimize=1,
)

pyz = PYZ(analysis.pure)

executable = EXE(
    pyz,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="AIMonitor",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=str(icon),
)

bundle = COLLECT(
    executable,
    analysis.binaries,
    analysis.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="AIMonitor",
)
