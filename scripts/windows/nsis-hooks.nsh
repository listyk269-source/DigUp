; Keep the old install identity while moving user-visible shortcuts to FileAtlas.
Var LegacyInstallDir
Var LegacyStartLink
Var LegacyDesktopLink
Var LegacyAutoStart

!macro FileAtlasRememberLegacyInstall
  ReadRegStr $R0 SHCTX "${UNINSTKEY}" "DisplayName"
  ReadRegStr $R1 SHCTX "${UNINSTKEY}" "MainBinaryName"
  ${If} $R0 == "DigUp"
  ${AndIf} $R1 == "digup-shell.exe"
    ReadRegStr $LegacyInstallDir SHCTX "${MANUPRODUCTKEY}" ""
    ${If} $LegacyInstallDir != ""
      !insertmacro IsShortcutTarget "$SMPROGRAMS\DigUp.lnk" "$LegacyInstallDir\digup-shell.exe"
      Pop $LegacyStartLink
      !insertmacro IsShortcutTarget "$DESKTOP\DigUp.lnk" "$LegacyInstallDir\digup-shell.exe"
      Pop $LegacyDesktopLink
      ReadRegStr $R0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "DigUp"
      ${If} $R0 == '"$LegacyInstallDir\digup-shell.exe"'
        StrCpy $LegacyAutoStart 1
      ${EndIf}
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_PREINSTALL
  ${If} $LegacyInstallDir != ""
  ${AndIf} ${FileExists} "$LegacyInstallDir\digup-shell.exe"
    !insertmacro CheckIfAppIsRunning "$LegacyInstallDir\digup-shell.exe" "DigUp"
  ${EndIf}
!macroend

!macro FileAtlasMigrateShortcut directory existed
  ${If} ${existed} == 1
    !insertmacro IsShortcutTarget "${directory}\DigUp.lnk" "$LegacyInstallDir\digup-shell.exe"
    Pop $R0
    ${If} $R0 == 1
      Delete "${directory}\DigUp.lnk"
    ${EndIf}
    ${If} $NoShortcutMode != 1
      CreateShortcut "${directory}\FileAtlas.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
      !insertmacro SetLnkAppUserModelId "${directory}\FileAtlas.lnk"
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro FileAtlasMigrateShortcut "$SMPROGRAMS" $LegacyStartLink
  !insertmacro FileAtlasMigrateShortcut "$DESKTOP" $LegacyDesktopLink
  ${If} $LegacyAutoStart == 1
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "FileAtlas" '"$INSTDIR\${MAINBINARYNAME}.exe" --background'
    ReadRegStr $R0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "DigUp"
    ${If} $R0 == '"$LegacyInstallDir\digup-shell.exe"'
      DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "DigUp"
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ReadRegStr $R0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "FileAtlas"
  ${If} $UpdateMode != 1
  ${AndIf} $R0 == '"$INSTDIR\${MAINBINARYNAME}.exe" --background'
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "FileAtlas"
  ${EndIf}
!macroend
