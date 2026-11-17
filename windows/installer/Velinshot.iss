; A per-user installer. User screenshots and preferences never belong to the install directory.
#ifndef PublishDir
  #error PublishDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef DisplayVersion
  #error DisplayVersion is required
#endif
#ifndef BuildNumber
  #error BuildNumber is required
#endif
#ifndef Runtime
  #define Runtime "win-x64"
#endif
#ifndef FixtureBuild
  #define FixtureBuild "0"
#endif

[Setup]
#if FixtureBuild == "1"
AppId=Velinshot.Windows.UpdateFixture
AppName=Velinshot Update Fixture
DefaultDirName={localappdata}\VelinshotUpdateFixture\app
#else
AppId=Velinshot.Windows
AppName=Velinshot
DefaultDirName={localappdata}\Programs\Velinshot
#endif
AppVersion=1.0.0.{#BuildNumber}
AppVerName=Velinshot {#DisplayVersion}
AppPublisher=Velinshot
AppPublisherURL=https://github.com/Jacknelson6/Velinshot
UninstallDisplayIcon={app}\Velinshot.exe
PrivilegesRequired=lowest
MinVersion=10.0.19041
#if Runtime == "win-arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
CloseApplications=no
RestartApplications=no
AppMutex={code:ApplicationMutex}
SetupMutex=Local\Velinshot.Windows.Setup.{#FixtureBuild}
DisableProgramGroupPage=yes
DisableDirPage=auto
OutputDir={#OutputDir}
OutputBaseFilename=Velinshot-{#DisplayVersion}-{#Runtime}-setup
SetupIconFile=..\Resources\Velinshot.ico
LicenseFile=..\..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
VersionInfoVersion=1.0.0.{#BuildNumber}

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Velinshot"; Filename: "{app}\Velinshot.exe"

[Run]
Filename: "{app}\Velinshot.exe"; Description: "Open Velinshot"; Flags: nowait postinstall skipifsilent

[Code]
function ApplicationMutex(Param: String): String;
var Identity: String;
begin
  Identity := 'Velinshot-' + GetEnv('USERDOMAIN') + '-' + GetEnv('USERNAME');
  StringChangeEx(Identity, '\', '-', True);
  Result := 'Local\' + Identity;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if CheckForMutexes(ApplicationMutex('')) then
    Result := 'Velinshot is running. Save or copy your screenshots, quit Velinshot from its notification-area menu, and try again.';
end;
