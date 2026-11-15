; Inno Setup script. Build it with installer\build.ps1, which passes VcRedist.
#define AppName "File Shredder"
#define AppVersion "1.0.0"
#define AppExe "fileshredder.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

#ifndef VcRedist
  #error Run installer\build.ps1 instead of compiling this file directly.
#endif

[Setup]
; Keep this AppId forever: Windows uses it to recognize upgrades.
AppId={{7C1E4B52-93A6-4D0F-8E27-5B6A1F3D9C40}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
; Per-user install: no administrator prompt, and the Explorer verb is per-user too.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Matches kInstanceMutexName in windows\runner\single_instance.h.
AppMutex=FileShredder.SingleInstance
OutputDir=..\dist
OutputBaseFilename=FileShredder-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(CompilerPath + "Languages\Bulgarian.isl")
Name: "bulgarian"; MessagesFile: "compiler:Languages\Bulgarian.isl"
#endif

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
; The C++ runtime, for PCs without Visual Studio or its redistributable.
Source: "{#VcRedist}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRedist}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRedist}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"

[Run]
Filename: "{app}\{#AppExe}"; Parameters: "--register"; Flags: runhidden waituntilterminated; StatusMsg: "Adding Shred to the context menu..."

[UninstallRun]
Filename: "{app}\{#AppExe}"; Parameters: "--unregister"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveShredVerb"
