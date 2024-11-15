; This script lets you press a key (default middle mouse) within an Explorer Save/Open dialog window, and it will show a list of paths from any currently open Directory Opus and/or Windows Explorer windows.
; Source Repo: https://github.com/ThioJoe/AHK-Scripts
; Parts of the logic from this script: https://gist.github.com/akaleeroy/f23bd4dd2ddae63ece2582ede842b028#file-currently-opened-folders-md

; HOW TO USE:
; Either run this script by itself, or include it in your main script using #Include
; Ensure the required RemoteTreeView class file is in the location in the #Include line
; Set the dialogMenuHotkey variable to the hotkey you want to use to show the menu
; Edit any configuration variables as needed

; ---------------------------------------------------------------------------------------------------

#Requires AutoHotkey v2.0
#SingleInstance force
SetWorkingDir(A_ScriptDir)
; Set the path to the RemoteTreeView class file as necessary. Here it is up one directory then in the Lib folder. Necessary to navigate legacy folder dialogs.
; Can be acquired from: https://github.com/ThioJoe/AHK-RemoteTreeView-V2/blob/main/RemoteTreeView.ahk
#Include "..\Lib\RemoteTreeView.ahk"

; ---------------------------------------- DEFAULT USER SETTINGS ----------------------------------------
; These will be overridden by settings in the settings ini file if it exists. Otherwise these defaults will be used.
class pathSelector_DefaultSettings {
    ; Hotkey to show the menu. Default is Middle Mouse Button. If including this script in another script, you could choose to set this hotkey in the main script and comment this line out
    static dialogMenuHotkey := "~MButton"
    ; Enable debug mode to show tooltips with debug info
    static enableExplorerDialogMenuDebug := false
    ; Whether to show the disabled clipboard path menu item when no valid path is found on the clipboard, or only when a valid path is found on the clipboard
    static alwaysShowClipboardmenuItem := true
    ; Whether to enable UI access by default to allow the script to run in elevated windows without running as admin
    static enableUIAccess := true
    static activeTabSuffix := ""            ;  Appears to the right of the active path for each window group
    static activeTabPrefix := "► "          ;  Appears to the left of the active path for each window group
    static standardEntryPrefix := "    "    ; Indentation for inactive tabs, so they line up
    ; Path to dopusrt.exe - can be empty to explicitly disable Directory Opus integration, but it will automatically disable if the file is not found anyway
    static dopusRTPath := "C:\Program Files\GPSoftware\Directory Opus\dopusrt.exe"
    static maxMenuLength := 120             ; Maximum length of menu items. The true max is MAX_PATH, but thats really long so this is a reasonable limit
    static defaultPaths := "C:\;C:\Tmp\" ; semicolon seperated list of default paths
}

; System Tray Menu Options
pathSelector_SystemTraySettings := {
    settingsMenuItemName: "Path Selector Settings   ",   ; Added spaces to the name or else it can get cut off when default menu item
    showSettingsTrayMenuItem: true,   ; Show the settings menu item in the system tray menu. If set to false none of these other settings matter
    forcePositionIndex: false,        ; If this is false, the position index will be increased by 1 if the script is running as included in another script (so it shows up after the parent script's menu items)
    positionIndex: 1,                 ; Position index for the settings menu item. 1 is the first item, 2 is the second, etc.
    addSeparatorBefore: false,        ; Add a separator before the settings menu item
    addSeparatorAfter: true,          ; Add a separator after the settings menu item
    alwaysDefaultItem: false          ; If true, the path selector menu item will always be the default even if the script is included in another script
}
PathSelector_SetupSystemTray(pathSelector_SystemTraySettings)

;TraySetIcon("Explorer Dialog Path Selector Icon.ico") ; Uncomment to set a custom icon for the system tray. There is one in the 'Assets' folder of the repo

; ------------------------------------------ INITIALIZATION ----------------------------------------------------

; Set global variables about the program and compiler directives. These use regex to extract data from the lines above them (A_PriorLine)
; Keep the line pairs together!
global g_pathSelector_version := "1.1.0.0"
;@Ahk2Exe-Let ProgramVersion=%A_PriorLine~U)^(.+"){1}(.+)".*$~$2%

global g_pathSelector_programName := "Explorer Dialog Path Selector"
;@Ahk2Exe-Let ProgramName=%A_PriorLine~U)^(.+"){1}(.+)".*$~$2%

; Compiler Options for exe manifest - Arguments: RequireAdmin, Name, Version, UIAccess
;    - The UIAccess option is necessary to allow the script to run in elevated windows protected by UAC without running as admin
;    - Be aware enabling UI Access for compiled would require the script to be signed to work properly and then placed in a trusted location
;    - If you enable the UI Access argument and DON'T sign it, Windows won't run it and will give an error message, therefore not recommended to set the last argument to '1' unless you will self-sign the exe or have a trusted certificate
;    - If you do sign it, it will still run even if not in a trusted location, but it just won't work in elevated dialog Windows
; Note: Though this may have UI Access argument as 0, for my releases I set it to 1 and sign the exe
;@Ahk2Exe-UpdateManifest 0, %U_ProgramName%, %U_ProgramVersion%, 0
;@Ahk2Exe-SetVersion %U_ProgramVersion%
;@Ahk2Exe-SetProductName %U_ProgramName%
;@Ahk2Exe-SetName %U_ProgramName%
;@Ahk2Exe-SetCopyright ThioJoe
;@Ahk2Exe-SetDescription Press a hotkey in an Explorer dialog to show a menu to navigate to paths of other Explorer windows

; Global variable to hold current settings
global g_pth_Settings := {}

; Construct object with info about the settings file. Class creates the various object properties using inputs for the file name and folder name in AppData
global g_pth_SettingsFile := SettingsFile(
    "ExplorerDialogPathSelector-Settings.ini", ; Name of the settings file
    "Explorer-Dialog-Path-Selector"            ; Name of the folder in AppData where the settings file will be stored
)

InitializePathSelectorSettings()
; If the script is running standalone and UI access is installed...
; Reload self with UI Access for the script - Allows usage within elevated windows protected by UAC without running the script as admin
; See Docs: https://www.autohotkey.com/docs/v1/FAQ.htm#uac
if (g_pth_Settings.enableUIAccess = true) and !A_IsCompiled and ThisScriptRunningStandalone() and !InStr(A_AhkPath, "_UIA") {
    Run("*uiAccess " A_ScriptFullPath)
    ExitApp()
}

PathSelector_UpdateHotkey("", "") ; Initialize the hotkey. It will use the hotkey from settings

; ---------------------------------------- INITIALIZATION FUNCTIONS AND CLASSES  ----------------------------------------------

InitializePathSelectorSettings() {
    ; ---------- Conditional Default Settings ----------
    ; Check for the existence of the hard coded default Directory Opus exe path and disable Directory Opus integration if it doesn't exist
    ; This is to prevent the script from trying to use Directory Opus integration if the path is invalid, but still load whatever value from user settings file if there is one
    if !FileExist(pathSelector_DefaultSettings.dopusRTPath) {
        pathSelector_DefaultSettings.dopusRTPath := ""
    }
    ; If the script is not running standalone or compiled, disable UI Access by default
    if !ThisScriptRunningStandalone() or A_IsCompiled {
        pathSelector_DefaultSettings.enableUIAccess := false
    }

    ; ------------------ Load settings Files ------------------
    ; If the settings file isn't in the current directory, but it is in AppData, use the AppData path
    if (!FileExist(g_pth_SettingsFile.filePath)) and FileExist(g_pth_SettingsFile.appDataFilePath) {
        g_pth_SettingsFile.filePath := g_pth_SettingsFile.appDataFilePath
        g_pth_SettingsFile.directoryPath := g_pth_SettingsFile.appDataDirectoryPath
    }

    try {
        PathSelector_LoadSettingsFromSettingsFilePath(g_pth_SettingsFile.filePath)
    } catch Error as err {
        MsgBox("Error reading settings file: " err.Message "`n`nUsing default settings.")
        for k, v in pathSelector_DefaultSettings.OwnProps() {
            g_pth_Settings.%k% := pathSelector_DefaultSettings.%k%
        }
    }

    ; ----- Special handling for certain settings -----
    ; For UI Access, always disable if not running standalone
    if !ThisScriptRunningStandalone() or A_IsCompiled {
        g_pth_Settings.enableUIAccess := false
    }
    return
}

; Updates the hotkey. If no new hotkey is provided, it will use the hotkey from settings
PathSelector_UpdateHotkey(newHotkey := "", previousHotkeyString := "") {
    ; Use the hotkey from settings if no new hotkey is provided
    if (newHotkey = "") {
        newHotkey := g_pth_Settings.dialogMenuHotkey
    }

    ; If the new hotkey is the same as before, return. Otherwise it will disable itself and re-enable itself unnecessarily
    ; By now newHotkey should have a value either from being set or from the settings
    if (newHotkey = "") or (newHotkey = previousHotkeyString)
        return

    if (previousHotkeyString != "") {
        try {
            HotKey(previousHotkeyString, "Off")
        } catch Error as hotkeyUnsetErr {
            MsgBox("Error disabling previous hotkey: " hotkeyUnsetErr.Message "`n`nHotkey Attempted to Disable:`n" previousHotkeyString "`n`nWill still try to set new hotkey.")
        }
    }

    try {
        HotKey(newHotkey, DisplayDialogPathMenu, "On") ; Include 'On' option to ensure it's enabled if it had been disabled before, like changing the hotkey back again
    } catch Error as hotkeySetErr {
        MsgBox("Error setting hotkey: " hotkeySetErr.Message "`n`nHotkey Set To:`n" newHotkey)
    }
}

; Stores info about the settings file - Using a class instead of object so that we can dynamically set certain properties based on the file name and folder name
class SettingsFile {
    ; Explicitly declare these properties as static because there should really only be one instance of it
    static fileName             := unset
    static directoryPath        := unset
    static appDataDirName       := unset
    static filePath             := unset
    static appDataDirectoryPath := unset
    static appDataFilePath      := unset
    static usingSettingsFile    := unset

    ; Actually set the properties using inputs for the file name and folder name in AppData
    __New(fileName, appDataFolderName) {
        this.fileName               := fileName
        this.directoryPath          := A_ScriptDir
        this.appDataDirName         := appDataFolderName
        this.filePath               := this.directoryPath "\" fileName
        this.appDataDirectoryPath   := A_AppData "\" this.appDataDirName
        this.appDataFilePath        := this.appDataDirectoryPath "\" fileName
        this.usingSettingsFile      := false
    }
}

; ---------------------------------------- UTILITY FUNCTIONS  ----------------------------------------------
; Function to check if the script is running standalone or included in another script
ThisScriptRunningStandalone() {
    ;MsgBox("A_ScriptName: " A_ScriptFullPath "`n`nA_LineFile: " A_LineFile "`n`nRunning Standalone: " (A_ScriptFullPath = A_LineFile ? "True" : "False"))
    return A_ScriptFullPath = A_LineFile
}

; ------------------------------------ MAIN LOGIC FUNCTIONS ---------------------------------------------------

; Get the paths of all tabs from all Windows of Windows Explorer, and identify which are the active tab for each window
GetAllExplorerPaths() {
    paths := []
    explorerHwnds := WinGetList("ahk_class CabinetWClass")
    shell := ComObject("Shell.Application")

    static IID_IShellBrowser := "{000214E2-0000-0000-C000-000000000046}"

    ; First make a pass through all explorer windows to get the active tab for each
    activeTabs := Map()
    for explorerHwnd in explorerHwnds {
        try {
            if activeTab := ControlGetHwnd("ShellTabWindowClass1", "ahk_id " explorerHwnd) {
                activeTabs[explorerHwnd] := activeTab
            }
        }
    }

    ; shell.Windows gives us a collection of all open open tabs as a flat list, not separated by window, so now we loop through and match them up by Hwnd
    ; Now do a single pass through all tabs
    for tab in shell.Windows {
        try {
            ; Ensure we have the handle of the tab
            if tab && tab.hwnd {
                parentWindowHwnd := tab.hwnd
                path := tab.Document.Folder.Self.Path
                if path {
                    ; Check if this tab is active
                    isActive := false
                    ; If we have any active tab at all for the parent window
                    if activeTabs.Has(parentWindowHwnd) {
                        ; Get an interface to interact with the tab's shell browser
                        shellBrowser := ComObjQuery(tab, IID_IShellBrowser, IID_IShellBrowser)
                        ; Call method of Index 3 on the interface to get the tab's handle so we can see if any windows have such an active tab
                        ; We need to know the method index number from the "vtable" - Apparently the struct for a vtable is often named with "Vtbl" at the end like "IWhateverInterfaceVtbl"
                        ; IShellBrowserVtbl is in the Windows SDK inside ShObjIdl_core.h. The first 3 methods are AddRef, Release, and QueryInterface, inhereted from IUnknown,
                        ;       so the first real method is the fourth, meaning index 3, which is GetWindow and is also the one we want
                        ; The output of the ComCall GetWindow method here is the handle of the tab, not the parent window, so we can compare it to the activeTabs map
                        ComCall(3, shellBrowser, "uint*", &thisTab := 0)
                        isActive := (thisTab = activeTabs[parentWindowHwnd])
                    }

                    paths.Push({
                        Hwnd: parentWindowHwnd,
                        Path: path,
                        IsActive: isActive
                    })
                }
            }
        }
    }
    return paths
}

; Call Directory Opus' DOpusRT to create temporary XML file with info about Opus open windows. Parse the XML and return an array of path objects
GetDOpusPaths() {
    if (g_pth_Settings.dopusRTPath = "") {
        return []
    }

    if !FileExist(g_pth_Settings.dopusRTPath) {
        MsgBox("Directory Opus Runtime (dopusrt.exe) not found at:`n" g_pth_Settings.dopusRTPath "`n`nDirectory Opus integration won't work. To enable it, set the correct path in the script configuration. Or set it to an empty string to avoid this error.", "DOpus Integration Error", "Icon!")
        return []
    }

    tempFile := A_Temp "\dopus_paths.xml"
    try FileDelete(tempFile)

    try {
        cmd := '"' g_pth_Settings.dopusRTPath '" /info "' tempFile '",paths'
        RunWait(cmd, unset, "Hide")

        if !FileExist(tempFile)
            return []

        xmlContent := FileRead(tempFile)
        FileDelete(tempFile)

        ; Parse paths from XML
        paths := []

        ; Start after the XML declaration
        xmlContent := RegExReplace(xmlContent, "^.*?<results.*?>", "")

        ; Extract each path element with its attributes
        while RegExMatch(xmlContent, "s)<path([^>]*)>(.*?)</path>", &match) {
            ; Get attributes
            attrs := Map()
            RegExMatch(match[1], "lister=`"(0x[^`"]*)`"", &listerMatch)
            RegExMatch(match[1], "active_tab=`"([^`"]*)`"", &activeTabMatch)
            RegExMatch(match[1], "active_lister=`"([^`"]*)`"", &activeListerMatch)

            ; Create path object
            pathObj := {
                path: match[2],
                lister: listerMatch ? listerMatch[1] : "unknown",
                isActiveTab: activeTabMatch ? (activeTabMatch[1] = "1") : false,
                isActiveLister: activeListerMatch ? (activeListerMatch[1] = "1") : false
            }
            paths.Push(pathObj)

            ; Remove the processed path element and continue searching
            xmlContent := SubStr(xmlContent, match.Pos + match.Len)
        }

        return paths
    } catch as err {
        MsgBox("Error reading Directory Opus paths: " err.Message "`n`nDirectory Opus integration will be disabled.", "DOpus Integration Error", "Icon!")
        return []
    }
}

; Display the menu
DisplayDialogPathMenu(thisHotkey) { ; Called via the Hotkey function, so it must accept the hotkey as its first parameter
    ; ------------------------- LOCAL FUNCTIONS -------------------------
    GetDialogAddressBarPath(windowHwnd) {
        controls := WinGetControls(windowHwnd)
        ; Go through controls that match "ToolbarWindow32*" in the class name and check if their text starts with "Address: "
        for controlClassNN in controls {
            if (controlClassNN ~= "ToolbarWindow32") {
                controlText := ControlGetText(controlClassNN, windowHwnd)
                if (controlText ~= "Address: ") {
                    ; Get the path from the address bar
                    return SubStr(controlText, 10)
                }
            }
        }
        return ""
    }

    ;global menuItemTrackerObj := {} ; For debugging purposes
    InsertMenuItem(menuObj, text, path := unset, iconPath := unset, iconIndex := unset, isActiveTab := unset) {
        if text = "" { ; It's a separator
            menuObj.Insert(unset)
            currentMenuNum++
            return
        }

        pathStr := "" ; Default to empty string so we can use the same callback without passing f_path parameter unset
        if (IsSet(path)) {
            pathStr := path
        }

        ; If the menuText is greater than the max, truncate it from the right using SubStr. The path should still work since this is only the text displayed in the menu
        stringLength := StrLen(text)
        ; Note: If the path is longer than MAX_PATH (I believe), Windows will convert it to 8.3 format. Navigation still work but our window path matching might not work
        if (stringLength > maxMenuLength) {
            if (isActiveTab)
                text := g_pth_Settings.activeTabPrefix "..." SubStr(text, (-1 * maxMenuLength)) g_pth_Settings.activeTabSuffix
            else
                text := g_pth_Settings.standardEntryPrefix "..." SubStr(text, (-1 * maxMenuLength))
        }

        ; Add the item and increment the counter
        menuObj.Insert(unset, text, PathSelector_Navigate.Bind(unset, unset, unset, pathStr, windowClass, windowID))
        currentMenuNum++

        ;menuItemTrackerObj.DefineProp(currentMenuNum, {Value: {pathStr: pathStr, text: pathStr}}) ; For debugging purposes

        if (!IsSet(path)) { ; It's a header because it's just text
            menuObj.Disable(currentMenuNum "&")
            return
        }
        
        if (IsSet(iconPath) and iconPath and IsSet(iconIndex) and iconIndex) {
            menuObj.SetIcon(currentMenuNum "&", iconPath, iconIndex)
        }

        ; Check if the path matches the dialog already. If so, disable the item
        if (windowPath and (windowPath = path)) {
            menuObj.Disable(currentMenuNum "&")
        }
    }

    ; ------------------------------------------------------------------------

    debugMode := g_pth_Settings.enableExplorerDialogMenuDebug
    maxMenuLength := g_pth_Settings.maxMenuLength

    if (debugMode) {
        ToolTip("Hotkey Pressed: " A_ThisHotkey)
        Sleep(1000)
        ToolTip()
    }

    ; Detect windows with error handling
    try {
        windowID := WinGetID("a")
        windowClass := WinGetClass("a")
        windowHwnd := WinExist("a")
    } catch as err {
        ; If we can't get window info, wait briefly and try once more
        Sleep(25)
        try {
            windowID := WinGetID("a")
            windowClass := WinGetClass("a")
            windowHwnd := WinExist("a")
        } catch as err {
            if (debugMode) {
                ToolTip("Unable to detect active window")
                Sleep(1000)
                ToolTip()
            }
            return
        }
    }

    ; Verify we got valid window info
    if (!windowID || !windowClass) {
        if (debugMode) {
            ToolTip("No valid window detected")
            Sleep(1000)
            ToolTip()
        }
        return
    }

    if (debugMode) {
        ToolTip("Window ID: " windowID "`nClass: " windowClass)
        Sleep(1000)
        ToolTip()
    }

    ; Don't display menu unless it's a dialog or console window
    if !(windowClass ~= "^(?i:#32770|ConsoleWindowClass)$") {
        if (debugMode) {
            ToolTip("Window class does not match expected: " windowClass)
            Sleep(1000)
            ToolTip()
        }
        return
    }

    ; Get the path from the dialog. At this point we know it's the correct type of window
    if (windowHwnd) {
        windowPath := GetDialogAddressBarPath(windowHwnd)
    } else {
        windowPath := ""
    }

    ; Proceed to display the menu
    CurrentLocations := Menu()
    hasItems := false
    currentMenuNum := 0 ; Used to keep track of the current menu item number so we can refer to each item by index like "1&" in case of duplicate path entries

    ; Only get Directory Opus paths if dopusRTPath is set
    if (g_pth_Settings.dopusRTPath != "") {
        ; Get paths from Directory Opus using DOpusRT
        paths := GetDOpusPaths()

        ; Group paths by lister
        listers := Map()

        ; First, group all paths by their lister
        for pathObj in paths {
            if !listers.Has(pathObj.lister)
                listers[pathObj.lister] := []
            listers[pathObj.lister].Push(pathObj)
        }

        ; First add paths from active lister
        for pathObj in paths {
            if (pathObj.isActiveLister) {
                InsertMenuItem(CurrentLocations, "Opus Window " A_Index " (Active)", unset, unset, unset, unset) ; Header

                ; Add all paths for this lister
                listerPaths := listers[pathObj.lister]
                for tabObj in listerPaths {
                    menuText := tabObj.path
                    ; Add prefix and suffix for active tab based on global settings
                    if (tabObj.isActiveTab)
                        menuText := g_pth_Settings.activeTabPrefix menuText g_pth_Settings.activeTabSuffix
                    else
                        menuText := g_pth_Settings.standardEntryPrefix menuText

                    InsertMenuItem(CurrentLocations, menuText, tabObj.path, A_WinDir . "\system32\imageres.dll", "4", tabObj.isActiveTab) ; Path
                    hasItems := true

                }

                ; Remove this lister from the map so we don't show it again
                listers.Delete(pathObj.lister)
                break
            }
        }

        ; Then add remaining Directory Opus listers. I forget why there's a separate block for the rest, I think there was a reason, maybe I'll conolidate it later
        ; Might have something to do with using pathObj vs tabObj
        windowNum := 2
        for lister, listerPaths in listers {
            InsertMenuItem(CurrentLocations, "Opus Window " windowNum " (Active)", unset, unset, unset, unset) ; Header

            ; Add all paths for this lister
            for pathObj in listerPaths {
                menuText := pathObj.path
                ; Add prefix and suffix for active tab based on global settings
                if (pathObj.isActiveTab)
                    menuText := g_pth_Settings.activeTabPrefix menuText g_pth_Settings.activeTabSuffix
                else
                    menuText := g_pth_Settings.standardEntryPrefix menuText

                InsertMenuItem(CurrentLocations, menuText, pathObj.path, A_WinDir . "\system32\imageres.dll", "4", pathObj.isActiveTab) ; Path
                hasItems := true
            }

            windowNum++
        }
    }

    explorerPaths := GetAllExplorerPaths()

    ; Group paths by window handle (Hwnd)
    windows := Map()
    for pathObj in explorerPaths {
        if !windows.Has(pathObj.Hwnd)
            windows[pathObj.Hwnd] := []
        windows[pathObj.Hwnd].Push(pathObj)
    }

    ; Add Explorer paths if any exist
    if explorerPaths.Length > 0 {
        ; Add separator if we had Directory Opus paths
        if (hasItems)
            InsertMenuItem(CurrentLocations, "", unset, unset, unset, unset) ; Separator

        windowNum := 1
        for hwnd, windowPaths in windows {
            InsertMenuItem(CurrentLocations, "Explorer Window " windowNum, unset, unset, unset, unset) ; Header

            for pathObj in windowPaths {
                menuText := pathObj.Path
                ; Add prefix and suffix for active tab based on global settings
                if (pathObj.IsActive)
                    menuText := g_pth_Settings.activeTabPrefix menuText g_pth_Settings.activeTabSuffix
                else
                    menuText := g_pth_Settings.standardEntryPrefix menuText

                InsertMenuItem(CurrentLocations, menuText, pathObj.path, A_WinDir . "\system32\imageres.dll", "4", pathObj.IsActive) ; Path
                hasItems := true
            }

            windowNum++
        }
    }

    ; Add Default paths if any exist
    if StrLen(g_pth_Settings.defaultPaths) > 0 {
        ; Add separator if we had Directory Explorer paths
        if (hasItems)
            InsertMenuItem(CurrentLocations, "", unset, unset, unset, unset) ; Separator

        InsertMenuItem(CurrentLocations, "Default", unset, unset, unset, unset) ; Header

        defaultPathsList := StrSplit(g_pth_Settings.defaultPaths, ";")

        for pathObj in defaultPathsList {
            menuText := g_pth_Settings.standardEntryPrefix pathObj

            InsertMenuItem(CurrentLocations, menuText, pathObj, A_WinDir . "\system32\imageres.dll", "111", false) ; Path
            hasItems := true
        }
    }

    ; If there is a path in the clipboard, add it to the menu
    if DllCall("Shlwapi\PathIsDirectoryW", "Str", A_Clipboard) != 0 {
        ; Add separator if we had Directory Opus or Explorer paths
        if (hasItems)
            InsertMenuItem(CurrentLocations, "", unset, unset, unset, unset) ; Separator

        path := A_Clipboard
        menuText := g_pth_Settings.standardEntryPrefix path Chr(0x200B) ; Add zero-with space as a janky way to make the menu item unique so it doesn't overwrite the icon of previous items with same path
        InsertMenuItem(CurrentLocations, menuText, path, A_WinDir . "\system32\imageres.dll", "-5301", false) ; Path (Clipboard)
        hasItems := true
        
    } else if g_pth_Settings.alwaysShowClipboardmenuItem = true {
        if (hasItems)
            InsertMenuItem(CurrentLocations, "", unset, unset, unset) ; Separator

        menuText := g_pth_Settings.standardEntryPrefix "Paste path from clipboard"
        InsertMenuItem(CurrentLocations, menuText, "placeholder path text", A_WinDir . "\system32\imageres.dll", "-5301", false) ; Clipboard Placeholder entry. 'Path' won't be used so using placeholder text
        CurrentLocations.Disable(currentMenuNum "&")
        hasItems := true ; Still show the menu item even if clipboard is empty, if the user has set it to always show clipboard item
    }

    RemoveToolTip() {
        SetTimer(RemoveToolTip, 0)
        ToolTip()
    }

    ; Show menu if we have items, otherwise show tooltip
    if (hasItems) {
        CurrentLocations.Show()
    } else {
        ToolTip("No folders open")
        SetTimer(RemoveToolTip, 1000)
    }

    ; Clean up
    CurrentLocations := ""
}

; Callback function to navigate to a path. The first 3 parameters are provided by the .Add method of the Menu object
; The other two parameters must be provided using .Bind when specifying this function as a callback!
PathSelector_Navigate(ThisMenuItemName, ThisMenuItemPos, MyMenu, f_path, windowClass, windowID) {
    ; ------------------------- LOCAL FUNCTIONS -------------------------
    NavigateDialog(path, windowHwnd, dialogInfo) {
        if (dialogInfo.Type = "HasEditControl") {
            ; Send the path to the edit control text box using SendMessage
            DllCall("SendMessage", "Ptr", dialogInfo.ControlHwnd, "UInt", 0x000C, "Ptr", 0, "Str", path) ; 0xC is WM_SETTEXT - Sets the text of the text box
            ; Tell the dialog to accept the text box contents, which will cause it to navigate to the path
            DllCall("SendMessage", "Ptr", windowHwnd, "UInt", 0x0111, "Ptr", 0x1, "Ptr", 0) ; command ID (0x1) typically corresponds to the IDOK control which represents the primary action button, whether it's labeled "Save" or "Open".

        } else if (dialogInfo.Type = "FolderBrowserDialog") {
            NavigateLegacyFolderDialog(path, dialogInfo.ControlHwnd)
        }
    }

    DetectDialogType(hwnd) {
        ; Wait for the dialog window with class #32770 to be active
        if !WinWaitActive("ahk_class #32770", unset, 10) {
            return 0
        }

        ; Look for an "Edit1" control, which is typically the file name edit box in file dialogs
        try {
            hFileNameEdit := ControlGetHwnd("Edit1", "ahk_class #32770")
            return { Type: "HasEditControl", ControlHwnd: hFileNameEdit }
        } catch {
            ; Try to get the handle of the TreeView control
            try {
                hTreeView := ControlGetHwnd("SysTreeView321", "ahk_class #32770")
                return { Type: "FolderBrowserDialog", ControlHwnd: hTreeView }
            } catch {
                ; Neither control found
                return 0
            }
        }
    }
    ; ------------------------------------------------------------------------

    ; Return if there's nothing
    if (f_path = "")
        return

    if (windowClass = "#32770") ; It's a dialog
    {
        WinActivate("ahk_id " windowID)

        ; Check if it's a legacy dialog
        if (dialogInfo := DetectDialogType(windowID)) {
            ; Use the legacy navigation approach
            NavigateDialog(f_path, windowID, dialogInfo)
        } else {
            ; Use the existing modern dialog approach
            Send("!{d}")
            Sleep(50)
            addressbar := ControlGetFocus("a")
            ControlSetText(f_path, addressbar, "a")
            ControlSend("{Enter}", addressbar, "a")
            ControlFocus("Edit1", "a")
        }
        return
    } else if (windowClass = "ConsoleWindowClass") {
        WinActivate("ahk_id " windowID)
        SetKeyDelay(0)
        Send("{Esc}pushd " f_path "{Enter}")
        return
    }
}

NavigateLegacyFolderDialog(path, hTV) {
    ; Helper function to navigate to a node with the given text under the given parent item
    NavigateToNode(treeView, parentItem, nodeText, isDriveLetter := false) {
        ; Helper function to escape special regex characters in node text
        RegExEscape(str) {
            static chars := "[\^\$\.\|\?\*\+\(\)\{\}\[\]\\]"
            return RegExReplace(str, chars, "\$0")
        }

        treeView.Expand(parentItem, true)
        hItem := treeView.GetChild(parentItem)
        while (hItem) {
            itemText := treeView.GetText(hItem)
            if (isDriveLetter) {
                ; Special handling for drive letters. Look for them in parentheses, because they might show with name like "Primary (C:)"
                if (itemText ~= "i)\(" . RegExEscape(nodeText) . "\)") {
                    ; Found the drive
                    return hItem
                }
            } else {
                ; Regular matching for other nodes
                if (itemText ~= "i)^" . RegExEscape(nodeText) . "(\s|$)") {
                    ; Found the item
                    return hItem
                }
            }
            hItem := treeView.GetNext(hItem)
        }
        return 0
    }

    ; -------------------------------------------------------------

    ; Initialize variables
    networkPath := ""
    driveLetter := ""
    hItem := ""

    ; Create RemoteTreeView object
    myTreeView := RemoteTreeView(hTV)

    ; Wait for the TreeView to load
    myTreeView.Wait()

    ; Split the path into components
    pathComponents := StrSplit(path, "\")
    ; Remove empty components caused by leading backslashes
    while (pathComponents.Length > 0 && pathComponents[1] = "") {
        pathComponents.RemoveAt(1)
    }

    ; Handle network paths starting with "\\"
    if (SubStr(path, 1, 2) = "\\") {
        networkPath := "\\" . pathComponents.RemoveAt(1)
        if pathComponents.Length > 0 {
            networkPath .= "\" . pathComponents.RemoveAt(1)
        }
    }

    ; Start from the "This PC" node (adjust for different Windows versions)
    startingNodes := ["This PC", "Computer", "My Computer", "Desktop"]
    for name in startingNodes {
        if (hItem := myTreeView.GetHandleByText(name)) {
            break
        }
    }
    if !hItem {
        MsgBox("Could not find a starting node like 'This PC' in the TreeView.")
        return
    }

    ; Expand the starting node
    myTreeView.Expand(hItem, true)

    ; If it's a network path
    if (networkPath != "") {
        ; Navigate to the network location
        hItem := NavigateToNode(myTreeView, hItem, networkPath)
        if !hItem {
            MsgBox("Could not find network path '" . networkPath . "' in the TreeView.")
            return
        }
    } else if (pathComponents.Length > 0 && pathComponents[1] ~= "^[A-Za-z]:$") {
        ; Handle drive letters
        driveLetter := pathComponents.RemoveAt(1)
        hItem := NavigateToNode(myTreeView, hItem, driveLetter, true) ; Pass true to indicate drive letter
        if !hItem {
            MsgBox("Could not find drive '" . driveLetter . "' in the TreeView.")
            return
        }
    } else {
        ; If path starts from a folder under starting node
        ; No action needed
    }

    ; Now navigate through the remaining components
    for component in pathComponents {
        hItem := NavigateToNode(myTreeView, hItem, component)
        if !hItem {
            MsgBox("Could not find folder '" . component . "' in the TreeView.")
            return
        }
    }

    ; Select the final item
    myTreeView.SetSelection(hItem, false)
    ; Optionally, send Enter to confirm selection
    ; Send("{Enter}")
}

; ----------------------------------------------------------------------------------------------
; ---------------------------------------- GUI-RELATED  ----------------------------------------
; ----------------------------------------------------------------------------------------------

; Function to show the settings GUI
ShowPathSelectorSettingsGUI(*) {
    ; Create the settings window
    settingsGui := Gui("+Resize", g_pathSelector_programName " - Settings")
    settingsGui.OnEvent("Size", GuiResize)
    settingsGui.SetFont("s10", "Segoe UI")

    hTT := CreateTooltipControl(settingsGui.Hwnd)

    ; Add controls - using current values from global variables
    labelHotkey := settingsGui.AddText("xm y10 w120 h23 +0x200", "Menu Hotkey:")
    hotkeyEdit := settingsGui.AddEdit("x+10 yp w200", g_pth_Settings.dialogMenuHotkey)
    hotkeyEdit.SetFont("s12", "Consolas")
    labelhotkeyTooltipText := "Enter the key or key combination that will trigger the dialog menu (Using AutoHotkey V2 syntax)`n`nSee `"Help`" menu for link to documentation about key names."
    labelhotkeyTooltipText .= "`n`nTip: Add a tilde (~) before the key to ensure the hotkey doesn't block the key's normal functionality.`nExample:  ~MButton"
    AddTooltipToControl(hTT, labelHotkey.Hwnd, labelhotkeyTooltipText)
    AddTooltipToControl(hTT, hotkeyEdit.Hwnd, labelhotkeyTooltipText)

    labelOpusRTPath := settingsGui.AddText("xm y+10 w120 h23 +0x200", "DOpus RT Path:")
    dopusPathEdit := settingsGui.AddEdit("x+10 yp w200 h30 -Multi -Wrap", g_pth_Settings.dopusRTPath) ; Setting explicit height and -Multi because for some reason it was wrapping the control box down. Not sure if -Wrap is necessary
    labelOpusRTPathTooltipText := "*** For Directory Opus users *** `nPath to dopusrt.exe`n`nOr leave empty to disable Directory Opus integration."
    AddTooltipToControl(hTT, labelOpusRTPath.Hwnd, labelOpusRTPathTooltipText)
    AddTooltipToControl(hTT, dopusPathEdit.Hwnd, labelOpusRTPathTooltipText)
    ; Button to browse for DOpusRT
    browseBtn := settingsGui.AddButton("x+5 yp w60", "Browse...")
    browseBtn.OnEvent("Click", (*) => BrowseForDopusRT(dopusPathEdit))

    labelActiveTabPrefix := settingsGui.AddText("xm y+10 w120 h23 +0x200", "Active Tab Prefix:")
    prefixEdit := settingsGui.AddEdit("x+10 yp w200", g_pth_Settings.activeTabPrefix)
    labelActiveTabPrefixTooltipText := "Text/Characters that appears to the left of the active path for each window group"
    AddTooltipToControl(hTT, labelActiveTabPrefix.Hwnd, labelActiveTabPrefixTooltipText)
    AddTooltipToControl(hTT, prefixEdit.Hwnd, labelActiveTabPrefixTooltipText)

    labelStandardEntryPrefix := settingsGui.AddText("xm y+10 w120 h23 +0x200", "Non-Active Prefix:")
    standardPrefixEdit := settingsGui.AddEdit("x+10 yp w200", g_pth_Settings.standardEntryPrefix)
    labelStandardEntryPrefixTooltipText := "Indentation spaces for inactive tabs, so they line up"
    AddTooltipToControl(hTT, labelStandardEntryPrefix.Hwnd, labelStandardEntryPrefixTooltipText)
    AddTooltipToControl(hTT, standardPrefixEdit.Hwnd, labelStandardEntryPrefixTooltipText)

    labelDefaultPaths := settingsGui.AddText("xm y+10 w120 h23 +0x200", "Default Paths:")
    DefaultPathsEdit := settingsGui.AddEdit("x+10 yp w200", g_pth_Settings.defaultPaths)
    labelDefaultPathsTooltipText := "Semicolon (;) seperated list of default Paths"
    AddTooltipToControl(hTT, labelDefaultPaths.Hwnd, labelDefaultPathsTooltipText)
    AddTooltipToControl(hTT, DefaultPathsEdit.Hwnd, labelDefaultPathsTooltipText)

    ; labelActiveTabSuffix := settingsGui.AddText("xm y+10 w120 h23 +0x200", "Active Tab Suffix:")
    ; suffixEdit := settingsGui.AddEdit("x+10 yp w200", g_settings.activeTabSuffix)
    ; labelActiveTabSuffixTooltipText := "Text/Characters will appear to the right of the active path for each window group, if you want as a label."
    ; AddTooltipToControl(hTT, labelActiveTabSuffix.Hwnd, labelActiveTabSuffixTooltipText)
    ; AddTooltipToControl(hTT, suffixEdit.Hwnd, labelActiveTabSuffixTooltipText)

    debugCheck := settingsGui.AddCheckbox("xm y+15", "Enable Debug Mode")
    debugCheck.Value := g_pth_Settings.enableExplorerDialogMenuDebug
    labelDebugCheckTooltipText := "Show tooltips with debug information when the hotkey is pressed.`nUseful for troubleshooting."
    AddTooltipToControl(hTT, debugCheck.Hwnd, labelDebugCheckTooltipText)

    clipboardCheck := settingsGui.AddCheckbox("xm y+5", "Always Show Clipboard Menu Item")
    clipboardCheck.Value := g_pth_Settings.alwaysShowClipboardmenuItem
    labelClipboardCheckTooltipText := "If Disabled: The option to paste the clipboard path will only appear when a valid path is found on the clipboard.`nIf Enabled: The menu entry will always appear, but is disabled when no valid path is found."
    AddTooltipToControl(hTT, clipboardCheck.Hwnd, labelClipboardCheckTooltipText)

    UIAccessCheck := settingsGui.AddCheckbox("xm y+5", "Enable UI Access")
    UIAccessCheck.Value := g_pth_Settings.enableUIAccess
    labelUIAccessCheckTooltipText := ""
    if !ThisScriptRunningStandalone() or A_IsCompiled {
        UIAccessCheck.Value := 0
        UIAccessCheck.Enabled := 0

        ; Get position of the checkbox before disabling it so we can add an invisible box to apply the tooltip to
        ; Because the tooltip won't show on a disabled control
        x := 0, y := 0, w := 0, h := 0
        UIAccessCheck.GetPos(&x, &y, &w, &h)
        tooltipOverlay := settingsGui.AddText("x" x " y" y " w" w " h" h " +BackgroundTrans", "")

        if A_IsCompiled {
            labelUIAccessCheckTooltipText := "UI Access allows the script to work on dialogs run by elevated processes, without having to run as Admin itself."
            labelUIAccessCheckTooltipText .= "`nHowever this setting does not apply for the compiled Exe version of the script."
            labelUIAccessCheckTooltipText .= "`n`nInstead, you must put the exe in a `"trusted`" Windows location such as the `"C:\Program Files\...`" directory."
            labelUIAccessCheckTooltipText .= "`nYou do NOT need to run the exe as Admin for this to work."
        } else {
            labelUIAccessCheckTooltipText := "This script appears to be running as being included by another script. You should enable UI Access via the parent script instead."
        }
        AddTooltipToControl(hTT, tooltipOverlay.Hwnd, labelUIAccessCheckTooltipText)
    } else {
        labelUIAccessCheckTooltipText := "Enable `"UI Access`" to allow the script to run in elevated windows protected by UAC without running as admin."
        AddTooltipToControl(hTT, UIAccessCheck.Hwnd, labelUIAccessCheckTooltipText)
    }

    ; Add divider line to the next checkboxes because they aren't persistent settings
    checkBoxDivider := settingsGui.AddText("xm y+15 h2 w150 0x10")

    ; Add checkbox for whether to keep the settings window open after saving
    keepOpenCheck := settingsGui.AddCheckbox("xm y+10", "Keep This Window Open After Saving")
    keepOpenCheck.SetFont("s9") ; Smaller font for this checkbox
    keepOpenCheck.Value := false ; False by default - This isn't a saved setting, just a temporary preference
    keepOpenCheck.OnEvent("Click", (*) => ToggleAlwaysOnTopCheckVisibility(keepOpenCheck.Value))
    labelKeepOpenCheckTooltipText := "Keep this window open after saving the settings.`nGood for experimenting with different settings.`n`n(Note: This checkbox setting is not saved.)"
    AddTooltipToControl(hTT, keepOpenCheck.Hwnd, labelKeepOpenCheckTooltipText)
    ; Checkbox for whether to keep the window on top always. Hidden by default and shown only if keepOpenCheck is checked
    keepOnTopCheck := settingsGui.AddCheckbox("xm y+5 +Hidden1", "Keep This Window Always On Top") ; +Hidden hides by default, but setting +Hidden1 to make it explicitly hidden
    keepOnTopCheck.SetFont("s9") ; Smaller font for this checkbox
    keepOnTopCheck.Value := false ; False by default - This isn't a saved setting, just a temporary preference
    keepOnTopCheck.OnEvent("Click", (*) => SetSettingsWindowAlwaysOnTop(keepOnTopCheck.Value))
    labelKeepOnTopCheckTooltipText := "Keep this window always on top of other windows.`nGood for keeping it visible while testing settings.`n`n(Note: This checkbox setting is not saved.)"
    AddTooltipToControl(hTT, keepOnTopCheck.Hwnd, labelKeepOnTopCheckTooltipText)

    ; Add buttons at the bottom - See positioning cheatsheet: https://www.reddit.com/r/AutoHotkey/comments/1968fq0/a_cheatsheet_for_building_guis_using_relative/
    buttonsY := "y+20"
    ; Reset button
    resetBtn := settingsGui.AddButton("xm " buttonsY " w80", "Defaults")
    resetBtn.OnEvent("Click", ResetSettings)
    settingsGui.AddButton("x+10 yp w80", "Cancel").OnEvent("Click", (*) => settingsGui.Destroy())
    labelButtonResetTooltipText := "Sets all settings above to their default values.`nYou'll still need to click Save to apply the changes."
    AddTooltipToControl(hTT, resetBtn.Hwnd, labelButtonResetTooltipText)
    ; Save button
    saveBtn := settingsGui.AddButton("x+10 yp w80 Default", "Save")
    saveBtn.OnEvent("Click", SaveSettings)
    labelButtonSaveTooltipText := "Save the current settings to a file to automatically load in the future."
    AddTooltipToControl(hTT, saveBtn.Hwnd, labelButtonSaveTooltipText)
    ; Help button
    helpBtn := settingsGui.AddButton("x+10 w70", "Help")
    helpBtn.OnEvent("Click", ShowPathSelectorHelpWindow)
    ; Smaller About button above the help button
    aboutBtn := settingsGui.AddButton("xp+0 yp-25 w70 h25", "About") ; These positions aren't right, but we'll fix them in the resize function
    aboutBtn.OnEvent("Click", ShowPathSelectorAboutWindow)

    ; Set variables to track when certain settings are changed for special handling.
    ; Setting this as a function so it can be called again if saving settings without closing the window
    UIAccessInitialValue := ""
    HotkeyInitialValue := ""
    RecordInitialValuesFromGlobalSettings() {
        UIAccessInitialValue := g_pth_Settings.enableUIAccess
        HotkeyInitialValue := g_pth_Settings.dialogMenuHotkey
    }
    RecordInitialValuesFromGlobalSettings()

    ; Show the GUI
    settingsGui.Show()

    ResetSettings(*) {
        hotkeyEdit.Value := pathSelector_DefaultSettings.dialogMenuHotkey
        dopusPathEdit.Value := pathSelector_DefaultSettings.dopusRTPath
        prefixEdit.Value := pathSelector_DefaultSettings.activeTabPrefix
        ;suffixEdit.Value := DefaultSettings.activeTabSuffix
        standardPrefixEdit.Value := pathSelector_DefaultSettings.standardEntryPrefix
        debugCheck.Value := pathSelector_DefaultSettings.enableExplorerDialogMenuDebug
        clipboardCheck.Value := pathSelector_DefaultSettings.alwaysShowClipboardmenuItem
        UIAccessCheck.Value := pathSelector_DefaultSettings.enableUIAccess
        DefaultPathsEdit.Value := pathSelector_DefaultSettings.defaultPaths
    }

    SaveSettings(*) {
        ; Update settings object
        g_pth_Settings.dialogMenuHotkey := hotkeyEdit.Value
        g_pth_Settings.dopusRTPath := dopusPathEdit.Value
        g_pth_Settings.activeTabPrefix := prefixEdit.Value
        ;g_settings.activeTabSuffix := suffixEdit.Value
        g_pth_Settings.standardEntryPrefix := standardPrefixEdit.Value
        g_pth_Settings.enableExplorerDialogMenuDebug := debugCheck.Value
        g_pth_Settings.alwaysShowClipboardmenuItem := clipboardCheck.Value
        g_pth_Settings.enableUIAccess := UIAccessCheck.Value
        g_pth_Settings.defaultPaths := DefaultPathsEdit.Value

        PathSelector_SaveSettingsToFile()

        ; When UI Access goes from enabled to disabled, the user must manually close and re-run the script
        if (UIAccessInitialValue = true && UIAccessCheck.Value = false) {
            MsgBox("NOTE: When changing UI Access from Enabled to Disabled, you must manually close and re-run the script/app for changes to take effect.", "Settings Saved - Process Restart Required", "Icon!")
        } else if (UIAccessInitialValue = false && UIAccessCheck.Value = true) {
            ; When enabling UI Access, we can reload the script to enable it. Ask the user if they want to do this now
            result := MsgBox("UI Access has been enabled. Do you want to restart the script now to apply the changes?", "Settings Saved - Process Restart Required", "YesNo Icon!")
            if (result = "Yes") {
                Reload()
            }
        }

        ; The rest of the settings don't require a restart, they are pulled directly from the settings object which has been updated

        ; Disable the original hotkey by passing in the previous hotkey string
        PathSelector_UpdateHotkey("", HotkeyInitialValue)

        ; At this point all settings have been saved and applied
        RecordInitialValuesFromGlobalSettings()

        if (keepOpenCheck.Value = false) {
            settingsGui.Destroy()
        }
    }

    GuiResize(thisGui, minMax, width, height) {
        if minMax = -1  ; The window has been minimized
            return

        ; Update control positions based on new window size
        for ctrl in thisGui {
            ; For specific control objects
            if ctrl = checkBoxDivider {
                ctrl.Move(unset, unset, width - 30)  ; Set width to fill the window
                continue
            }

            ; For certain control types
            if ctrl.HasProp("Type") {
                if ctrl.Type = "Edit" {
                    ; Leave space for the Browse button if this is the DOpus path edit box
                    if (ctrl.HasProp("ClassNN") && ctrl.ClassNN = "Edit2") {
                        ctrl.Move(unset, unset, width - 220)  ; Leave extra space for Browse button
                    } else {
                        ctrl.Move(unset, unset, width - 150)  ; Set consistent width for other edit boxes
                    }
                } else if ctrl.Type = "Button" {
                    if ctrl.Text = "Browse..." {
                        ctrl.Move(width - 70)  ; Anchor Browse button to right side window edge
                    } else if ctrl.Text = "Help" {
                        ctrl.Move(width-85, height-45)  ; Right align Help button with some margin
                    } else if ctrl.Text = "About" {
                        ; Align it with the Help button and go above it
                        ctrl.Move(width-85, height-75)
                    } else {
                        ctrl.Move(unset, height-45)  ; Bottom align buttons with 40px margin from bottom
                    }
                    ctrl.Redraw()
                }
            }
        }
    }

    SetSettingsWindowAlwaysOnTop(checkValue) {
        if (checkValue) {
            settingsGui.Opt("+AlwaysOnTop")
        } else {
            settingsGui.Opt("-AlwaysOnTop")
        }
    }

    ToggleAlwaysOnTopCheckVisibility(keepOpenCheckValue) {
        if (keepOpenCheckValue) {
            keepOnTopCheck.Visible := true
        } else {
            ; Hide the checkbox but only if it's not checked
            if !keepOnTopCheck.Value {
                keepOnTopCheck.Visible := false
            }
        }
    }
}

ShowPathSelectorHelpWindow(*) {
    ; Added MinSize to prevent window from becoming too small
    helpGui := Gui("+Resize +MinSize400x300", g_pathSelector_programName " - Help & Tips")
    helpGui.SetFont("s10", "Segoe UI")
    helpGui.OnEvent("Size", GuiResize)

    hTT := CreateTooltipControl(helpGui.Hwnd)

    ; Settings file info
    settingsFileDescription := helpGui.AddText("xm y+10 w300 h20", "Current config file path:") ; Creating this separately so we can set the font
    settingsFileDescription.SetFont("s10 bold")
    labelFileLocationText := ""
    labelFileLocationEdit := ""
    if g_pth_SettingsFile.usingSettingsFile {
        ; labelFileLocation := helpGui.AddText("xm y+0 w300 +Wrap", g_settingsFilePath)
        ; Show an edit text box so the user can copy the path and also so it word wraps properly even with no spaces
        labelFileLocationEdit := helpGui.AddEdit("xm y+5 w300 h30 +ReadOnly", g_pth_SettingsFile.filePath)
    } else {
        labelFileLocation := helpGui.AddText("xm y+0 w300 +Wrap", "N/A - Using default settings (no config file)")
    }

    ; AHK Key Names documentation link
    linkDescription := helpGui.AddText("xm y+20 w300 h20", "For information about key names in AutoHotkey, click here:") ; Creating this separately so we can set the font
    linkDescription.SetFont("s10 bold")
    linkText := '<a href="https://www.autohotkey.com/docs/v2/lib/Send.htm#keynames">https://www.autohotkey.com/docs/v2/lib/Send.htm</a>'
    keyNameLink := helpGui.AddLink("xm y+0 w300", linkText)

    ; Tips section
    tipsHeader := helpGui.AddText("xm y+20 w300 h20", "Tips:")
    tipsHeader.SetFont("s10 bold")

    ; Display info about UI Access depending on the mode the script is running in
    elevatedTipText := ""
    if A_IsCompiled {
        elevatedTipText := "• To make this program work with dialogs launched by elevated processes without having to run it as admin, place the executable in a trusted location such as `"C:\Program Files\...`""
        elevatedTipText .= "  (You do NOT need to run this exe itself as Admin for this to work.)"
    } else if !ThisScriptRunningStandalone() {
        elevatedTipText := "• To make this work with dialogs launched by elevated processes, enable UI Access via the parent script."
        elevatedTipText .= 'See this documentation page for more info:`n <a href="https://www.autohotkey.com/docs/v1/FAQ.htm#uac">https://www.autohotkey.com/docs/v1/FAQ.htm#uac</a>'
    } else {
        elevatedTipText := "• Enable `"UI Access`" setting to allow the script to work in dialogs from elevated windows without running this script itself as admin."
    }
    labelElevatedTip := helpGui.AddLink("xm y+5 w300", elevatedTipText)

    ; ------------------------------------------------------------------------
    closeButton := helpGui.AddButton("xm y+10 w80 Default", "Close")
    closeButton.OnEvent("Click", (*) => helpGui.Destroy())

    ; Show with specific initial size
    helpGui.Show("w500 h250")

    GuiResize(thisGui, minMax, width, height) {
        if minMax = -1  ; The window has been minimized
            return

        ; Update control positions based on new window size
        for ctrl in thisGui {
            if ctrl.HasProp("Type") {
                if ctrl.Type = "Text" or ctrl.Type = "Link" {
                    ctrl.Move(unset, unset, width - 25)  ; Add some margin to the right
                    ctrl.Redraw()
                } else if ctrl.Type = "Button" {
                    if ctrl.Text = "Close" {
                        ctrl.Move(unset, height - 40)  ; Bottom align Close button with 40px margin from bottom
                    }
                } else if ctrl.Type = "Edit" {
                    ctrl.Move(unset, unset, width - 25)  ; Add some margin to the right
                }
            }
        }
    }

    if (labelFileLocationEdit != "") {
        labelFileLocationEdit.Value := labelFileLocationEdit.Value ; This is hacky but it forces the edit box to update and show the text properly, before it was strangely shifted until clicked on
    }
    ; Default to focus on the close button. Doesn't really matter which control, just so it doesn't select the text in the edit box
    closeButton.Focus()
}

; Create a tooltip control window and return its handle
CreateTooltipControl(guiHwnd) {
    ; Create tooltip window
    static ICC_TAB_CLASSES := 0x8
    static CW_USEDEFAULT := 0x80000000
    static TTS_ALWAYSTIP := 0x01
    static TTS_NOPREFIX := 0x02
    static WS_POPUP := 0x80000000

    ; Initialize common controls
    INITCOMMONCONTROLSEX := Buffer(8, 0)
    NumPut("UInt", 8, "UInt", ICC_TAB_CLASSES, INITCOMMONCONTROLSEX)
    DllCall("comctl32\InitCommonControlsEx", "Ptr", INITCOMMONCONTROLSEX)

    ; Create tooltip window
    hTT := DllCall("CreateWindowEx", "UInt", 0
        , "Str", "tooltips_class32"
        , "Ptr", 0
        , "UInt", TTS_ALWAYSTIP | TTS_NOPREFIX | WS_POPUP
        , "Int", CW_USEDEFAULT
        , "Int", CW_USEDEFAULT
        , "Int", CW_USEDEFAULT
        , "Int", CW_USEDEFAULT
        , "Ptr", guiHwnd
        , "Ptr", 0
        , "Ptr", 0
        , "Ptr", 0
        , "Ptr")

    ; Set maximum width to enable word wrapping and newlines in tooltips
    static TTM_SETMAXTIPWIDTH := 0x418
    DllCall("SendMessage", "Ptr", hTT, "UInt", TTM_SETMAXTIPWIDTH, "Ptr", 0, "Ptr", 600)

    return hTT
}

; Add a tooltip to a control
AddTooltipToControl(hTT, controlHwnd, text) {
    ; TTM_ADDTOOLW - Unicode version only
    static TTM_ADDTOOL := 0x432
    ; Enum values used in TOOLINFO structure - See: https://learn.microsoft.com/en-us/windows/win32/api/commctrl/ns-commctrl-tttoolinfow
    static TTF_IDISHWND := 0x1
    static TTF_SUBCLASS := 0x10
    ; Static control style - See: https://learn.microsoft.com/en-us/windows/win32/controls/static-control-styles
    static SS_NOTIFY := 0x100
    static GWL_STYLE := -16 ; Used in SetWindowLongPtr: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowlongptrw

    ; Check if this is a static text control and add SS_NOTIFY style if needed
    className := Buffer(256)
    if DllCall("GetClassName", "Ptr", controlHwnd, "Ptr", className, "Int", 256) {
        if (StrGet(className) = "Static") {
            ; Get current style
            currentStyle := DllCall("GetWindowLongPtr", "Ptr", controlHwnd, "Int", GWL_STYLE, "Ptr")
            ; Add SS_NOTIFY if it's not already there
            if !(currentStyle & SS_NOTIFY)
                DllCall("SetWindowLongPtr", "Ptr", controlHwnd, "Int", GWL_STYLE, "Ptr", currentStyle | SS_NOTIFY)
        }
    }

    ; Create and populate TOOLINFO structure
    TOOLINFO := Buffer(A_PtrSize = 8 ? 72 : 44, 0)  ; Size differs between 32 and 64 bit

    ; Calculate size of TOOLINFO structure
    cbSize := A_PtrSize = 8 ? 72 : 44

    ; Populate TOOLINFO structure
    NumPut("UInt", cbSize, TOOLINFO, 0)   ; cbSize
    NumPut("UInt", TTF_IDISHWND | TTF_SUBCLASS, TOOLINFO, 4)   ; uFlags
    NumPut("Ptr",  controlHwnd,  TOOLINFO, A_PtrSize = 8 ? 16 : 12)  ; hwnd
    NumPut("Ptr",  controlHwnd,  TOOLINFO, A_PtrSize = 8 ? 24 : 16)  ; uId
    NumPut("Ptr",  StrPtr(text), TOOLINFO, A_PtrSize = 8 ? 48 : 36)  ; lpszText

    ; Add the tool
    result := DllCall("SendMessage", "Ptr", hTT, "UInt", TTM_ADDTOOL, "Ptr", 0, "Ptr", TOOLINFO)
    return result
}

BrowseForDopusRT(editControl) {
    selectedFile := FileSelect(3, unset, "Select dopusrt.exe", "Executable (*.exe)")
    if selectedFile
        editControl.Value := selectedFile
}

PathSelector_SaveSettingsToFile() {
    SaveToPath(settingsFileDir) {
        settingsFilePath := settingsFileDir "\" g_pth_SettingsFile.fileName

        fileAlreadyExisted := (FileExist(settingsFilePath) != "") ; If an empty string is returned from FileExist, the file was not found

        ; Create the necessary folders
        DirCreate(settingsFileDir)

        ; Save all settings to INI file
        IniWrite(g_pth_Settings.dialogMenuHotkey, settingsFilePath, "Settings", "dialogMenuHotkey")
        IniWrite(g_pth_Settings.dopusRTPath, settingsFilePath, "Settings", "dopusRTPath")
        ; Put quotes around the prefix and suffix values, otherwise spaces will be trimmed by the OS. The quotes will be removed when the values are read back in.
        IniWrite('"' g_pth_Settings.activeTabPrefix '"', settingsFilePath, "Settings", "activeTabPrefix")
        IniWrite('"' g_pth_Settings.activeTabSuffix '"', settingsFilePath, "Settings", "activeTabSuffix")
        IniWrite('"' g_pth_Settings.standardEntryPrefix '"', settingsFilePath, "Settings", "standardEntryPrefix")
        IniWrite(g_pth_Settings.enableExplorerDialogMenuDebug ? "1" : "0", settingsFilePath, "Settings", "enableExplorerDialogMenuDebug")
        IniWrite(g_pth_Settings.alwaysShowClipboardmenuItem ? "1" : "0", settingsFilePath, "Settings", "alwaysShowClipboardmenuItem")
        IniWrite(g_pth_Settings.enableUIAccess ? "1" : "0", settingsFilePath, "Settings", "enableUIAccess")
        IniWrite(g_pth_Settings.maxMenuLength, settingsFilePath, "Settings", "maxMenuLength")
        IniWrite(g_pth_Settings.defaultPaths, settingsFilePath, "Settings", "defaultPaths")

        g_pth_SettingsFile.usingSettingsFile := true

        if (!fileAlreadyExisted) {
            MsgBox("Settings saved to file:`n" g_pth_SettingsFile.fileName "`n`nIn Location:`n" settingsFilePath "`n`n Settings will be automatically loaded from file from now on.", "Settings File Created", "Iconi")
        }
    }

    ; Try saving to the current default settings path
    try {
        SaveToPath(g_pth_SettingsFile.directoryPath)
    } catch OSError as oErr {
        ; If it's error number 5, it's access denied, so try appdata path instead unless it's already the appdata path
        if (oErr.Number = 5 && g_pth_SettingsFile.filePath != g_pth_SettingsFile.appDataFilePath) {
            try {
                ; Try to save to AppData path
                SaveToPath(g_pth_SettingsFile.appDataDirectoryPath)
                g_pth_SettingsFile.filePath := g_pth_SettingsFile.appDataFilePath ; If successful, update the global settings file path
                g_pth_SettingsFile.directoryPath := g_pth_SettingsFile.appDataDirectoryPath
            } catch Error as innerErr {
                MsgBox("Error saving settings to file:`n" innerErr.Message "`n`nTried to save in: `n" g_pth_SettingsFile.appDataFilePath, "Error Saving Settings", "Icon!")
            }
        } else if (oErr.Number = 5) {
            MsgBox("Error saving settings to file:`n" oErr.Message "`n`nTried to save in: `n" g_pth_SettingsFile.filePath, "Error Saving Settings", "Icon!")
        }
    } catch {
        MsgBox("Error saving settings to file:`n" A_LastError "`n`nTried to save in: `n" g_pth_SettingsFile.filePath, "Error Saving Settings", "Icon!")
    }

}

PathSelector_LoadSettingsFromSettingsFilePath(settingsFilePath) {
    if FileExist(settingsFilePath) {
        ; Load each setting from the INI file
        g_pth_Settings.dialogMenuHotkey := IniRead(settingsFilePath, "Settings", "dialogMenuHotkey", pathSelector_DefaultSettings.dialogMenuHotkey)
        g_pth_Settings.dopusRTPath := IniRead(settingsFilePath, "Settings", "dopusRTPath", pathSelector_DefaultSettings.dopusRTPath)
        g_pth_Settings.activeTabPrefix := IniRead(settingsFilePath, "Settings", "activeTabPrefix", pathSelector_DefaultSettings.activeTabPrefix)
        g_pth_Settings.activeTabSuffix := IniRead(settingsFilePath, "Settings", "activeTabSuffix", pathSelector_DefaultSettings.activeTabSuffix)
        g_pth_Settings.standardEntryPrefix := IniRead(settingsFilePath, "Settings", "standardEntryPrefix", pathSelector_DefaultSettings.standardEntryPrefix)
        g_pth_Settings.enableExplorerDialogMenuDebug := IniRead(settingsFilePath, "Settings", "enableExplorerDialogMenuDebug", pathSelector_DefaultSettings.enableExplorerDialogMenuDebug)
        g_pth_Settings.alwaysShowClipboardmenuItem := IniRead(settingsFilePath, "Settings", "alwaysShowClipboardmenuItem", pathSelector_DefaultSettings.alwaysShowClipboardmenuItem)
        g_pth_Settings.enableUIAccess := IniRead(settingsFilePath, "Settings", "enableUIAccess", pathSelector_DefaultSettings.enableUIAccess)
        g_pth_settings.maxMenuLength := IniRead(settingsFilePath, "Settings", "maxMenuLength", pathSelector_DefaultSettings.maxMenuLength)
        g_pth_settings.defaultPaths := IniRead(settingsFilePath, "Settings", "defaultPaths", pathSelector_DefaultSettings.defaultPaths)

        ; Convert string boolean values to actual booleans
        g_pth_Settings.enableExplorerDialogMenuDebug := g_pth_Settings.enableExplorerDialogMenuDebug = "1"
        g_pth_Settings.alwaysShowClipboardmenuItem := g_pth_Settings.alwaysShowClipboardmenuItem = "1"
        g_pth_Settings.enableUIAccess := g_pth_Settings.enableUIAccess = "1"

        ; Convert to int where necessary
        g_pth_settings.maxMenuLength := g_pth_settings.maxMenuLength + 0

        g_pth_SettingsFile.usingSettingsFile := true
    } else {
        ; If no settings file exists, use defaults
        for k, v in pathSelector_DefaultSettings.OwnProps() {
            g_pth_Settings.%k% := pathSelector_DefaultSettings.%k%
        }
    }
}

ShowPathSelectorAboutWindow(*) {
    MsgBox(g_pathSelector_programName "`nVersion: " g_pathSelector_version "`n`nAuthor: ThioJoe`n`nProject Repository: https://github.com/ThioJoe/AHK-Scripts", "About", "Iconi")
}

; ---------------------------- SYSTEM TRAY MENU CUSTOMIZATION ----------------------------
PathSelector_SetupSystemTray(systemTraySettings) {
    settingsMenuItemName        := systemTraySettings.HasOwnProp("settingsMenuItemName")       ? systemTraySettings.settingsMenuItemName       : "Settings"
    showSettingsTrayMenuItem    := systemTraySettings.HasOwnProp("showSettingsTrayMenuItem")   ? systemTraySettings.showSettingsTrayMenuItem   : true
    forcePositionIndex          := systemTraySettings.HasOwnProp("forcePositionIndex")         ? systemTraySettings.forcePositionIndex         : false
    positionIndex               := systemTraySettings.HasOwnProp("positionIndex")              ? systemTraySettings.positionIndex              : 1
    addSeparatorBefore          := systemTraySettings.HasOwnProp("addSeparatorBefore")         ? systemTraySettings.addSeparatorBefore         : false
    addSeparatorAfter           := systemTraySettings.HasOwnProp("addSeparatorAfter")          ? systemTraySettings.addSeparatorAfter          : true
    alwaysDefaultItem           := systemTraySettings.HasOwnProp("alwaysDefaultItem")          ? systemTraySettings.alwaysDefaultItem          : false

    if (!showSettingsTrayMenuItem) {
        return
    }

    if (!forcePositionIndex) {
        if (ThisScriptRunningStandalone() or A_IsCompiled) {
            ; If it's running standalone or compiled, use the default position
        } else {
            ; If it's running as an included script, put it next so it goes after the parent script's menu items
            positionIndex := positionIndex + 1
        }
    }

    ; Uses the & symbol to indicate the 1-indexed position of the menu item
    if (addSeparatorBefore) {
        A_TrayMenu.Insert(positionIndex . "&", "")  ; Separator
        positionIndex := positionIndex + 1
    }

    A_TrayMenu.Insert(positionIndex . "&", settingsMenuItemName, ShowPathSelectorSettingsGUI)

    if (addSeparatorAfter) {
        A_TrayMenu.Insert((positionIndex + 1) . "&", "")  ; Separator - Comment/Uncomment if you want to add a separator or not
    }

    ; If the script is compiled or running standalone, make the settings the default menu item
    if (ThisScriptRunningStandalone() or A_IsCompiled or alwaysDefaultItem) {
        A_TrayMenu.Default := settingsMenuItemName
    }
}
