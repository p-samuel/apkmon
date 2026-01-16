program apkmon;

{$APPTYPE CONSOLE}

uses
  APKMon.Console in 'src\APKMon.Console.pas',
  APKMon.Types in 'src\APKMon.Types.pas',
  APKMon.Utils in 'src\APKMon.Utils.pas',
  APKMon.Config in 'src\APKMon.Config.pas',
  APKMon.ADB in 'src\APKMon.ADB.pas',
  APKMon.Projects in 'src\APKMon.Projects.pas',
  APKMon.Monitor in 'src\APKMon.Monitor.pas',
  APKMon.Deployer in 'src\APKMon.Deployer.pas',
  APKMon.Commands in 'src\APKMon.Commands.pas',
  APKMon.Watcher in 'src\APKMon.Watcher.pas',
  APKMon.Logcat in 'src\APKMon.Logcat.pas',
  APKMon.Recorder in 'src\APKMon.Recorder.pas',
  APKMon.FPS in 'src\APKMon.FPS.pas',
  APKMon.Profile in 'src\APKMon.Profile.pas',
  APKMon.App in 'src\APKMon.App.pas',
  QRCode in 'src\QRCode.pas',
  APKMon.QRPair in 'src\APKMon.QRPair.pas';

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
