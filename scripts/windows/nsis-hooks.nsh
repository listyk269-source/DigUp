; The opt-in login entry belongs to the current user, like this installer.
!macro NSIS_HOOK_POSTUNINSTALL
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "DigUp"
!macroend
