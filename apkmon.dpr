program apkmon;

{$APPTYPE CONSOLE}

uses
  APKMon.Types in 'src\APKMon.Types.pas',
  APKMon.Utils in 'src\APKMon.Utils.pas',
  APKMon.ADB in 'src\APKMon.ADB.pas',
  APKMon.Projects in 'src\APKMon.Projects.pas',
  APKMon.Monitor in 'src\APKMon.Monitor.pas',
  APKMon.Deployer in 'src\APKMon.Deployer.pas',
  APKMon.Commands in 'src\APKMon.Commands.pas',
  APKMon.Watcher in 'src\APKMon.Watcher.pas',
  APKMon.App in 'src\APKMon.App.pas';

var
  App: TAppRunner;
begin
  App := TAppRunner.Create;
  try
    App.Run;
  finally
    App.Free;
  end;
end.
