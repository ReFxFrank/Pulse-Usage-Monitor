; Pulse - Inno Setup 6 script for PulseSetup.exe
;
; Wraps the same binaries the release already ships: dist-exe\pulse.exe
; (required) and, when it was built, dist-strip\pulse-strip.exe (the taskbar
; companion). Installs PER USER into %LOCALAPPDATA%\Programs\Pulse - the exact
; directory `pulse.exe --install` uses - so the installer and Pulse's own
; built-in install converge on one layout instead of fighting over shortcuts.
;
; Build (from anywhere, after `node build/make-exe.mjs`):
;   iscc /DMyAppVersion=1.27.0 build\installer.iss
;   -> dist-installer\PulseSetup.exe
;
; NOTE: the binaries are UNSIGNED. SmartScreen will warn on this installer
; (More info -> Run anyway). Nothing here claims otherwise.
;
; ASCII only, deliberately: Inno reads a .iss without a UTF-8 BOM in the system
; ANSI codepage, so non-ASCII text would render differently per machine.

#ifndef MyAppVersion
; Fallback so a bare `iscc build\installer.iss` (no define) still compiles,
; which is how you syntax-check this locally. CI always passes the real tag.
#define MyAppVersion "0.0.0"
#endif

#define MyAppName "Pulse"
#define MyAppPublisher "ReFxFrank"
#define MyAppURL "https://github.com/ReFxFrank/Pulse-Usage-Monitor"
#define MyAppExe "pulse.exe"
; The HKCU Run entry Pulse also manages itself (Server panel toggle /
; `pulse.exe --startup on|off`). Same key, same value name, same data shape, so
; the two paths stay interchangeable.
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"
#define RunValue "Pulse"
; Anchor every source path to the script's own location rather than to the
; compiler's working directory, so `iscc build\installer.iss` works from any cwd.
#define RepoRoot SourcePath + "\.."

[Setup]
; AppId is the upgrade identity - NEVER change it, or existing installs stop
; being recognised as the same product and users end up with two copies.
AppId={{76C28179-9CBE-42EA-B9E6-7BE166115AD3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases/latest
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=Pulse - local Claude Code / Codex usage dashboard

; Per-user install: no admin prompt anywhere, nothing written outside the
; user's own profile (plus the opt-in HKCU Run value below).
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\Pulse
; No Start Menu group page - the shortcuts go straight into Programs, on the
; same paths `pulse.exe --install` writes.
DisableProgramGroupPage=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExe}
LicenseFile={#RepoRoot}\LICENSE

; The shipped binaries are x64; x64compatible also covers arm64 Windows, which
; runs them under emulation. (x64compatible needs Inno 6.3+.)
ArchitecturesAllowed=x64compatible
MinVersion=10.0

SourceDir={#RepoRoot}
OutputDir=dist-installer
OutputBaseFilename=PulseSetup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

; Pulse holds its own exe open while the server runs, so an upgrade would hit a
; locked file. We stop it ourselves in PrepareToInstall (which also runs in
; silent mode) instead of letting Restart Manager put a close-programs page in
; the way.
CloseApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create &desktop shortcuts (Pulse and Pulse - Stop)"; GroupDescription: "Shortcuts:"
; Startup is deliberately UNCHECKED: the Run key is the one thing Pulse writes
; outside its own ~/.pulse folder, so it only ever happens when the user asks
; for it here (or in the Server panel / `pulse.exe --startup on`).
Name: "startup"; Description: "Start Pulse when I sign in to Windows (server only, no browser popup)"; GroupDescription: "Options:"; Flags: unchecked
; Installing the strip binary only makes it available; it stays off until the
; user enables "Pulse Strip" in the dashboard's Server panel.
Name: "strip"; Description: "Include Pulse Strip, the taskbar strip companion (enable it later in the Server panel)"; GroupDescription: "Options:"; Flags: unchecked

[Files]
Source: "dist-exe\pulse.exe"; DestDir: "{app}"; Flags: ignoreversion
; skipifsourcedoesntexist: a build machine without the .NET toolchain has no
; strip, and that must not break the installer build.
Source: "dist-strip\pulse-strip.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist; Tasks: strip
Source: "LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
; Pulse Strip is a port of openusage-windows (MIT); MIT requires the notice to
; travel with the binary, so it ships whenever the strip does.
Source: "strip\LICENSE-openusage"; DestDir: "{app}"; DestName: "LICENSE-openusage.txt"; Flags: ignoreversion skipifsourcedoesntexist; Tasks: strip

[Icons]
; Flat entries (no group folder) so they land on exactly the paths
; `pulse.exe --install` / `--install-shortcuts` use: running either afterwards
; overwrites these instead of duplicating them.
; Launching pulse.exe when a server is already up just opens the dashboard, so
; the "Pulse" entry doubles as "open Pulse dashboard"; a separate localhost
; shortcut would only be a duplicate that dead-ends whenever Pulse is stopped.
Name: "{autoprograms}\Pulse"; Filename: "{app}\{#MyAppExe}"; WorkingDir: "{app}"; Comment: "Start Pulse (opens the dashboard if it is already running)"
Name: "{autoprograms}\Pulse - Stop"; Filename: "{app}\{#MyAppExe}"; Parameters: "--stop"; WorkingDir: "{app}"; Comment: "Stop the running Pulse server"
Name: "{autodesktop}\Pulse"; Filename: "{app}\{#MyAppExe}"; WorkingDir: "{app}"; Comment: "Start Pulse (opens the dashboard if it is already running)"; Tasks: desktopicon
Name: "{autodesktop}\Pulse - Stop"; Filename: "{app}\{#MyAppExe}"; Parameters: "--stop"; WorkingDir: "{app}"; Comment: "Stop the running Pulse server"; Tasks: desktopicon

[Registry]
; The startup entry, identical to what Pulse writes for itself: quoted exe path
; plus --no-open, which starts the server at sign-in without popping a browser.
; uninsdeletevalue removes it again when Pulse is uninstalled.
; There is deliberately NO "delete when the task is unchecked" counterpart: a
; user who turned startup on in the Server panel should not have it silently
; turned off by running an upgrade installer. Turning it off is the Server panel
; toggle, `pulse.exe --startup off`, or uninstalling.
Root: HKCU; Subkey: "{#RunKey}"; ValueType: string; ValueName: "{#RunValue}"; ValueData: """{app}\{#MyAppExe}"" --no-open"; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\{#MyAppExe}"; Description: "Start Pulse now (opens the dashboard)"; Flags: postinstall nowait skipifsilent

[UninstallRun]
; Stop the server before its files are deleted, otherwise the running exe is
; locked and the uninstall leaves it behind.
Filename: "{app}\{#MyAppExe}"; Parameters: "--stop"; RunOnceId: "StopPulse"; Flags: runhidden skipifdoesntexist

[UninstallDelete]
; Intentionally empty. Pulse's config, logs and sealed history live in
; %USERPROFILE%\.pulse and are the USER'S DATA - uninstalling the program must
; never delete them. Anything ever added here must stay inside {app}.

[Messages]
; Say plainly that the data folder survived, rather than leaving people guessing.
UninstalledAll=%1 was successfully removed from your computer.%n%nYour Pulse settings and usage history in the .pulse folder of your user profile were left untouched.

[Code]
// Ask a running Pulse to shut down so its exe can be replaced or removed.
// `--stop` is a no-op when nothing is listening, so this is always safe.
procedure StopRunningPulse;
var
  Exe: String;
  ResultCode: Integer;
begin
  Exe := ExpandConstant('{app}\{#MyAppExe}');
  if FileExists(Exe) then
    if Exec(Exe, '--stop', ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      // The daemon acknowledges the stop and then exits; give it a moment to
      // release the file handle before we start copying over it.
      Sleep(1500);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopRunningPulse;
  Result := '';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Data: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // The Run value may have been created by Pulse itself (Server panel /
    // `--startup on`), in which case [Registry] never recorded it for
    // uninsdeletevalue. Remove it when it points at the copy being uninstalled,
    // so uninstalling never leaves a sign-in entry aimed at a deleted exe. One
    // pointing anywhere else (a portable copy) is left alone.
    if RegQueryStringValue(HKCU, '{#RunKey}', '{#RunValue}', Data) then
      if Pos(Lowercase(ExpandConstant('{app}')), Lowercase(Data)) > 0 then
        RegDeleteValue(HKCU, '{#RunKey}', '{#RunValue}');
  end;
end;
