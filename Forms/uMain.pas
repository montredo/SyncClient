unit uMain;

{$MODE OBJFPC}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs,
  ComCtrls, StdCtrls, uService;

type

  { TMainForm }

  TMainForm = class(TForm)
    FilesView: TListView;

    Label1: TLabel;
    ServerNameEdit: TEdit;
    Label2: TLabel;
    FilePathEdit: TEdit;

    RefreshButton: TButton;
    DownloadButton: TButton;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);

    procedure FilesViewCustomDrawItem(Sender: TCustomListView;
      Item: TListItem; State: TCustomDrawState; var DefaultDraw: Boolean);
    procedure FilesViewItemChecked(Sender: TObject; Item: TListItem);

    procedure RefreshButtonClick(Sender: TObject);
    procedure DownloadButtonClick(Sender: TObject);
  private
    FInsertType: TInsertType;

    procedure ShowRefresh(AID, AName, AStatus: string; AInsertType: TInsertType;
      ACheck: Boolean);
    procedure ShowStatus(AIndex: Integer; AStatus: string);
  public

  end;

var
  MainForm: TMainForm;

implementation

uses
  uConsts;

{$R *.lfm}

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  CriticalSectionCreate();

  SetLength(FFileArray, 0);

  DoubleBuffered := True;
  Position := poScreenCenter;

  Caption := Format('%s %s Build %s', [STitle, SVersion, SBuild]);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  CriticalSectionFree();

  SetLength(FFileArray, 0);
end;

procedure TMainForm.FilesViewCustomDrawItem(Sender: TCustomListView;
  Item: TListItem; State: TCustomDrawState; var DefaultDraw: Boolean);
begin
  if FInsertType = itNull then
    DefaultDraw := True;

  if FInsertType = itExists then
    Sender.Canvas.Font.Color := clGreen;

  if FInsertType = itNotExists then
    Sender.Canvas.Font.Color := clBlue;

  FInsertType := itNull;
end;

procedure TMainForm.FilesViewItemChecked(Sender: TObject; Item: TListItem);
begin
  CS.Enter;
  FFileArray[Item.Index].FileCheck := Item.Checked;
  CS.Leave;
end;

procedure TMainForm.ShowRefresh(AID, AName, AStatus: string;
  AInsertType: TInsertType; ACheck: Boolean);
begin
  FInsertType := AInsertType;

  with FilesView.Items.Add do
  begin
    Caption := AID;
    SubItems.Add(AName);
    SubItems.Add(AStatus);
    Checked := ACheck;
  end;
end;

procedure TMainForm.ShowStatus(AIndex: Integer; AStatus: string);
begin
  if (AIndex >= 0) and (AIndex < FilesView.Items.Count) then
  begin
    FilesView.Items[AIndex].SubItems[1] := AStatus;
  end;
end;

procedure TMainForm.RefreshButtonClick(Sender: TObject);
var
  ServiceThread: TServiceThread;
begin
  FilesView.Items.Clear;
  SetLength(FFileArray, 0);

  ServiceThread := TServiceThread.Create(True);
  ServiceThread.FreeOnTerminate := True;

  ServiceThread.OnShowRefresh := @ShowRefresh;
  ServiceThread.OnShowStatus := @ShowStatus;

  ServiceThread.ServiceType := stRefresh;

  ServiceThread.ServerName := ServerNameEdit.Text;
  ServiceThread.FilePath := FilePathEdit.Text;

  ServiceThread.Start;
end;

procedure TMainForm.DownloadButtonClick(Sender: TObject);
var
  ServiceThread: TServiceThread;
begin
  ServiceThread := TServiceThread.Create(True);
  ServiceThread.FreeOnTerminate := True;

  ServiceThread.OnShowRefresh := @ShowRefresh;
  ServiceThread.OnShowStatus := @ShowStatus;

  ServiceThread.ServiceType := stDownload;

  ServiceThread.ServerName := ServerNameEdit.Text;
  ServiceThread.FilePath := FilePathEdit.Text;

  ServiceThread.Start;
end;

end.
