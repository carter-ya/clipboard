#ifndef BundleDir
#error BundleDir must name a verified package directory
#endif
#ifndef DesktopVersion
#error DesktopVersion is required
#endif
#ifndef ArtifactDir
#error ArtifactDir is required
#endif

[Setup]
AppId=com.clipboard.desktop
AppName=Clipboard
AppVersion={#DesktopVersion}
AppPublisher=Clipboard
DefaultDirName={localappdata}\Programs\Clipboard
DefaultGroupName=Clipboard
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir={#ArtifactDir}
OutputBaseFilename=ClipboardDesktop-{#DesktopVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\share\icons\clipboard.ico
SetupIconFile={#BundleDir}\share\icons\clipboard.ico
AppMutex=Local\ClipboardDesktop.Running
CloseApplications=no
RestartApplications=no

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Clipboard"; Filename: "{app}\bin\ClipboardDesktop.exe"; IconFilename: "{app}\share\icons\clipboard.ico"
Name: "{group}\Uninstall Clipboard"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\bin\ClipboardDesktop.exe"; Description: "Open Clipboard"; Flags: nowait postinstall skipifsilent

[Code]
function NormalizeCommand(Value: String): String;
begin
  StringChangeEx(Value, '/', '\', True);
  Result := Lowercase(Value);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Actual, Expected: String;
begin
  if CurUninstallStep = usUninstall then begin
    Expected := '"' + ExpandConstant('{app}\bin\ClipboardDesktop.exe') + '" --background';
    if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'com.clipboard.desktop', Actual) then
      if NormalizeCommand(Actual) = NormalizeCommand(Expected) then
        RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'com.clipboard.desktop');
  end;
end;
