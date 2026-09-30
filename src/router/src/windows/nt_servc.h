/*
  Copyright (c) 2026, MariaDB plc.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; version 2 of the License.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 USA
*/

#ifndef NT_SERVC_INCLUDED
#define NT_SERVC_INCLUDED

#include <windows.h>

#ifdef StartService
#undef StartService
#endif

/**
  @file

  @brief
  Windows NT Service class library

  Copyright Abandoned 1998 Irena Pancirov - Irnet Snc
  This file is public domain and comes with NO WARRANTY of any kind
*/

// main application thread
typedef void (*THREAD_FC)(void *);

class NTService {
 public:
  NTService();
  ~NTService();

  BOOL bOsNT;  ///< true if OS is NT, false for Win95
  // install optinos
  DWORD dwDesiredAccess;
  DWORD dwServiceType;
  DWORD dwStartType;
  DWORD dwErrorControl;

  LPSTR szLoadOrderGroup;
  LPDWORD lpdwTagID;
  LPSTR szDependencies;
  OSVERSIONINFO osVer;

  // time-out (in milisec)
  int nStartTimeOut;
  int nStopTimeOut;
  int nPauseTimeOut;
  int nResumeTimeOut;

  //
  DWORD my_argc;
  LPTSTR *my_argv;
  HANDLE hShutdownEvent;
  int nError;
  DWORD dwState;

  BOOL GetOS() noexcept;  // returns TRUE if WinNT
  BOOL IsNT() { return bOsNT; }
  // init service entry point
  long Init(LPCSTR szInternName, void *ServiceThread,
            void (*fpReqAppShutdownCb)()) noexcept;

  // application shutdown event
  void SetShutdownEvent(HANDLE hEvent) noexcept { hShutdownEvent = hEvent; }

  // service install / un-install
  BOOL Install(int startType, LPCSTR szInternName, LPCSTR szDisplayName,
               LPCSTR szFullPath, LPCSTR szAccountName = nullptr,
               LPCSTR szPassword = nullptr) noexcept;
  BOOL SeekStatus(LPCSTR szInternName, int OperationType);
  BOOL Remove(LPCSTR szInternName);
  BOOL is_super_user();

  // running
  BOOL got_service_option(char **argv, char *service_option);
  static BOOL IsService(LPCSTR ServiceName) noexcept;

  /*
    SetRunning() is to be called by the application
    when initialization completes and it can accept
    stop request
  */
  void SetRunning(void);

  /**
    Sets a timeout after which SCM will abort service startup if SetRunning()
    was not called or the timeout was not extended with another call to
    SetSlowStarting(). Should be called when static initialization completes,
    and the variable initialization part begins

    @arg timeout  the timeout to pass to the SCM (in milliseconds)
  */
  void SetSlowStarting(unsigned long timeout);

  /*
    Stop() is to be called by the application to stop
    the service
  */
  void Stop(void);

 protected:
  LPSTR ServiceName;
  HANDLE hExitEvent;
  SERVICE_STATUS_HANDLE hServiceStatusHandle;
  BOOL bPause;
  BOOL bRunning;
  HANDLE hThreadHandle;
  THREAD_FC fpServiceThread;
  void (*fpRequestApplicationShutdownCallback)() = nullptr;

  void PauseService();
  void ResumeService();
  void StopService();
  BOOL StartService();

  static void ServiceMain(DWORD argc, LPTSTR *argv);
  static void ServiceCtrlHandler(DWORD ctrlCode);

  void Exit(DWORD error);
  BOOL SetStatus(DWORD dwCurrentState, DWORD dwWin32ExitCode,
                 DWORD dwServiceSpecificExitCode, DWORD dwCheckPoint,
                 DWORD dwWaitHint);
};
/* ------------------------- the end -------------------------------------- */

#endif /* NT_SERVC_INCLUDED */
