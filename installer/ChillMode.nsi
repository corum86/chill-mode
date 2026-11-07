; Chill Mode installer (NSIS 3)
; Build:  makensis -DVERSION=1.1.0 installer/ChillMode.nsi
; Output: dist/ChillMode-Setup-<version>.exe

Unicode true
SetCompressor /SOLID lzma

!ifndef VERSION
  !define VERSION "1.1.2"
!endif
!define APPNAME   "Chill Mode"
!define APPKEY    "ChillMode"
!define PUBLISHER "corum86"
!define URL       "https://github.com/corum86/chill-mode"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}"
!define PS        "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
!define PSARGS    "-NoProfile -ExecutionPolicy Bypass -STA"

!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"

Name "${APPNAME}"
OutFile "..\dist\ChillMode-Setup-${VERSION}.exe"
InstallDir "$PROGRAMFILES64\${APPNAME}"
InstallDirRegKey HKLM "${UNINSTKEY}" "InstallLocation"
RequestExecutionLevel admin
BrandingText "${APPNAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName"     "${APPNAME}"
VIAddVersionKey "ProductVersion"  "${VERSION}"
VIAddVersionKey "FileVersion"     "${VERSION}"
VIAddVersionKey "FileDescription" "${APPNAME} Setup - one-panel battery optimizer"
VIAddVersionKey "CompanyName"     "${PUBLISHER}"
VIAddVersionKey "LegalCopyright"  "${PUBLISHER}"

; ---------------------------------------------------------------- UI
!define MUI_ICON   "..\assets\ChillMode.ico"
!define MUI_UNICON "..\assets\ChillMode.ico"
!define MUI_ABORTWARNING
!define MUI_COMPONENTSPAGE_SMALLDESC

!define MUI_WELCOMEPAGE_TITLE "Welcome to ${APPNAME} ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "${APPNAME} puts every battery-saving setting of your laptop - power mode, CPU limits, iGPU, refresh rate, display, browsers, wireless and sleep - in one panel, with one-click presets and a full undo.$\r$\n$\r$\nClick Next to continue."
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Open ${APPNAME} now"
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchApp
!define MUI_FINISHPAGE_LINK "Project page on GitHub"
!define MUI_FINISHPAGE_LINK_LOCATION "${URL}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ---------------------------------------------------------------- init
Function .onInit
  SetRegView 64
  ${IfNot} ${RunningX64}
    StrCpy $INSTDIR "$PROGRAMFILES\${APPNAME}"
  ${EndIf}
FunctionEnd

Function un.onInit
  SetRegView 64
FunctionEnd

Function LaunchApp
  Exec '"${PS}" ${PSARGS} -WindowStyle Hidden -File "$INSTDIR\ChillMode.ps1"'
FunctionEnd

; ---------------------------------------------------------------- sections
Section "${APPNAME} (required)" SecCore
  SectionIn RO
  SetShellVarContext all
  SetOutPath "$INSTDIR"
  File "..\ChillMode.ps1"
  File "..\ChillMode.cmd"
  File "..\README.md"
  SetOutPath "$INSTDIR\assets"
  File "..\assets\ChillMode.ico"
  File "..\assets\ChillMode.png"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  WriteRegStr   HKLM "${UNINSTKEY}" "DisplayName"          "${APPNAME}"
  WriteRegStr   HKLM "${UNINSTKEY}" "DisplayVersion"       "${VERSION}"
  WriteRegStr   HKLM "${UNINSTKEY}" "Publisher"            "${PUBLISHER}"
  WriteRegStr   HKLM "${UNINSTKEY}" "URLInfoAbout"         "${URL}"
  WriteRegStr   HKLM "${UNINSTKEY}" "DisplayIcon"          "$INSTDIR\assets\ChillMode.ico"
  WriteRegStr   HKLM "${UNINSTKEY}" "InstallLocation"      "$INSTDIR"
  WriteRegStr   HKLM "${UNINSTKEY}" "UninstallString"      '"$INSTDIR\Uninstall.exe"'
  WriteRegStr   HKLM "${UNINSTKEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoRepair" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "EstimatedSize" 200
SectionEnd

Section "Start menu shortcuts" SecStart
  SetShellVarContext all
  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "${PS}" \
    '${PSARGS} -WindowStyle Hidden -File "$INSTDIR\ChillMode.ps1"' \
    "$INSTDIR\assets\ChillMode.ico" 0 SW_SHOWMINIMIZED "" "Open the battery optimizer panel"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\${APPNAME} - Optimize for battery.lnk" "${PS}" \
    '${PSARGS} -File "$INSTDIR\ChillMode.ps1" -Preset MaxBattery' \
    "$INSTDIR\assets\ChillMode.ico" 0 SW_SHOWMINIMIZED "" "Apply every battery-saving setting in one click"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\${APPNAME} - Restore original.lnk" "${PS}" \
    '${PSARGS} -File "$INSTDIR\ChillMode.ps1" -Restore' \
    "$INSTDIR\assets\ChillMode.ico" 0 SW_SHOWMINIMIZED "" "Undo every change Chill Mode made"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Uninstall ${APPNAME}.lnk" "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Desktop shortcut" SecDesktop
  SetShellVarContext all
  CreateShortcut "$DESKTOP\${APPNAME}.lnk" "${PS}" \
    '${PSARGS} -WindowStyle Hidden -File "$INSTDIR\ChillMode.ps1"' \
    "$INSTDIR\assets\ChillMode.ico" 0 SW_SHOWMINIMIZED "" "Open the battery optimizer panel"
SectionEnd

Section /o "Desktop one-click 'Optimize for battery' shortcut" SecDesktopMax
  SetShellVarContext all
  CreateShortcut "$DESKTOP\${APPNAME} - Optimize for battery.lnk" "${PS}" \
    '${PSARGS} -File "$INSTDIR\ChillMode.ps1" -Preset MaxBattery' \
    "$INSTDIR\assets\ChillMode.ico" 0 SW_SHOWMINIMIZED "" "Apply every battery-saving setting in one click"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecCore}       "The Chill Mode app, icon and uninstaller."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecStart}      "Start menu entries: open the panel, one-click optimize, restore original, uninstall."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop}    "A desktop shortcut that opens the panel."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktopMax} "A desktop shortcut that applies the 'Optimize for battery' preset without opening the panel."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ---------------------------------------------------------------- uninstall
Section "Uninstall"
  ; Offer to undo the setting changes before removing the app.
  SetShellVarContext current
  ${If} ${FileExists} "$LOCALAPPDATA\ChillMode\backup.json"
    MessageBox MB_YESNO|MB_ICONQUESTION "Restore your original battery and display settings before uninstalling?$\r$\n$\r$\n(Choose No to keep the optimized settings.)" /SD IDNO IDNO skipRestore
      ${DisableX64FSRedirection}
      ExecWait '"${PS}" ${PSARGS} -WindowStyle Hidden -File "$INSTDIR\ChillMode.ps1" -Restore'
      ${EnableX64FSRedirection}
    skipRestore:
  ${EndIf}
  RMDir "$LOCALAPPDATA\ChillMode"

  SetShellVarContext all
  Delete "$DESKTOP\${APPNAME}.lnk"
  Delete "$DESKTOP\${APPNAME} - Optimize for battery.lnk"
  RMDir /r "$SMPROGRAMS\${APPNAME}"

  Delete "$INSTDIR\ChillMode.ps1"
  Delete "$INSTDIR\ChillMode.cmd"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\assets\ChillMode.ico"
  Delete "$INSTDIR\assets\ChillMode.png"
  RMDir  "$INSTDIR\assets"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir  "$INSTDIR"

  DeleteRegKey HKLM "${UNINSTKEY}"
SectionEnd
