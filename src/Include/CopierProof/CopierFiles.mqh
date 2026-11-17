//+------------------------------------------------------------------+
//| CopierFiles.mqh                                                  |
//| File names and atomic writes in Terminal\Common\Files, shared by |
//| the four EAs (MQL4 and MQL5 use the same file functions here).   |
//+------------------------------------------------------------------+
#ifndef COPIER_PROOF_FILES_MQH
#define COPIER_PROOF_FILES_MQH

#define CP_FOLDER "CopierProof"

void CP_Log(const string msg) { Print("[CopierProof] ", msg); }

string CP_SnapshotPath(const string channel) { return CP_FOLDER + "\\" + channel + ".snap"; }

string CP_SlaveMapPath(const string channel, const long login, const long magic)
  {
   return CP_FOLDER + "\\" + channel + ".slave-" + IntegerToString(login) + "-" + IntegerToString(magic) + ".map";
  }

string CP_AliasPath(const string channel, const string role, const long login)
  {
   return CP_FOLDER + "\\" + channel + "." + role + "-" + IntegerToString(login) + ".mt4alias";
  }

bool CP_EnsureFolder(void)
  {
   if(FolderCreate(CP_FOLDER, FILE_COMMON))
      return true;
   return FileIsExist(CP_FOLDER, FILE_COMMON);
  }

//--- write to "<path>.tmp", then rename over <path>: a reader sees the old file,
//--- no file, or the new file; the sealed format rejects anything else
bool CP_WriteTextAtomic(const string path, const string text)
  {
   string tmp = path + ".tmp";
   int h = FileOpen(tmp, FILE_WRITE | FILE_BIN | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return false;
   uint written = FileWriteString(h, text);
   FileClose(h);
   if(written != (uint)StringLen(text))
      return false;
   return FileMove(tmp, FILE_COMMON, path, FILE_COMMON | FILE_REWRITE);
  }

bool CP_ReadText(const string path, string &text)
  {
   text = "";
   if(!FileIsExist(path, FILE_COMMON))
      return false;
   int h = FileOpen(path, FILE_READ | FILE_BIN | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return false;
   int size = (int)FileSize(h);
   if(size > 0)
      text = FileReadString(h, size);
   FileClose(h);
   return true;
  }

#endif
